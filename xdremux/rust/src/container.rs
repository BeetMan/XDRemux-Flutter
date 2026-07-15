
// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Parsed result of container extraction.
#[derive(Debug, Clone)]
pub struct ExtractedLhdr {
    pub mode: String,                  // "lhdr" or "uhdr"
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

// ---------------------------------------------------------------------------
// Extension region discovery
// ---------------------------------------------------------------------------

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
fn find_extension_start(data: &[u8]) -> Result<usize, String> {
    for marker in QTI_MARKERS {
        if let Some(pos) = data.windows(marker.len()).position(|w| w == *marker) {
            if pos >= 4 {
                let box_start = pos - 4;
                let box_size = read_u32_be(data, box_start) as usize;
                return Ok(box_start + box_size);
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
                    name = Some(std::str::from_utf8(&bytes[val_start..val_end]).ok()?.to_string());
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
fn extract_lhdr_meta_float144(data: &[u8]) -> Option<(Vec<u8>, Vec<f32>)> {
    let mut best: Option<(Vec<u8>, Vec<f32>)> = None;
    let mut best_sc = 0;
    let mut off = 0;

    while let Some(hit) = data[off..]
        .windows(4)
        .position(|w| w == FLOAT_144_BYTES)
    {
        let hit = off + hit;
        let start = hit.wrapping_sub(8);
        if start + 144 <= data.len() {
            let floats = bytes_to_f32s(&data[start..start + 144]);
            if floats.len() == 36 {
                let sc = score_lhdr_meta(&floats);
                if sc > best_sc {
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
    u32::from_be_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
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
        data.extend_from_slice(b"QTI Debug");            // offset 4-13: marker
        data.extend_from_slice(&[0xAAu8; 100]);          // extension content

        // find_extension_start finds "QTI Debug" at pos=4, reads size from pos-4=0,
        // returns pos-4 + size = 0 + 154
        let ext_start = find_extension_start(&data).unwrap();
        assert_eq!(ext_start, ext_size as usize);
    }
}
