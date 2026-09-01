//! Cross-platform Android/OPPO Motion Photo parsing.
//!
//! Ported from upstream XDRemux v1.4 `xdremux_py/motion_photo.py` (MIT,
//! 21Z121Z1/XDRemux). Understands Android Motion Photo V1 (XMP
//! `Container:Directory`), legacy MicroVideo, HEIF `mpvd` payloads, and the
//! OPPO LPEX extensions used by ColorOS 15/16.
//!
//! Everything works on in-memory bytes; the photo files we handle are at most
//! a few tens of MB and the rest of the pipeline already buffers whole files.

use serde_json::json;

const MAX_XMP_SCAN_BYTES: usize = 4 * 1024 * 1024;
const MAX_DIRECTORY_ITEMS: usize = 64;
const MAX_METADATA_STRING: usize = 4096;
const MAX_LPEX_JSON_BYTES: usize = 256 * 1024;
const MAX_VENDOR_TAIL_SCAN_BYTES: u64 = 512 * 1024 * 1024;

/// Checked half-open byte range `[start, end)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

impl ByteRange {
    pub fn new(start: u64, end: u64) -> Result<Self, String> {
        if end < start {
            return Err("invalid Motion Photo byte range".into());
        }
        Ok(Self { start, end })
    }
    pub fn length(self) -> u64 {
        self.end - self.start
    }
}

/// One entry of the XMP `Container:Directory`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MotionPhotoItem {
    pub mime: String,
    pub semantic: String,
    pub length: u64,
    pub padding: u64,
}

/// OPPO LPEX vendor metadata (ColorOS Live Photo extensions).
#[derive(Debug, Clone, Default)]
pub struct OppoMetadata {
    pub cover_frame_pts_us: Option<i64>,
    pub version: i64,
    pub matrix_count: i64,
    pub video_width: Option<u32>,
    pub video_height: Option<u32>,
    pub origin_photo_width: Option<u32>,
    pub origin_photo_height: Option<u32>,
    pub photo_crop_factor: Option<f64>,
    pub stream_count: u32,
    /// ColorOS 16+ still-image crop/EIS homographies (row-major 3x3).
    pub photo_crop_matrix: Option<[f64; 9]>,
    pub photo_eis_matrix: Option<[f64; 9]>,
    /// ColorOS 16+ axis crop factors (EIS compensation scale source).
    pub photo_eis_crop_factor: Option<[f64; 2]>,
    pub eis_crop_factor: Option<[f64; 2]>,
}

/// Fully resolved Motion Photo layout.
#[derive(Debug, Clone)]
pub struct MotionPhotoAsset {
    /// "androidMotionPhotoV1" | "androidHeifMotionPhotoV1" |
    /// "legacyMicroVideoV1b" | "oppoLivePhoto"
    pub source_kind: String,
    pub items: Vec<MotionPhotoItem>,
    pub still_range: ByteRange,
    pub video_range: ByteRange,
    pub presentation_timestamp_us: Option<i64>,
    pub presentation_source: Option<String>,
    pub vendor_metadata: Option<OppoMetadata>,
}

impl MotionPhotoAsset {
    /// JSON summary for the FFI report.
    pub fn to_json(&self) -> serde_json::Value {
        let mut v = json!({
            "isMotionPhoto": true,
            "sourceKind": self.source_kind,
            "stillStart": self.still_range.start,
            "stillEnd": self.still_range.end,
            "videoStart": self.video_range.start,
            "videoEnd": self.video_range.end,
            "items": self
                .items
                .iter()
                .map(|it| json!({
                    "mime": it.mime,
                    "semantic": it.semantic,
                    "length": it.length,
                    "padding": it.padding,
                }))
                .collect::<Vec<_>>(),
        });
        if let Some(pts) = self.presentation_timestamp_us {
            v["presentationTimestampUs"] = pts.into();
            if let Some(src) = &self.presentation_source {
                v["presentationSource"] = src.clone().into();
            }
        }
        if let Some(meta) = &self.vendor_metadata {
            v["oppoMetadata"] = json!({
                "coverFramePtsUs": meta.cover_frame_pts_us,
                "version": meta.version,
                "matrixCount": meta.matrix_count,
                "videoWidth": meta.video_width,
                "videoHeight": meta.video_height,
                "originPhotoWidth": meta.origin_photo_width,
                "originPhotoHeight": meta.origin_photo_height,
                "photoCropFactor": meta.photo_crop_factor,
                "streamCount": meta.stream_count,
            });
        }
        v
    }
}

// ---------------------------------------------------------------------------
// XMP extraction & parsing
// ---------------------------------------------------------------------------

fn extract_xmp_prefix(data: &[u8]) -> Result<Option<&[u8]>, String> {
    let prefix = &data[..data.len().min(MAX_XMP_SCAN_BYTES)];
    let starts = [find_sub(prefix, b"<x:xmpmeta"), find_sub(prefix, b"<xmpmeta")]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    let Some(&start) = starts.iter().min() else {
        return Ok(None);
    };
    let mut ends: Vec<usize> = Vec::new();
    for closing in [&b"</x:xmpmeta>"[..], &b"</xmpmeta>"[..]] {
        if let Some(pos) = find_sub(&prefix[start..], closing) {
            ends.push(start + pos + closing.len());
        }
    }
    if ends.is_empty() {
        return Err("Motion Photo XMP is malformed or exceeds safety limit".into());
    }
    let end = *ends.iter().min().unwrap();
    Ok(Some(&prefix[start..end]))
}

