//! Apple Live Photo pair composition (Phase 3b), cross-platform.
//!
//! Ported from upstream XDRemux v1.4 `xdremux_py/live_photo_mov.py` and
//! `live_photo_still.py` (MIT, 21Z121Z1/XDRemux). No Apple framework is used:
//! the still gets a minimal Apple MakerNote with the shared content
//! identifier injected into its Exif IFD, and the video is rewritten as a
//! QuickTime MOV whose original media samples keep their exact bytes — only
//! `moov` is rebuilt with a metadata track marking the cover frame
//! (`com.apple.quicktime.still-image-time`) and the movie-level content
//! identifier.

use crate::motion_photo::OppoMetadata;

const QUICKTIME_EPOCH_OFFSET: u64 = 2_082_844_800;
const METADATA_TIMESCALE: u32 = 600;
const CONTENT_IDENTIFIER_KEY: &[u8] = b"com.apple.quicktime.content.identifier";
const STILL_IMAGE_KEY: &[u8] = b"com.apple.quicktime.still-image-time";
const TRANSFORM_KEY: &[u8] = b"com.apple.quicktime.live-photo-still-image-transform";
const REFERENCE_DIMENSIONS_KEY: &[u8] =
    b"com.apple.quicktime.live-photo-still-image-transform-reference-dimensions";
const LEGACY_COLOROS16_EIS_COMPENSATION_SCALE: f64 = 0.90;

// ---------------------------------------------------------------------------
// Apple MakerNote (still side)
// ---------------------------------------------------------------------------

/// Minimal Apple iOS MakerNote pairing the still to the movie: a single
/// tag 0x0011 ASCII entry carrying the upper-cased content identifier.
/// Mirrors upstream `build_apple_makernote`.
pub fn build_apple_makernote(content_identifier: &str) -> Result<Vec<u8>, String> {
    let upper = content_identifier.to_uppercase();
    if upper.is_empty() || !upper.is_ascii() || upper.contains('\0') {
        return Err("invalid Live Photo content identifier".into());
    }
    let mut value = upper.into_bytes();
    value.push(0);
    let mut header = Vec::from(&b"Apple iOS\0\0\x01MM"[..]);
    header.extend_from_slice(&1u16.to_be_bytes()); // one entry
    let value_offset = (header.len() + 12 + 4) as u32;
    header.extend_from_slice(&0x0011u16.to_be_bytes());
    header.extend_from_slice(&2u16.to_be_bytes()); // ASCII
    header.extend_from_slice(&(value.len() as u32).to_be_bytes());
    header.extend_from_slice(&value_offset.to_be_bytes());
    header.extend_from_slice(&0u32.to_be_bytes()); // next IFD = 0
    header.extend_from_slice(&value);
    Ok(header)
}

// ---------------------------------------------------------------------------
// TIFF/EXIF rewriter: inject MakerNote (tag 0x927C) into the Exif IFD
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct TiffEntry {
    tag: u16,
    type_id: u16,
    data: Vec<u8>, // resolved value bytes (count * type size)
}

struct TiffModel {
    little_endian: bool,
    ifd0: Vec<TiffEntry>,
    exif_ifd: Vec<TiffEntry>,
    gps_ifd: Vec<TiffEntry>,
}

fn type_size(type_id: u16) -> Option<usize> {
    match type_id {
        1 | 2 | 6 | 7 => Some(1),
        3 | 8 => Some(2),
        4 | 9 | 11 => Some(4),
        5 | 10 | 12 => Some(8),
        16 | 17 | 18 => Some(8),
        _ => None,
    }
}

fn read_tiff(tiff: &[u8]) -> Result<TiffModel, String> {
    if tiff.len() < 8 {
        return Err("TIFF header truncated".into());
    }
    let le = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return Err("invalid TIFF byte order".into()),
    };
    let u16 = |o: usize| -> Result<u16, String> {
        let b: [u8; 2] = tiff
            .get(o..o + 2)
            .ok_or("TIFF read out of range")?
            .try_into()
            .unwrap();
        Ok(if le {
            u16::from_le_bytes(b)
        } else {
            u16::from_be_bytes(b)
        })
    };
    let u32 = |o: usize| -> Result<u32, String> {
        let b: [u8; 4] = tiff
            .get(o..o + 4)
            .ok_or("TIFF read out of range")?
            .try_into()
            .unwrap();
        Ok(if le {
            u32::from_le_bytes(b)
        } else {
            u32::from_be_bytes(b)
        })
    };
    let read_ifd = |ifd_off: usize| -> Result<Vec<TiffEntry>, String> {
        let count = u16(ifd_off)? as usize;
        if count > 512 {
            return Err("TIFF IFD entry count exceeds safety limit".into());
        }
        let mut entries = Vec::with_capacity(count);
        for i in 0..count {
            let base = ifd_off + 2 + i * 12;
            let tag = u16(base)?;
            let type_id = u16(base + 2)?;
            let num = u32(base + 4)? as usize;
            let size = type_size(type_id).ok_or("unsupported TIFF field type")?;
            let total = num
                .checked_mul(size)
                .ok_or("TIFF field size overflow")?;
            let data = if total <= 4 {
                tiff.get(base + 8..base + 8 + total)
                    .ok_or("TIFF inline value out of range")?
                    .to_vec()
            } else {
                let value_off = u32(base + 8)? as usize;
                tiff.get(value_off..value_off + total)
                    .ok_or("TIFF value offset out of range")?
                    .to_vec()
            };
            entries.push(TiffEntry { tag, type_id, data });
        }
        Ok(entries)
    };
    let ifd0_off = u32(4)? as usize;
    let ifd0 = read_ifd(ifd0_off)?;
    let find_sub = |entries: &[TiffEntry], tag: u16| -> Option<usize> {
        entries
            .iter()
            .find(|e| e.tag == tag)
            .and_then(|e| {
                if e.data.len() == 4 {
                    Some(if le {
                        u32::from_le_bytes(e.data.clone().try_into().unwrap())
                    } else {
                        u32::from_be_bytes(e.data.clone().try_into().unwrap())
                    } as usize)
                } else {
                    None
                }
            })
    };
    let exif_ifd = match find_sub(&ifd0, 0x8769) {
        Some(off) if off + 2 <= tiff.len() => read_ifd(off)?,
        _ => Vec::new(),
    };
    let gps_ifd = match find_sub(&ifd0, 0x8825) {
        Some(off) if off + 2 <= tiff.len() => read_ifd(off)?,
        _ => Vec::new(),
    };
    Ok(TiffModel {
        little_endian: le,
        ifd0,
        exif_ifd,
        gps_ifd,
    })
}

