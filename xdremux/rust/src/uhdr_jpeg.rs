//! Ultra HDR JPEG (MPF + hdrgm XMP) input support.
//!
//! OPPO Motion Photo stills (and Google Ultra HDR photos in general) are
//! JPEGs: the primary image plus an embedded gain-map JPEG referenced by an
//! MPF (Multi-Picture Format) APP2 segment, with tone-mapping metadata in an
//! `hdrgm` XMP block. The OPPO-tail extractor cannot see these files; this
//! module decodes the base JPEG, re-encodes the primary as HEVC tiles and
//! synthesizes a minimal HEIF source container so the regular UHDR pipeline
//! (`isobmff_write::write_uhdr_iso_output`) can take over unchanged.

use crate::isobmff::{self, IlocEntry, IrefEntry};

const TILE_SIZE: u32 = 512;

/// Parsed Ultra HDR JPEG essentials.
pub struct UhdrJpeg {
    /// Embedded gain-map JPEG bytes.
    pub gainmap_jpeg: Vec<u8>,
    /// OPPO-layout 20-float metadata block (inverse of
    /// `iso21496::build_iso_metadata_from_uhdr`).
    pub meta_floats: Vec<f32>,
    /// TIFF payload from the APP1 Exif segment (without the 6-byte prefix).
    pub exif_tiff: Option<Vec<u8>>,
}

// ---------------------------------------------------------------------------
// JPEG segment walk
// ---------------------------------------------------------------------------

struct Segments {
    xmp: Option<Vec<u8>>,
    mpf_tiff_file_pos: Option<usize>,
    mpf_tiff_len: usize,
    exif_tiff: Option<Vec<u8>>,
}

/// The JPEG's APP1 Exif as a bare TIFF, regardless of Ultra HDR support —
/// malformed or gain-map-less JPEGs still carry capture metadata worth keeping
/// when they are rebuilt as an SDR styles source.
pub fn extract_exif_tiff(data: &[u8]) -> Option<Vec<u8>> {
    walk_segments(data).ok()?.exif_tiff
}

/// Read the original JPEG's APP1 EXIF independently of Ultra HDR support.
pub(crate) fn read_exif_payload(data: &[u8]) -> Result<Option<Vec<u8>>, String> {
    Ok(walk_segments(data)?.exif_tiff.map(|tiff| {
        let mut payload = vec![0, 0, 0, 0]; // HEIF TIFF starts after offset field
        payload.extend(tiff);
        payload
    }))
}

fn walk_segments(data: &[u8]) -> Result<Segments, String> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return Err("not a JPEG file".into());
    }
    let mut out = Segments {
        xmp: None,
        mpf_tiff_file_pos: None,
        mpf_tiff_len: 0,
        exif_tiff: None,
    };
    let mut pos = 2usize;
    while pos + 4 <= data.len() {
        if data[pos] != 0xFF {
            return Err("malformed JPEG marker stream".into());
        }
        let marker = data[pos + 1];
        // SOS starts entropy-coded data; all metadata segments precede it.
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        // Standalone markers without payload.
        if (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            pos += 2;
            continue;
        }
        let seg_len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
        if seg_len < 2 || pos + 2 + seg_len > data.len() {
            return Err("malformed JPEG segment length".into());
        }
        let payload = &data[pos + 4..pos + 2 + seg_len];
        match marker {
            0xE1 => {
                if payload.starts_with(b"Exif\0\0") {
                    out.exif_tiff = Some(payload[6..].to_vec());
                } else if payload.starts_with(b"http://ns.adobe.com/xap/1.0/\0") {
                    out.xmp = Some(payload[29..].to_vec());
                }
            }
            0xE2 => {
                if payload.starts_with(b"MPF\0") {
                    out.mpf_tiff_file_pos = Some(pos + 4 + 4);
                    out.mpf_tiff_len = payload.len() - 4;
                }
            }
            _ => {}
        }
        pos += 2 + seg_len;
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// MPF (Multi-Picture Format) parsing
// ---------------------------------------------------------------------------

fn tiff_u16(t: &[u8], off: usize, le: bool) -> Option<u16> {
    let b: [u8; 2] = t.get(off..off + 2)?.try_into().ok()?;
    Some(if le {
        u16::from_le_bytes(b)
    } else {
        u16::from_be_bytes(b)
    })
}

fn tiff_u32(t: &[u8], off: usize, le: bool) -> Option<u32> {
    let b: [u8; 4] = t.get(off..off + 4)?.try_into().ok()?;
    Some(if le {
        u32::from_le_bytes(b)
    } else {
        u32::from_be_bytes(b)
    })
}

/// Locate the second image (gain map) via the MPF index IFD.
fn extract_gainmap_jpeg(
    data: &[u8],
    tiff_file_pos: usize,
    tiff_len: usize,
) -> Result<Vec<u8>, String> {
    let tiff = data
        .get(tiff_file_pos..tiff_file_pos + tiff_len)
        .ok_or("MPF TIFF payload out of range")?;
    if tiff.len() < 8 {
        return Err("MPF TIFF header truncated".into());
    }
    let le = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return Err("MPF TIFF byte order invalid".into()),
    };
    let ifd_off = tiff_u32(tiff, 4, le).ok_or("MPF IFD offset missing")? as usize;
    let entry_count = tiff_u16(tiff, ifd_off, le).ok_or("MPF IFD truncated")? as usize;
    let mut mp_entries_off = None;
    for i in 0..entry_count {
        let entry = ifd_off + 2 + i * 12;
        let tag = tiff_u16(tiff, entry, le).ok_or("MPF IFD entry truncated")?;
        if tag == 0xB002 {
            // Value fits in the 4-byte field only when count*16 <= 4 — never
            // for MP entries, so it is always an offset relative to TIFF start.
            let value = tiff_u32(tiff, entry + 8, le).ok_or("MPF MP entry truncated")?;
            mp_entries_off = Some(value as usize);
        }
    }
    let mp_off = mp_entries_off.ok_or("MPF index IFD has no MP entry (0xB002)")?;
    // Entry 0 is the primary image; entry 1 is the gain map.
    let second = mp_off + 16;
    let size = tiff_u32(tiff, second + 4, le).ok_or("MPF gain-map size missing")? as usize;
    let offset =
        tiff_u32(tiff, second + 8, le).ok_or("MPF gain-map offset missing")? as usize;
    let start = tiff_file_pos
        .checked_add(offset)
        .ok_or("MPF gain-map offset overflow")?;
    let end = start
        .checked_add(size)
        .ok_or("MPF gain-map size overflow")?;
    let blob = data
        .get(start..end)
        .ok_or("MPF gain-map extent outside the file")?;
    if !blob.starts_with(&[0xFF, 0xD8]) {
        return Err("MPF gain-map extent is not a JPEG".into());
    }
    Ok(blob.to_vec())
}

