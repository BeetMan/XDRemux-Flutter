use std::fmt::Write;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Parsed result of container extraction.
#[derive(Debug, Clone)]
pub struct ExtractedLhdr {
    pub mode: String, // "lhdr" or "uhdr"
    pub meta_bytes: Vec<u8>,
    pub meta_floats: Vec<f32>,
    pub mask_data: Option<Vec<u8>>,
    pub gainmap_data: Option<Vec<u8>>,
    pub manifest_entries: Option<Vec<ManifestEntry>>,
}

#[derive(Debug, Clone)]
pub struct ManifestEntry {
    pub name: String,
    pub offset: u64,
    pub length: u64,
}

/// Family classification from the LHDR metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    /// Early LHDR generation (x6)
    X6,
    /// Modern UHDR / LHDR v3+ (x7)
    X7,
}

impl Family {
    pub fn as_str(&self) -> &'static str {
        match self {
            Family::X6 => "x6",
            Family::X7 => "x7",
        }
    }
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const QTI_MARKERS: &[&[u8]] = &[b"QTI Debug", b"QTI "];
const FLOAT_144_BYTES: [u8; 4] = 144.0_f32.to_le_bytes();

const JPEG_START: &[u8] = b"\xff\xd8\xff";
const JPEG_END: &[u8] = b"\xff\xd9";

const WATERMARK_AUXILIARY_ENTRY_NAMES: &[&str] = &[
    "color.space",
    "gr.effect.info",
    "master.mode.preset.info",
    "private.emptyspace",
];

const PORTRAIT_EDITING_ENTRY_NAMES: &[&str] = &[
    "crop.region",
    "front.depth",
    "front.depth.config",
    "front.hair.mask",
    "front.matter.info",
    "front.negevimg",
    "front.segment",
    "mesh.coord",
    "mesh.coord.config",
    "rear.depth",
    "rear.depth.config",
    "rear.spotlight",
    "src.image",
    "src.image.block",
];

const PRIVATE_UHDR_ENTRY_NAMES: &[&str] = &["local.uhdr.gainmap.data", "local.uhdr.gainmap.info"];

/// Policy controlling which OPPO camera-tail entries are copied to output.
/// Values 0 through 9 mirror upstream `OppoCameraTail`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OppoCameraTail {
    Off,
    Watermark,
    Compact,
    Preserve,
    PreserveWithoutPortrait,
    PreserveWithoutPortraitOrPrivateHdr,
    PreserveWithoutPrivateUhdr,
    PreserveWithoutPrivateHdr,
    PreserveNoUhdr,
    PreserveNoHdr,
}

impl OppoCameraTail {
    /// FFI value that asks the library to select the legacy-compatible default.
    pub const AUTOMATIC: u8 = u8::MAX;

    pub const fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Off),
            1 => Some(Self::Watermark),
            2 => Some(Self::Compact),
            3 => Some(Self::Preserve),
            4 => Some(Self::PreserveWithoutPortrait),
            5 => Some(Self::PreserveWithoutPortraitOrPrivateHdr),
            6 => Some(Self::PreserveWithoutPrivateUhdr),
            7 => Some(Self::PreserveWithoutPrivateHdr),
            8 => Some(Self::PreserveNoUhdr),
            9 => Some(Self::PreserveNoHdr),
            _ => None,
        }
    }

    /// Preserve the old default: clean ISO removes private HDR entries, while
    /// OPPO-compatible output retains the entire camera tail.
    pub const fn default_for_compat(oppo_compat: crate::exif::OppoCompat) -> Self {
        if oppo_compat.wants_oppo_compat() {
            Self::Preserve
        } else {
            Self::PreserveWithoutPrivateHdr
        }
    }

    pub const fn resolve(value: u8, oppo_compat: crate::exif::OppoCompat) -> Self {
        match Self::from_u8(value) {
            Some(mode) => mode,
            None => Self::default_for_compat(oppo_compat),
        }
    }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Extract LHDR or UHDR metadata and mask/gainmap from a HEIC file.
pub fn extract_lhdr(path: &str) -> Result<ExtractedLhdr, String> {
    let data = std::fs::read(path).map_err(|e| format!("cannot read input: {e}"))?;
    extract_lhdr_from_bytes(&data)
}