fn write_tiff(model: &TiffModel) -> Vec<u8> {
    let le = model.little_endian;
    let mut out: Vec<u8> = Vec::new();
    let push_u16 = |v: u16, o: &mut Vec<u8>| {
        let bytes = if le { v.to_le_bytes() } else { v.to_be_bytes() };
        o.extend_from_slice(&bytes);
    };
    let push_u32 = |v: u32, o: &mut Vec<u8>| {
        let bytes = if le { v.to_le_bytes() } else { v.to_be_bytes() };
        o.extend_from_slice(&bytes);
    };
    out.extend_from_slice(if le { b"II" } else { b"MM" });
    push_u16(42, &mut out);
    push_u32(8, &mut out); // IFD0 right after the header

    // Layout: IFD0 | data0 | ExifIFD | dataExif | GpsIFD | dataGps.
    let has_exif = !model.exif_ifd.is_empty();
    let has_gps = !model.gps_ifd.is_empty();
    let ifd0_len = 2 + model.ifd0.len() * 12 + 4;
    let exif_off = 8 + ifd0_len + model
        .ifd0
        .iter()
        .map(|e| if e.data.len() > 4 { e.data.len() } else { 0 })
        .sum::<usize>();
    let gps_off = exif_off
        + if has_exif {
            2 + model.exif_ifd.len() * 12 + 4
                + model
                    .exif_ifd
                    .iter()
                    .map(|e| if e.data.len() > 4 { e.data.len() } else { 0 })
                    .sum::<usize>()
        } else {
            0
        };

    let mut write_ifd = |entries: &[TiffEntry],
                         out: &mut Vec<u8>,
                         exif_target: Option<u32>,
                         gps_target: Option<u32>|
     -> Vec<u8> {
        // Returns the data area bytes for this IFD.
        let mut data_area: Vec<u8> = Vec::new();
        let mut table: Vec<u8> = Vec::new();
        push_u16(entries.len() as u16, &mut table);
        let ifd_start = out.len();
        for e in entries {
            push_u16(e.tag, &mut table);
            push_u16(e.type_id, &mut table);
            let size = type_size(e.type_id).unwrap();
            let count = (e.data.len() / size) as u32;
            push_u32(count, &mut table);
            if e.data.len() <= 4 {
                table.extend_from_slice(&e.data);
                table.extend(std::iter::repeat(0u8).take(4 - e.data.len()));
            } else if e.tag == 0x8769 && exif_target.is_some() {
                push_u32(exif_target.unwrap(), &mut table);
            } else if e.tag == 0x8825 && gps_target.is_some() {
                push_u32(gps_target.unwrap(), &mut table);
            } else {
                let area_start = ifd_start + 2 + entries.len() * 12 + 4;
                let value_off = area_start + data_area.len();
                push_u32(value_off as u32, &mut table);
                data_area.extend_from_slice(&e.data);
            }
        }
        push_u32(0, &mut table); // no next IFD
        out.extend_from_slice(&table);
        data_area
    };

    let data0 = write_ifd(
        &model.ifd0,
        &mut out,
        has_exif.then_some(exif_off as u32),
        has_gps.then_some(gps_off as u32),
    );
    out.extend_from_slice(&data0);
    if has_exif {
        let data = write_ifd(&model.exif_ifd, &mut out, None, None);
        out.extend_from_slice(&data);
    }
    if has_gps {
        let data = write_ifd(&model.gps_ifd, &mut out, None, None);
        out.extend_from_slice(&data);
    }
    out
}

/// Inject the Apple MakerNote carrying the Live Photo content identifier
/// into the Exif IFD of a TIFF payload (the part after the HEIF Exif item's
/// 4-byte offset prefix). The IFD1 thumbnail chain is dropped; camera
/// thumbnails are not needed for the pairing contract.
pub fn inject_makernote(tiff: &[u8], content_identifier: &str) -> Result<Vec<u8>, String> {
    let mut model = read_tiff(tiff)?;
    let note = build_apple_makernote(content_identifier)?;
    match model.exif_ifd.iter_mut().find(|e| e.tag == 0x927C) {
        Some(e) => e.data = note,
        None => model.exif_ifd.push(TiffEntry {
            tag: 0x927C,
            type_id: 7,
            data: note,
        }),
    }
    Ok(write_tiff(&model))
}

// ---------------------------------------------------------------------------
// ISO BMFF / QuickTime helpers (movie side)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
struct MovBox {
    offset: usize,
    size: usize,
    kind: [u8; 4],
    header_size: usize,
}

impl MovBox {
    fn payload_offset(&self) -> usize {
        self.offset + self.header_size
    }
    fn end(&self) -> usize {
        self.offset + self.size
    }
}