fn find_sub(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

fn local_name(name: &str) -> &str {
    if let Some(rest) = name.strip_prefix('{') {
        if let Some(idx) = rest.find('}') {
            return &rest[idx + 1..];
        }
    }
    name.rsplit(':').next().unwrap_or(name)
}

struct StandardXmp {
    enabled: bool,
    version: Option<i64>,
    timestamp: Option<i64>,
    legacy_offset: Option<u64>,
    items: Vec<MotionPhotoItem>,
}

fn parse_standard_xmp(xmp: &[u8]) -> Result<StandardXmp, String> {
    let upper: Vec<u8> = xmp.iter().map(|b| b.to_ascii_uppercase()).collect();
    if find_sub(&upper, b"<!DOCTYPE").is_some() || find_sub(&upper, b"<!ENTITY").is_some() {
        return Err("DTD/entity declarations are forbidden in Motion Photo XMP".into());
    }
    let text = std::str::from_utf8(xmp).map_err(|_| "Motion Photo XMP is not UTF-8".to_string())?;
    let mut reader = quick_xml::Reader::from_str(text);
    reader.config_mut().check_end_names = false;

    let mut desc_attrs: Vec<(String, String)> = Vec::new();
    let mut items: Vec<MotionPhotoItem> = Vec::new();
    let mut inside_directory = false;

    loop {
        match reader.read_event() {
            Ok(quick_xml::events::Event::Start(e)) | Ok(quick_xml::events::Event::Empty(e)) => {
                let name = e.name().as_ref().to_string();
                let local = local_name(&name).to_string();
                let mut attrs: Vec<(String, String)> = Vec::new();
                for attr in e.attributes().flatten() {
                    let key = attr.key.as_ref().to_string();
                    // XMP attributes in Motion Photo files are machine-generated
                    // plain ASCII (numbers and MIME types); entity unescaping is
                    // not needed for the fields we consume.
                    let value = attr.value.as_ref().to_string();
                    attrs.push((local_name(&key).to_string(), value));
                }
                if local == "Directory" {
                    inside_directory = true;
                } else if local == "Description" {
                    desc_attrs.extend(attrs);
                } else if inside_directory && local == "Item" {
                    let get = |k: &str| -> Option<String> {
                        attrs.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
                    };
                    let mime = get("Mime").unwrap_or_default();
                    let semantic = get("Semantic").unwrap_or_default();
                    if mime.is_empty() || semantic.is_empty() {
                        return Err("Motion Photo container item lacks Mime/Semantic".into());
                    }
                    if mime.len() > MAX_METADATA_STRING || semantic.len() > MAX_METADATA_STRING {
                        return Err("Motion Photo metadata string exceeds safety limit".into());
                    }
                    items.push(MotionPhotoItem {
                        mime,
                        semantic,
                        length: checked_nonnegative(get("Length").as_deref())?,
                        padding: checked_nonnegative(get("Padding").as_deref())?,
                    });
                    if items.len() > MAX_DIRECTORY_ITEMS {
                        return Err("Motion Photo directory exceeds item limit".into());
                    }
                }
            }
            Ok(quick_xml::events::Event::End(e)) => {
                if local_name(e.name().as_ref()) == "Directory" {
                    inside_directory = false;
                }
            }
            Ok(quick_xml::events::Event::Eof) => break,
            Err(_) => return Err("Motion Photo XMP is malformed".into()),
            _ => {}
        }
    }

    let attr = |name: &str| -> Option<String> {
        desc_attrs
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.clone())
    };
    let enabled = attr("MotionPhoto").as_deref() == Some("1")
        || attr("MicroVideo").as_deref() == Some("1");
    let version = attr("MotionPhotoVersion").and_then(|v| v.parse::<i64>().ok());
    let mut timestamp: Option<i64> = None;
    for name in [
        "MotionPhotoPresentationTimestampUs",
        "MicroVideoPresentationTimestampUs",
    ] {
        if let Some(raw) = attr(name) {
            let value: i64 = raw
                .parse()
                .map_err(|_| "invalid Motion Photo presentation timestamp".to_string())?;
            timestamp = if value == -1 { None } else { Some(value) };
            break;
        }
    }
    let legacy_offset = match attr("MicroVideoOffset") {
        Some(raw) => Some(checked_nonnegative(Some(&raw))?),
        None => None,
    };
    Ok(StandardXmp {
        enabled,
        version,
        timestamp,
        legacy_offset,
        items,
    })
}

fn checked_nonnegative(value: Option<&str>) -> Result<u64, String> {
    let Some(v) = value else { return Ok(0) };
    if v.len() > 32 {
        return Err("Motion Photo integer metadata is too long".into());
    }
    v.parse::<u64>()
        .map_err(|_| "invalid Motion Photo integer metadata".to_string())
}

