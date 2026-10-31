//! Photographic Styles companion tracks for the Live Photo MOV.
//!
//! When the paired still declares Photographic Styles, Photos builds the
//! Live Photo edit pipeline with a style branch on the *video* too:
//! `/video/photographicStyleLearn` consumes the asset's `linearThumbnail`
//! port, which comes from the MOV auxiliary picture track tagged
//! `com.apple.quicktime.video-map.smart-style-linear-thumbnail`. A MOV
//! without it makes `-[_NUPipeline connect:to:]` assert and Photos aborts
//! on Edit (macOS 27.2, 2026-10-31).
//!
//! Native iOS 27 styled Live Photo MOVs (`smartstyle.bypassed = 1`) carry:
//!
//! * auxv `smart-style-linear-thumbnail`: HEVC Main10 128×96, `colr nclc
//!   9/1/9`, `logs` = `com.apple.rec2020.apple-log`, `udta/tagc`;
//! * auxv `sky` / `person` / `skin` mattes: 8-bit 256×192, `colr nclc 12/1/6`;
//! * mebx `live-photo-info`: per-frame binary record (faces, camera state);
//! * mebx `smartstyle-info`: per-frame bplist `{0: 16, 3, 4, 5, h[, b]}`;
//! * mebx `texturestyle-info` and the `smartstyle.*` / `texturestyle.*`
//!   movie keys.
//!
//! The port has no video decoder, so every frame reuses the still: one
//! thumbnail and one (empty) matte sample, repeated at the main video's
//! timing. Main video samples are never touched; the new samples go into an
//! appended `mdat` and `moov` is rebuilt, as in `live_photo::write_live_photo_movie`.
//! Which of these Photos actually requires is still being narrowed down on
//! device, hence [`MovieStyleLevel`].

use crate::live_photo::{
    direct_child, full_box, handler_type, make_box, mdhd_timescale, movie_timescale,
    sample_pts_seconds, scan_boxes, track_id, MovBox, QUICKTIME_EPOCH_OFFSET,
};
use crate::linear_thumbnail::MovieLinearThumbnail;
use crate::styles_attach::{find_item, item_payload_bytes, STYLES_URI};
use crate::styles_bplist::BplistWriter;
use crate::texture_styles::TEXTURE_STYLES_URI;

/// Environment override for [`MovieStyleLevel`] (`off|thumbnail|info|full`).
pub const LEVEL_ENV: &str = "XDREMUX_LIVE_STYLE_TRACKS";

const THUMBNAIL_TAG: &[u8] = b"com.apple.quicktime.video-map.smart-style-linear-thumbnail";
const MATTE_TAGS: [&[u8]; 3] = [
    b"com.apple.quicktime.video-map.sky",
    b"com.apple.quicktime.video-map.person",
    b"com.apple.quicktime.video-map.skin",
];
const SMARTSTYLE_INFO_KEY: &[u8] = b"com.apple.quicktime.smartstyle-info";
const TEXTURESTYLE_INFO_KEY: &[u8] = b"com.apple.quicktime.texturestyle-info";
const APPLE_LOG_TRANSFER: &[u8] = b"com.apple.rec2020.apple-log";
const THUMBNAIL_MAX_EDGE: u32 = 128;
const MATTE_MAX_EDGE: u32 = 256;
/// `smartstyle-info` key 0 on every iOS 27 MOV we have (HEIC says 15/16).
const SMARTSTYLE_INFO_VERSION: u64 = 16;

/// How much of the native style payload to write into the MOV.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MovieStyleLevel {
    Off,
    /// The linear thumbnail and `live-photo-info` tracks: the two asset
    /// ports `photographicStyleLearn` asserted on (2026-10-31).
    Thumbnail,
    /// Plus `smartstyle-info` and the `smartstyle.*` movie keys.
    Info,
    /// Plus sky/person/skin mattes and the texture style track/keys.
    Full,
}

impl MovieStyleLevel {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "off" | "0" | "none" => Some(Self::Off),
            "thumbnail" | "thumb" | "a" => Some(Self::Thumbnail),
            "info" | "b" => Some(Self::Info),
            "full" | "c" => Some(Self::Full),
            _ => None,
        }
    }

    /// [`LEVEL_ENV`] when set and valid, otherwise [`MovieStyleLevel::Full`].
    pub fn from_env() -> Self {
        std::env::var(LEVEL_ENV)
            .ok()
            .and_then(|v| Self::parse(&v))
            .unwrap_or(Self::Full)
    }
}

// ---------------------------------------------------------------------------
// Still side: Styles / texture plists
// ---------------------------------------------------------------------------

/// The still's Styles values the MOV mirrors.
#[derive(Debug, Clone, PartialEq)]
pub struct StillStyles {
    /// Key 3: 257-point u16 tone curve (516 bytes).
    pub tone_curve: Vec<u8>,
    /// Key 4: baseline exposure; equals the MOV value at the still frame.
    pub baseline_exposure: f64,
    /// Key 5.
    pub key5: u64,
    /// Key h. Native MOV `h` ≈ HEIC `h` / 4 (IMG_0004: 2.375 → 0.589).
    pub h: f64,
    pub texture: Option<StillTexture>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StillTexture {
    pub preset: String,
    pub port_type: String,
    pub hardware_model: String,
    pub people_data_version: u64,
}

/// True when the still declares Photographic Styles (the case Photos
/// routes through the styled Live Photo pipeline).
pub fn still_has_styles(still_heic: &[u8]) -> bool {
    crate::isobmff::parse_source_meta(still_heic)
        .map(|meta| find_item(&meta, STYLES_URI).is_some())
        .unwrap_or(false)
}

/// Read the Styles (and optional texture) plist of a converted still.
pub fn read_still_styles(still_heic: &[u8]) -> Option<StillStyles> {
    let meta = crate::isobmff::parse_source_meta(still_heic).ok()?;
    let payload = item_payload_bytes(still_heic, &meta, find_item(&meta, STYLES_URI)?)?;
    let dict = parse_bplist_dict(&payload)?;
    let tone_curve = match lookup(&dict, "3")? {
        PlistValue::Data(d) => d.clone(),
        _ => return None,
    };
    let baseline_exposure = lookup(&dict, "4")?.as_f64()?;
    let key5 = lookup(&dict, "5").and_then(PlistValue::as_f64).unwrap_or(0.0).max(0.0) as u64;
    let h = lookup(&dict, "h").and_then(PlistValue::as_f64).unwrap_or(0.0);
    let texture = find_item(&meta, TEXTURE_STYLES_URI)
        .and_then(|id| item_payload_bytes(still_heic, &meta, id))
        .and_then(|p| parse_bplist_dict(&p))
        .map(|t| {
            let text = |k: &str, default: &str| match lookup(&t, k) {
                Some(PlistValue::Str(s)) => s.clone(),
                _ => default.to_string(),
            };
            StillTexture {
                preset: text("Preset", "Standard"),
                port_type: text("PortType", "PortTypeBack"),
                hardware_model: text("HardwareModel", ""),
                people_data_version: lookup(&t, "TextureStylePeopleDataVersion")
                    .and_then(PlistValue::as_f64)
                    .unwrap_or(3.0) as u64,
            }
        });
    if !baseline_exposure.is_finite() || baseline_exposure <= 0.0 {
        return None;
    }
    Some(StillStyles {
        tone_curve,
        baseline_exposure,
        key5,
        h: h / 4.0,
        texture,
    })
}

#[derive(Debug, Clone, PartialEq)]
enum PlistValue {
    Bool(bool),
    Int(i64),
    Real(f64),
    Data(Vec<u8>),
    Str(String),
    Other,
}

impl PlistValue {
    fn as_f64(&self) -> Option<f64> {
        match self {
            PlistValue::Int(v) => Some(*v as f64),
            PlistValue::Real(v) => Some(*v),
            PlistValue::Bool(v) => Some(*v as u8 as f64),
            _ => None,
        }
    }
}

fn lookup<'a>(dict: &'a [(String, PlistValue)], key: &str) -> Option<&'a PlistValue> {
    dict.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// Minimal binary plist reader: the top-level dictionary's scalar values.