// ---------------------------------------------------------------------------
// hdrgm XMP parsing
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Hdrgm {
    gain_map_min: Option<f32>,
    gain_map_max: Option<f32>,
    gamma: Option<f32>,
    offset_sdr: Option<f32>,
    offset_hdr: Option<f32>,
    capacity_min: Option<f32>,
    capacity_max: Option<f32>,
    base_is_hdr: bool,
}

fn parse_hdrgm_xmp(xmp: &[u8]) -> Result<Hdrgm, String> {
    let text =
        std::str::from_utf8(xmp).map_err(|_| "hdrgm XMP is not UTF-8".to_string())?;
    let mut reader = quick_xml::Reader::from_str(text);
    reader.config_mut().check_end_names = false;
    let mut out = Hdrgm::default();
    let mut current: Option<String> = None;
    let get_f = |attrs: &[(String, String)], name: &str| -> Option<f32> {
        attrs
            .iter()
            .find(|(n, _)| n == name)
            .and_then(|(_, v)| v.split_whitespace().next()?.parse::<f32>().ok())
    };
    loop {
        match reader.read_event() {
            Ok(quick_xml::events::Event::Start(e)) | Ok(quick_xml::events::Event::Empty(e)) => {
                let name = e.name().as_ref().to_string();
                let local = name.rsplit(':').next().unwrap_or(&name).to_string();
                let mut attrs: Vec<(String, String)> = Vec::new();
                for attr in e.attributes().flatten() {
                    let key = attr.key.as_ref().to_string();
                    let local_key = key.rsplit(':').next().unwrap_or(&key).to_string();
                    attrs.push((local_key, attr.value.as_ref().to_string()));
                }
                if local == "Description" {
                    out.gain_map_min = out.gain_map_min.or(get_f(&attrs, "GainMapMin"));
                    out.gain_map_max = out.gain_map_max.or(get_f(&attrs, "GainMapMax"));
                    out.gamma = out.gamma.or(get_f(&attrs, "Gamma"));
                    out.offset_sdr = out.offset_sdr.or(get_f(&attrs, "OffsetSDR"));
                    out.offset_hdr = out.offset_hdr.or(get_f(&attrs, "OffsetHDR"));
                    out.capacity_min =
                        out.capacity_min.or(get_f(&attrs, "HDRCapacityMin"));
                    out.capacity_max =
                        out.capacity_max.or(get_f(&attrs, "HDRCapacityMax"));
                    if let Some(v) = attrs.iter().find(|(n, _)| n == "BaseRenditionIsHDR") {
                        out.base_is_hdr =
                            v.1.eq_ignore_ascii_case("true") || v.1 == "1";
                    }
                } else if matches!(
                    local.as_str(),
                    "GainMapMin"
                        | "GainMapMax"
                        | "Gamma"
                        | "OffsetSDR"
                        | "OffsetHDR"
                        | "HDRCapacityMin"
                        | "HDRCapacityMax"
                        | "BaseRenditionIsHDR"
                ) {
                    current = Some(local);
                }
            }
            Ok(quick_xml::events::Event::Text(e)) => {
                if let Some(local) = &current {
                    let text = e.as_ref().to_string();
                    if let Ok(v) = text
                        .split_whitespace()
                        .next()
                        .unwrap_or("")
                        .parse::<f32>()
                    {
                        match local.as_str() {
                            "GainMapMin" => out.gain_map_min = out.gain_map_min.or(Some(v)),
                            "GainMapMax" => out.gain_map_max = out.gain_map_max.or(Some(v)),
                            "Gamma" => out.gamma = out.gamma.or(Some(v)),
                            "OffsetSDR" => out.offset_sdr = out.offset_sdr.or(Some(v)),
                            "OffsetHDR" => out.offset_hdr = out.offset_hdr.or(Some(v)),
                            "HDRCapacityMin" => {
                                out.capacity_min = out.capacity_min.or(Some(v))
                            }
                            "HDRCapacityMax" => {
                                out.capacity_max = out.capacity_max.or(Some(v))
                            }
                            "BaseRenditionIsHDR" => out.base_is_hdr = v > 0.5,
                            _ => {}
                        }
                    } else if local == "BaseRenditionIsHDR" {
                        out.base_is_hdr = text.eq_ignore_ascii_case("true");
                    }
                }
            }
            Ok(quick_xml::events::Event::End(_)) => current = None,
            Ok(quick_xml::events::Event::Eof) => break,
            Err(_) => return Err("hdrgm XMP is malformed".into()),
            _ => {}
        }
    }
    Ok(out)
}