fn validate_directory(items: &[MotionPhotoItem]) -> Result<(), String> {
    if items.len() < 2 || items.len() > MAX_DIRECTORY_ITEMS {
        return Err("invalid Motion Photo container directory".into());
    }
    if !items[0].semantic.eq_ignore_ascii_case("primary") || items[0].length != 0 {
        return Err("Motion Photo must begin with one zero-length Primary item".into());
    }
    if items[1..]
        .iter()
        .any(|it| it.semantic.eq_ignore_ascii_case("primary"))
    {
        return Err("Motion Photo contains multiple Primary items".into());
    }
    let motion: Vec<usize> = items
        .iter()
        .enumerate()
        .filter(|(_, it)| it.semantic.eq_ignore_ascii_case("motionphoto"))
        .map(|(i, _)| i)
        .collect();
    if motion != [items.len() - 1] {
        return Err("MotionPhoto resource must be unique and last".into());
    }
    let last = &items[items.len() - 1];
    let mime = last.mime.to_ascii_lowercase();
    if (mime != "video/mp4" && mime != "video/quicktime") || last.length == 0 {
        return Err("invalid MotionPhoto video resource".into());
    }
    if items[1..].iter().any(|it| it.padding != 0) {
        return Err("secondary Motion Photo padding is unsupported".into());
    }
    Ok(())
}

/// Tightly packed Android JPEG resources, walked from EOF backwards.
fn jpeg_resource_ranges(items: &[MotionPhotoItem], file_size: u64) -> Result<Vec<ByteRange>, String> {
    validate_directory(items)?;
    let n = items.len();
    let mut starts = vec![0u64; n];
    let mut ends = vec![0u64; n];
    let mut cursor = file_size;
    for index in (0..n).rev() {
        let item = &items[index];
        let end = cursor;
        if index == 0 {
            if end < item.padding {
                return Err("Motion Photo primary padding exceeds file size".into());
            }
            let unpadded = end - item.padding;
            starts[index] = 0;
            ends[index] = unpadded;
            cursor = 0;
        } else {
            if cursor < item.length {
                return Err("Motion Photo item range exceeds file size".into());
            }
            let start = cursor - item.length;
            starts[index] = start;
            ends[index] = end;
            cursor = start;
        }
    }
    if starts[0] != 0 || ends[n - 1] != file_size {
        return Err("invalid Motion Photo resource ranges".into());
    }
    Ok((0..n).map(|i| ByteRange { start: starts[i], end: ends[i] }).collect())
}

// ---------------------------------------------------------------------------
// ISO BMFF helpers
// ---------------------------------------------------------------------------

struct BoxHeaderLite {
    offset: u64,
    size: u64,
    kind: [u8; 4],
    header_size: u64,
}

impl BoxHeaderLite {
    fn payload_offset(&self) -> u64 {
        self.offset + self.header_size
    }
    fn end(&self) -> u64 {
        self.offset + self.size
    }
}

fn read_box_header(data: &[u8], offset: u64, upper_bound: u64) -> Option<BoxHeaderLite> {
    if offset + 8 > upper_bound || upper_bound as usize > data.len() {
        return None;
    }
    let off = offset as usize;
    let size32 = u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]);
    let kind = [data[off + 4], data[off + 5], data[off + 6], data[off + 7]];
    let (size, header_size) = if size32 == 1 {
        if offset + 16 > upper_bound {
            return None;
        }
        (
            u64::from_be_bytes([
                data[off + 8],
                data[off + 9],
                data[off + 10],
                data[off + 11],
                data[off + 12],
                data[off + 13],
                data[off + 14],
                data[off + 15],
            ]),
            16u64,
        )
    } else if size32 == 0 {
        (upper_bound - offset, 8u64)
    } else {
        (size32 as u64, 8u64)
    };
    if size < header_size || offset + size > upper_bound {
        return None;
    }
    Some(BoxHeaderLite {
        offset,
        size,
        kind,
        header_size,
    })
}

fn is_ftyp_start(data: &[u8], offset: u64, upper_bound: u64) -> bool {
    let Some(b) = read_box_header(data, offset, upper_bound) else {
        return false;
    };
    if &b.kind != b"ftyp" || b.size < b.header_size + 8 {
        return false;
    }
    let p = b.payload_offset() as usize;
    data.len() >= p + 4 && data[p..p + 4].iter().all(|&v| (0x20..=0x7e).contains(&v))
}

/// All plausible ftyp offsets within `range`, validated as box starts.
fn ftyp_offsets(data: &[u8], range: ByteRange) -> Vec<u64> {
    let mut out = Vec::new();
    if range.end as usize > data.len() || range.end <= range.start + 12 {
        return out;
    }
    let slice = &data[range.start as usize..range.end as usize];
    let mut pos = 0usize;
    while let Some(found) = find_sub(&slice[pos..], b"ftyp") {
        let abs_in_slice = pos + found;
        pos = abs_in_slice + 4;
        if abs_in_slice >= 4 {
            let candidate = range.start + (abs_in_slice - 4) as u64;
            if candidate < range.end && is_ftyp_start(data, candidate, range.end) {
                if !out.contains(&candidate) {
                    out.push(candidate);
                }
            }
        }
    }
    out.sort_unstable();
    out
}