fn scan_boxes(data: &[u8], start: usize, end: usize) -> Result<Vec<MovBox>, String> {
    let mut out = Vec::new();
    let mut offset = start;
    while offset < end {
        if offset + 8 > end {
            return Err("truncated ISO BMFF box header".into());
        }
        let size32 = u32::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]);
        let kind = [data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7]];
        let (size, header_size) = if size32 == 1 {
            if offset + 16 > end {
                return Err("truncated extended box header".into());
            }
            (
                u64::from_be_bytes(data[offset + 8..offset + 16].try_into().unwrap()) as usize,
                16usize,
            )
        } else if size32 == 0 {
            (end - offset, 8usize)
        } else {
            (size32 as usize, 8usize)
        };
        if size < header_size || offset + size > end {
            return Err(format!(
                "invalid {} box size {size}",
                String::from_utf8_lossy(&kind)
            ));
        }
        out.push(MovBox {
            offset,
            size,
            kind,
            header_size,
        });
        offset += size;
    }
    Ok(out)
}

fn make_box(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let size = 8 + payload.len();
    if size <= 0xFFFF_FFFF {
        let mut v = Vec::with_capacity(size);
        v.extend_from_slice(&(size as u32).to_be_bytes());
        v.extend_from_slice(kind);
        v.extend_from_slice(payload);
        v
    } else {
        let mut v = Vec::with_capacity(16 + payload.len());
        v.extend_from_slice(&1u32.to_be_bytes());
        v.extend_from_slice(kind);
        v.extend_from_slice(&((size + 8) as u64).to_be_bytes());
        v.extend_from_slice(payload);
        v
    }
}

fn full_box(kind: &[u8; 4], version: u8, flags: u32, payload: &[u8]) -> Vec<u8> {
    let mut p = Vec::with_capacity(4 + payload.len());
    p.push(version);
    p.extend_from_slice(&flags.to_be_bytes()[1..]);
    p.extend_from_slice(payload);
    make_box(kind, &p)
}

fn direct_child<'a>(data: &[u8], parent: &MovBox, kind: &[u8; 4]) -> Result<MovBox, String> {
    scan_boxes(data, parent.payload_offset(), parent.end())?
        .into_iter()
        .find(|b| &b.kind == kind)
        .ok_or_else(|| format!("missing {} box", String::from_utf8_lossy(kind)))
}