/// Nested containers come back as [`PlistValue::Other`].
fn parse_bplist_dict(buf: &[u8]) -> Option<Vec<(String, PlistValue)>> {
    if buf.len() < 40 || &buf[..8] != b"bplist00" {
        return None;
    }
    let trailer = &buf[buf.len() - 32..];
    let offset_size = trailer[6] as usize;
    let ref_size = trailer[7] as usize;
    let num_objects = be(&trailer[8..16]);
    let top = be(&trailer[16..24]);
    let table = be(&trailer[24..32]);
    if offset_size == 0 || ref_size == 0 || top >= num_objects {
        return None;
    }
    let object_offset = |index: usize| -> Option<usize> {
        let start = table.checked_add(index.checked_mul(offset_size)?)?;
        Some(be(buf.get(start..start + offset_size)?))
    };
    // Length of a container/data object: inline nibble or a following int.
    let length = |off: usize| -> Option<(usize, usize)> {
        let nibble = (buf[off] & 0x0f) as usize;
        if nibble < 15 {
            return Some((nibble, off + 1));
        }
        let marker = *buf.get(off + 1)?;
        if marker >> 4 != 1 {
            return None;
        }
        let n = 1usize << (marker & 0x0f);
        Some((be(buf.get(off + 2..off + 2 + n)?), off + 2 + n))
    };
    let scalar = |index: usize| -> Option<PlistValue> {
        let off = object_offset(index)?;
        let marker = *buf.get(off)?;
        Some(match marker >> 4 {
            0x0 if marker == 0x08 => PlistValue::Bool(false),
            0x0 if marker == 0x09 => PlistValue::Bool(true),
            0x1 => {
                let n = 1usize << (marker & 0x0f);
                let bytes = buf.get(off + 1..off + 1 + n)?;
                PlistValue::Int(be(bytes) as i64)
            }
            0x2 => match marker & 0x0f {
                2 => PlistValue::Real(f32::from_be_bytes(buf.get(off + 1..off + 5)?.try_into().ok()?) as f64),
                3 => PlistValue::Real(f64::from_be_bytes(buf.get(off + 1..off + 9)?.try_into().ok()?)),
                _ => PlistValue::Other,
            },
            0x4 => {
                let (n, start) = length(off)?;
                PlistValue::Data(buf.get(start..start + n)?.to_vec())
            }
            0x5 => {
                let (n, start) = length(off)?;
                PlistValue::Str(String::from_utf8_lossy(buf.get(start..start + n)?).into_owned())
            }
            0x6 => {
                let (n, start) = length(off)?;
                let units: Vec<u16> = buf
                    .get(start..start + 2 * n)?
                    .chunks_exact(2)
                    .map(|c| u16::from_be_bytes([c[0], c[1]]))
                    .collect();
                PlistValue::Str(String::from_utf16_lossy(&units))
            }
            _ => PlistValue::Other,
        })
    };
    let off = object_offset(top)?;
    if *buf.get(off)? >> 4 != 0xd {
        return None;
    }
    let (count, refs) = length(off)?;
    let read_ref = |i: usize| -> Option<usize> {
        let start = refs.checked_add(i.checked_mul(ref_size)?)?;
        Some(be(buf.get(start..start + ref_size)?))
    };
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let key = match scalar(read_ref(i)?)? {
            PlistValue::Str(s) => s,
            _ => return None,
        };
        out.push((key, scalar(read_ref(count + i)?)?));
    }
    Some(out)
}

fn be(bytes: &[u8]) -> usize {
    bytes.iter().fold(0usize, |v, b| v.saturating_mul(256).saturating_add(*b as usize))
}

// ---------------------------------------------------------------------------
// Movie side
// ---------------------------------------------------------------------------

/// The main video track facts the companion tracks copy.
struct VideoTrack {
    id: u32,
    matrix: [u8; 36],
    /// Track duration in the movie timescale.
    duration: u64,
    coded_width: u32,
    coded_height: u32,
    media_timescale: u32,
    /// Presentation-order sample durations in the media timescale.
    durations: Vec<u32>,
    /// Movie time of the first frame (leading empty edits).
    start: u64,
}

impl VideoTrack {
    /// Quarter turns (CW) the track matrix applies to coded frames.
    fn display_cw_quarter_turns(&self) -> u32 {
        let fixed = |i: usize| i32::from_be_bytes(self.matrix[i * 4..i * 4 + 4].try_into().unwrap());
        match (fixed(0).signum(), fixed(1).signum(), fixed(3).signum(), fixed(4).signum()) {
            (0, 1, -1, 0) => 1,
            (-1, 0, 0, -1) => 2,
            (0, -1, 1, 0) => 3,
            _ => 0,
        }
    }

    fn media_duration(&self) -> u64 {
        self.durations.iter().map(|&d| d as u64).sum()
    }
}