fn heif_ranges(
    data: &[u8],
    items: &[MotionPhotoItem],
    file_size: u64,
) -> Result<(ByteRange, ByteRange), String> {
    validate_directory(items)?;
    let primary = &items[0];
    let motion = &items[items.len() - 1];
    let mime = primary.mime.to_ascii_lowercase();
    if (mime != "image/heic" && mime != "image/heif") || primary.padding != 8 {
        return Err("HEIF Motion Photo requires Primary padding=8".into());
    }
    let mut boxes: Vec<BoxHeaderLite> = Vec::new();
    let mut cursor = 0u64;
    while cursor < file_size {
        if boxes.len() >= 4096 {
            return Err("too many HEIF top-level boxes".into());
        }
        let b = read_box_header(data, cursor, file_size)
            .ok_or("invalid HEIF top-level box")?;
        cursor = b.end();
        boxes.push(b);
    }
    if boxes.first().map(|b| &b.kind) != Some(b"ftyp") {
        return Err("HEIF Motion Photo lacks ftyp".into());
    }
    let mpvd: Vec<&BoxHeaderLite> = boxes.iter().filter(|b| &b.kind == b"mpvd").collect();
    if mpvd.len() != 1 {
        return Err("HEIF Motion Photo must contain one mpvd box".into());
    }
    let b = mpvd[0];
    let payload_start = b.payload_offset();
    if file_size - motion.length != payload_start {
        return Err("HEIF Motion Photo directory does not point at mpvd payload".into());
    }
    if !is_ftyp_start(data, payload_start, b.end()) {
        return Err("mpvd payload is not ISO BMFF video".into());
    }
    Ok((
        ByteRange::new(0, b.offset)?,
        ByteRange::new(payload_start, b.end())?,
    ))
}

// ---------------------------------------------------------------------------
// Standard Android parsing
// ---------------------------------------------------------------------------

fn parse_android_motion_photo(data: &[u8]) -> Result<Option<MotionPhotoAsset>, String> {
    if data.len() < 16 {
        return Err("Motion Photo input is too small".into());
    }
    let Some(xmp) = extract_xmp_prefix(data)? else {
        return Ok(None);
    };
    let parsed = parse_standard_xmp(xmp)?;
    if !parsed.enabled {
        return Ok(None);
    }
    let size = data.len() as u64;
    let (items, still_range, video_range, source_kind, presentation_source);
    if !parsed.items.is_empty() {
        if parsed.version != Some(1) {
            return Err(format!(
                "unsupported Motion Photo version: {:?}",
                parsed.version
            ));
        }
        let first_mime = parsed.items[0].mime.to_ascii_lowercase();
        if first_mime == "image/heic" || first_mime == "image/heif" {
            let (still, video) = heif_ranges(data, &parsed.items, size)?;
            still_range = still;
            video_range = video;
            source_kind = "androidHeifMotionPhotoV1";
        } else {
            let ranges = jpeg_resource_ranges(&parsed.items, size)?;
            video_range = ranges[ranges.len() - 1];
            still_range = ByteRange::new(0, video_range.start)?;
            if !is_ftyp_start(data, video_range.start, video_range.end) {
                return Err("Motion Photo video is not a valid ISO BMFF stream".into());
            }
            source_kind = "androidMotionPhotoV1";
        }
        items = parsed.items.clone();
        presentation_source = parsed.timestamp.map(|_| "androidXMP".to_string());
    } else if let Some(legacy_offset) = parsed.legacy_offset {
        if legacy_offset == 0 || legacy_offset > size {
            return Err("invalid legacy MicroVideo offset".into());
        }
        video_range = ByteRange::new(size - legacy_offset, size)?;
        still_range = ByteRange::new(0, video_range.start)?;
        if !is_ftyp_start(data, video_range.start, video_range.end) {
            return Err("legacy MicroVideo payload is not ISO BMFF".into());
        }
        items = vec![
            MotionPhotoItem {
                mime: "image/jpeg".into(),
                semantic: "Primary".into(),
                length: 0,
                padding: 0,
            },
            MotionPhotoItem {
                mime: "video/mp4".into(),
                semantic: "MotionPhoto".into(),
                length: legacy_offset,
                padding: 0,
            },
        ];
        source_kind = "legacyMicroVideoV1b";
        presentation_source = parsed
            .timestamp
            .map(|_| "legacyMicroVideoXMP".to_string());
    } else {
        return Err("Motion Photo directory is missing".into());
    }
    Ok(Some(MotionPhotoAsset {
        source_kind: source_kind.into(),
        items,
        still_range,
        video_range,
        presentation_timestamp_us: parsed.timestamp,
        presentation_source,
        vendor_metadata: None,
    }))
}

// ---------------------------------------------------------------------------
// OPPO LPEX
// ---------------------------------------------------------------------------

fn extract_balanced_json(data: &[u8], brace: usize) -> Option<&[u8]> {
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaping = false;
    let end = (brace + MAX_LPEX_JSON_BYTES + 1).min(data.len());
    for (index, &byte) in data[brace..end].iter().enumerate() {
        let i = brace + index;
        if in_string {
            if escaping {
                escaping = false;
            } else if byte == b'\\' {
                escaping = true;
            } else if byte == b'"' {
                in_string = false;
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&data[brace..=i]);
                }
                if depth < 0 {
                    return None;
                }
            }
            _ => {}
        }
    }
    None
}