fn movie_timescale(moov: &[u8]) -> Result<(u32, u64), String> {
    let root = MovBox {
        offset: 0,
        size: moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let mvhd = direct_child(moov, &root, b"mvhd")?;
    let version = moov[mvhd.payload_offset()];
    let (ts_off, dur_off, width) = match version {
        0 => (mvhd.offset + 20, mvhd.offset + 24, 4usize),
        1 => (mvhd.offset + 28, mvhd.offset + 32, 8usize),
        v => return Err(format!("unsupported mvhd version {v}")),
    };
    let timescale = u32::from_be_bytes(moov[ts_off..ts_off + 4].try_into().unwrap());
    let duration = u64::from_be_bytes({
        let mut b = [0u8; 8];
        b[8 - width..].copy_from_slice(&moov[dur_off..dur_off + width]);
        b
    });
    if timescale == 0 {
        return Err("invalid movie timescale".into());
    }
    Ok((timescale, duration))
}

fn track_id(moov: &[u8], track: &MovBox) -> Result<u32, String> {
    let tkhd = direct_child(moov, track, b"tkhd")?;
    let version = moov[tkhd.payload_offset()];
    let off = tkhd.offset + if version == 0 { 20 } else { 28 };
    Ok(u32::from_be_bytes(moov[off..off + 4].try_into().unwrap()))
}

fn handler_type(moov: &[u8], track: &MovBox) -> Result<[u8; 4], String> {
    let mdia = direct_child(moov, track, b"mdia")?;
    let hdlr = direct_child(moov, &mdia, b"hdlr")?;
    if hdlr.size < 20 {
        return Err("truncated media handler".into());
    }
    Ok(moov[hdlr.payload_offset() + 8..hdlr.payload_offset() + 12]
        .try_into()
        .unwrap())
}

fn mdhd_timescale(moov: &[u8], track: &MovBox) -> Result<u32, String> {
    let mdia = direct_child(moov, track, b"mdia")?;
    let mdhd = direct_child(moov, &mdia, b"mdhd")?;
    let version = moov[mdhd.payload_offset()];
    let off = mdhd.offset + if version == 0 { 20 } else { 28 };
    let value = u32::from_be_bytes(moov[off..off + 4].try_into().unwrap());
    if value == 0 {
        return Err("invalid media timescale".into());
    }
    Ok(value)
}

/// Sample presentation times (seconds) of a track from stts+ctts.
fn sample_pts_seconds(moov: &[u8], track: &MovBox) -> Result<Vec<f64>, String> {
    let timescale = mdhd_timescale(moov, track)?;
    let mdia = direct_child(moov, track, b"mdia")?;
    let minf = direct_child(moov, &mdia, b"minf")?;
    let stbl = direct_child(moov, &minf, b"stbl")?;
    let stts = direct_child(moov, &stbl, b"stts")?;
    let mut cursor = stts.payload_offset() + 4;
    if cursor + 4 > stts.end() {
        return Err("truncated stts".into());
    }
    let entry_count =
        u32::from_be_bytes(moov[cursor..cursor + 4].try_into().unwrap()) as usize;
    cursor += 4;
    let mut dts: Vec<u64> = Vec::new();
    let mut clock = 0u64;
    for _ in 0..entry_count {
        if cursor + 8 > stts.end() {
            return Err("truncated stts entry".into());
        }
        let count = u32::from_be_bytes(moov[cursor..cursor + 4].try_into().unwrap()) as usize;
        let delta = u32::from_be_bytes(moov[cursor + 4..cursor + 8].try_into().unwrap()) as u64;
        cursor += 8;
        if count > 10_000_000usize.saturating_sub(dts.len()) {
            return Err("video sample table exceeds safety limit".into());
        }
        for _ in 0..count {
            dts.push(clock);
            clock += delta;
        }
    }
    if dts.is_empty() {
        return Err("video track has no samples".into());
    }
    let mut offsets = vec![0i64; dts.len()];
    if let Some(ctts) = scan_boxes(moov, stbl.payload_offset(), stbl.end())?
        .into_iter()
        .find(|b| &b.kind == b"ctts")
    {
        let version = moov[ctts.payload_offset()];
        let mut cursor = ctts.payload_offset() + 4;
        let entry_count =
            u32::from_be_bytes(moov[cursor..cursor + 4].try_into().unwrap()) as usize;
        cursor += 4;
        let mut sample_index = 0usize;
        for _ in 0..entry_count {
            if cursor + 8 > ctts.end() {
                return Err("truncated ctts entry".into());
            }
            let count =
                u32::from_be_bytes(moov[cursor..cursor + 4].try_into().unwrap()) as usize;
            let value = if version == 1 {
                i32::from_be_bytes(moov[cursor + 4..cursor + 8].try_into().unwrap()) as i64
            } else {
                u32::from_be_bytes(moov[cursor + 4..cursor + 8].try_into().unwrap()) as i64
            };
            cursor += 8;
            if sample_index + count > offsets.len() {
                return Err("ctts sample count exceeds stts".into());
            }
            for slot in offsets.iter_mut().skip(sample_index).take(count) {
                *slot = value;
            }
            sample_index += count;
        }
        if sample_index != offsets.len() {
            return Err("ctts/stts sample count mismatch".into());
        }
    }
    Ok(dts
        .iter()
        .zip(offsets.iter())
        .map(|(&d, &o)| (d as i64 + o) as f64 / timescale as f64)
        .collect())
}

/// Cover-frame timestamp: nearest sample PTS to the requested XMP timestamp,
/// or one sample before the midpoint when no timestamp was declared.
pub fn resolve_still_time(
    video: &[u8],
    requested_timestamp_us: Option<i64>,
) -> Result<f64, String> {
    let top = scan_boxes(video, 0, video.len())?;
    let moov_boxes: Vec<&MovBox> = top.iter().filter(|b| &b.kind == b"moov").collect();
    if moov_boxes.len() != 1 {
        return Err("embedded video must contain exactly one moov box".into());
    }
    let moov = &video[moov_boxes[0].offset..moov_boxes[0].end()];
    let (movie_ts, movie_dur) = movie_timescale(moov)?;
    let root = MovBox {
        offset: 0,
        size: moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let tracks: Vec<MovBox> = scan_boxes(moov, root.payload_offset(), root.end())?
        .into_iter()
        .filter(|b| &b.kind == b"trak")
        .collect();
    let video_tracks: Vec<&MovBox> = tracks
        .iter()
        .filter(|t| handler_type(moov, t).map(|h| &h == b"vide").unwrap_or(false))
        .collect();
    let Some(track) = video_tracks.first() else {
        return Err("embedded video contains no video track".into());
    };
    let pts = sample_pts_seconds(moov, track)?;
    let duration_seconds = movie_dur as f64 / movie_ts as f64;
    if let Some(us) = requested_timestamp_us {
        let requested = us as f64 / 1_000_000.0;
        if requested < 0.0 || requested > duration_seconds {
            return Err("Motion Photo still timestamp lies outside the video".into());
        }
        return pts
            .iter()
            .copied()
            .reduce(|a, b| {
                if (a - requested).abs() <= (b - requested).abs() {
                    a
                } else {
                    b
                }
            })
            .ok_or("video track has no samples".into());
    }
    let midpoint = duration_seconds * 0.5;
    let closest = pts
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| {
            (**a - midpoint)
                .abs()
                .partial_cmp(&(**b - midpoint).abs())
                .unwrap()
        })
        .map(|(i, _)| i)
        .unwrap_or(0);
    Ok(pts[closest.saturating_sub(1)])
}

// ---------------------------------------------------------------------------
// OPPO still-image transform (EIS/crop alignment)
// ---------------------------------------------------------------------------

fn invert3(m: [f64; 9]) -> Option<[f64; 9]> {
    let [a, b, c, d, e, f, g, h, i] = m;
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if !det.is_finite() || det.abs() <= 1e-10 {
        return None;
    }
    let inv = 1.0 / det;
    Some([
        (e * i - f * h) * inv,
        (c * h - b * i) * inv,
        (b * f - c * e) * inv,
        (f * g - d * i) * inv,
        (a * i - c * g) * inv,
        (c * d - a * f) * inv,
        (d * h - e * g) * inv,
        (b * g - a * h) * inv,
        (a * e - b * d) * inv,
    ])
}

fn multiply3(a: [f64; 9], b: [f64; 9]) -> [f64; 9] {
    let mut out = [0.0; 9];
    for r in 0..3 {
        for c in 0..3 {
            out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
        }
    }
    out
}

fn normalized_axis_scale(value: f64) -> Option<f64> {
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    let scale = if value > 1.0 { 1.0 / value } else { value };
    (scale.is_finite() && scale > 0.0 && scale <= 1.0).then_some(scale)
}

fn normalized_scale(factors: Option<[f64; 2]>) -> Option<(f64, f64)> {
    let [x, y] = factors?;
    Some((normalized_axis_scale(x)?, normalized_axis_scale(y)?))
}

fn normalize_homography(m: [f64; 9]) -> Option<[f64; 9]> {
    if m.iter().any(|v| !v.is_finite()) || m[8].abs() <= 1e-12 {
        return None;
    }
    let mut out = [0.0; 9];
    for i in 0..9 {
        out[i] = m[i] / m[8];
    }
    Some(out)
}

/// ColorOS 16+ (LPEX version >= 1): scale by the EIS compensation factor,
/// then un-apply the photo crop and EIS homographies. Mirrors upstream
/// `oppo_transform`; returns None for identity/absent metadata.
pub fn oppo_transform(metadata: Option<&OppoMetadata>) -> Option<[f64; 9]> {
    let metadata = metadata?;
    if metadata.version < 1 {
        return None; // legacy matrix-list path not needed for current devices
    }
    let (scale_x, scale_y) = normalized_scale(metadata.photo_eis_crop_factor)
        .or_else(|| normalized_scale(metadata.eis_crop_factor))
        .unwrap_or((
            LEGACY_COLOROS16_EIS_COMPENSATION_SCALE,
            LEGACY_COLOROS16_EIS_COMPENSATION_SCALE,
        ));
    let mut result = [scale_x, 0.0, 0.0, 0.0, scale_y, 0.0, 0.0, 0.0, 1.0];
    if let Some(m) = metadata.photo_crop_matrix.and_then(invert3) {
        result = multiply3(result, m);
    }
    if let Some(m) = metadata.photo_eis_matrix.and_then(invert3) {
        result = multiply3(result, m);
    }
    let normalized = normalize_homography(result)?;
    const IDENTITY: [f64; 9] = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
    if normalized
        .iter()
        .zip(IDENTITY.iter())
        .all(|(a, b)| (a - b).abs() <= 1e-6)
    {
        return None;
    }
    Some(normalized)
}

// ---------------------------------------------------------------------------
// Metadata track + movie metadata
// ---------------------------------------------------------------------------

fn metadata_key_atom(local_id: u32, name: &[u8], type_code: u32) -> Vec<u8> {
    let mut keyd_payload = b"mdta".to_vec();
    keyd_payload.extend_from_slice(name);
    let keyd = make_box(b"keyd", &keyd_payload);
    let mut dtyp_payload = Vec::new();
    dtyp_payload.extend_from_slice(&0u32.to_be_bytes());
    dtyp_payload.extend_from_slice(&type_code.to_be_bytes());
    let dtyp = make_box(b"dtyp", &dtyp_payload);
    make_box(&local_id.to_be_bytes(), &[keyd, dtyp].concat())
}

fn metadata_sample(transform: Option<[f64; 9]>, dimensions: Option<(f32, f32)>) -> Vec<u8> {
    let mut out = make_box(&1u32.to_be_bytes(), b"\x00");
    if let Some(t) = transform {
        let mut payload = Vec::new();
        for v in t {
            payload.extend_from_slice(&v.to_be_bytes());
        }
        out.extend_from_slice(&make_box(&2u32.to_be_bytes(), &payload));
    }
    if let Some((w, h)) = dimensions {
        let mut payload = Vec::new();
        payload.extend_from_slice(&w.to_be_bytes());
        payload.extend_from_slice(&h.to_be_bytes());
        out.extend_from_slice(&make_box(&3u32.to_be_bytes(), &payload));
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn metadata_track(
    track_id: u32,
    movie_timescale: u32,
    still_time_seconds: f64,
    chunk_offset: u64,
    timestamp: u64,
    transform: Option<[f64; 9]>,
    dimensions: Option<(f32, f32)>,
) -> (Vec<u8>, Vec<u8>) {
    let sample = metadata_sample(transform, dimensions);
    let empty_duration = (still_time_seconds * movie_timescale as f64).round().max(0.0) as u32;
    let marker_duration = (movie_timescale / METADATA_TIMESCALE).max(1);
    let track_duration = empty_duration + marker_duration;
    assert!(track_duration != 0 || true);

    let matrix: [u32; 9] = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000];
    let mut tkhd_payload = Vec::new();
    for v in [timestamp, timestamp, track_id as u64, 0, track_duration as u64] {
        tkhd_payload.extend_from_slice(&(v as u32).to_be_bytes());
    }
    tkhd_payload.extend_from_slice(&[0u8; 8]);
    tkhd_payload.extend_from_slice(&[0u8; 8]); // layer/group/volume/reserved
    for v in matrix {
        tkhd_payload.extend_from_slice(&v.to_be_bytes());
    }
    tkhd_payload.extend_from_slice(&[0u8; 8]); // width/height
    let tkhd = full_box(b"tkhd", 0, 0x0F, &tkhd_payload);

    let mut edits: Vec<u8> = Vec::new();
    let mut edit_count = 0u32;
    if empty_duration > 0 {
        edits.extend_from_slice(&empty_duration.to_be_bytes());
        edits.extend_from_slice(&(-1i32).to_be_bytes());
        edits.extend_from_slice(&1u16.to_be_bytes());
        edits.extend_from_slice(&0u16.to_be_bytes());
        edit_count += 1;
    }
    edits.extend_from_slice(&marker_duration.to_be_bytes());
    edits.extend_from_slice(&0i32.to_be_bytes());
    edits.extend_from_slice(&1u16.to_be_bytes());
    edits.extend_from_slice(&0u16.to_be_bytes());
    edit_count += 1;
    let mut elst_payload = Vec::new();
    elst_payload.extend_from_slice(&edit_count.to_be_bytes());
    elst_payload.extend_from_slice(&edits);
    let edts = make_box(b"edts", &full_box(b"elst", 0, 0, &elst_payload));

    let mut mdhd_payload = Vec::new();
    for v in [timestamp, timestamp, METADATA_TIMESCALE as u64, 1] {
        mdhd_payload.extend_from_slice(&(v as u32).to_be_bytes());
    }
    mdhd_payload.extend_from_slice(&0x55C4u16.to_be_bytes()); // und language
    mdhd_payload.extend_from_slice(&0u16.to_be_bytes());
    let mdhd = full_box(b"mdhd", 0, 0, &mdhd_payload);

    let media_name = b"Core Media Metadata";
    let mut mhlr_payload = b"mhlrmetaappl".to_vec();
    mhlr_payload.extend_from_slice(&1u32.to_be_bytes());
    mhlr_payload.extend_from_slice(&0u32.to_be_bytes());
    mhlr_payload.push(media_name.len() as u8);
    mhlr_payload.extend_from_slice(media_name);
    let media_handler = full_box(b"hdlr", 0, 0, &mhlr_payload);

    let mut gmin_payload = Vec::new();
    gmin_payload.extend_from_slice(&0x40u16.to_be_bytes());
    gmin_payload.extend_from_slice(&0x8000u16.to_be_bytes());
    gmin_payload.extend_from_slice(&0x8000u16.to_be_bytes());
    gmin_payload.extend_from_slice(&0x8000u16.to_be_bytes());
    gmin_payload.extend_from_slice(&0i16.to_be_bytes());
    gmin_payload.extend_from_slice(&0u16.to_be_bytes());
    let gmhd = make_box(b"gmhd", &full_box(b"gmin", 0, 0, &gmin_payload));

    let data_name = b"Core Media Data Handler";
    let mut dhlr_payload = b"dhlralisappl".to_vec();
    dhlr_payload.extend_from_slice(&0u32.to_be_bytes());
    dhlr_payload.extend_from_slice(&0u32.to_be_bytes());
    dhlr_payload.push(data_name.len() as u8);
    dhlr_payload.extend_from_slice(data_name);
    let data_handler = full_box(b"hdlr", 0, 0, &dhlr_payload);

    let mut dref_payload = Vec::new();
    dref_payload.extend_from_slice(&1u32.to_be_bytes());
    dref_payload.extend_from_slice(&full_box(b"alis", 0, 1, &[]));
    let dinf = make_box(b"dinf", &full_box(b"dref", 0, 0, &dref_payload));

    let mut key_atoms = vec![metadata_key_atom(1, STILL_IMAGE_KEY, 65)];
    if transform.is_some() {
        key_atoms.push(metadata_key_atom(2, TRANSFORM_KEY, 79));
    }
    if dimensions.is_some() {
        key_atoms.push(metadata_key_atom(3, REFERENCE_DIMENSIONS_KEY, 71));
    }
    let keys = make_box(b"keys", &key_atoms.concat());
    let mut mebx_payload = vec![0u8; 6];
    mebx_payload.extend_from_slice(&1u16.to_be_bytes()); // one entry
    mebx_payload.extend_from_slice(&keys);
    let mebx = make_box(b"mebx", &mebx_payload);

    let mut stsd_payload = Vec::new();
    stsd_payload.extend_from_slice(&1u32.to_be_bytes());
    stsd_payload.extend_from_slice(&mebx);
    let stsd = full_box(b"stsd", 0, 0, &stsd_payload);

    let mut stts_payload = Vec::new();
    for v in [1u32, 1, 1] {
        stts_payload.extend_from_slice(&v.to_be_bytes());
    }
    let stts = full_box(b"stts", 0, 0, &stts_payload);

    let mut stsc_payload = Vec::new();
    for v in [1u32, 1, 1, 1] {
        stsc_payload.extend_from_slice(&v.to_be_bytes());
    }
    let stsc = full_box(b"stsc", 0, 0, &stsc_payload);

    let mut stsz_payload = Vec::new();
    stsz_payload.extend_from_slice(&(sample.len() as u32).to_be_bytes());
    stsz_payload.extend_from_slice(&1u32.to_be_bytes());
    let stsz = full_box(b"stsz", 0, 0, &stsz_payload);

    let chunk = if chunk_offset > 0xFFFF_FFFF {
        let mut p = Vec::new();
        p.extend_from_slice(&1u32.to_be_bytes());
        p.extend_from_slice(&chunk_offset.to_be_bytes());
        full_box(b"co64", 0, 0, &p)
    } else {
        let mut p = Vec::new();
        p.extend_from_slice(&1u32.to_be_bytes());
        p.extend_from_slice(&(chunk_offset as u32).to_be_bytes());
        full_box(b"stco", 0, 0, &p)
    };

    let stbl = make_box(b"stbl", &[stsd, stts, stsc, stsz, chunk].concat());
    let minf = make_box(b"minf", &[gmhd, data_handler, dinf, stbl].concat());
    let mdia = make_box(b"mdia", &[mdhd, media_handler, minf].concat());
    (make_box(b"trak", &[tkhd, edts, mdia].concat()), sample)
}

fn movie_metadata(content_identifier: &str) -> Result<Vec<u8>, String> {
    if !content_identifier.is_ascii()
        || content_identifier.is_empty()
        || content_identifier.contains('\0')
    {
        return Err("Live Photo content identifier must be non-empty ASCII".into());
    }
    let identifier = content_identifier.as_bytes();
    let mut handler_payload = vec![0u8; 8];
    handler_payload.extend_from_slice(b"mdta");
    handler_payload.extend_from_slice(&[0u8; 14]);
    let handler = make_box(b"hdlr", &handler_payload);
    let mut keys_payload = Vec::new();
    keys_payload.extend_from_slice(&1u32.to_be_bytes());
    keys_payload.extend_from_slice(&make_box(b"mdta", CONTENT_IDENTIFIER_KEY));
    let keys = full_box(b"keys", 0, 0, &keys_payload);
    let mut data_payload = Vec::new();
    data_payload.extend_from_slice(&1u32.to_be_bytes());
    data_payload.extend_from_slice(&0u32.to_be_bytes());
    data_payload.extend_from_slice(identifier);
    let data = make_box(b"data", &data_payload);
    let ilst = make_box(b"ilst", &make_box(&1u32.to_be_bytes(), &data));
    Ok(make_box(b"meta", &[handler, keys, ilst].concat()))
}

fn rebuild_moov(
    original: &[u8],
    metadata_track: &[u8],
    movie_meta: &[u8],
    new_track_id: u32,
) -> Result<Vec<u8>, String> {
    let root = MovBox {
        offset: 0,
        size: original.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let mut rebuilt: Vec<u8> = Vec::new();
    for child in scan_boxes(original, root.payload_offset(), root.end())? {
        if &child.kind == b"meta" {
            continue;
        }
        let mut raw = original[child.offset..child.end()].to_vec();
        if &child.kind == b"mvhd" {
            // next_track_id is the last 4 bytes of mvhd (both versions).
            let pos = raw.len() - 4;
            raw[pos..pos + 4].copy_from_slice(&(new_track_id + 1).to_be_bytes());
        }
        rebuilt.extend_from_slice(&raw);
    }
    rebuilt.extend_from_slice(metadata_track);
    rebuilt.extend_from_slice(movie_meta);
    Ok(make_box(b"moov", &rebuilt))
}

/// Rewrite a Motion Photo video stream as the MOV half of an Apple Live
/// Photo pair. Source media bytes are preserved exactly; the old moov is
/// replaced by an equal-size free box and the rebuilt moov is appended.
pub fn write_live_photo_movie(
    source: &[u8],
    content_identifier: &str,
    still_time_seconds: f64,
    oppo_metadata: Option<&OppoMetadata>,
) -> Result<Vec<u8>, String> {
    if !still_time_seconds.is_finite() || still_time_seconds < 0.0 {
        return Err("invalid Live Photo still time".into());
    }
    let top = scan_boxes(source, 0, source.len())?;
    let ftyp_boxes: Vec<&MovBox> = top.iter().filter(|b| &b.kind == b"ftyp").collect();
    let moov_boxes: Vec<&MovBox> = top.iter().filter(|b| &b.kind == b"moov").collect();
    if ftyp_boxes.len() != 1 || moov_boxes.len() != 1 {
        return Err("source video must contain exactly one ftyp and one moov".into());
    }
    let ftyp = ftyp_boxes[0];
    let moov_box = moov_boxes[0];
    if ftyp.size < ftyp.header_size + 8 {
        return Err("source ftyp is too small".into());
    }
    let original_moov = &source[moov_box.offset..moov_box.end()];
    let (movie_ts, _) = movie_timescale(original_moov)?;
    let root = MovBox {
        offset: 0,
        size: original_moov.len(),
        kind: *b"moov",
        header_size: 8,
    };
    let tracks: Vec<MovBox> = scan_boxes(original_moov, root.payload_offset(), root.end())?
        .into_iter()
        .filter(|b| &b.kind == b"trak")
        .collect();
    let new_track_id = tracks
        .iter()
        .map(|t| track_id(original_moov, t))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .max()
        .unwrap_or(0)
        + 1;

    let transform = oppo_transform(oppo_metadata);
    let dimensions = match (transform, oppo_metadata) {
        (Some(_), Some(m)) => match (m.video_width, m.video_height) {
            (Some(w), Some(h)) => Some((w as f32, h as f32)),
            _ => None,
        },
        _ => None,
    };

    let timestamp = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0))
        + QUICKTIME_EPOCH_OFFSET;
    let marker_payload_offset = source.len() as u64 + 8;
    let (metadata_track_bytes, marker_sample) = metadata_track(
        new_track_id,
        movie_ts,
        still_time_seconds,
        marker_payload_offset,
        timestamp,
        transform,
        dimensions,
    );
    let marker_mdat = make_box(b"mdat", &marker_sample);
    let movie_meta = movie_metadata(content_identifier)?;
    let new_moov = rebuild_moov(original_moov, &metadata_track_bytes, &movie_meta, new_track_id)?;

    let mut out = Vec::with_capacity(source.len() + marker_mdat.len() + new_moov.len());
    for b in &top {
        if &b.kind == b"moov" {
            // Equal-size free box keeps every existing sample offset valid.
            if b.size < 8 {
                return Err("cannot replace undersized moov box".into());
            }
            if b.size <= 0xFFFF_FFFF {
                out.extend_from_slice(&(b.size as u32).to_be_bytes());
                out.extend_from_slice(b"free");
                out.extend(std::iter::repeat(0u8).take(b.size - 8));
            } else {
                out.extend_from_slice(&1u32.to_be_bytes());
                out.extend_from_slice(b"free");
                out.extend_from_slice(&((b.size + 8) as u64).to_be_bytes());
                out.extend(std::iter::repeat(0u8).take(b.size - 16));
            }
        } else if &b.kind == b"ftyp" {
            let mut raw = source[b.offset..b.end()].to_vec();
            // QuickTime brand, version 0.
            raw[b.header_size..b.header_size + 4].copy_from_slice(b"qt  ");
            raw[b.header_size + 4..b.header_size + 8].copy_from_slice(&[0, 0, 0, 0]);
            out.extend_from_slice(&raw);
        } else {
            out.extend_from_slice(&source[b.offset..b.end()]);
        }
    }
    out.extend_from_slice(&marker_mdat);
    out.extend_from_slice(&new_moov);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Pair orchestration
// ---------------------------------------------------------------------------

/// Compose an Apple Live Photo pair from a converted HEIC still and the
/// Motion Photo video bytes. Returns (still_heic, video_mov, content_id).
/// The still gains the Apple MakerNote; the video is rewritten as a MOV with
/// the content identifier and still-image-time marker.
pub fn make_live_photo(
    still_heic: &[u8],
    video: &[u8],
    cover_pts_us: Option<i64>,
    oppo_metadata: Option<&OppoMetadata>,
) -> Result<(Vec<u8>, Vec<u8>, String), String> {
    let content_id = uuid_v4();
    let still_time = resolve_still_time(video, cover_pts_us)?;

    // Still side: inject the MakerNote into the Exif item payload.
    let mut still_out = still_heic.to_vec();
    let payload = crate::isobmff_write::read_exif_payload(still_heic)?
        .ok_or("converted still has no Exif item; cannot pair Live Photo")?;
    // HEIF Exif item: 4-byte TIFF-offset prefix + TIFF payload.
    let tiff_start = if payload.starts_with(b"II") || payload.starts_with(b"MM") {
        0
    } else {
        4
    };
    let tiff = &payload[tiff_start..];
    let new_tiff = inject_makernote(tiff, &content_id)?;
    let mut new_payload = payload[..tiff_start].to_vec();
    new_payload.extend_from_slice(&new_tiff);
    if !crate::isobmff_write::install_exif_payload(&mut still_out, &new_payload)? {
        return Err("failed to write the Live Photo MakerNote into the still".into());
    }

    let mov = write_live_photo_movie(video, &content_id, still_time, oppo_metadata)?;
    Ok((still_out, mov, content_id))
}

fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
        .to_be_bytes();
    let pid = std::process::id().to_be_bytes();
    for i in 0..16 {
        bytes[i] = seed[i % 16] ^ pid[i % 4] ^ (i as u8).wrapping_mul(0x6D);
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_tiff() -> Vec<u8> {
        // II, magic 42, IFD0 at 8 with two entries: Make (ASCII, inline) and
        // ExifIFD pointer (0x8769 → offset 34), then ExifIFD with one entry.
        let mut t = Vec::new();
        t.extend_from_slice(b"II*\x00");
        t.extend_from_slice(&8u32.to_le_bytes());
        // IFD0: 2 entries
        t.extend_from_slice(&2u16.to_le_bytes());
        // tag 0x010F Make ASCII count 4 inline "OPPO\0"->4 bytes
        t.extend_from_slice(&0x010Fu16.to_le_bytes());
        t.extend_from_slice(&2u16.to_le_bytes());
        t.extend_from_slice(&5u32.to_le_bytes());
        t.extend_from_slice(&34u32.to_le_bytes()); // value offset → 34
        // tag 0x8769 ExifIFD pointer LONG count 1
        t.extend_from_slice(&0x8769u16.to_le_bytes());
        t.extend_from_slice(&4u16.to_le_bytes());
        t.extend_from_slice(&1u32.to_le_bytes());
        // IFD0 table: 8 + 2 + 24 + 4 = 38; data area holds "OPPO\0" at 38..43,
        // ExifIFD after that: 43
        t.extend_from_slice(&43u32.to_le_bytes());
        t.extend_from_slice(&0u32.to_le_bytes()); // next IFD
        // data area at 38
        t.extend_from_slice(b"OPPO\0");
        // ExifIFD at 43: 1 entry (tag 0x9000 ExifVersion UNDEFINED count 4)
        t.extend_from_slice(&1u16.to_le_bytes());
        t.extend_from_slice(&0x9000u16.to_le_bytes());
        t.extend_from_slice(&7u16.to_le_bytes());
        t.extend_from_slice(&4u32.to_le_bytes());
        t.extend_from_slice(b"0232");
        t.extend_from_slice(&0u32.to_le_bytes());
        t
    }

    #[test]
    fn makernote_injection_roundtrip() {
        let tiff = minimal_tiff();
        let out = inject_makernote(&tiff, "ABCD-1234").expect("inject ok");
        let model = read_tiff(&out).expect("read back");
        // IFD0 entries preserved
        assert!(model.ifd0.iter().any(|e| e.tag == 0x010F));
        assert!(model.ifd0.iter().any(|e| e.tag == 0x8769));
        // Exif version entry preserved and MakerNote added
        assert!(model.exif_ifd.iter().any(|e| e.tag == 0x9000));
        let note = model
            .exif_ifd
            .iter()
            .find(|e| e.tag == 0x927C)
            .expect("makernote present");
        assert!(note.data.starts_with(b"Apple iOS\0\0\x01MM"));
        assert!(note.data.windows(9).any(|w| w == b"ABCD-1234"));
    }

    #[test]
    fn makernote_structure_matches_apple_layout() {
        let note = build_apple_makernote("01234567-89ab-4def-8def-0123456789ab").unwrap();
        assert!(note.starts_with(b"Apple iOS\0\0\x01MM"));
        // header "Apple iOS\0\0\x01MM" is 14 bytes; entry count follows
        let count = u16::from_be_bytes([note[14], note[15]]);
        assert_eq!(count, 1);
        let tag = u16::from_be_bytes([note[16], note[17]]);
        assert_eq!(tag, 0x0011);
        // value contains the upper-cased identifier + NUL
        assert!(note.ends_with(b"01234567-89AB-4DEF-8DEF-0123456789AB\0"));
    }
}