fn video_track(moov: &[u8]) -> Result<VideoTrack, String> {
    let root = MovBox {
        offset: 0,
        size: moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let track = scan_boxes(moov, root.payload_offset(), root.end())?
        .into_iter()
        .find(|b| &b.kind == b"trak" && handler_type(moov, b).map(|h| &h == b"vide").unwrap_or(false))
        .ok_or("movie has no video track")?;
    let id = track_id(moov, &track)?;
    let tkhd = direct_child(moov, &track, b"tkhd")?;
    let version = moov[tkhd.payload_offset()];
    let (duration, matrix_at) = if version == 1 {
        let at = tkhd.payload_offset() + 28;
        (u64::from_be_bytes(moov[at..at + 8].try_into().unwrap()), tkhd.payload_offset() + 52)
    } else {
        let at = tkhd.payload_offset() + 20;
        (
            u32::from_be_bytes(moov[at..at + 4].try_into().unwrap()) as u64,
            tkhd.payload_offset() + 40,
        )
    };
    if matrix_at + 36 > tkhd.end() {
        return Err("truncated video tkhd".into());
    }
    let matrix: [u8; 36] = moov[matrix_at..matrix_at + 36].try_into().unwrap();

    let mdia = direct_child(moov, &track, b"mdia")?;
    let minf = direct_child(moov, &mdia, b"minf")?;
    let stbl = direct_child(moov, &minf, b"stbl")?;
    let stsd = direct_child(moov, &stbl, b"stsd")?;
    let entry = stsd.payload_offset() + 8;
    if entry + 36 > stsd.end() {
        return Err("truncated video sample description".into());
    }
    let coded_width = u16::from_be_bytes(moov[entry + 32..entry + 34].try_into().unwrap()) as u32;
    let coded_height = u16::from_be_bytes(moov[entry + 34..entry + 36].try_into().unwrap()) as u32;
    if coded_width == 0 || coded_height == 0 {
        return Err("video sample description has zero extent".into());
    }

    let media_timescale = mdhd_timescale(moov, &track)?;
    let mdhd = direct_child(moov, &mdia, b"mdhd")?;
    let media_duration = if moov[mdhd.payload_offset()] == 1 {
        let at = mdhd.payload_offset() + 24;
        u64::from_be_bytes(moov[at..at + 8].try_into().unwrap())
    } else {
        let at = mdhd.payload_offset() + 16;
        u32::from_be_bytes(moov[at..at + 4].try_into().unwrap()) as u64
    };
    let mut pts: Vec<i64> = sample_pts_seconds(moov, &track)?
        .into_iter()
        .map(|s| (s * media_timescale as f64).round() as i64)
        .collect();
    pts.sort_unstable();
    let mut durations: Vec<u32> = pts.windows(2).map(|w| (w[1] - w[0]).max(1) as u32).collect();
    let tail = (media_duration as i64 - pts[pts.len() - 1])
        .max(durations.last().map(|&d| d as i64).unwrap_or(1))
        .max(1);
    durations.push(tail as u32);

    let mut start = 0u64;
    if let Ok(edts) = direct_child(moov, &track, b"edts") {
        if let Ok(elst) = direct_child(moov, &edts, b"elst") {
            let v1 = moov[elst.payload_offset()] == 1;
            let count = u32::from_be_bytes(
                moov[elst.payload_offset() + 4..elst.payload_offset() + 8].try_into().unwrap(),
            ) as usize;
            let entry_size = if v1 { 20 } else { 12 };
            let mut at = elst.payload_offset() + 8;
            for _ in 0..count {
                if at + entry_size > elst.end() {
                    break;
                }
                let (dur, media_time) = if v1 {
                    (
                        u64::from_be_bytes(moov[at..at + 8].try_into().unwrap()),
                        i64::from_be_bytes(moov[at + 8..at + 16].try_into().unwrap()),
                    )
                } else {
                    (
                        u32::from_be_bytes(moov[at..at + 4].try_into().unwrap()) as u64,
                        i32::from_be_bytes(moov[at + 4..at + 8].try_into().unwrap()) as i64,
                    )
                };
                if media_time != -1 {
                    break;
                }
                start += dur;
                at += entry_size;
            }
        }
    }

    Ok(VideoTrack {
        id,
        matrix,
        duration,
        coded_width,
        coded_height,
        media_timescale,
        durations,
        start,
    })
}

/// One companion track: its `trak` minus `stco`, plus its sample bytes.
struct Companion {
    /// Builds the trak once the chunk offset is known.
    build: Box<dyn Fn(u64) -> Vec<u8>>,
    data: Vec<u8>,
}

#[derive(Clone, Copy)]
struct TrackCommon<'a> {
    id: u32,
    timestamp: u64,
    video: &'a VideoTrack,
}

fn tkhd_box(common: TrackCommon<'_>, flags: u32, width: u32, height: u32) -> Vec<u8> {
    let mut p = Vec::new();
    for v in [common.timestamp, common.timestamp, common.id as u64, 0, common.video.duration] {
        p.extend_from_slice(&(v as u32).to_be_bytes());
    }
    p.extend_from_slice(&[0u8; 8]);
    p.extend_from_slice(&[0u8; 8]); // layer, alternate group, volume, reserved
    p.extend_from_slice(&common.video.matrix);
    p.extend_from_slice(&(width << 16).to_be_bytes());
    p.extend_from_slice(&(height << 16).to_be_bytes());
    full_box(b"tkhd", 0, flags, &p)
}

fn edts_box(video: &VideoTrack) -> Vec<u8> {
    let mut entries = Vec::new();
    let mut count = 0u32;
    if video.start > 0 {
        entries.extend_from_slice(&(video.start as u32).to_be_bytes());
        entries.extend_from_slice(&(-1i32).to_be_bytes());
        entries.extend_from_slice(&0x0001_0000u32.to_be_bytes());
        count += 1;
    }
    let body = video.duration.saturating_sub(video.start).max(1);
    entries.extend_from_slice(&(body as u32).to_be_bytes());
    entries.extend_from_slice(&0i32.to_be_bytes());
    entries.extend_from_slice(&0x0001_0000u32.to_be_bytes());
    count += 1;
    let mut p = count.to_be_bytes().to_vec();
    p.extend_from_slice(&entries);
    make_box(b"edts", &full_box(b"elst", 0, 0, &p))
}