/// Extract from in-memory bytes (for testing and FFI).
pub fn extract_lhdr_from_bytes(data: &[u8]) -> Result<ExtractedLhdr, String> {
    let (ext_start, ext) = find_extension_region(data)?;

    let manifest = parse_manifest(&ext);

    // Check for UHDR entries first
    if let Some((entries, json_start, _json_end)) = &manifest {
        let info_entry = entries.iter().find(|e| e.name == "local.uhdr.gainmap.info");
        let data_entry = entries.iter().find(|e| e.name == "local.uhdr.gainmap.data");
        if let (Some(info), Some(data_e)) = (info_entry, data_entry) {
            let info_start = (*json_start as i64 - info.offset as i64) as usize;
            let info_end = info_start + info.length as usize;
            if info_end <= ext.len() {
                let info_bytes = &ext[info_start..info_end];
                let info_floats = bytes_to_f32s(info_bytes);
                if info_floats.len() >= 20 {
                    let data_start = (*json_start as i64 - data_e.offset as i64) as usize;
                    let data_end = data_start + data_e.length as usize;
                    let gainmap_bytes = if data_end <= ext.len() {
                        Some(ext[data_start..data_end].to_vec())
                    } else {
                        None
                    };
                    return Ok(ExtractedLhdr {
                        mode: "uhdr".into(),
                        meta_bytes: info_bytes.to_vec(),
                        meta_floats: info_floats,
                        mask_data: None,
                        gainmap_data: gainmap_bytes,
                        manifest_entries: Some(entries.clone()),
                    });
                }
            }
        }
    }

    // Try float144 scan
    let result = extract_lhdr_meta_float144(&ext)
        .or_else(|| {
            // Fallback: manifest-based extraction
            extract_lhdr_meta_manifest(if ext_start == 0 { data } else { &ext })
        })
        .ok_or_else(|| "Failed to locate LHDR metadata block".to_string())?;

    let (meta_bytes, floats) = result;

    // Extract mask JPEG
    let mask_data = if let Some((entries, json_start, _json_end)) = &manifest {
        entries
            .iter()
            .find(|e| e.name == "local.hdr.linear.mask")
            .and_then(|mask_entry| {
                let mask_start = (*json_start as i64 - mask_entry.offset as i64) as usize;
                let mask_end = mask_start + mask_entry.length as usize;
                if mask_end <= ext.len() {
                    Some(ext[mask_start..mask_end].to_vec())
                } else {
                    None
                }
            })
    } else {
        find_jpeg_in_data(&ext, None)
    };

    Ok(ExtractedLhdr {
        mode: "lhdr".into(),
        meta_bytes: meta_bytes.to_vec(),
        meta_floats: floats,
        mask_data,
        gainmap_data: None,
        manifest_entries: manifest.map(|m| m.0),
    })
}

/// Extract a named entry payload from the OPPO/FileExtendedContainer tail
/// manifest (e.g. "rear.depth", "rear.depth.config"). Payload offsets in the
/// manifest are relative to the manifest JSON start, counting backwards.
pub fn extract_tail_entry(data: &[u8], name: &str) -> Option<Vec<u8>> {
    let (_ext_start, ext) = find_extension_region(data).ok()?;
    let (entries, json_start, _json_end) = parse_manifest(ext)?;
    let entry = entries.iter().find(|e| e.name == name)?;
    let start = (json_start as i64 - entry.offset as i64) as usize;
    let end = start.checked_add(entry.length as usize)?;
    if end > ext.len() {
        return None;
    }
    Some(ext[start..end].to_vec())
}