fn log2(v: f32) -> f32 {
    if v > 0.0 { v.log2() } else { 0.0 }
}

/// Map hdrgm fields to the OPPO-layout 20-float block (inverse of
/// `iso21496::build_iso_metadata_from_uhdr`).
fn hdrgm_to_meta_floats(h: &Hdrgm) -> Result<Vec<f32>, String> {
    let cap_max = h
        .capacity_max
        .ok_or("hdrgm XMP lacks HDRCapacityMax; not an Ultra HDR JPEG")?;
    let cap_min = h.capacity_min.unwrap_or(0.0).max(0.0);
    let ratio_min = 2f32.powf(h.gain_map_min.unwrap_or(0.0).max(0.0));
    let ratio_max = 2f32.powf(h.gain_map_max.unwrap_or(cap_max));
    let gamma = h.gamma.unwrap_or(1.0);
    let eps_sdr = h.offset_sdr.unwrap_or(1.0 / 64.0);
    let eps_hdr = h.offset_hdr.unwrap_or(1.0 / 64.0);
    let drs = 2f32.powf(cap_min);
    let drh = 2f32.powf(cap_max);
    let _ = log2; // keep helper available for future mappings
    let mut f = vec![ratio_min, ratio_min, ratio_min, 0.0];
    f.extend_from_slice(&[ratio_max, ratio_max, ratio_max]);
    f.extend_from_slice(&[gamma, gamma, gamma]);
    f.extend_from_slice(&[eps_sdr, eps_sdr, eps_sdr]);
    f.extend_from_slice(&[eps_hdr, eps_hdr, eps_hdr]);
    f.push(drs);
    f.push(drh);
    f.push(drh); // scale, mirroring OPPO info where scale == displayRatioHdr
    f.push(if h.base_is_hdr { 1.0 } else { 0.0 });
    debug_assert_eq!(f.len(), 20);
    Ok(f)
}

// ---------------------------------------------------------------------------
// Public parse entry
// ---------------------------------------------------------------------------

/// Parse an Ultra HDR JPEG. Returns Ok(None) for files that are not JPEGs
/// with an MPF gain map (plain JPEGs, HEICs, etc.).
/// Minimal 1×1 gray JPEG used as an identity gain map for SDR inputs
/// (gain 1.0 = no HDR boost, the pipeline treats it as base = HDR).
pub const IDENTITY_GAINMAP_JPEG: &[u8] = &[
    0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,
    0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,0x00,0x03,0x02,0x02,0x03,0x02,0x02,0x03,
    0x02,0x02,0x03,0x03,0x03,0x03,0x04,0x03,0x03,0x04,0x05,0x08,0x05,0x05,0x04,0x04,
    0x05,0x0A,0x07,0x07,0x06,0x08,0x0C,0x0A,0x0C,0x0C,0x0B,0x0A,0x0B,0x0B,0x0D,0x0E,
    0x12,0x10,0x0D,0x0E,0x11,0x0E,0x0B,0x0B,0x10,0x16,0x10,0x11,0x13,0x14,0x15,0x15,
    0x15,0x0C,0x0F,0x17,0x18,0x16,0x14,0x18,0x12,0x14,0x15,0x14,0xFF,0xC0,0x00,0x0B,
    0x08,0x00,0x01,0x00,0x01,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,
    0x05,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,
    0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0xFF,0xC4,0x00,0xB5,0x10,0x00,
    0x02,0x01,0x03,0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7D,0x01,
    0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,
    0x71,0x14,0x32,0x81,0x91,0xA1,0x08,0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,0x24,
    0x33,0x62,0x72,0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,0x28,0x29,
    0x2A,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,
    0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,
    0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8A,
    0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,
    0xA9,0xAA,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,0xC6,
    0xC7,0xC8,0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xE1,0xE2,0xE3,
    0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,
    0xFA,0xFF,0xDA,0x00,0x08,0x01,0x01,0x00,0x00,0x3F,0x00,0x2B,0xFF,0xD9,
];

/// Neutral 20-float metadata for an identity gain map (gain 1.0, no boost).
pub fn neutral_meta_floats() -> Vec<f32> {
    let eps = 1.0 / 64.0;
    vec![
        1.0, 1.0, 1.0,  // ratio_min
        0.0,             // pad
        1.0, 1.0, 1.0,  // ratio_max
        1.0, 1.0, 1.0,  // gamma
        eps, eps, eps,   // eps_sdr
        eps, eps, eps,   // eps_hdr
        1.0,             // drs
        1.0,             // drh
        1.0,             // scale
        0.0,             // base_is_hdr
    ]
}