fn parse_lpex_object(raw: &[u8]) -> Option<OppoMetadata> {
    let obj: serde_json::Value = serde_json::from_slice(raw).ok()?;
    let obj = obj.as_object()?;
    let integer = |name: &str| -> Option<i64> {
        match obj.get(name) {
            Some(serde_json::Value::Number(n)) => n.as_i64(),
            _ => None,
        }
    };
    let size_pair = |name: &str| -> (Option<u32>, Option<u32>) {
        let Some(arr) = obj.get(name).and_then(|v| v.as_array()) else {
            return (None, None);
        };
        if arr.len() < 2 {
            return (None, None);
        }
        let (w, h) = (arr[0].as_u64(), arr[1].as_u64());
        match (w, h) {
            (Some(w), Some(h)) if w > 0 && h > 0 => (Some(w as u32), Some(h as u32)),
            _ => (None, None),
        }
    };
    let (vw, vh) = size_pair("videoSize");
    let (ow, oh) = size_pair("originPhotoSize");
    let matrix = |name: &str| -> Option<[f64; 9]> {
        let arr = obj.get(name)?.as_array()?;
        if arr.len() != 9 {
            return None;
        }
        let mut out = [0.0; 9];
        for (i, v) in arr.iter().enumerate() {
            out[i] = v.as_f64().filter(|x| x.is_finite())?;
        }
        Some(out)
    };
    let pair2 = |name: &str| -> Option<[f64; 2]> {
        let arr = obj.get(name)?.as_array()?;
        if arr.is_empty() || arr.len() > 8 {
            return None;
        }
        let x = arr[0].as_f64().filter(|v| v.is_finite())?;
        let y = arr
            .get(1)
            .and_then(|v| v.as_f64())
            .filter(|v| v.is_finite())
            .unwrap_or(x);
        Some([x, y])
    };
    Some(OppoMetadata {
        cover_frame_pts_us: integer("coverFramePts"),
        version: integer("version").unwrap_or(0),
        matrix_count: integer("matrixCount").unwrap_or(0),
        video_width: vw,
        video_height: vh,
        origin_photo_width: ow,
        origin_photo_height: oh,
        photo_crop_factor: obj.get("photoCropFactor").and_then(|v| v.as_f64()),
        stream_count: 1,
        photo_crop_matrix: matrix("photoCropMatrix"),
        photo_eis_matrix: matrix("photoEisMatrix"),
        photo_eis_crop_factor: pair2("photoEisCropFactor"),
        eis_crop_factor: pair2("eisCropFactor"),
    })
}

fn parse_oppo_lpex(data: &[u8]) -> Option<OppoMetadata> {
    let needles: [&[u8]; 3] = [
        b"lpexLivePhotoExtension",
        b"LivePhotoExtension",
        b"pexLivePhotoExtension",
    ];
    for needle in needles {
        let mut search = 0usize;
        while let Some(found) = find_sub(&data[search..], needle) {
            let abs = search + found;
            let after = abs + needle.len();
            let brace_end = (after + 33).min(data.len());
            if let Some(rel_brace) = find_sub(&data[after..brace_end], b"{") {
                let brace = after + rel_brace;
                if let Some(raw) = extract_balanced_json(data, brace) {
                    if let Some(parsed) = parse_lpex_object(raw) {
                        return Some(parsed);
                    }
                }
            }
            search = after;
        }
    }
    None
}

// ---------------------------------------------------------------------------
// OPPO fallback (vendor tail heuristics)
// ---------------------------------------------------------------------------

fn xmp_integer(text: &str, names: &[&str]) -> Option<i64> {
    for name in names {
        // <name>123</name>
        if let Some(open_end) = find_sub(text.as_bytes(), format!("<{name}>").as_bytes()) {
            let rest = &text[open_end + name.len() + 2..];
            if let Some(close) = rest.find("</") {
                if let Ok(v) = rest[..close].trim().parse::<i64>() {
                    return Some(v);
                }
            }
        }
        // name="123" or name='123'
        for quote in ['"', '\''] {
            let needle = format!("{name}={quote}");
            if let Some(pos) = find_sub(text.as_bytes(), needle.as_bytes()) {
                let rest = &text[pos + needle.len()..];
                if let Some(end) = rest.find(quote) {
                    if let Ok(v) = rest[..end].trim().parse::<i64>() {
                        return Some(v);
                    }
                }
            }
            // name = "123"
            let needle2 = format!("{name} = {quote}");
            if let Some(pos) = find_sub(text.as_bytes(), needle2.as_bytes()) {
                let rest = &text[pos + needle2.len()..];
                if let Some(end) = rest.find(quote) {
                    if let Ok(v) = rest[..end].trim().parse::<i64>() {
                        return Some(v);
                    }
                }
            }
        }
    }
    None
}