/// List the tail entry names present in the manifest (diagnostics).
pub fn tail_entry_names(data: &[u8]) -> Vec<String> {
    let Ok((_ext_start, ext)) = find_extension_region(data) else {
        return Vec::new();
    };
    match parse_manifest(ext) {
        Some((entries, _, _)) => entries.into_iter().map(|e| e.name).collect(),
        None => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// Extension region discovery
// ---------------------------------------------------------------------------

/// Extract the complete OPPO/QTI/FileExtendedContainer tail bytes from a
/// source HEIC file. Returns `None` if no extension region is found.
///
/// The policy supports compact watermark-only tails, portrait-editing removal,
/// private-HDR removal, and full preservation. `Off` removes the tail.
pub fn get_oppo_tail(data: &[u8], policy: OppoCameraTail) -> Option<Vec<u8>> {
    let tail_start = find_qti_box_start(data)?;
    let raw_tail = &data[tail_start..];
    apply_oppo_tail_policy(raw_tail, policy)
}

/// Remove an existing OPPO/FileExtendedContainer footer from a returned
/// photo. The returned Apple file may already contain a stale footer, so a
/// writeback must never append a second competing manifest.
pub fn strip_oppo_tail(data: &[u8]) -> Vec<u8> {
    find_qti_box_start(data)
        .map(|start| data[..start].to_vec())
        .unwrap_or_else(|| data.to_vec())
}

/// Return whether the file contains the manifest entries used by OPPO's
/// visible watermark and its layout metadata.
pub fn has_watermark_entries(data: &[u8]) -> bool {
    tail_entry_names(data)
        .iter()
        .any(|name| name == "watermark" || name.starts_with("watermark."))
}

/// Find the start of the QTI box in the data. Returns the absolute offset
/// of the 4-byte size header preceding the QTI marker.
fn find_qti_box_start(data: &[u8]) -> Option<usize> {
    for marker in QTI_MARKERS {
        if let Some(pos) = data.windows(marker.len()).position(|w| w == *marker) {
            if pos >= 4 {
                return Some(pos - 4);
            }
        }
    }
    None
}

/// Apply a camera-tail policy to a raw source tail.
fn apply_oppo_tail_policy(tail: &[u8], policy: OppoCameraTail) -> Option<Vec<u8>> {
    match policy {
        OppoCameraTail::Off => return None,
        OppoCameraTail::Preserve => return Some(tail.to_vec()),
        OppoCameraTail::PreserveNoUhdr | OppoCameraTail::PreserveNoHdr => {
            return neutralize_oppo_tail_entries(tail, policy)
        }
        OppoCameraTail::Watermark
        | OppoCameraTail::Compact
        | OppoCameraTail::PreserveWithoutPortrait
        | OppoCameraTail::PreserveWithoutPortraitOrPrivateHdr
        | OppoCameraTail::PreserveWithoutPrivateUhdr
        | OppoCameraTail::PreserveWithoutPrivateHdr => {}
    }

    let (entries, json_start, _json_end) = parse_manifest(tail)?;
    let mut kept: Vec<(usize, &ManifestEntry)> = entries
        .iter()
        .filter(|entry| should_preserve_oppo_tail_entry(&entry.name, policy))
        .filter_map(|entry| {
            let source_start = json_start.checked_sub(entry.offset as usize)?;
            let source_end = source_start.checked_add(entry.length as usize)?;
            (source_end <= tail.len()).then_some((source_start, entry))
        })
        .collect();
    if kept.is_empty() {
        return None;
    }
    kept.sort_by_key(|(source_start, _)| *source_start);

    // Rebuild payload: kept entry bytes + new manifest + vendor footer.
    let mut payload = Vec::new();
    let mut offsets_from_start: Vec<usize> = Vec::new();
    for (source_start, entry) in &kept {
        let start_in_payload = payload.len();
        let end = source_start + entry.length as usize;
        payload.extend_from_slice(&tail[*source_start..end]);
        offsets_from_start.push(start_in_payload);
    }

    let payload_length = payload.len();
    // The manifest offset is measured backwards from its own start, matching
    // OPPO's `jsonStart - entry.offset` lookup convention.
    let mut manifest = String::from("[");
    for (i, (start_in_payload, (_, entry))) in offsets_from_start.iter().zip(&kept).enumerate() {
        if i > 0 {
            manifest.push(',');
        }
        let offset = payload_length - *start_in_payload;
        write!(
            &mut manifest,
            r#"{{"length":{},"name":"{}","offset":{},"version":1}}"#,
            entry.length, entry.name, offset
        )
        .unwrap();
    }
    manifest.push(']');
    let manifest_bytes = manifest.as_bytes();
    payload.extend_from_slice(manifest_bytes);
    payload.push(0); // null before footer

    // Footer is NUL + vendor tag + manifest length, just as in source tails.
    let footer_size = (manifest_bytes.len() + 9) as u32;
    payload.extend_from_slice(b"jxrs");
    payload.extend_from_slice(&footer_size.to_le_bytes());

    Some(payload)
}

fn neutralize_oppo_tail_entries(tail: &[u8], policy: OppoCameraTail) -> Option<Vec<u8>> {
    let (entries, json_start, json_end) = parse_manifest(tail)?;
    let mut result = tail.to_vec();
    for entry in entries {
        if !should_neutralize_oppo_tail_entry(&entry.name, policy) {
            continue;
        }
        let name_bytes = entry.name.as_bytes();
        let name_offset = result[json_start..json_end]
            .windows(name_bytes.len())
            .position(|window| window == name_bytes)?
            + json_start;
        result[name_offset] = b'x';
    }
    Some(result)
}

/// Mirror of upstream `shouldPreserveOppoCameraTailEntry`.
fn should_preserve_oppo_tail_entry(name: &str, policy: OppoCameraTail) -> bool {
    match policy {
        OppoCameraTail::Off => false,
        OppoCameraTail::Watermark => {
            name.starts_with("watermark.") || WATERMARK_AUXILIARY_ENTRY_NAMES.contains(&name)
        }
        OppoCameraTail::Compact => {
            should_preserve_oppo_tail_entry(name, OppoCameraTail::Watermark)
                || PORTRAIT_EDITING_ENTRY_NAMES.contains(&name)
                || matches!(name, "hdr.transform.data" | "src.local.hdr.linear.mask")
        }
        OppoCameraTail::PreserveWithoutPortrait => !PORTRAIT_EDITING_ENTRY_NAMES.contains(&name),
        OppoCameraTail::PreserveWithoutPortraitOrPrivateHdr => {
            !PORTRAIT_EDITING_ENTRY_NAMES.contains(&name) && !is_private_hdr_tail_entry(name)
        }
        OppoCameraTail::PreserveWithoutPrivateUhdr => !PRIVATE_UHDR_ENTRY_NAMES.contains(&name),
        OppoCameraTail::PreserveWithoutPrivateHdr => !is_private_hdr_tail_entry(name),
        OppoCameraTail::Preserve
        | OppoCameraTail::PreserveNoUhdr
        | OppoCameraTail::PreserveNoHdr => true,
    }
}

fn should_neutralize_oppo_tail_entry(name: &str, policy: OppoCameraTail) -> bool {
    match policy {
        OppoCameraTail::PreserveNoUhdr => PRIVATE_UHDR_ENTRY_NAMES.contains(&name),
        OppoCameraTail::PreserveNoHdr => is_private_hdr_tail_entry(name),
        _ => false,
    }
}

fn is_private_hdr_tail_entry(name: &str) -> bool {
    PRIVATE_UHDR_ENTRY_NAMES.contains(&name)
        || name.starts_with("hdr.")
        || name.starts_with("local.hdr.")
        || name.starts_with("src.local.hdr.")
}

/// Locate the OPPO extension region in the HEIC file.
///
/// Returns `(ext_start, extension_bytes)` where `ext_start` is the absolute
/// offset within `data` and `extension_bytes` is a slice of `data` starting
/// at that offset.
fn find_extension_region(data: &[u8]) -> Result<(usize, &[u8]), String> {
    // Try QTI marker first
    if let Ok(ext_start) = find_extension_start(data) {
        return Ok((ext_start, &data[ext_start..]));
    }

    // No QTI marker — locate container header by scanning backward
    let footer_pos = data.windows(6).position(|w| w == b"\x00jxrsq");

    if let Some(footer_pos) = footer_pos {
        let scan_start = footer_pos.saturating_sub(8192);
        let json_end = data[..footer_pos].iter().rposition(|&b| b == b']');
        if let Some(json_end) = json_end {
            if json_end >= scan_start {
                let json_start = data[..json_end].iter().rposition(|&b| b == b'[');
                if let Some(json_start) = json_start {
                    if json_start >= scan_start
                        && json_start + 1 < json_end
                        && data[json_start] == b'['
                        && data[json_start + 1] == b'{'
                    {
                        // Scan ISOBMFF boxes to find extension region
                        let known_types: &[&[u8]] = &[b"ftyp", b"meta", b"free", b"mdat", b"QTI "];
                        let mut pos = 0usize;
                        let ext_start = loop {
                            if pos + 8 > data.len() {
                                break 0usize;
                            }
                            let box_size = read_u32_be(data, pos) as usize;
                            let box_type = &data[pos + 4..pos + 8];
                            if box_size < 8 || pos + box_size > data.len() {
                                break 0;
                            }
                            if !known_types.contains(&box_type) {
                                break pos;
                            }
                            pos += box_size;
                        };
                        let ext = if ext_start > 0 && ext_start + 2168 < data.len() {
                            &data[ext_start + 2168..]
                        } else {
                            data
                        };
                        return Ok((ext_start, ext));
                    }
                }
            }
        }
    }

    // Last resort: treat whole file as extension region
    Ok((0, data))
}

/// Find the start of the OPPO extension region via QTI Debug marker.
///
/// The size header preceding the marker must be plausible (in-bounds and a
/// sensible box length); otherwise a `QTI ` sequence inside compressed or
/// embedded data (e.g. the HDR container in a camera JPEG) would be misread
/// as an extension header and produce an out-of-range slice.
fn find_extension_start(data: &[u8]) -> Result<usize, String> {
    for marker in QTI_MARKERS {
        if let Some(pos) = data.windows(marker.len()).position(|w| w == *marker) {
            if pos >= 4 {
                let box_start = pos - 4;
                let box_size = read_u32_be(data, box_start) as usize;
                if box_size >= 8
                    && box_size <= 100_000_000
                    && box_start
                        .checked_add(box_size)
                        .is_some_and(|end| end <= data.len())
                {
                    return Ok(box_start + box_size);
                }
            }
        }
    }
    Err("QTI extension marker not found".into())
}

// ---------------------------------------------------------------------------
// Manifest parsing
// ---------------------------------------------------------------------------

/// Parse JSON manifest from the extension region tail.
///
/// Returns `(entries, json_start_offset, json_end_offset)` or `None`.
fn parse_manifest(data: &[u8]) -> Option<(Vec<ManifestEntry>, usize, usize)> {
    let json_start = data.windows(2).rposition(|w| w == b"[{")?;
    let json_end = data[json_start..].iter().position(|&b| b == b']')? + json_start;

    let json_str = std::str::from_utf8(&data[json_start..=json_end]).ok()?;
    let entries = parse_manifest_json(json_str)?;

    Some((entries, json_start, json_end + 1))
}

/// Minimal JSON array-of-objects parser for the manifest format.
///
/// The manifest is always `[{"name":"...","offset":N,"length":N}, ...]`.
/// We parse it by hand to avoid a serde_json dependency at this stage.
fn parse_manifest_json(json: &str) -> Option<Vec<ManifestEntry>> {
    let json = json.trim();
    let inner = json.strip_prefix('[')?.strip_suffix(']')?.trim();
    if inner.is_empty() {
        return Some(Vec::new());
    }

    let mut entries = Vec::new();
    let mut depth = 0;
    let mut obj_start = 0;

    for (i, ch) in inner.char_indices() {
        match ch {
            '{' => {
                if depth == 0 {
                    obj_start = i;
                }
                depth += 1;
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let obj_str = &inner[obj_start..=i];
                    if let Some(entry) = parse_one_manifest_entry(obj_str) {
                        entries.push(entry);
                    }
                }
            }
            _ => {}
        }
    }

    Some(entries)
}

fn parse_one_manifest_entry(obj: &str) -> Option<ManifestEntry> {
    let mut name = None;
    let mut offset = None;
    let mut length = None;

    let mut pos = 0;
    let bytes = obj.as_bytes();

    while pos < bytes.len() {
        // Skip to next quote — break if no more keys to parse
        let next = bytes[pos..].iter().position(|&b| b == b'"');
        if next.is_none() {
            break;
        }
        pos = next.unwrap() + pos;
        let key_start = pos + 1;
        let key_end = bytes[key_start..].iter().position(|&b| b == b'"')? + key_start;
        let key = std::str::from_utf8(&bytes[key_start..key_end]).ok()?;
        pos = key_end + 1;

        // Skip colon
        pos = bytes[pos..].iter().position(|&b| b == b':')? + pos + 1;

        // Skip whitespace
        while pos < bytes.len() && bytes[pos].is_ascii_whitespace() {
            pos += 1;
        }

        match key {
            "name" => {
                if bytes[pos] == b'"' {
                    let val_start = pos + 1;
                    let val_end = bytes[val_start..].iter().position(|&b| b == b'"')? + val_start;
                    name = Some(
                        std::str::from_utf8(&bytes[val_start..val_end])
                            .ok()?
                            .to_string(),
                    );
                    pos = val_end + 1;
                }
            }
            "offset" | "length" => {
                let val_end = bytes[pos..]
                    .iter()
                    .position(|&b| b == b',' || b == b'}' || b == b']' || b.is_ascii_whitespace())
                    .unwrap_or(bytes.len() - pos);
                let val_str = std::str::from_utf8(&bytes[pos..pos + val_end]).ok()?;
                let val: u64 = val_str.parse().ok()?;
                if key == "offset" {
                    offset = Some(val);
                } else {
                    length = Some(val);
                }
                pos += val_end;
            }
            _ => {
                // Skip unknown values
                if bytes[pos] == b'"' {
                    let val_end = bytes[pos + 1..].iter().position(|&b| b == b'"')? + pos + 2;
                    pos = val_end;
                } else {
                    let val_end = bytes[pos..]
                        .iter()
                        .position(|&b| b == b',' || b == b'}')
                        .unwrap_or(bytes.len() - pos);
                    pos += val_end;
                }
            }
        }

        // Skip trailing comma
        while pos < bytes.len() && (bytes[pos].is_ascii_whitespace() || bytes[pos] == b',') {
            pos += 1;
        }
    }

    match (name, offset, length) {
        (Some(n), Some(o), Some(l)) => Some(ManifestEntry {
            name: n,
            offset: o,
            length: l,
        }),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// LHDR metadata extraction
// ---------------------------------------------------------------------------

/// Score a 36-float candidate for LHDR metadata validity.
fn score_lhdr_meta(floats: &[f32]) -> i32 {
    let mut score = 0;
    if (floats[2] - 144.0).abs() < 0.01 {
        score += 5;
    }
    if (floats[5] + 1.0).abs() < 0.01 {
        score += 3;
    }
    if (floats[18] - 10.0).abs() < 0.01 {
        score += 2;
    }
    if (floats[19] - 6.0).abs() < 0.01 {
        score += 2;
    }
    if (2.0..=5.0).contains(&floats[0]) {
        score += 2;
    }
    if (0.0..=2000.0).contains(&floats[29]) {
        score += 1;
    }
    score
}

/// Scan for 144-byte LHDR metadata block using the float144 sentinel.
///
/// Minimum plausibility score for a float144 LHDR metadata candidate.
///
/// A genuine OPPO LHDR block scores ~15: every field occupies its expected
/// range (f0 ≈ 2-5, f2 == 144, f5 == -1, f18 == 10, f19 == 6, f29 ∈ 0-2000).
/// A false positive in compressed data typically only matches f2 == 144
/// (the sentinel itself) and scores 5-6. Requiring 10 keeps the whole-file
/// fallback path from misclassifying plain HEICs as LHDR.
const MIN_FLOAT144_SCORE: i32 = 10;

fn extract_lhdr_meta_float144(data: &[u8]) -> Option<(Vec<u8>, Vec<f32>)> {
    let mut best: Option<(Vec<u8>, Vec<f32>)> = None;
    let mut best_sc = 0;
    let mut off = 0;

    while let Some(hit) = data[off..].windows(4).position(|w| w == FLOAT_144_BYTES) {
        let hit = off + hit;
        let start = hit.wrapping_sub(8);
        if start + 144 <= data.len() {
            let floats = bytes_to_f32s(&data[start..start + 144]);
            if floats.len() == 36 && plausible_lhdr_meta(&floats) {
                let sc = score_lhdr_meta(&floats);
                if sc >= MIN_FLOAT144_SCORE && sc > best_sc {
                    best_sc = sc;
                    best = Some((data[start..start + 144].to_vec(), floats));
                }
            }
        }
        off = hit + 1;
        if off >= data.len() {
            break;
        }
    }
    best
}

/// Reject a candidate whose fields contradict the LHDR block layout even if
/// individual scoring rules happen to match. `f5` is the first channel's
/// display-ratio-max; it is -1.0 in every known OPPO LHDR sample. Compressed
/// data that collides with the 144.0 sentinel almost never satisfies this,
/// so it acts as a second line of defense behind the score threshold.
fn plausible_lhdr_meta(floats: &[f32]) -> bool {
    if floats.len() < 36 {
        return false;
    }
    // f5 is the -1 sentinel that distinguishes genuine LHDR blocks; a
    // candidate lacking it is not OPPO LHDR.
    (floats[5] + 1.0).abs() < 0.01
}

/// Extract LHDR meta via manifest offset calculation.
fn extract_lhdr_meta_manifest(data: &[u8]) -> Option<(Vec<u8>, Vec<f32>)> {
    let (entries, json_start, _json_end) = parse_manifest(data)?;
    for entry in &entries {
        if entry.name == "local.hdr.meta.data" && entry.length >= 144 {
            let phys = json_start.checked_sub(entry.offset as usize)?;
            if phys + 144 <= data.len() {
                let floats = bytes_to_f32s(&data[phys..phys + 144]);
                if floats.len() == 36 && (2.0..=5.0).contains(&floats[0]) {
                    return Some((data[phys..phys + 144].to_vec(), floats));
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// JPEG scanner
// ---------------------------------------------------------------------------

/// Find a JPEG blob in raw bytes, optionally matching a target length.
fn find_jpeg_in_data(data: &[u8], target_length: Option<usize>) -> Option<Vec<u8>> {
    let mut pos = 0;
    while let Some(hit) = data[pos..].windows(3).position(|w| w == JPEG_START) {
        let hit = pos + hit;
        let search_start = hit + 3;
        if let Some(end_rel) = data[search_start..].windows(2).position(|w| w == JPEG_END) {
            let end = search_start + end_rel + 2;
            let blob = &data[hit..end];
            if let Some(target) = target_length {
                if blob.len().abs_diff(target) < 64 {
                    return Some(blob.to_vec());
                }
                pos = end;
            } else {
                return Some(blob.to_vec());
            }
        } else {
            pos = hit + 1;
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read a big-endian u32 at `offset`.
fn read_u32_be(data: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
    ])
}

/// Interpret a byte slice as little-endian f32 values.
fn bytes_to_f32s(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a synthetic buffer that exercises container extraction via the
    /// no-QTI-marker fallback path (ext = entire data).
    ///
    /// Layout: [meta_bytes:144]["PADDING":7][manifest_json]
    /// No QTI marker — the function falls through to using the entire buffer
    /// as the extension region, then finds LHDR via manifest offset.
    fn make_synthetic_ext(meta_bytes: &[u8; 144], manifest_json: &str) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(meta_bytes);
        data.extend_from_slice(b"PADDING");
        data.extend_from_slice(manifest_json.as_bytes());
        data
    }

    #[test]
    fn extract_lhdr_from_synthetic() {
        let mut floats = [0.0f32; 36];
        floats[0] = 3.5;
        floats[2] = 144.0;
        floats[5] = -1.0;
        floats[18] = 10.0;
        floats[19] = 6.0;
        floats[29] = 500.0;
        floats[32] = 30000.0;

        let meta_bytes: [u8; 144] = std::array::from_fn(|i| {
            let float_idx = i / 4;
            let byte_idx = i % 4;
            floats[float_idx].to_le_bytes()[byte_idx]
        });

        // manifest offset = distance from json_start backward to meta start
        // json_start = meta_bytes.len() + b"PADDING".len() = 144 + 7 = 151
        let json_start: u64 = 151;
        let manifest_json = format!(
            r#"[{{"name":"local.hdr.meta.data","offset":{},"length":144}}]"#,
            json_start
        );

        let data = make_synthetic_ext(&meta_bytes, &manifest_json);
        let result = extract_lhdr_from_bytes(&data).unwrap();

        assert_eq!(result.mode, "lhdr");
        assert_eq!(result.meta_floats.len(), 36);
        assert!((result.meta_floats[0] - 3.5).abs() < 0.001);
        assert!((result.meta_floats[32] - 30000.0).abs() < 0.1);
    }

    #[test]
    fn float144_rejects_plain_heic_false_positive() {
        // A candidate matching only the 144.0 sentinel (score 5) with a
        // nonsensical f5 must be rejected — this is what a plain HEIC's
        // compressed data produces when the whole file is scanned.
        let mut floats = [0.0f32; 36];
        floats[2] = 144.0; // sentinel hit
        // f0, f5, f18, f19, f29 all left at garbage defaults
        assert!(!plausible_lhdr_meta(&floats));
        assert!(score_lhdr_meta(&floats) < MIN_FLOAT144_SCORE);

        // A genuine block still passes.
        floats[0] = 3.5;
        floats[5] = -1.0;
        floats[18] = 10.0;
        floats[19] = 6.0;
        floats[29] = 500.0;
        assert!(plausible_lhdr_meta(&floats));
        assert!(score_lhdr_meta(&floats) >= MIN_FLOAT144_SCORE);
    }

    #[test]
    fn find_jpeg_soi_eoi() {
        let mut data = vec![0u8; 100];
        data[10..13].copy_from_slice(b"\xff\xd8\xff");
        data[50..52].copy_from_slice(b"\xff\xd9");
        let result = find_jpeg_in_data(&data, None);
        assert!(result.is_some());
        let blob = result.unwrap();
        assert!(blob.starts_with(b"\xff\xd8\xff"));
        assert!(blob.ends_with(b"\xff\xd9"));
    }

    #[test]
    fn find_qti_debug_marker() {
        // Real ProXDR files have: [extension_size:4]["QTI Debug":9][content...]
        // The 4 bytes before the marker are the raw extension size (big-endian u32),
        // not an ISOBMFF box header. So pos - 4 = size field, pos = marker.
        let ext_size: u32 = 154;
        let mut data = Vec::new();
        data.extend_from_slice(&ext_size.to_be_bytes()); // offset 0-4: size
        data.extend_from_slice(b"QTI Debug"); // offset 4-13: marker
        data.extend_from_slice(&[0xAAu8; 200]); // extension content (≥ size)

        // find_extension_start finds "QTI Debug" at pos=4, reads size from pos-4=0,
        // returns pos-4 + size = 0 + 154
        let ext_start = find_extension_start(&data).unwrap();
        assert_eq!(ext_start, ext_size as usize);
    }

    #[test]
    fn find_qti_rejects_bogus_size_header() {
        // A `QTI ` sequence inside compressed/embedded data whose preceding
        // 4 bytes are not a plausible box size must be ignored, not treated
        // as an extension header (previously caused out-of-range slicing on
        // camera JPEGs that embed an Ultra HDR container).
        let mut data = Vec::new();
        data.extend_from_slice(&0xFFFF_FFFFu32.to_be_bytes());
        data.extend_from_slice(b"QTI Debug");
        data.extend_from_slice(&[0xAAu8; 32]);
        assert!(find_extension_start(&data).is_err());

        // Sanity: the valid form still resolves.
        let mut valid = Vec::new();
        valid.extend_from_slice(&60u32.to_be_bytes());
        valid.extend_from_slice(b"QTI Debug");
        valid.extend_from_slice(&[0xAAu8; 100]);
        assert_eq!(find_extension_start(&valid).unwrap(), 60);
    }

    fn make_manifest_tail(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut payload = Vec::new();
        let mut positions = Vec::new();
        for (_, bytes) in entries {
            positions.push(payload.len());
            payload.extend_from_slice(bytes);
        }
        let payload_len = payload.len();
        let mut manifest = String::from("[");
        for (index, ((name, bytes), start)) in entries.iter().zip(&positions).enumerate() {
            if index > 0 {
                manifest.push(',');
            }
            write!(
                &mut manifest,
                r#"{{"length":{},"name":"{}","offset":{},"version":1}}"#,
                bytes.len(),
                name,
                payload_len - start,
            )
            .unwrap();
        }
        manifest.push(']');
        payload.extend_from_slice(manifest.as_bytes());
        payload.push(0);
        payload.extend_from_slice(b"jxrs");
        payload.extend_from_slice(&((manifest.len() + 9) as u32).to_le_bytes());
        payload
    }

    fn manifest_names(tail: &[u8]) -> Vec<String> {
        parse_manifest(tail)
            .unwrap()
            .0
            .into_iter()
            .map(|entry| entry.name)
            .collect()
    }

    #[test]
    fn camera_tail_policies_select_watermark_compact_and_non_portrait_entries() {
        let tail = make_manifest_tail(&[
            ("watermark.text", b"w"),
            ("color.space", b"c"),
            ("front.depth", b"d"),
            ("hdr.transform.data", b"t"),
            ("local.uhdr.gainmap.data", b"u"),
            ("camera.params", b"p"),
        ]);

        assert_eq!(
            manifest_names(
                &apply_oppo_tail_policy(&tail, OppoCameraTail::Watermark).expect("watermark tail"),
            ),
            vec!["watermark.text", "color.space"],
        );
        assert_eq!(
            manifest_names(
                &apply_oppo_tail_policy(&tail, OppoCameraTail::Compact).expect("compact tail"),
            ),
            vec![
                "watermark.text",
                "color.space",
                "front.depth",
                "hdr.transform.data"
            ],
        );
        let without_portrait = manifest_names(
            &apply_oppo_tail_policy(&tail, OppoCameraTail::PreserveWithoutPortrait)
                .expect("non-portrait tail"),
        );
        assert!(!without_portrait.contains(&"front.depth".to_string()));
        assert!(without_portrait.contains(&"local.uhdr.gainmap.data".to_string()));
        assert!(without_portrait.contains(&"camera.params".to_string()));
    }

    #[test]
    fn filtered_tail_manifest_offsets_remain_readable() {
        let tail = make_manifest_tail(&[
            ("camera.params", b"first"),
            ("local.hdr.meta.data", b"discard"),
            ("watermark.text", b"last"),
        ]);
        let filtered = apply_oppo_tail_policy(&tail, OppoCameraTail::PreserveWithoutPrivateHdr)
            .expect("filtered tail");
        let (entries, json_start, _) = parse_manifest(&filtered).expect("rebuilt manifest");
        assert_eq!(entries.len(), 2);
        for entry in entries {
            let start = json_start - entry.offset as usize;
            let end = start + entry.length as usize;
            assert!(
                end <= filtered.len(),
                "{} must point inside the tail",
                entry.name
            );
        }
    }

    #[test]
    fn no_hdr_policy_neutralizes_manifest_names_in_place() {
        let tail = make_manifest_tail(&[
            ("local.uhdr.gainmap.data", b"u"),
            ("hdr.transform.data", b"h"),
            ("camera.params", b"p"),
        ]);
        let neutralized =
            apply_oppo_tail_policy(&tail, OppoCameraTail::PreserveNoHdr).expect("neutralized tail");
        let names = manifest_names(&neutralized);
        assert!(!names.iter().any(|name| name == "local.uhdr.gainmap.data"));
        assert!(!names.iter().any(|name| name == "hdr.transform.data"));
        assert!(names.iter().any(|name| name == "camera.params"));
    }
}