pub fn parse(data: &[u8]) -> Result<Option<UhdrJpeg>, String> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return Ok(None);
    }
    let segments = walk_segments(data)?;
    let Some(tiff_pos) = segments.mpf_tiff_file_pos else {
        // Plain SDR JPEG (no Ultra HDR gain map): synthesize an identity
        // gain map so the standard pipeline can process it.
        return Ok(Some(UhdrJpeg {
            gainmap_jpeg: IDENTITY_GAINMAP_JPEG.to_vec(),
            meta_floats: neutral_meta_floats(),
            exif_tiff: segments.exif_tiff,
        }));
    };
    let gainmap = extract_gainmap_jpeg(data, tiff_pos, segments.mpf_tiff_len)?;
    // Per the Ultra HDR spec the hdrgm tone-map metadata lives in the gain
    // map JPEG's own XMP; fall back to the primary's XMP for producers that
    // put it there instead.
    let gm_segments = walk_segments(&gainmap)?;
    let xmp = gm_segments
        .xmp
        .or(segments.xmp)
        .ok_or("Ultra HDR JPEG lacks its hdrgm XMP block")?;
    let hdrgm = parse_hdrgm_xmp(&xmp)?;
    let meta_floats = hdrgm_to_meta_floats(&hdrgm)?;
    Ok(Some(UhdrJpeg {
        gainmap_jpeg: gainmap,
        meta_floats,
        exif_tiff: segments.exif_tiff,
    }))
}

// ---------------------------------------------------------------------------
// Source container synthesis
// ---------------------------------------------------------------------------

/// Build a minimal HEIF source container around a re-encoded primary derived
/// from the Ultra HDR base JPEG, so the standard UHDR assembly path can run
/// unchanged. The container carries: primary grid + HEVC tiles (+ optional
/// Exif item) — everything `parse_source_structure` needs.
pub fn synthesize_source_container(
    source: &[u8],
    info: &UhdrJpeg,
    use_420: bool,
) -> Result<Vec<u8>, String> {
    let (rgb, width, height) = crate::jpeg_decode::decode_jpeg_to_rgb(source)
        .map_err(|e| format!("Ultra HDR base JPEG decode failed: {e}"))?;
    // The base JPEG stores its pixels in capture orientation plus an EXIF
    // orientation. Store the primary in presentation orientation instead (like
    // Apple's references, which need no `irot`) and keep the source orientation
    // in the Exif item so the gain map can still be rotated to match.
    let orientation = info
        .exif_tiff
        .as_deref()
        .map(crate::exif::parse_exif_orientation)
        .transpose()?
        .unwrap_or(crate::exif::ExifOrientation::Normal);
    let (rgb, width, height) = crate::isobmff_write::orient_gainmap_pixels(
        &rgb,
        width,
        height,
        3,
        width as usize * 3,
        orientation,
    )
    .map_err(|e| format!("Ultra HDR base JPEG orientation failed: {e}"))?;
    synthesize_source_container_from_rgb(&rgb, width, height, info.exif_tiff.clone(), use_420)
}