fn oppo_fallback(data: &[u8], lpex: Option<&OppoMetadata>) -> Option<MotionPhotoAsset> {
    let text = extract_xmp_prefix(data)
        .ok()
        .flatten()
        .map(|x| String::from_utf8_lossy(x).into_owned())
        .unwrap_or_default();
    let lower = text.to_ascii_lowercase();
    let has_signature =
        lpex.is_some() || text.contains("OpCamera:") || lower.contains("oppo") || lower.contains("oplus");
    if !has_signature {
        return None;
    }
    let size = data.len() as u64;
    let tail = ByteRange {
        start: size.saturating_sub(MAX_VENDOR_TAIL_SCAN_BYTES),
        end: size,
    };
    let offsets = ftyp_offsets(data, tail);
    if offsets.is_empty() {
        return None;
    }

    let mut declared_lengths: Vec<u64> = Vec::new();
    // Length="123" / Item:Length="123" / <...Length>123</...>
    let bytes = text.as_bytes();
    let mut pos = 0usize;
    while let Some(found) = find_sub(&bytes[pos..], b"Length") {
        let abs = pos + found;
        let rest = &text[abs + 6..];
        let rest_trim = rest.trim_start_matches([' ', '=', '"', '\'', '>']);
        let digits: String = rest_trim
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if let Ok(v) = digits.parse::<u64>() {
            if v > 100_000 {
                declared_lengths.push(v);
            }
        }
        pos = abs + 6;
    }
    for name in ["OpCamera:VideoLength", "GCamera:VideoLength", "VideoLength"] {
        if let Some(v) = xmp_integer(&text, &[name]) {
            if v > 100_000 {
                declared_lengths.push(v as u64);
            }
        }
    }
    let presentation = xmp_integer(
        &text,
        &[
            "GCamera:MotionPhotoPresentationTimestampUs",
            "MotionPhotoPresentationTimestampUs",
            "GCamera:MicroVideoPresentationTimestampUs",
        ],
    );

    let (video_start, stream_count) = if lpex.map(|l| l.version >= 1).unwrap_or(false)
        && offsets.len() >= 2
    {
        (offsets[offsets.len() - 2], 2u32)
    } else {
        let mut start = None;
        let mut lengths = declared_lengths.clone();
        lengths.sort_unstable_by(|a, b| b.cmp(a));
        for length in lengths {
            if length > 0 && length <= size && is_ftyp_start(data, size - length, size) {
                start = Some(size - length);
                break;
            }
        }
        (start.unwrap_or(offsets[offsets.len() - 1]), 1u32)
    };

    let mut metadata = lpex.cloned().unwrap_or_default();
    metadata.stream_count = stream_count;
    let selected = presentation.or(metadata.cover_frame_pts_us);
    let source_name = if presentation.is_some() {
        Some("androidXMP".to_string())
    } else {
        metadata.cover_frame_pts_us.map(|_| "oppoCoverFrame".to_string())
    };
    let video_range = ByteRange::new(video_start, size).ok()?;
    Some(MotionPhotoAsset {
        source_kind: "oppoLivePhoto".into(),
        items: vec![
            MotionPhotoItem {
                mime: "image/jpeg".into(),
                semantic: "Primary".into(),
                length: 0,
                padding: 0,
            },
            MotionPhotoItem {
                mime: "video/mp4".into(),
                semantic: "MotionPhoto".into(),
                length: video_range.length(),
                padding: 0,
            },
        ],
        still_range: ByteRange::new(0, video_start).ok()?,
        video_range,
        presentation_timestamp_us: selected,
        presentation_source: source_name,
        vendor_metadata: Some(metadata),
    })
}