fn mdhd_box(common: TrackCommon<'_>) -> Vec<u8> {
    let mut p = Vec::new();
    for v in [
        common.timestamp,
        common.timestamp,
        common.video.media_timescale as u64,
        common.video.media_duration(),
    ] {
        p.extend_from_slice(&(v as u32).to_be_bytes());
    }
    p.extend_from_slice(&0x55C4u16.to_be_bytes()); // und
    p.extend_from_slice(&0u16.to_be_bytes());
    full_box(b"mdhd", 0, 0, &p)
}

fn handler_box(component: &[u8; 4], subtype: &[u8; 4], flags: u32, name: &[u8]) -> Vec<u8> {
    let mut p = component.to_vec();
    p.extend_from_slice(subtype);
    p.extend_from_slice(b"appl");
    p.extend_from_slice(&flags.to_be_bytes());
    p.extend_from_slice(&0u32.to_be_bytes());
    p.push(name.len() as u8);
    p.extend_from_slice(name);
    full_box(b"hdlr", 0, 0, &p)
}

fn data_info_boxes() -> Vec<u8> {
    let data_handler = handler_box(b"dhlr", b"alis", 0, b"Core Media Data Handler");
    let mut dref = 1u32.to_be_bytes().to_vec();
    dref.extend_from_slice(&full_box(b"alis", 0, 1, &[]));
    [data_handler, make_box(b"dinf", &full_box(b"dref", 0, 0, &dref))].concat()
}

/// Sample table: one chunk holding every sample, all of `sample_size` bytes.
fn stbl_box(stsd_entry: &[u8], durations: &[u32], sample_size: usize, chunk_offset: u64) -> Vec<u8> {
    let mut stsd = 1u32.to_be_bytes().to_vec();
    stsd.extend_from_slice(stsd_entry);
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for &d in durations {
        match runs.last_mut() {
            Some((count, delta)) if *delta == d => *count += 1,
            _ => runs.push((1, d)),
        }
    }
    let mut stts = (runs.len() as u32).to_be_bytes().to_vec();
    for (count, delta) in runs {
        stts.extend_from_slice(&count.to_be_bytes());
        stts.extend_from_slice(&delta.to_be_bytes());
    }
    let mut stsc = 1u32.to_be_bytes().to_vec();
    for v in [1u32, durations.len() as u32, 1] {
        stsc.extend_from_slice(&v.to_be_bytes());
    }
    let mut stsz = (sample_size as u32).to_be_bytes().to_vec();
    stsz.extend_from_slice(&(durations.len() as u32).to_be_bytes());
    let chunk = if chunk_offset > 0xFFFF_FFFF {
        let mut p = 1u32.to_be_bytes().to_vec();
        p.extend_from_slice(&chunk_offset.to_be_bytes());
        full_box(b"co64", 0, 0, &p)
    } else {
        let mut p = 1u32.to_be_bytes().to_vec();
        p.extend_from_slice(&(chunk_offset as u32).to_be_bytes());
        full_box(b"stco", 0, 0, &p)
    };
    make_box(
        b"stbl",
        &[
            full_box(b"stsd", 0, 0, &stsd),
            full_box(b"stts", 0, 0, &stts),
            full_box(b"stsc", 0, 0, &stsc),
            full_box(b"stsz", 0, 0, &stsz),
            chunk,
        ]
        .concat(),
    )
}

/// `hvc1` sample entry with `hvcC`, `colr nclc` and an optional `logs`.
fn hvc1_entry(width: u32, height: u32, hvcc: &[u8], nclc: (u16, u16, u16), logs: Option<&[u8]>) -> Vec<u8> {
    let mut e = vec![0u8; 6];
    e.extend_from_slice(&1u16.to_be_bytes()); // data reference index
    e.extend_from_slice(&[0u8; 8]); // version, revision, vendor
    e.extend_from_slice(&0x200u32.to_be_bytes()); // temporal quality
    e.extend_from_slice(&0x200u32.to_be_bytes()); // spatial quality
    e.extend_from_slice(&(width as u16).to_be_bytes());
    e.extend_from_slice(&(height as u16).to_be_bytes());
    e.extend_from_slice(&0x0048_0000u32.to_be_bytes());
    e.extend_from_slice(&0x0048_0000u32.to_be_bytes());
    e.extend_from_slice(&0u32.to_be_bytes());
    e.extend_from_slice(&1u16.to_be_bytes()); // frame count
    let mut compressor = [0u8; 32];
    compressor[0] = 4;
    compressor[1..5].copy_from_slice(b"HEVC");
    e.extend_from_slice(&compressor);
    e.extend_from_slice(&0x0018u16.to_be_bytes());
    e.extend_from_slice(&(-1i16).to_be_bytes());
    e.extend_from_slice(&make_box(b"hvcC", hvcc));
    let mut colr = b"nclc".to_vec();
    for v in [nclc.0, nclc.1, nclc.2] {
        colr.extend_from_slice(&v.to_be_bytes());
    }
    e.extend_from_slice(&make_box(b"colr", &colr));
    if let Some(name) = logs {
        e.extend_from_slice(&make_box(b"logs", name));
    }
    make_box(b"hvc1", &e)
}

/// Auxiliary picture track repeating one coded `sample` at the video timing.
fn aux_video_track(
    common: TrackCommon<'_>,
    tag: &'static [u8],
    sample: Vec<u8>,
    stsd_entry: Vec<u8>,
    width: u32,
    height: u32,
) -> Companion {
    let video = common.video;
    let n = video.durations.len();
    let data = sample.repeat(n);
    let size = sample.len();
    let tkhd = tkhd_box(common, 0x0e, width, height);
    let edts = edts_box(video);
    let tref = make_box(b"tref", &make_box(b"vmap", &video.id.to_be_bytes()));
    let mdhd = mdhd_box(common);
    let hdlr = handler_box(b"mhlr", b"auxv", 0, b"Core Media Auxiliary Picture");
    let mut vmhd = 0x40u16.to_be_bytes().to_vec();
    for _ in 0..3 {
        vmhd.extend_from_slice(&0x8000u16.to_be_bytes());
    }
    let vmhd = full_box(b"vmhd", 0, 1, &vmhd);
    let udta = make_box(b"udta", &make_box(b"tagc", tag));
    let durations = video.durations.clone();
    Companion {
        build: Box::new(move |offset| {
            let stbl = stbl_box(&stsd_entry, &durations, size, offset);
            let minf = make_box(b"minf", &[vmhd.clone(), data_info_boxes(), stbl].concat());
            let mdia = make_box(b"mdia", &[mdhd.clone(), hdlr.clone(), minf].concat());
            make_box(b"trak", &[tkhd.clone(), edts.clone(), tref.clone(), mdia, udta.clone()].concat())
        }),
        data,
    }
}