/// Build the same standard HEIC source container from pixels a caller already
/// decoded (and already rotated into presentation orientation). Used for
/// non-ProXDR inputs — the platform codec decodes any format to RGBA, the
/// caller drops alpha, and this produces the container the styles pipeline
/// expects (`tmap` + gain grid come later from the normal conversion path).
pub fn synthesize_source_container_from_rgb(
    rgb: &[u8],
    width: u32,
    height: u32,
    exif_tiff: Option<Vec<u8>>,
    use_420: bool,
) -> Result<Vec<u8>, String> {
    let rgb = rgb.to_vec();
    let cols = width.div_ceil(TILE_SIZE).max(1);
    let rows = height.div_ceil(TILE_SIZE).max(1);
    let total_tiles = (cols * rows) as usize;

    // Padded 512x512 tiles, RGB 4:4:4 (3 bytes/px), same pattern as gain maps.
    let mut padded: Vec<Vec<u8>> = Vec::with_capacity(total_tiles);
    for row in 0..rows {
        for col in 0..cols {
            let x0 = col * TILE_SIZE;
            let y0 = row * TILE_SIZE;
            let mut tile = vec![0u8; (TILE_SIZE * TILE_SIZE * 3) as usize];
            let copy_w = (width - x0).min(TILE_SIZE);
            let copy_h = (height - y0).min(TILE_SIZE);
            for y in 0..copy_h {
                let src = (((y0 + y) * width + x0) * 3) as usize;
                let dst = (y * TILE_SIZE * 3) as usize;
                tile[dst..dst + (copy_w * 3) as usize]
                    .copy_from_slice(&rgb[src..src + (copy_w * 3) as usize]);
            }
            padded.push(tile);
        }
    }
    let tile_refs: Vec<&[u8]> = padded.iter().map(|t| t.as_slice()).collect();
    let streams = crate::hevc::x265_encode_tiles(
        &tile_refs,
        TILE_SIZE,
        TILE_SIZE,
        3,
        use_420,
    )
    .map_err(|e| format!("Ultra HDR primary HEVC encode: {e}"))?;
    if streams.len() != total_tiles {
        return Err("primary HEVC encode produced an unexpected tile count".into());
    }
    let chroma = if use_420 { 1u8 } else { 3u8 };
    let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&streams[0], chroma)
        .ok_or("primary hvcC extraction failed")?;
    let tile_payloads: Vec<Vec<u8>> = streams
        .iter()
        .map(|s| {
            let idr = crate::hevc::drop_parameter_nals(s);
            crate::hevc::hevc_byte_stream_to_length_prefixed(&idr)
        })
        .collect();

    // ---- ids ----
    let grid_id: u32 = 1;
    let first_tile_id: u32 = 2;
    let exif_id: Option<u32> = exif_tiff
        .as_ref()
        .map(|_| first_tile_id + total_tiles as u32);

    // ---- ipco / ipma ----
    let grid_ispe = isobmff::make_ispe_box(width, height);
    let tile_ispe = isobmff::make_ispe_box(TILE_SIZE, TILE_SIZE);
    let hvcc_box = isobmff::make_box(b"hvcC", &hvcc);
    // property indices (1-based)
    let idx_grid_ispe = 1u32;
    let idx_tile_ispe = 2u32;
    let idx_hvcc = 3u32;
    let idx_colr = 4u32;
    // Explicit zero-turn `irot` on the primary: the tiles above are already in
    // presentation orientation, so `isobmff_write` must not generate a rotation
    // from the container's EXIF orientation. The gain map still reads that EXIF
    // orientation to end up in the same frame.
    let idx_irot = 5u32;
    let mut ipco = Vec::new();
    ipco.extend_from_slice(&grid_ispe);
    ipco.extend_from_slice(&tile_ispe);
    ipco.extend_from_slice(&hvcc_box);
    ipco.extend_from_slice(isobmff::COLR_SRGB_BOX);
    ipco.extend_from_slice(&isobmff::make_irot_box(0));

    let mut ipma_entries: Vec<u8> = Vec::new();
    let mut entry_count = 0u32;
    let mut push_entry = |id: u32, assocs: &[(u32, bool)], out: &mut Vec<u8>| {
        out.extend_from_slice(&isobmff::make_ipma_entry(id, assocs, 0));
        entry_count += 1;
    };
    push_entry(
        grid_id,
        &[(idx_grid_ispe, true), (idx_colr, true), (idx_irot, true)],
        &mut ipma_entries,
    );
    for i in 0..total_tiles {
        push_entry(
            first_tile_id + i as u32,
            &[(idx_tile_ispe, true), (idx_hvcc, true), (idx_colr, true)],
            &mut ipma_entries,
        );
    }
    if let Some(id) = exif_id {
        let _ = id; // Exif items carry no property associations.
    }
    let mut ipma = vec![0u8, 0, 0, 0];
    isobmff::write_u32be(entry_count, &mut ipma);
    ipma.extend_from_slice(&ipma_entries);
    let iprp = isobmff::make_box(
        b"iprp",
        &[
            isobmff::make_box(b"ipco", &ipco),
            isobmff::make_box(b"ipma", &ipma),
        ]
        .concat(),
    );

    // ---- iinf ----
    // Primary grid must not be hidden (flags=0): libheif refuses a hidden
    // pitm target ("pitm references an unsupported or non-existing image").
    let mut infes: Vec<Vec<u8>> = vec![isobmff::make_infe_box(grid_id, "grid", 0)];
    for i in 0..total_tiles {
        infes.push(isobmff::make_infe_box(first_tile_id + i as u32, "hvc1", 1));
    }
    if let Some(id) = exif_id {
        infes.push(isobmff::make_infe_box(id, "Exif", 0));
    }
    let iinf = isobmff::make_iinf_box(0, &infes);

    // ---- iref ----
    let mut refs = vec![IrefEntry {
        rtype: "dimg".into(),
        from: grid_id,
        to: (0..total_tiles)
            .map(|i| first_tile_id + i as u32)
            .collect(),
    }];
    if let Some(id) = exif_id {
        refs.push(IrefEntry {
            rtype: "cdsc".into(),
            from: id,
            to: vec![grid_id],
        });
    }
    let iref = isobmff::make_iref_full_box(0, &refs);

    // ---- idat: grid descriptor ----
    let grid_box = isobmff::make_grid_box(TILE_SIZE, TILE_SIZE, rows, cols, width, height);
    let idat = isobmff::make_box(b"idat", &grid_box[8..]);

    // ---- Exif payload (Apple-native convention: 4-byte offset value 6 +
    // "Exif\0\0" + TIFF, so libheif/ImageIO land on the TIFF header —
    // a bare value-4 prefix makes libheif skip 8 bytes and fail) ----
    let exif_payload: Option<Vec<u8>> = exif_tiff.as_ref().map(|tiff| {
        let mut p = Vec::with_capacity(tiff.len() + 10);
        p.extend_from_slice(&6u32.to_be_bytes());
        p.extend_from_slice(b"Exif\0\0");
        p.extend_from_slice(tiff);
        p
    });

    // ---- iloc (two passes; make_iloc_box uses fixed widths) ----
    let mut iloc: Vec<IlocEntry> = Vec::new();
    iloc.push(IlocEntry {
        item_id: grid_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(0, (grid_box.len() - 8) as u64)],
    });
    for i in 0..total_tiles {
        iloc.push(IlocEntry {
            item_id: first_tile_id + i as u32,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, tile_payloads[i].len() as u64)],
        });
    }
    if let (Some(id), Some(payload)) = (exif_id, &exif_payload) {
        iloc.push(IlocEntry {
            item_id: id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, payload.len() as u64)],
        });
    }

    // ---- hdlr (pict) ----
    let mut hdlr_payload = vec![0u8, 0, 0, 0];
    hdlr_payload.extend_from_slice(&0u32.to_be_bytes());
    hdlr_payload.extend_from_slice(b"pict");
    hdlr_payload.extend_from_slice(&[0u8; 12]);
    hdlr_payload.push(0);
    let hdlr = isobmff::make_box(b"hdlr", &hdlr_payload);

    let pitm = isobmff::make_pitm_box(0, grid_id);

    let assemble_meta = |iloc_box: &[u8]| -> Vec<u8> {
        let mut body = vec![0u8, 0, 0, 0];
        for part in [
            &hdlr, &pitm, &iinf, iloc_box, &iprp, &iref, &idat,
        ] {
            body.extend_from_slice(part);
        }
        isobmff::make_box(b"meta", &body)
    };

    let ftyp = isobmff::make_box(b"ftyp", b"heic\0\0\0\0heicmif1");
    let meta_pass1 = assemble_meta(&isobmff::make_iloc_box(&iloc));
    let mdat_data_start = ftyp.len() + meta_pass1.len() + 8;

    // Fix absolute tile/Exif offsets now that the mdat position is known.
    let mut cursor = mdat_data_start as u64;
    let mut tile_idx = 0usize;
    for entry in &mut iloc {
        if entry.construction_method == 0 {
            let len = entry.extents[0].1;
            entry.extents[0].0 = cursor;
            cursor += len;
            tile_idx += 1;
        }
    }
    let _ = tile_idx;
    let meta_final = assemble_meta(&isobmff::make_iloc_box(&iloc));
    debug_assert_eq!(meta_pass1.len(), meta_final.len());

    let mut mdat_payload = Vec::new();
    for payload in &tile_payloads {
        mdat_payload.extend_from_slice(payload);
    }
    if let Some(payload) = &exif_payload {
        mdat_payload.extend_from_slice(payload);
    }
    let mdat = isobmff::make_box(b"mdat", &mdat_payload);

    let mut out = Vec::with_capacity(ftyp.len() + meta_final.len() + mdat.len());
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&meta_final);
    out.extend_from_slice(&mdat);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn original_jpeg_exif_is_read_without_mpf_or_ultra_hdr() {
        let tiff = tiff_with_orientation(6);
        let mut app1 = b"Exif\0\0".to_vec();
        app1.extend_from_slice(&tiff);
        let mut jpeg = vec![0xff, 0xd8];
        jpeg.extend(appseg(0xe1, &app1));
        jpeg.extend_from_slice(&[0xff, 0xd9]);
        let payload = read_exif_payload(&jpeg).unwrap().unwrap();
        assert_eq!(&payload[4..], &tiff);
        assert_eq!(crate::exif::parse_exif_orientation(&payload).unwrap(),
            crate::exif::ExifOrientation::Rotate90Clockwise);
        assert!(read_exif_payload(&[0xff, 0xd8, 0xff, 0xd9]).unwrap().is_none());
        assert!(read_exif_payload(&[0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff]).is_err());
    }

    fn appseg(marker: u8, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![0xFF, marker];
        v.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
        v.extend_from_slice(payload);
        v
    }

    fn make_mpf(gainmap_size: u32, gainmap_offset: u32) -> Vec<u8> {
        // TIFF (LE): magic, IFD at 8 with one MP entry pointing at 26.
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II*\x00");
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes()); // 1 IFD entry
        tiff.extend_from_slice(&0xB002u16.to_le_bytes());
        tiff.extend_from_slice(&7u16.to_le_bytes()); // UNDEFINED
        tiff.extend_from_slice(&32u32.to_le_bytes()); // 2 images * 16 bytes
        tiff.extend_from_slice(&26u32.to_le_bytes()); // value offset
        tiff.extend_from_slice(&0u32.to_le_bytes()); // next IFD
        // MP entries at offset 26
        // entry 0: primary
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        // entry 1: gain map
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&gainmap_size.to_le_bytes());
        tiff.extend_from_slice(&gainmap_offset.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        let mut payload = b"MPF\0".to_vec();
        payload.extend_from_slice(&tiff);
        payload
    }

    fn tiny_jpeg(seed: u8, len: usize) -> Vec<u8> {
        // SOI + SOS(8-byte header) + entropy filler + EOI
        let mut v = vec![0xFF, 0xD8];
        v.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00]);
        v.extend(std::iter::repeat(seed).take(len));
        v.extend_from_slice(&[0xFF, 0xD9]);
        v
    }

    #[test]
    fn parses_mpf_and_hdrgm() {
        let xmp = br#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:GainMapMin="0" hdrgm:GainMapMax="3.5" hdrgm:Gamma="1" hdrgm:OffsetSDR="0.015625" hdrgm:OffsetHDR="0.015625" hdrgm:HDRCapacityMin="0" hdrgm:HDRCapacityMax="3.5" hdrgm:BaseRenditionIsHDR="False"/></rdf:RDF></x:xmpmeta>"#;
        // hdrgm metadata lives in the gain map JPEG's own XMP (spec layout).
        let mut gainmap = vec![0xFF, 0xD8];
        let mut xmp_payload = b"http://ns.adobe.com/xap/1.0/\0".to_vec();
        xmp_payload.extend_from_slice(xmp);
        gainmap.extend_from_slice(&appseg(0xE1, &xmp_payload));
        gainmap.extend_from_slice(&tiny_jpeg(0x11, 64)[2..]);
        let primary = tiny_jpeg(0x22, 100);
        // Real layout: SOI, APP segments, SOS, scan data, EOI, then gain map.
        let mut file = vec![0xFF, 0xD8];
        file.extend_from_slice(&appseg(0xE1, b"Exif\0\0II*\x00\x08\x00\x00\x00\x00\x00"));
        // MPF: TIFF starts right after the 4-byte "MPF\0" prefix of the APP2
        // payload; the gain map sits after the primary EOI.
        let mpf_app2_pos = file.len();
        let tiff_file_pos = mpf_app2_pos + 4 + 4; // marker(2)+len(2)+"MPF\0"(4)
        let mpf_probe = make_mpf(gainmap.len() as u32, 0);
        let gainmap_file_pos =
            tiff_file_pos + (mpf_probe.len() - 4) + (primary.len() - 2); // after SOS+scan+EOI
        let mpf = make_mpf(
            gainmap.len() as u32,
            (gainmap_file_pos - tiff_file_pos) as u32,
        );
        file.extend_from_slice(&appseg(0xE2, &mpf));
        file.extend_from_slice(&primary[2..]); // SOS + scan + EOI
        file.extend_from_slice(&gainmap);

        let parsed = parse(&file).expect("parse ok").expect("is uhdr jpeg");
        assert_eq!(parsed.gainmap_jpeg, gainmap);
        assert_eq!(parsed.meta_floats.len(), 20);
        // ratio_max = 2^3.5
        assert!((parsed.meta_floats[4] - 2f32.powf(3.5)).abs() < 1e-4);
        // display_ratio_hdr = 2^3.5, scale mirrors it
        assert!((parsed.meta_floats[17] - 2f32.powf(3.5)).abs() < 1e-4);
        assert_eq!(parsed.meta_floats[19], 0.0);
        assert!(parsed.exif_tiff.is_some());
    }

    #[test]
    fn plain_jpeg_synthesizes_an_identity_gain_map() {
        // Non-ProXDR inputs still need to reach the styles pipeline, so a
        // plain JPEG yields an identity gain map (gain 1.0, no boost) rather
        // than `None`. This is what lets any photo go through the conversion
        // and pick up the full styles scaffold.
        let data = tiny_jpeg(0x33, 256);
        let info = parse(&data).expect("ok").expect("identity gain map");
        assert_eq!(info.gainmap_jpeg, IDENTITY_GAINMAP_JPEG);
        assert_eq!(info.meta_floats, neutral_meta_floats());
        // Identity: no ratio above 1.0 on either side of the tone map.
        assert_eq!(&info.meta_floats[0..3], &[1.0, 1.0, 1.0]);
        assert_eq!(&info.meta_floats[4..7], &[1.0, 1.0, 1.0]);
        assert_eq!(info.meta_floats[19], 0.0);
    }

    #[test]
    fn non_jpeg_returns_none() {
        // Only JPEG streams take the Ultra HDR route; containers are handled
        // elsewhere.
        assert!(parse(b"\x00\x00\x00\x18ftypheic").expect("ok").is_none());
    }

    /// A real, decodable 16x8 RGB baseline JPEG (Pillow, quality 85). The
    /// orientation tests need decoded pixels, which the synthetic
    /// `tiny_jpeg` buffers above cannot provide.
    #[rustfmt::skip]
    const TINY_16X8_JPEG: &[u8] = &[
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
        0x00, 0x05, 0x03, 0x04, 0x04, 0x04, 0x03, 0x05, 0x04, 0x04, 0x04, 0x05,
        0x05, 0x05, 0x06, 0x07, 0x0c, 0x08, 0x07, 0x07, 0x07, 0x07, 0x0f, 0x0b,
        0x0b, 0x09, 0x0c, 0x11, 0x0f, 0x12, 0x12, 0x11, 0x0f, 0x11, 0x11, 0x13,
        0x16, 0x1c, 0x17, 0x13, 0x14, 0x1a, 0x15, 0x11, 0x11, 0x18, 0x21, 0x18,
        0x1a, 0x1d, 0x1d, 0x1f, 0x1f, 0x1f, 0x13, 0x17, 0x22, 0x24, 0x22, 0x1e,
        0x24, 0x1c, 0x1e, 0x1f, 0x1e, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x05, 0x05,
        0x05, 0x07, 0x06, 0x07, 0x0e, 0x08, 0x08, 0x0e, 0x1e, 0x14, 0x11, 0x14,
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e,
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e,
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e,
        0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e, 0x1e,
        0x1e, 0x1e, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x10, 0x03,
        0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
        0x16, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x07, 0xff, 0xc4, 0x00,
        0x19, 0x10, 0x00, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x07, 0x24, 0x32, 0xa2,
        0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x06, 0xff,
        0xc4, 0x00, 0x19, 0x11, 0x00, 0x02, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x05, 0x06,
        0x22, 0x52, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03,
        0x11, 0x00, 0x3f, 0x00, 0x80, 0x4e, 0x34, 0xb5, 0x8d, 0x93, 0x49, 0x4e,
        0x34, 0xb5, 0x8d, 0x90, 0x09, 0xa5, 0xa4, 0xd8, 0xe8, 0x1e, 0x93, 0x69,
        0x92, 0xce, 0xcf, 0xff, 0xd9,
    ];

    /// Minimal little-endian TIFF with a single IFD0 Orientation tag.
    fn tiff_with_orientation(orientation: u16) -> Vec<u8> {
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II");
        tiff.extend_from_slice(&42u16.to_le_bytes());
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes());
        tiff.extend_from_slice(&0x0112u16.to_le_bytes());
        tiff.extend_from_slice(&3u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&orientation.to_le_bytes());
        tiff.extend_from_slice(&[0, 0]);
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff
    }

    fn associated_property<'a>(
        meta: &'a isobmff::ParsedMeta,
        item_id: u32,
        property_type: &str,
    ) -> &'a isobmff::PropertyInfo {
        let entry = meta
            .ipma_entries
            .iter()
            .find(|entry| entry.item_id == item_id)
            .expect("item has an ipma entry");
        entry
            .associations
            .iter()
            .find_map(|(index, _)| {
                meta.props
                    .iter()
                    .find(|property| property.index == *index && property.ptype == property_type)
            })
            .expect("item has the associated property")
    }

    /// The Ultra HDR base JPEG's EXIF orientation is baked into the primary
    /// tiles, and the whole graph stays self-consistent: the primary is stored
    /// in presentation orientation with an explicit zero-turn `irot`, the tmap
    /// matches that ispe, and the gain map is rotated into the same frame so it
    /// remains a 0.5x companion. A non-zero `irot` here is what made Photos
    /// render the portrait aperture preview black.
    #[test]
    fn synthesize_bakes_exif_orientation_into_primary_and_gain_map() {
        let info = UhdrJpeg {
            gainmap_jpeg: TINY_16X8_JPEG.to_vec(),
            meta_floats: vec![0.0f32; 20],
            exif_tiff: Some(tiff_with_orientation(6)),
        };
        let container =
            synthesize_source_container(TINY_16X8_JPEG, &info, true).expect("synthesize container");
        let parsed = isobmff::parse_source_meta(&container).expect("parse synthesized container");
        let primary_ispe = associated_property(&parsed, parsed.primary_id, "ispe");
        assert_eq!(
            isobmff::ispe_dimensions(&primary_ispe.raw).unwrap(),
            (8, 16),
            "a 16x8 EXIF-6 base must be stored as its 8x16 presentation"
        );
        let primary_irot = associated_property(&parsed, parsed.primary_id, "irot");
        assert_eq!(isobmff::irot_quarter_turns(&primary_irot.raw).unwrap(), 0);

        // The grid descriptor must describe the same (presentation) geometry.
        let top = isobmff::parse_boxes(&container, 0, container.len());
        let meta_box = top.iter().find(|b| &b.btype == b"meta").expect("meta box");
        let idat = isobmff::parse_boxes(&container, meta_box.data_start + 4, meta_box.data_end)
            .into_iter()
            .find(|b| &b.btype == b"idat")
            .expect("idat box");
        let grid = &container[idat.data_start..idat.data_end];
        assert_eq!(&grid[0..4], &[0, 0, 0, 0], "single 512x512 tile");
        assert_eq!(u16::from_be_bytes([grid[4], grid[5]]), 8);
        assert_eq!(u16::from_be_bytes([grid[6], grid[7]]), 16);

        // Feed the same container through the UHDR writer: the explicit `irot`
        // wins over the EXIF-derived one and the 16x8 gain map is rotated to
        // the primary's presentation frame.
        let unique = format!(
            "xdremux_test_baked_orientation_{}_{}.heic",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock is after the Unix epoch")
                .as_nanos(),
        );
        let tmp = std::env::temp_dir().join(unique);
        crate::isobmff_write::write_uhdr_iso_output(
            &container,
            &info.gainmap_jpeg,
            &info.meta_floats,
            crate::exif::OppoCompat::Off,
            crate::container::OppoCameraTail::default_for_compat(crate::exif::OppoCompat::Off),
            false,
            tmp.to_str().expect("temporary path is valid UTF-8"),
        )
        .expect("UHDR writer accepts the synthesized container");

        let written = std::fs::read(&tmp).expect("read written HEIC");
        let out = isobmff::parse_source_meta(&written).expect("parse written HEIC");
        let out_primary_irot = associated_property(&out, out.primary_id, "irot");
        assert_eq!(
            isobmff::irot_quarter_turns(&out_primary_irot.raw).unwrap(),
            0,
            "the container's explicit irot must replace the EXIF-derived one"
        );
        let gain_grid = out
            .items
            .iter()
            .find(|item| item.itype == "grid" && item.item_id != out.primary_id)
            .expect("gain-map grid item")
            .item_id;
        let gain_ispe = associated_property(&out, gain_grid, "ispe");
        assert_eq!(
            isobmff::ispe_dimensions(&gain_ispe.raw).unwrap(),
            (8, 16),
            "the gain map must follow the primary into presentation orientation"
        );
        let tmap_id = out
            .items
            .iter()
            .find(|item| item.itype == "tmap")
            .expect("tmap item")
            .item_id;
        let tmap_ispe = associated_property(&out, tmap_id, "ispe");
        assert_eq!(isobmff::ispe_dimensions(&tmap_ispe.raw).unwrap(), (8, 16));

        std::fs::remove_file(&tmp).expect("remove written HEIC");
    }
}