/// Extract OPPO LPEX metadata from any container bytes (used by the Live
/// Photo movie writer for the still-image transform).
pub fn parse_oppo_lpex_pub(data: &[u8]) -> Option<OppoMetadata> {
    parse_oppo_lpex(data)
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Parse a Motion Photo from in-memory bytes. Returns Ok(None) for ordinary
/// photos, Ok(Some(asset)) for recognized Motion Photos, Err for malformed
/// Motion-Photo-looking inputs.
pub fn parse_motion_photo(data: &[u8]) -> Result<Option<MotionPhotoAsset>, String> {
    let lpex = parse_oppo_lpex(data);
    let base = match parse_android_motion_photo(data) {
        Ok(base) => base,
        Err(e) => {
            return oppo_fallback(data, lpex.as_ref()).map_or(Err(e), |a| Ok(Some(a)));
        }
    };
    let Some(base) = base else {
        return Ok(oppo_fallback(data, lpex.as_ref()));
    };
    let Some(lpex) = lpex else {
        return Ok(Some(base));
    };
    let size = data.len() as u64;
    let tail = ByteRange {
        start: size.saturating_sub(MAX_VENDOR_TAIL_SCAN_BYTES),
        end: size,
    };
    let offsets = ftyp_offsets(data, tail);
    let mut metadata = lpex;
    let (still_range, video_range) = if metadata.version >= 1 && offsets.len() >= 2 {
        metadata.stream_count = 2;
        (
            ByteRange::new(0, offsets[offsets.len() - 2])?,
            ByteRange::new(offsets[offsets.len() - 2], size)?,
        )
    } else {
        let inside = offsets
            .iter()
            .filter(|&&o| base.video_range.start <= o && o < base.video_range.end)
            .count();
        metadata.stream_count = inside.max(1) as u32;
        (base.still_range, base.video_range)
    };
    let (selected, selected_source) = match base.presentation_timestamp_us {
        Some(pts) => (Some(pts), base.presentation_source.clone()),
        None => (
            metadata.cover_frame_pts_us,
            metadata
                .cover_frame_pts_us
                .map(|_| "oppoCoverFrame".to_string()),
        ),
    };
    Ok(Some(MotionPhotoAsset {
        source_kind: "oppoLivePhoto".into(),
        items: base.items,
        still_range,
        video_range,
        presentation_timestamp_us: selected,
        presentation_source: selected_source,
        vendor_metadata: Some(metadata),
    }))
}

/// For OPPO dual-stream files, the primary (higher quality) video is the
/// second stream; everything else maps to the full video range.
pub fn primary_video_range(data: &[u8], asset: &MotionPhotoAsset) -> ByteRange {
    let dual = asset.source_kind == "oppoLivePhoto"
        && asset
            .vendor_metadata
            .as_ref()
            .map(|m| m.stream_count >= 2)
            .unwrap_or(false);
    if !dual {
        return asset.video_range;
    }
    let offsets = ftyp_offsets(data, asset.video_range);
    if offsets.len() < 2 {
        return asset.video_range;
    }
    ByteRange {
        start: offsets[offsets.len() - 2],
        end: offsets[offsets.len() - 1],
    }
}

/// Length of the complete standalone BMFF prefix of an embedded video
/// stream. Some ColorOS Stream-1 payloads carry opaque vendor bytes after the
/// last complete box; those are excluded. Ported from upstream
/// `motion_video.standalone_bmff_length`.
pub fn standalone_bmff_length(data: &[u8]) -> Result<usize, String> {
    let file_size = data.len();
    let mut offset = 0usize;
    let mut kinds: Vec<[u8; 4]> = Vec::new();
    while offset < file_size {
        let parsed = read_box_header(data, offset as u64, file_size as u64).filter(|b| {
            b.kind.iter().all(|&v| (0x20..=0x7e).contains(&v))
        });
        match parsed {
            Some(b) => {
                if kinds.is_empty() && &b.kind != b"ftyp" {
                    return Err("embedded video does not begin with ftyp".into());
                }
                kinds.push(b.kind);
                offset += b.size as usize;
            }
            None => {
                let has = |k: &[u8; 4]| kinds.iter().any(|x| x == k);
                if has(b"ftyp") && has(b"moov") && has(b"mdat") {
                    break;
                }
                return Err(format!("invalid ISO-BMFF data at offset {offset}"));
            }
        }
    }
    let has = |k: &[u8; 4]| kinds.iter().any(|x| x == k);
    if !has(b"ftyp") || !has(b"moov") || !has(b"mdat") {
        return Err("embedded video lacks required ftyp/moov/mdat boxes".into());
    }
    Ok(offset)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_ftyp_stream(payload_len: usize) -> Vec<u8> {
        // ftyp(isom) box + free payload
        let mut v = Vec::new();
        v.extend_from_slice(&24u32.to_be_bytes());
        v.extend_from_slice(b"ftyp");
        v.extend_from_slice(b"isom");
        v.extend_from_slice(&0u32.to_be_bytes());
        v.extend_from_slice(b"isom");
        v.extend_from_slice(b"mp41");
        let free_len = 8 + payload_len;
        v.extend_from_slice(&(free_len as u32).to_be_bytes());
        v.extend_from_slice(b"free");
        v.extend(std::iter::repeat(0u8).take(payload_len));
        v
    }

    fn jpeg_motion_xmp(video_len: u64, padding: u64) -> String {
        format!(
            r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1" GCamera:MotionPhotoPresentationTimestampUs="1265580"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="{padding}"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="{video_len}" Item:Padding="0"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>"#
        )
    }

    fn build_jpeg_motion_photo() -> Vec<u8> {
        let video = make_ftyp_stream(200);
        let xmp = jpeg_motion_xmp(video.len() as u64, 0);
        let mut data = vec![0xFF, 0xD8];
        data.extend(std::iter::repeat(0xABu8).take(2048));
        data.extend_from_slice(&[0xFF, 0xD9]);
        data.extend_from_slice(xmp.as_bytes());
        data.extend_from_slice(&video);
        data
    }

    #[test]
    fn parses_jpeg_motion_photo_v1() {
        let data = build_jpeg_motion_photo();
        let asset = parse_motion_photo(&data)
            .expect("parse ok")
            .expect("is motion photo");
        assert_eq!(asset.source_kind, "androidMotionPhotoV1");
        assert_eq!(asset.presentation_timestamp_us, Some(1_265_580));
        assert_eq!(asset.presentation_source.as_deref(), Some("androidXMP"));
        let video = &data[asset.video_range.start as usize..asset.video_range.end as usize];
        assert!(is_ftyp_start(video, 0, video.len() as u64));
        assert_eq!(asset.still_range.start, 0);
        assert_eq!(asset.still_range.end, asset.video_range.start);
        // still payload is the JPEG+XMP part
        assert!(asset.still_range.length() > 2048);
    }

    #[test]
    fn parses_legacy_micro_video() {
        let video = make_ftyp_stream(100);
        let xmp = format!(
            r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" GCamera:MicroVideo="1" GCamera:MicroVideoVersion="1" GCamera:MicroVideoOffset="{}" GCamera:MicroVideoPresentationTimestampUs="42"/></rdf:RDF></x:xmpmeta>"#,
            video.len()
        );
        let mut data = vec![0xFF, 0xD8];
        data.extend(std::iter::repeat(0xCDu8).take(1024));
        data.extend_from_slice(&[0xFF, 0xD9]);
        data.extend_from_slice(xmp.as_bytes());
        data.extend_from_slice(&video);
        let asset = parse_motion_photo(&data)
            .expect("parse ok")
            .expect("is motion photo");
        assert_eq!(asset.source_kind, "legacyMicroVideoV1b");
        assert_eq!(asset.video_range.length(), video.len() as u64);
        assert_eq!(asset.presentation_timestamp_us, Some(42));
    }

    fn make_box(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
        v.extend_from_slice(kind);
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn parses_heif_mpvd_motion_photo() {
        let video = make_ftyp_stream(150);
        let xmp = format!(
            r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/heic" Item:Semantic="Primary" Item:Length="0" Item:Padding="8"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="{video_len}" Item:Padding="0"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>"#,
            video_len = video.len()
        );
        // XMP must live inside the still part... but _heif_ranges only needs
        // box structure at top level and XMP anywhere in the first 4MB. Place
        // XMP after the still boxes but before mpvd, as a 'free' box payload
        // would break box walk; instead append XMP raw — the top-level box
        // walk requires clean boxes, so keep XMP inside meta payload region.
        // Simplest: rebuild still = ftyp + free(xmp) + meta + mpvd.
        let mut data = make_box(b"ftyp", &{
            let mut f = Vec::new();
            f.extend_from_slice(b"heic");
            f.extend_from_slice(&0u32.to_be_bytes());
            f.extend_from_slice(b"heic");
            f.extend_from_slice(b"mif1");
            f
        });
        data.extend_from_slice(&make_box(b"free", xmp.as_bytes()));
        data.extend_from_slice(&make_box(b"meta", b"\x00\x00\x00\x00"));
        let mpvd_offset = data.len() as u64;
        let mut mpvd = Vec::new();
        mpvd.extend_from_slice(&((8 + video.len()) as u32).to_be_bytes());
        mpvd.extend_from_slice(b"mpvd");
        mpvd.extend_from_slice(&video);
        data.extend_from_slice(&mpvd);
        let asset = parse_motion_photo(&data)
            .expect("parse ok")
            .expect("is motion photo");
        assert_eq!(asset.source_kind, "androidHeifMotionPhotoV1");
        assert_eq!(asset.still_range.end, mpvd_offset);
        assert_eq!(asset.video_range.length(), video.len() as u64);
    }

    #[test]
    fn rejects_dtd_in_xmp() {
        let mut data = build_jpeg_motion_photo();
        let marker = b"<rdf:RDF";
        let pos = find_sub(&data, marker).unwrap();
        let mut injected = data[..pos].to_vec();
        injected.extend_from_slice(b"<!DOCTYPE x [<!ENTITY e 'boom'>]>");
        injected.extend_from_slice(&data[pos..]);
        data = injected;
        // DTD rejection happens inside the standard parser; the OPPO fallback
        // has no signature here so parse must surface the error.
        let result = parse_motion_photo(&data);
        assert!(result.is_err(), "DTD must be rejected, got {result:?}");
    }

    #[test]
    fn plain_jpeg_is_not_motion_photo() {
        let mut data = vec![0xFF, 0xD8];
        data.extend(std::iter::repeat(0u8).take(4096));
        data.extend_from_slice(&[0xFF, 0xD9]);
        assert!(parse_motion_photo(&data).expect("ok").is_none());
    }

    #[test]
    fn parses_oppo_dual_stream_fallback() {
        let video1 = make_ftyp_stream(120);
        let video2 = make_ftyp_stream(180);
        let lpex_json = br#"{"version":1,"coverFramePts":1634640,"videoSize":[1920,1080],"streamCount":2}"#;
        let xmp = r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:OpCamera="http://com.oppo/camera" OpCamera:VideoLength="0"/></rdf:RDF></x:xmpmeta>"#;
        let mut data = vec![0xFF, 0xD8];
        data.extend(std::iter::repeat(0x55u8).take(3000));
        data.extend_from_slice(&[0xFF, 0xD9]);
        data.extend_from_slice(xmp.as_bytes());
        data.extend_from_slice(&video1);
        data.extend_from_slice(&video2);
        data.extend_from_slice(b"lpexLivePhotoExtension");
        data.extend_from_slice(lpex_json);
        let asset = parse_motion_photo(&data)
            .expect("parse ok")
            .expect("is motion photo");
        assert_eq!(asset.source_kind, "oppoLivePhoto");
        let meta = asset.vendor_metadata.clone().expect("oppo metadata");
        assert_eq!(meta.stream_count, 2);
        assert_eq!(meta.cover_frame_pts_us, Some(1_634_640));
        assert_eq!(meta.video_width, Some(1920));
        assert_eq!(asset.presentation_timestamp_us, Some(1_634_640));
        assert_eq!(
            asset.presentation_source.as_deref(),
            Some("oppoCoverFrame")
        );
        // video range covers both streams; the primary (high quality) video
        // is the FIRST stream, the second is a proxy (matches upstream's
        // ColorOS 16 fixture expectations).
        let v1_start = asset.video_range.start;
        let primary = primary_video_range(&data, &asset);
        assert_eq!(primary.start, v1_start);
        assert_eq!(primary.length(), video1.len() as u64);
    }
}