/// Local key atom body for a plain `mdta` key with a raw (0/0) data type.
fn plain_key_body(key: &[u8]) -> Vec<u8> {
    let mut keyd = b"mdta".to_vec();
    keyd.extend_from_slice(key);
    let mut dtyp = 0u32.to_be_bytes().to_vec();
    dtyp.extend_from_slice(&0u32.to_be_bytes());
    let sdpd = make_box(b"sdpd", &make_box(b"sdpi", &0u32.to_be_bytes()));
    [make_box(b"keyd", &keyd), make_box(b"dtyp", &dtyp), sdpd].concat()
}

/// Timed metadata track with one key (`key_body`: keyd, dtyp, ...) whose
/// `payload` repeats per frame.
fn mebx_track(common: TrackCommon<'_>, key_body: &[u8], payload: &[u8]) -> Companion {
    let video = common.video;
    let mut sample = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
    sample.extend_from_slice(&1u32.to_be_bytes());
    sample.extend_from_slice(payload);
    let size = sample.len();
    let data = sample.repeat(video.durations.len());

    let key_atom = make_box(&1u32.to_be_bytes(), key_body);
    let mut mebx = vec![0u8; 6];
    mebx.extend_from_slice(&1u16.to_be_bytes());
    mebx.extend_from_slice(&make_box(b"keys", &key_atom));
    let stsd_entry = make_box(b"mebx", &mebx);

    let tkhd = tkhd_box(common, 0x0f, 0, 0);
    let edts = edts_box(video);
    let mut refs = make_box(b"cdsc", &video.id.to_be_bytes());
    refs.extend_from_slice(&make_box(b"cdep", &video.id.to_be_bytes()));
    let tref = make_box(b"tref", &refs);
    let mdhd = mdhd_box(common);
    let hdlr = handler_box(b"mhlr", b"meta", 1, b"Core Media Metadata");
    let mut gmin = 0x40u16.to_be_bytes().to_vec();
    for _ in 0..3 {
        gmin.extend_from_slice(&0x8000u16.to_be_bytes());
    }
    gmin.extend_from_slice(&[0u8; 4]);
    let gmhd = make_box(b"gmhd", &full_box(b"gmin", 0, 0, &gmin));
    let durations = video.durations.clone();
    Companion {
        build: Box::new(move |offset| {
            let stbl = stbl_box(&stsd_entry, &durations, size, offset);
            let minf = make_box(b"minf", &[gmhd.clone(), data_info_boxes(), stbl].concat());
            let mdia = make_box(b"mdia", &[mdhd.clone(), hdlr.clone(), minf].concat());
            make_box(b"trak", &[tkhd.clone(), edts.clone(), tref.clone(), mdia].concat())
        }),
        data,
    }
}

fn smartstyle_info_payload(styles: &StillStyles, with_mattes: bool) -> Vec<u8> {
    let mut w = BplistWriter::new();
    let mut entries = Vec::new();
    let k = w.add_str("0");
    let v = w.add_int(SMARTSTYLE_INFO_VERSION);
    entries.push((k, v));
    let k = w.add_str("3");
    let v = w.add_data(&styles.tone_curve);
    entries.push((k, v));
    let k = w.add_str("4");
    let v = w.add_real(styles.baseline_exposure as f32 as f64);
    entries.push((k, v));
    let k = w.add_str("5");
    let v = w.add_int(styles.key5);
    entries.push((k, v));
    let k = w.add_str("h");
    let v = w.add_real(styles.h as f32 as f64);
    entries.push((k, v));
    if with_mattes {
        // Native frames that carry matte samples also carry b = 0.0.
        let k = w.add_str("b");
        let v = w.add_real(0.0);
        entries.push((k, v));
    }
    let top = w.add_dict(&entries);
    w.finish(top)
}

fn texturestyle_info_payload(texture: &StillTexture) -> Vec<u8> {
    let mut w = BplistWriter::new();
    let mut entries = Vec::new();
    for (key, value) in [
        ("Preset", texture.preset.as_str()),
        ("CaptureType", "None"),
        ("PortType", texture.port_type.as_str()),
        ("CaptureMode", "LivePhoto"),
        ("HardwareModel", texture.hardware_model.as_str()),
    ] {
        let k = w.add_str(key);
        let v = w.add_str(value);
        entries.push((k, v));
    }
    let k = w.add_str("BrightnessValue");
    let v = w.add_real(0.0);
    entries.push((k, v));
    let k = w.add_str("TextureStyleFaceAttitudeMetadata");
    let v = w.add_array(&[]);
    entries.push((k, v));
    let k = w.add_str("TextureStylePeopleDataVersion");
    let v = w.add_int(texture.people_data_version);
    entries.push((k, v));
    let top = w.add_dict(&entries);
    w.finish(top)
}

/// `texturestyle.preset` integer for a texture `Preset` name.
fn texture_preset_code(preset: &str) -> u64 {
    match preset {
        "Studio" => 3,
        _ => 1,
    }
}

/// One empty 8-bit 4:0:0 matte picture: (length-prefixed IDR, hvcC).
fn empty_matte(width: u32, height: u32) -> Result<(Vec<u8>, Vec<u8>), String> {
    let pixels = vec![0u8; (width * height) as usize];
    let stream = crate::hevc::x265_encode_tiles(&[pixels.as_slice()], width, height, 1, false)
        .map_err(|e| format!("Live Photo matte encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("Live Photo matte encode produced no stream")?;
    let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, 0)
        .ok_or("Live Photo matte hvcC extraction failed")?;
    let idr = crate::hevc::drop_parameter_nals(&stream);
    Ok((crate::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc))
}

/// Native `live-photo-info` key atom body (iPhone Air, iOS 27.0): keyd,
/// reverse-DNS dtyp, sdpd, setu/cfgv setup plist, dims, ctps. Only `dims`
/// changes, to the video's coded size.
fn live_photo_info_key_body(width: u32, height: u32) -> Vec<u8> {
    let mut body = LIVE_PHOTO_INFO_KEY_BODY.to_vec();
    let at = LIVE_PHOTO_INFO_DIMS_OFFSET;
    debug_assert_eq!(&body[at..at + 4], b"dims");
    body[at + 4..at + 8].copy_from_slice(&width.to_be_bytes());
    body[at + 8..at + 12].copy_from_slice(&height.to_be_bytes());
    body
}

/// Offset of the `dims` box type inside [`LIVE_PHOTO_INFO_KEY_BODY`].
const LIVE_PHOTO_INFO_DIMS_OFFSET: usize = 518;

#[rustfmt::skip]
const LIVE_PHOTO_INFO_KEY_BODY: [u8; 554] = [
    0x00, 0x00, 0x00, 0x2f, 0x6b, 0x65, 0x79, 0x64, 0x6d, 0x64, 0x74, 0x61, 0x63, 0x6f, 0x6d, 0x2e,
    0x61, 0x70, 0x70, 0x6c, 0x65, 0x2e, 0x71, 0x75, 0x69, 0x63, 0x6b, 0x74, 0x69, 0x6d, 0x65, 0x2e,
    0x6c, 0x69, 0x76, 0x65, 0x2d, 0x70, 0x68, 0x6f, 0x74, 0x6f, 0x2d, 0x69, 0x6e, 0x66, 0x6f, 0x00,
    0x00, 0x00, 0x43, 0x64, 0x74, 0x79, 0x70, 0x00, 0x00, 0x00, 0x01, 0x63, 0x6f, 0x6d, 0x2e, 0x61,
    0x70, 0x70, 0x6c, 0x65, 0x2e, 0x71, 0x75, 0x69, 0x63, 0x6b, 0x74, 0x69, 0x6d, 0x65, 0x2e, 0x63,
    0x6f, 0x6d, 0x2e, 0x61, 0x70, 0x70, 0x6c, 0x65, 0x2e, 0x71, 0x75, 0x69, 0x63, 0x6b, 0x74, 0x69,
    0x6d, 0x65, 0x2e, 0x6c, 0x69, 0x76, 0x65, 0x2d, 0x70, 0x68, 0x6f, 0x74, 0x6f, 0x2d, 0x69, 0x6e,
    0x66, 0x6f, 0x00, 0x00, 0x00, 0x14, 0x73, 0x64, 0x70, 0x64, 0x00, 0x00, 0x00, 0x0c, 0x73, 0x64,
    0x70, 0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x8c, 0x73, 0x65, 0x74, 0x75, 0x00, 0x00,
    0x01, 0x74, 0x63, 0x66, 0x67, 0x76, 0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30, 0xd3, 0x01,
    0x02, 0x03, 0x04, 0x05, 0x0c, 0x5f, 0x10, 0x21, 0x4c, 0x69, 0x76, 0x65, 0x50, 0x68, 0x6f, 0x74,
    0x6f, 0x4d, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61, 0x53, 0x65, 0x74, 0x75, 0x70, 0x44, 0x61,
    0x74, 0x61, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x5d, 0x53, 0x79, 0x73, 0x74, 0x65, 0x6d,
    0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x5f, 0x10, 0x11, 0x46, 0x72, 0x61, 0x6d, 0x65, 0x77,
    0x6f, 0x72, 0x6b, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x73, 0x10, 0x01, 0xd3, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x5f, 0x10, 0x13, 0x50, 0x72, 0x6f, 0x64, 0x75, 0x63, 0x74, 0x42, 0x75,
    0x69, 0x6c, 0x64, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x5b, 0x50, 0x72, 0x6f, 0x64, 0x75,
    0x63, 0x74, 0x4e, 0x61, 0x6d, 0x65, 0x5e, 0x50, 0x72, 0x6f, 0x64, 0x75, 0x63, 0x74, 0x56, 0x65,
    0x72, 0x73, 0x69, 0x6f, 0x6e, 0x58, 0x32, 0x34, 0x41, 0x35, 0x34, 0x32, 0x34, 0x61, 0x59, 0x69,
    0x50, 0x68, 0x6f, 0x6e, 0x65, 0x20, 0x4f, 0x53, 0x54, 0x32, 0x37, 0x2e, 0x30, 0xd5, 0x0d, 0x0e,
    0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x5a, 0x43, 0x6f, 0x72, 0x65, 0x4d, 0x6f, 0x74,
    0x69, 0x6f, 0x6e, 0x5b, 0x49, 0x53, 0x50, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x73, 0x5d,
    0x43, 0x4d, 0x43, 0x61, 0x70, 0x74, 0x75, 0x72, 0x65, 0x43, 0x6f, 0x72, 0x65, 0x5e, 0x48, 0x31,
    0x36, 0x49, 0x53, 0x50, 0x53, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x73, 0x59, 0x43, 0x6f, 0x72,
    0x65, 0x4d, 0x65, 0x64, 0x69, 0x61, 0x5c, 0x33, 0x31, 0x38, 0x35, 0x2e, 0x30, 0x2e, 0x36, 0x2e,
    0x30, 0x2e, 0x33, 0x55, 0x32, 0x30, 0x2e, 0x37, 0x37, 0x59, 0x37, 0x36, 0x34, 0x2e, 0x32, 0x32,
    0x2e, 0x31, 0x33, 0x54, 0x36, 0x2e, 0x32, 0x31, 0x5b, 0x33, 0x33, 0x35, 0x30, 0x2e, 0x37, 0x37,
    0x2e, 0x31, 0x2e, 0x36, 0x00, 0x08, 0x00, 0x0f, 0x00, 0x33, 0x00, 0x41, 0x00, 0x55, 0x00, 0x57,
    0x00, 0x5e, 0x00, 0x74, 0x00, 0x80, 0x00, 0x8f, 0x00, 0x98, 0x00, 0xa2, 0x00, 0xa7, 0x00, 0xb2,
    0x00, 0xbd, 0x00, 0xc9, 0x00, 0xd7, 0x00, 0xe6, 0x00, 0xf0, 0x00, 0xfd, 0x01, 0x03, 0x01, 0x0d,
    0x01, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x1e, 0x00, 0x00, 0x00, 0x10, 0x64, 0x69, 0x6d, 0x73, 0x00, 0x00, 0x07, 0x80, 0x00, 0x00,
    0x05, 0xa0, 0x00, 0x00, 0x00, 0x18, 0x63, 0x74, 0x70, 0x73, 0x00, 0x00, 0x00, 0x10, 0x64, 0x74,
    0x79, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

/// One native frame record with no detected faces (face count 0), reused for
/// every frame: format version 3, the rest opaque camera state.
#[rustfmt::skip]
const LIVE_PHOTO_INFO_RECORD: [u8; 136] = [
    0x03, 0x00, 0x00, 0x00, 0xd8, 0xd2, 0x23, 0x3c, 0xff, 0x94, 0x72, 0x5e, 0x26, 0x00, 0x00, 0x00,
    0x36, 0xf2, 0xe1, 0x28, 0xdd, 0x7c, 0x11, 0xa9, 0x31, 0xf0, 0xdf, 0xbe, 0xb4, 0x80, 0xa4, 0xbf,
    0x00, 0x00, 0x80, 0x3f, 0x37, 0x02, 0x46, 0x40, 0x02, 0x08, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x07, 0x00, 0x00, 0x00, 0x7d, 0x6a, 0x21, 0xbe, 0x68, 0x5c, 0x4d, 0xbf, 0x50, 0xad, 0x1d, 0xc4,
    0x6c, 0x5a, 0x94, 0xbf, 0xbe, 0x09, 0x11, 0xbe, 0xfe, 0xc3, 0x90, 0x44, 0x85, 0x59, 0x9e, 0xb9,
    0xff, 0x3e, 0x42, 0x39, 0x26, 0x1b, 0x34, 0xbf, 0xe8, 0xdf, 0x2d, 0xef, 0xb3, 0x2b, 0x00, 0x00,
    0xe8, 0xdf, 0x2d, 0xef, 0xb3, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

// ---------------------------------------------------------------------------
// Movie metadata merge
// ---------------------------------------------------------------------------

/// A movie-level `mdta` item: key, well-known data type, raw value.
type MetaItem = (Vec<u8>, u32, Vec<u8>);

fn style_movie_items(styles: &StillStyles, level: MovieStyleLevel) -> Vec<MetaItem> {
    let key = |s: &str| format!("com.apple.quicktime.{s}").into_bytes();
    let mut items: Vec<MetaItem> = Vec::new();
    if level >= MovieStyleLevel::Info {
        items.push((key("smartstyle.rendering-version"), 21, 1u32.to_be_bytes().to_vec()));
        items.push((key("smartstyle.tone"), 23, 0f32.to_be_bytes().to_vec()));
        items.push((key("smartstyle.color"), 23, 0f32.to_be_bytes().to_vec()));
        items.push((key("smartstyle.intensity"), 23, 1f32.to_be_bytes().to_vec()));
        items.push((key("smartstyle.bypassed"), 21, vec![1]));
        items.push((key("smartstyle.cast"), 21, 1u64.to_be_bytes().to_vec()));
    }
    if level >= MovieStyleLevel::Full {
        if let Some(texture) = &styles.texture {
            items.push((key("texturestyle.rendering-version"), 21, 1u32.to_be_bytes().to_vec()));
            items.push((
                key("texturestyle.preset"),
                21,
                texture_preset_code(&texture.preset).to_be_bytes().to_vec(),
            ));
            items.push((key("texturestyle.intensity"), 23, 1f32.to_be_bytes().to_vec()));
            items.push((key("texturestyle.grain"), 23, 0f32.to_be_bytes().to_vec()));
        }
    }
    items
}

/// Rebuild `moov/meta` with `extra` appended; existing keys keep their values.
fn merge_movie_meta(moov: &[u8], extra: &[MetaItem]) -> Result<Vec<u8>, String> {
    let root = MovBox {
        offset: 0,
        size: moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let mut names: Vec<Vec<u8>> = Vec::new();
    let mut values: Vec<Option<Vec<u8>>> = Vec::new();
    let mut handler: Option<Vec<u8>> = None;
    if let Some(meta) = scan_boxes(moov, root.payload_offset(), root.end())?
        .into_iter()
        .find(|b| &b.kind == b"meta")
    {
        for child in scan_boxes(moov, meta.payload_offset(), meta.end())? {
            match &child.kind {
                b"hdlr" => handler = Some(moov[child.offset..child.end()].to_vec()),
                b"keys" => {
                    for key in scan_boxes(moov, child.payload_offset() + 8, child.end())? {
                        // Namespace + name, e.g. b"mdta" + key.
                        names.push(moov[key.offset + 4..key.end()].to_vec());
                        values.push(None);
                    }
                }
                _ => {}
            }
        }
        if let Ok(ilst) = direct_child(moov, &meta, b"ilst") {
            for item in scan_boxes(moov, ilst.payload_offset(), ilst.end())? {
                let index = u32::from_be_bytes(item.kind) as usize;
                if index >= 1 && index <= values.len() {
                    values[index - 1] = Some(moov[item.payload_offset()..item.end()].to_vec());
                }
            }
        }
    }
    for (key, type_code, value) in extra {
        let mut name = b"mdta".to_vec();
        name.extend_from_slice(key);
        if names.contains(&name) {
            continue;
        }
        let mut data = type_code.to_be_bytes().to_vec();
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(value);
        names.push(name);
        values.push(Some(make_box(b"data", &data)));
    }
    let handler = handler.unwrap_or_else(|| {
        let mut p = vec![0u8; 8];
        p.extend_from_slice(b"mdta");
        p.extend_from_slice(&[0u8; 14]);
        make_box(b"hdlr", &p)
    });
    let mut keys = (names.len() as u32).to_be_bytes().to_vec();
    for name in &names {
        keys.extend_from_slice(&((name.len() + 4) as u32).to_be_bytes());
        keys.extend_from_slice(name);
    }
    let mut ilst = Vec::new();
    for (i, value) in values.iter().enumerate() {
        if let Some(v) = value {
            ilst.extend_from_slice(&make_box(&((i + 1) as u32).to_be_bytes(), v));
        }
    }
    Ok(make_box(
        b"meta",
        &[handler, full_box(b"keys", 0, 0, &keys), make_box(b"ilst", &ilst)].concat(),
    ))
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Add the Photographic Styles companion tracks to a paired Live Photo MOV.
///
/// `still_heic` is the paired still; it must carry the Styles plist. Source
/// samples keep their exact bytes: the companion samples go into one
/// appended `mdat` and a rebuilt `moov` replaces the old one.
pub fn attach_style_tracks(
    mov: &[u8],
    still_heic: &[u8],
    level: MovieStyleLevel,
) -> Result<Vec<u8>, String> {
    if level == MovieStyleLevel::Off {
        return Ok(mov.to_vec());
    }
    let styles = read_still_styles(still_heic)
        .ok_or("paired still has no readable Photographic Styles plist")?;
    attach_with(mov, &styles, level, |coded_turns, width, height| {
        crate::linear_thumbnail::generate_movie_linear_thumbnail(
            still_heic,
            coded_turns,
            width,
            height,
            styles.baseline_exposure as f32,
        )
    })
}

/// [`attach_style_tracks`] with the thumbnail source injected:
/// `thumbnail(coded_cw_quarter_turns, width, height)`.
fn attach_with(
    mov: &[u8],
    styles: &StillStyles,
    level: MovieStyleLevel,
    thumbnail: impl FnOnce(u32, u32, u32) -> Result<MovieLinearThumbnail, String>,
) -> Result<Vec<u8>, String> {
    if level == MovieStyleLevel::Off {
        return Ok(mov.to_vec());
    }
    let top = scan_boxes(mov, 0, mov.len())?;
    let moov_boxes: Vec<&MovBox> = top.iter().filter(|b| &b.kind == b"moov").collect();
    if moov_boxes.len() != 1 {
        return Err("movie must contain exactly one moov".into());
    }
    let moov_box = *moov_boxes[0];
    let moov = &mov[moov_box.offset..moov_box.end()];
    if moov.windows(THUMBNAIL_TAG.len()).any(|w| w == THUMBNAIL_TAG) {
        return Err("movie already carries style companion tracks".into());
    }
    let (_, _) = movie_timescale(moov)?;
    let video = video_track(moov)?;
    let root = MovBox {
        offset: 0,
        size: moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let children = scan_boxes(moov, root.payload_offset(), root.end())?;
    let first_id = children
        .iter()
        .filter(|b| &b.kind == b"trak")
        .map(|t| track_id(moov, t))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .max()
        .unwrap_or(0)
        + 1;
    let mut ids = first_id..;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        + QUICKTIME_EPOCH_OFFSET;
    let mut common = || TrackCommon {
        id: ids.next().unwrap(),
        timestamp,
        video: &video,
    };

    let mut companions: Vec<Companion> = Vec::new();
    let display_turns = video.display_cw_quarter_turns();
    let (tw, th) = crate::linear_thumbnail::fitted_even_dimensions(
        video.coded_width,
        video.coded_height,
        THUMBNAIL_MAX_EDGE,
    )?;
    let thumb = thumbnail((4 - display_turns) % 4, tw, th)?;
    let entry = hvc1_entry(tw, th, &thumb.hvcc, (9, 1, 9), Some(APPLE_LOG_TRANSFER));
    companions.push(aux_video_track(common(), THUMBNAIL_TAG, thumb.sample, entry, tw, th));
    // photographicStyleLearn also reads faceInfoTimedMetadata from the
    // asset's livePhotoInfo port (macOS 27.2 assert once the thumbnail
    // resolved). Every native Live Photo MOV carries this track.
    companions.push(mebx_track(
        common(),
        &live_photo_info_key_body(video.coded_width, video.coded_height),
        &LIVE_PHOTO_INFO_RECORD,
    ));

    if level >= MovieStyleLevel::Full {
        let (mw, mh) = crate::linear_thumbnail::fitted_even_dimensions(
            video.coded_width,
            video.coded_height,
            MATTE_MAX_EDGE,
        )?;
        let (matte, hvcc) = empty_matte(mw, mh)?;
        for tag in MATTE_TAGS {
            let entry = hvc1_entry(mw, mh, &hvcc, (12, 1, 6), None);
            companions.push(aux_video_track(common(), tag, matte.clone(), entry, mw, mh));
        }
    }
    if level >= MovieStyleLevel::Info {
        let payload = smartstyle_info_payload(styles, level >= MovieStyleLevel::Full);
        companions.push(mebx_track(common(), &plain_key_body(SMARTSTYLE_INFO_KEY), &payload));
    }
    if level >= MovieStyleLevel::Full {
        if let Some(texture) = &styles.texture {
            let payload = texturestyle_info_payload(texture);
            companions.push(mebx_track(common(), &plain_key_body(TEXTURESTYLE_INFO_KEY), &payload));
        }
    }
    let next_id = first_id + companions.len() as u32;

    // Output: source boxes (old moov dropped when last, else blanked), then
    // the companion mdat, then the rebuilt moov.
    let mut out = Vec::with_capacity(mov.len() + companions.iter().map(|c| c.data.len()).sum::<usize>());
    let moov_is_last = top.last().map(|b| b.offset == moov_box.offset).unwrap_or(false);
    for b in &top {
        if b.offset != moov_box.offset {
            out.extend_from_slice(&mov[b.offset..b.end()]);
        } else if !moov_is_last {
            if b.size > 0xFFFF_FFFF {
                return Err("cannot blank an oversized moov".into());
            }
            out.extend_from_slice(&(b.size as u32).to_be_bytes());
            out.extend_from_slice(b"free");
            out.extend(std::iter::repeat(0u8).take(b.size - 8));
        }
    }
    let payload_len: usize = companions.iter().map(|c| c.data.len()).sum();
    let large = payload_len + 8 > 0xFFFF_FFFF;
    let mut offset = out.len() as u64 + if large { 16 } else { 8 };
    let mut traks = Vec::new();
    let mut mdat_payload = Vec::with_capacity(payload_len);
    for companion in &companions {
        traks.extend_from_slice(&(companion.build)(offset));
        offset += companion.data.len() as u64;
        mdat_payload.extend_from_slice(&companion.data);
    }
    out.extend_from_slice(&make_box(b"mdat", &mdat_payload));

    let mut rebuilt = Vec::new();
    for child in &children {
        if &child.kind == b"meta" {
            continue;
        }
        let mut raw = moov[child.offset..child.end()].to_vec();
        // Pairs written before the QuickTime AAC fix: Photos renders the
        // video of a styled edit, which needs decodable audio.
        if &child.kind == b"trak" && handler_type(moov, child).ok() == Some(*b"soun") {
            if let Some(fixed) = crate::live_photo::quicktime_aac_track(&raw)? {
                raw = fixed;
            }
        }
        if &child.kind == b"mvhd" {
            let pos = raw.len() - 4;
            raw[pos..].copy_from_slice(&next_id.to_be_bytes());
        }
        rebuilt.extend_from_slice(&raw);
    }
    rebuilt.extend_from_slice(&traks);
    rebuilt.extend_from_slice(&merge_movie_meta(moov, &style_movie_items(styles, level))?);
    out.extend_from_slice(&make_box(b"moov", &rebuilt));
    Ok(out)
}

#[cfg(test)]
#[path = "live_photo_styles_tests.rs"]
mod tests;
