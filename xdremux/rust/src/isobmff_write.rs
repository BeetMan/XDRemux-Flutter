//! ISOBMFF LHDR/UHDR output assembly.
//!
//! Takes a parsed source HEIC, decoded gain map pixels, HEVC-encoded gain map
//! tiles, and ISO metadata, and assembles a complete ISO HDR HEIC file.
//!
//! Supports both LHDR (reconstructed gray gain map) and UHDR (pre-computed
//! gain map JPEG) paths, with optional OPPO Gallery compatibility modes.
//!
//! Ported from Swift `writePrivateJPEGPassthroughOutput()` /
//! `writeHybridPrimaryPassthrough()` and informed by Python `heif_io`.

use crate::container::OppoCameraTail;
use crate::exif::{self, ExifOrientation, OppoCompat};
use crate::isobmff::{
    self, BoxHeader, IlocEntry, IrefEntry, AUX_C_BOX, COLR_BT2020_PQ_BOX, COLR_SRGB_BOX,
    COLR_UNSPECIFIED_BT601_BOX, DINF_BOX, PIXI_RGB10_BOX, PIXI_RGB8_BOX,
};

/// Context for output assembly.
struct OutputConfig {
    _oppo_compat: OppoCompat,
    oppo_rgb: bool, // true for OPPO LHDR RGB-copy or UHDR 3ch
    tail_policy: OppoCameraTail,
    tile_payloads: Vec<Vec<u8>>,
    tile_ids: Vec<u32>,
    gain_grid_id: u32,
    tmap_id: u32,
    xmp_id: u32,
    group_id: u32,
    tmap_payload: Vec<u8>,
    xmp_bytes: Vec<u8>,
    gain_hvcc: Vec<u8>, // pre-extracted HEVC decoder config (byte-stream → hvcC)
    // clli (content light level) properties, mirroring the Python/Swift
    // reference. base_clli goes on the primary grid, tmap_clli on the tmap item.
    base_clli: Vec<u8>,
    tmap_clli: Vec<u8>,
}

/// Locate the source Exif item and apply the OPPO UserComment patch to the
/// source mdat payload, confined to the Exif iloc extent (Swift
/// `applyOppoUserCommentPatch` behaviour). Returns `None` when no patch is
/// wanted, the Exif item is absent, or the patch would not apply.
fn patch_oppo_usercomment(
    parsed: &ParsedSource,
    source_mdat: &mut Vec<u8>,
    mdat_data_start: usize,
    oppo_compat: OppoCompat,
) -> Option<exif::OppoUserCommentPatch> {
    if !oppo_compat.wants_patch() {
        return None;
    }
    let exif_entry = exif::find_exif_iloc_entry(&parsed.items, &parsed.iloc_entries)?;
    exif::apply_oppo_usercomment_patch(source_mdat, mdat_data_start, exif_entry, oppo_compat)
}

// ---------------------------------------------------------------------------
// LHDR output
// ---------------------------------------------------------------------------

/// Write a complete ISO HDR HEIC for LHDR input.
pub fn write_lhdr_iso_output(
    source_data: &[u8],
    mask_pixels: &[u8],
    mask_width: u32,
    mask_height: u32,
    meta_floats: &[f32],
    edr_scale: f32,
    oppo_compat: OppoCompat,
    tail_policy: OppoCameraTail,
    strict_tmap: bool,
    output_path: &str,
) -> Result<(), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;

    let (parsed, mut source_mdat, idat_opt) = parse_source_structure(source_data, &top, meta)?;
    let orientation = exif::read_heif_exif_orientation(
        source_data,
        &parsed.items,
        &parsed.iloc_entries,
        idat_opt.as_ref(),
    )?;

    // Reconstruct the gain map from the OPPO mask through the Reinhard knee
    // LUT chain, exactly like the Swift reference (GainMapReconstructor).
    // Verified against Swift's debug output: for this x6 LHDR sample the mask
    // (mean ≈ 46) reconstructs to a gain map with mean ≈ 31.5. Using the mask
    // pixels directly (mean ≈ 18.6 after tiling) produces a different, brighter
    // result that does not match Swift.
    let gainmap = crate::gainmap::reconstruct(
        mask_pixels,
        mask_width as usize,
        mask_height as usize,
        mask_width as usize,
        edr_scale,
        meta_floats.first().copied().unwrap_or(3.0),
    );
    let (mut gainmap, gain_width, gain_height) = orient_gainmap_pixels(
        &gainmap,
        mask_width,
        mask_height,
        1,
        mask_width as usize,
        orientation,
    )?;

    // Gain-map pixels: match the Python reference. The underlying tile data is
    // monochrome (the OPPO mask is a single channel) and the HEVC stream is
    // encoded gray — pyref's decoded gain-map stream is `gray` with no colour
    // VUI. Only the container pixi declares RGB; do not force RGB encoding.
    let (hevc_pixels, pixel_bytes): (&[u8], usize) = if oppo_compat.wants_oppo_rgb() {
        // OPPO Gallery reads a 4:2:0 RGB stream; replicate gray → RGB.
        let n_pixels = (gain_width * gain_height) as usize;
        let mut rgb = vec![0u8; n_pixels * 3];
        for i in 0..n_pixels {
            let v = gainmap[i];
            rgb[i * 3] = v;
            rgb[i * 3 + 1] = v;
            rgb[i * 3 + 2] = v;
        }
        gainmap = rgb;
        (&gainmap[..], 3)
    } else {
        (&gainmap[..], 1)
    };

    // Tile & HEVC-encode
    let (tile_payloads, tile_ids, cols, rows, gain_hvcc) = tile_and_encode(
        hevc_pixels,
        gain_width,
        gain_height,
        pixel_bytes,
        gain_width as usize * pixel_bytes,
        &parsed,
        oppo_compat,
    )?;

    // ISO metadata
    let iso_meta = crate::iso21496::build_iso_metadata(edr_scale);
    let xmp_bytes: Vec<u8> = if oppo_compat.wants_oppo_rgb() {
        // OPPO mode: minimal XMP (dates only, no hdrgm namespace).
        // The 142-byte tmap payload carries all HDR metadata;
        // hdrgm:* tags in XMP confuse OPPO Gallery routing.
        crate::iso21496::format_minimal_xmp().into_bytes()
    } else {
        crate::iso21496::format_hdrgm_xmp(&iso_meta).into_bytes()
    };
    let tmap_payload = if oppo_compat.wants_oppo_rgb() {
        crate::iso21496::make_imageio_native_tmap_payload(&iso_meta)
    } else {
        crate::iso21496::make_apple_tmap_payload(&iso_meta)
    };
    let tmap_payload = if strict_tmap {
        crate::iso21496::make_strict_tmap_payload(&tmap_payload)?
    } else {
        tmap_payload
    };

    // Item IDs
    let (gain_grid_id, tmap_id, xmp_id, group_id) =
        assign_new_ids(&parsed, tile_payloads.len() as u32);

    let cfg = OutputConfig {
        _oppo_compat: oppo_compat,
        oppo_rgb: oppo_compat.wants_oppo_rgb(),
        tail_policy,
        tile_payloads: tile_payloads.clone(),
        tile_ids: tile_ids.clone(),
        gain_grid_id,
        tmap_id,
        xmp_id,
        group_id,
        tmap_payload: tmap_payload.clone(),
        xmp_bytes: xmp_bytes.clone(),
        gain_hvcc,
        base_clli: crate::iso21496::make_iso_clli_box(&iso_meta, false),
        tmap_clli: crate::iso21496::make_iso_clli_box(&iso_meta, true),
    };

    // OPPO UserComment patch
    let patch = patch_oppo_usercomment(&parsed, &mut source_mdat, mdat.data_start as usize, oppo_compat);

    assemble_and_write(
        source_data,
        ftyp,
        meta,
        mdat,
        &parsed,
        idat_opt,
        &source_mdat,
        patch,
        gain_width,
        gain_height,
        cols,
        rows,
        orientation,
        &cfg,
        output_path,
    )
}

// ---------------------------------------------------------------------------
// UHDR output
// ---------------------------------------------------------------------------

/// Write a complete ISO HDR HEIC for UHDR input.
///
/// UHDR gain maps are pre-computed (no pixel reconstruction needed).
/// The gain map JPEG is decoded to raw pixels and encoded as HEVC tiles.
pub fn write_uhdr_iso_output(
    source_data: &[u8],
    gainmap_jpeg: &[u8],
    meta_floats: &[f32],
    oppo_compat: OppoCompat,
    tail_policy: OppoCameraTail,
    strict_tmap: bool,
    output_path: &str,
) -> Result<(), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;

    let (parsed, mut source_mdat, idat_opt) = parse_source_structure(source_data, &top, meta)?;
    let orientation = exif::read_heif_exif_orientation(
        source_data,
        &parsed.items,
        &parsed.iloc_entries,
        idat_opt.as_ref(),
    )?;

    // Decode gain map JPEG to raw pixels
    // UHDR gain maps are RGB JPEGs; we decode to RGB and optionally extract gray
    let (rgb_pixels, gm_w, gm_h) = crate::jpeg_decode::decode_jpeg_to_rgb(gainmap_jpeg)
        .map_err(|e| format!("UHDR gain map JPEG decode failed: {e}"))?;
    let (rgb_pixels, gain_width, gain_height) =
        orient_gainmap_pixels(&rgb_pixels, gm_w, gm_h, 3, gm_w as usize * 3, orientation)?;

    // UHDR gain maps are 3-channel RGB regardless of compat mode
    let (hevc_pixels, pixel_bytes): (&[u8], usize) = (&rgb_pixels[..], 3);

    // Tile & HEVC-encode
    let (tile_payloads, tile_ids, cols, rows, gain_hvcc) = tile_and_encode(
        hevc_pixels,
        gain_width,
        gain_height,
        pixel_bytes,
        gain_width as usize * pixel_bytes,
        &parsed,
        oppo_compat,
    )?;

    // ISO metadata from UHDR 20-float info
    let iso_meta = crate::iso21496::build_iso_metadata_from_uhdr(meta_floats)
        .map_err(|e| format!("UHDR metadata: {e}"))?;
    let xmp_bytes: Vec<u8> = if oppo_compat.wants_oppo_rgb() {
        crate::iso21496::format_minimal_xmp().into_bytes()
    } else {
        crate::iso21496::format_hdrgm_xmp(&iso_meta).into_bytes()
    };

    // tmap: OPPO gets 142-byte ImageIO-native, clean gets 62-byte Apple
    let tmap_payload = if oppo_compat.wants_oppo_rgb() {
        crate::iso21496::make_imageio_native_tmap_payload(&iso_meta)
    } else {
        crate::iso21496::make_apple_tmap_payload(&iso_meta)
    };
    let tmap_payload = if strict_tmap {
        crate::iso21496::make_strict_tmap_payload(&tmap_payload)?
    } else {
        tmap_payload
    };

    // Item IDs
    let (gain_grid_id, tmap_id, xmp_id, group_id) =
        assign_new_ids(&parsed, tile_payloads.len() as u32);

    let cfg = OutputConfig {
        _oppo_compat: oppo_compat,
        oppo_rgb: true, // UHDR gain maps are always 3-channel
        tail_policy,
        tile_payloads: tile_payloads.clone(),
        tile_ids: tile_ids.clone(),
        gain_grid_id,
        tmap_id,
        xmp_id,
        group_id,
        tmap_payload: tmap_payload.clone(),
        xmp_bytes: xmp_bytes.clone(),
        gain_hvcc,
        base_clli: crate::iso21496::make_iso_clli_box(&iso_meta, false),
        tmap_clli: crate::iso21496::make_iso_clli_box(&iso_meta, true),
    };

    // OPPO UserComment patch
    let patch = patch_oppo_usercomment(&parsed, &mut source_mdat, mdat.data_start as usize, oppo_compat);

    assemble_and_write(
        source_data,
        ftyp,
        meta,
        mdat,
        &parsed,
        idat_opt,
        &source_mdat,
        patch,
        gain_width,
        gain_height,
        cols,
        rows,
        orientation,
        &cfg,
        output_path,
    )
}

// ---------------------------------------------------------------------------
// Split encode: prepare (gain map → tiled YUV420) + assemble (HEVC → ISO)
//
// Used by the Android hardware-encoding path: Rust decodes/rebuilds/orients
// the gain map and tiles it into 512×512 YUV420 buffers; Dart drives a
// MediaCodec encoder over those buffers; the resulting HEVC byte-streams are
// handed back here to be wrapped into the final ISO 21496-1 HEIC.
// ---------------------------------------------------------------------------

/// Everything needed to assemble the final HEIC once per-tile HEVC encoding
/// is done. Owns the source bytes so assembly is self-contained.
pub struct PreparedOutput {
    pub source: Vec<u8>,
    pub meta_floats: Vec<f32>,
    pub edr_scale: f32,
    pub mode_key: String,
    pub family: String,
    pub oppo_compat: OppoCompat,
    pub tail_policy: OppoCameraTail,
    pub strict_tmap: bool,
    pub orientation: ExifOrientation,
    pub gain_width: u32,
    pub gain_height: u32,
    pub cols: u32,
    pub rows: u32,
    /// Whether the gain map is RGB (3ch, OPPO / UHDR) or gray (1ch, clean LHDR).
    pub oppo_rgb: bool,
}

/// Grid dimensions for a gain map at [GAIN_TILE_SIZE] tiles.
fn tile_grid_dims(width: u32, height: u32) -> (u32, u32) {
    let cols = ((width + GAIN_TILE_SIZE - 1) / GAIN_TILE_SIZE).max(1);
    let rows = ((height + GAIN_TILE_SIZE - 1) / GAIN_TILE_SIZE).max(1);
    (cols, rows)
}

/// Tile a gain map into [GAIN_TILE_SIZE]-square 4:2:0 YUV buffers, packed
/// contiguously as [Y][U][V] per tile in row-major order. Gray input (1 byte
/// per pixel) becomes Y = gray with chroma at 128; RGB input is converted with
/// BT.709 full-range coefficients.
fn tile_all_to_yuv420(
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
) -> Result<Vec<u8>, String> {
    let stride = width as usize * pixel_bytes;
    let (cols, rows) = tile_grid_dims(width, height);
    let mut out = Vec::with_capacity((rows * cols) as usize * 512 * 512 * 3 / 2);
    for row in 0..rows {
        for col in 0..cols {
            let tile = build_padded_gain_tile(
                pixels,
                width,
                height,
                pixel_bytes,
                stride,
                col * GAIN_TILE_SIZE,
                row * GAIN_TILE_SIZE,
            )?;
            tile_to_yuv420_into(&tile, pixel_bytes, &mut out)?;
        }
    }
    Ok(out)
}

fn tile_to_yuv420_into(tile: &[u8], pixel_bytes: usize, out: &mut Vec<u8>) -> Result<(), String> {
    let tw = GAIN_TILE_SIZE as usize;
    match pixel_bytes {
        1 => {
            out.extend_from_slice(tile);
            let chroma = vec![128u8; (tw / 2) * (tw / 2)];
            out.extend_from_slice(&chroma);
            out.extend_from_slice(&chroma);
        }
        3 => {
            let (y, u, v) = crate::hevc::rgb_to_yuv420(tile, GAIN_TILE_SIZE, GAIN_TILE_SIZE);
            out.extend_from_slice(&y);
            out.extend_from_slice(&u);
            out.extend_from_slice(&v);
        }
        other => return Err(format!("unsupported gain-map pixel bytes: {other}")),
    }
    Ok(())
}

/// Prepare an LHDR source for external tile encoding: reconstruct the gain
/// map, apply EXIF orientation, tile, and pack YUV420. Returns the prepared
/// context plus the packed YUV tile buffer.
pub fn prepare_lhdr_tiles(
    source_data: &[u8],
    mask_pixels: &[u8],
    mask_width: u32,
    mask_height: u32,
    meta_floats: &[f32],
    edr_scale: f32,
    oppo_compat: OppoCompat,
    tail_policy: OppoCameraTail,
    strict_tmap: bool,
) -> Result<(PreparedOutput, Vec<u8>), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let meta = find(&top, b"meta")?;
    let (parsed, _, idat_opt) = parse_source_structure(source_data, &top, meta)?;
    let orientation = exif::read_heif_exif_orientation(
        source_data,
        &parsed.items,
        &parsed.iloc_entries,
        idat_opt.as_ref(),
    )?;

    let gainmap = crate::gainmap::reconstruct(
        mask_pixels,
        mask_width as usize,
        mask_height as usize,
        mask_width as usize,
        edr_scale,
        meta_floats[0],
    );
    let aligned_row = ((mask_width as usize + 255) / 256) * 256;
    let (mut gainmap, gain_width, gain_height) = orient_gainmap_pixels(
        &gainmap,
        mask_width,
        mask_height,
        1,
        aligned_row,
        orientation,
    )?;

    let oppo_rgb = oppo_compat.wants_oppo_rgb();
    let (hevc_pixels, pixel_bytes) = if oppo_rgb {
        let n_pixels = (gain_width * gain_height) as usize;
        let mut rgb = vec![0u8; n_pixels * 3];
        for i in 0..n_pixels {
            let v = gainmap[i];
            rgb[i * 3] = v;
            rgb[i * 3 + 1] = v;
            rgb[i * 3 + 2] = v;
        }
        gainmap = rgb;
        (&gainmap[..], 3)
    } else {
        (&gainmap[..], 1)
    };

    let yuv = tile_all_to_yuv420(hevc_pixels, gain_width, gain_height, pixel_bytes)?;
    let (cols, rows) = tile_grid_dims(gain_width, gain_height);
    let family = if meta_floats[0] >= 3.0 { "x7" } else { "x6" };

    Ok((
        PreparedOutput {
            source: source_data.to_vec(),
            meta_floats: meta_floats.to_vec(),
            edr_scale,
            mode_key: "lhdr".into(),
            family: family.into(),
            oppo_compat,
            tail_policy,
            strict_tmap,
            orientation,
            gain_width,
            gain_height,
            cols,
            rows,
            oppo_rgb,
        },
        yuv,
    ))
}

/// Prepare a UHDR source for external tile encoding. UHDR gain maps are
/// pre-computed RGB JPEGs; the decoded raster is oriented, tiled, and packed.
pub fn prepare_uhdr_tiles(
    source_data: &[u8],
    gainmap_jpeg: &[u8],
    meta_floats: &[f32],
    oppo_compat: OppoCompat,
    tail_policy: OppoCameraTail,
    strict_tmap: bool,
) -> Result<(PreparedOutput, Vec<u8>), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let meta = find(&top, b"meta")?;
    let (parsed, _, idat_opt) = parse_source_structure(source_data, &top, meta)?;
    let orientation = exif::read_heif_exif_orientation(
        source_data,
        &parsed.items,
        &parsed.iloc_entries,
        idat_opt.as_ref(),
    )?;

    let (rgb_pixels, gm_w, gm_h) = crate::jpeg_decode::decode_jpeg_to_rgb(gainmap_jpeg)
        .map_err(|e| format!("UHDR gain map JPEG decode failed: {e}"))?;
    let (rgb_pixels, gain_width, gain_height) =
        orient_gainmap_pixels(&rgb_pixels, gm_w, gm_h, 3, gm_w as usize * 3, orientation)?;

    let yuv = tile_all_to_yuv420(&rgb_pixels, gain_width, gain_height, 3)?;
    let (cols, rows) = tile_grid_dims(gain_width, gain_height);

    Ok((
        PreparedOutput {
            source: source_data.to_vec(),
            meta_floats: meta_floats.to_vec(),
            edr_scale: meta_floats.get(18).copied().unwrap_or(1.0),
            mode_key: "uhdr".into(),
            family: "x7".into(),
            oppo_compat,
            tail_policy,
            strict_tmap,
            orientation,
            gain_width,
            gain_height,
            cols,
            rows,
            oppo_rgb: true, // UHDR gain maps are always 3-channel
        },
        yuv,
    ))
}

/// Wrap per-tile HEVC byte-streams (row-major, one per tile) into the final
/// ISO 21496-1 HEIC. Extracts hvcC from the first stream, length-prefixes the
/// NALs, and reuses the shared assembler. Returns (edr_scale, gain_map_max).
pub fn assemble_prepared_tiles(
    prepared: &PreparedOutput,
    tile_streams: &[&[u8]],
    output_path: &str,
) -> Result<(f32, f32), String> {
    let top = isobmff::parse_boxes(&prepared.source, 0, prepared.source.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;
    let (parsed, mut source_mdat, idat_opt) =
        parse_source_structure(&prepared.source, &top, meta)?;

    let mut tile_payloads: Vec<Vec<u8>> = Vec::with_capacity(tile_streams.len());
    let mut gain_hvcc: Vec<u8> = Vec::new();
    for (i, stream) in tile_streams.iter().enumerate() {
        if gain_hvcc.is_empty() {
            // The hardware path always encodes 4:2:0 (MediaCodec has no 4:4:4),
            // so the hvcC must claim chroma_format_idc=1 regardless of the
            // x265 fallback's cfg/env-driven default.
            gain_hvcc =
                crate::hevc::extract_hvcc_config_with_chroma(stream, 1).unwrap_or_default();
        }
        tile_payloads.push(crate::hevc::hevc_byte_stream_to_length_prefixed(stream));
        crate::progress::set_progress(4, (i + 1) as u32, tile_streams.len() as u32);
    }

    let iso_meta = if prepared.mode_key == "uhdr" {
        crate::iso21496::build_iso_metadata_from_uhdr(&prepared.meta_floats)
            .map_err(|e| format!("UHDR metadata: {e}"))?
    } else {
        crate::iso21496::build_iso_metadata(prepared.edr_scale)
    };
    // tmap/xmp format follows the user's OPPO compat mode, exactly like the
    // software path (`write_uhdr_iso_output`). `oppo_rgb` (UHDR 3-channel
    // layout) must NOT drive this: an OPPO-native 142-byte tmap paired with a
    // MediaCodec 4:2:0 stream breaks OPPO gallery decoding (color channel
    // mismatch → garbled image).
    let oppo_meta = prepared.oppo_compat.wants_oppo_rgb();
    let xmp_bytes: Vec<u8> = if oppo_meta {
        crate::iso21496::format_minimal_xmp().into_bytes()
    } else {
        crate::iso21496::format_hdrgm_xmp(&iso_meta).into_bytes()
    };
    let tmap_payload = if oppo_meta {
        crate::iso21496::make_imageio_native_tmap_payload(&iso_meta)
    } else {
        crate::iso21496::make_apple_tmap_payload(&iso_meta)
    };
    let tmap_payload = if prepared.strict_tmap {
        crate::iso21496::make_strict_tmap_payload(&tmap_payload)?
    } else {
        tmap_payload
    };

    let tile_ids: Vec<u32> = {
        let first_new = (parsed.max_src_id + 1).max(2);
        (0..tile_payloads.len())
            .map(|i| first_new + i as u32)
            .collect()
    };
    let (gain_grid_id, tmap_id, xmp_id, group_id) =
        assign_new_ids(&parsed, tile_payloads.len() as u32);

    let cfg = OutputConfig {
        _oppo_compat: prepared.oppo_compat,
        oppo_rgb: prepared.oppo_rgb,
        tail_policy: prepared.tail_policy,
        tile_payloads: tile_payloads.clone(),
        tile_ids: tile_ids.clone(),
        gain_grid_id,
        tmap_id,
        xmp_id,
        group_id,
        tmap_payload: tmap_payload.clone(),
        xmp_bytes: xmp_bytes.clone(),
        gain_hvcc,
        base_clli: crate::iso21496::make_iso_clli_box(&iso_meta, false),
        tmap_clli: crate::iso21496::make_iso_clli_box(&iso_meta, true),
    };

    let patch = patch_oppo_usercomment(
        &parsed,
        &mut source_mdat,
        mdat.data_start as usize,
        prepared.oppo_compat,
    );

    assemble_and_write(
        &prepared.source,
        ftyp,
        meta,
        mdat,
        &parsed,
        idat_opt,
        &source_mdat,
        patch,
        prepared.gain_width,
        prepared.gain_height,
        prepared.cols,
        prepared.rows,
        prepared.orientation,
        &cfg,
        output_path,
    )?;

    if prepared.mode_key == "uhdr" {
        let scale = prepared.meta_floats.get(18).copied().unwrap_or(1.0);
        let ratio_max = prepared
            .meta_floats
            .get(4..7)
            .map(|s| s.iter().copied().fold(0.0f32, f32::max))
            .unwrap_or(0.0);
        let gm_max = if ratio_max > 0.0 { ratio_max.log2() } else { 0.0 };
        Ok((scale, gm_max))
    } else {
        let edr = prepared.edr_scale;
        let gm_max = if edr > 1.0 { edr.log2() } else { 0.0 };
        Ok((edr, gm_max))
    }
}

// ---------------------------------------------------------------------------
// Shared: source parsing
// ---------------------------------------------------------------------------

struct ParsedSource {
    items: Vec<crate::isobmff::ItemInfo>,
    iloc_entries: Vec<IlocEntry>,
    props: Vec<crate::isobmff::PropertyInfo>,
    ipma_entries: Vec<crate::isobmff::IpmaEntry>,
    ipma_flags: u32,
    ipma_box: BoxHeader,
    ipco_box_raw: Option<BoxHeader>,
    #[allow(dead_code)]
    ipma_data: Vec<BoxHeader>,
    refs: Vec<IrefEntry>,
    iref_version: u8,
    pitm_version: u8,
    iinf_version: u8,
    primary_id: u32,
    max_src_id: u32,
}

fn parse_source_structure(
    source_data: &[u8],
    top: &[BoxHeader],
    meta: &BoxHeader,
) -> Result<(ParsedSource, Vec<u8>, Option<BoxHeader>), String> {
    let meta_kids = isobmff::parse_boxes(source_data, meta.data_start + 4, meta.data_end);
    let pitm = find(&meta_kids, b"pitm")?;
    let iinf = find(&meta_kids, b"iinf")?;
    let iloc_box = find(&meta_kids, b"iloc")?;
    let iprp = find(&meta_kids, b"iprp")?;
    let idat_opt = meta_kids.iter().find(|b| &b.btype == b"idat").cloned();
    let iref_opt = meta_kids.iter().find(|b| &b.btype == b"iref").cloned();
    let mdat = find(top, b"mdat")?;

    let primary_id = isobmff::parse_pitm(source_data, pitm);
    let items = isobmff::parse_iinf(source_data, iinf)?;
    let iloc_entries = isobmff::parse_iloc(source_data, iloc_box)?;
    let props = isobmff::parse_iprp_properties(source_data, iprp)?;

    let ipma_data = isobmff::parse_boxes(source_data, iprp.data_start, iprp.data_end);
    let ipma_box = ipma_data
        .iter()
        .find(|b| &b.btype == b"ipma")
        .ok_or("ipma missing")?
        .clone();
    let (ipma_flags, ipma_entries) = isobmff::parse_ipma(source_data, &ipma_box);

    let (iref_version, refs) = if let Some(iref) = &iref_opt {
        isobmff::parse_iref(source_data, iref)
    } else {
        (0, Vec::new())
    };

    let max_src_id = items.iter().map(|i| i.item_id).max().unwrap_or(1);
    let source_mdat = source_data[mdat.data_start..mdat.data_end].to_vec();
    let ipco_box_raw = ipma_data.iter().find(|b| &b.btype == b"ipco").cloned();

    Ok((
        ParsedSource {
            items,
            iloc_entries,
            props,
            ipma_entries,
            ipma_flags,
            ipma_box,
            ipco_box_raw,
            ipma_data,
            refs,
            iref_version,
            pitm_version: source_data[pitm.data_start],
            iinf_version: source_data[iinf.data_start],
            primary_id,
            max_src_id,
        },
        source_mdat,
        idat_opt,
    ))
}

// ---------------------------------------------------------------------------
// Gain-map orientation
// ---------------------------------------------------------------------------

/// Apply the primary image's EXIF storage-to-presentation transform to a gain
/// map. Input rows may be padded; the returned raster is tightly packed.
fn orient_gainmap_pixels(
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    stride: usize,
    orientation: ExifOrientation,
) -> Result<(Vec<u8>, u32, u32), String> {
    if width == 0 || height == 0 || pixel_bytes == 0 {
        return Err("gain map has invalid dimensions or pixel format".into());
    }
    let packed_row = width as usize * pixel_bytes;
    if stride < packed_row {
        return Err("gain map stride is smaller than a packed row".into());
    }
    let required_len = stride
        .checked_mul(height as usize)
        .ok_or("gain map input size overflow")?;
    if pixels.len() < required_len {
        return Err("gain map buffer is shorter than its declared geometry".into());
    }

    let (out_width, out_height) = orientation.output_dimensions(width, height);
    let out_len = (out_width as usize)
        .checked_mul(out_height as usize)
        .and_then(|pixels| pixels.checked_mul(pixel_bytes))
        .ok_or("gain map output size overflow")?;
    let mut output = vec![0u8; out_len];

    for source_y in 0..height {
        for source_x in 0..width {
            let (dest_x, dest_y) = match orientation {
                ExifOrientation::Normal => (source_x, source_y),
                ExifOrientation::FlipHorizontal => (width - 1 - source_x, source_y),
                ExifOrientation::Rotate180 => (width - 1 - source_x, height - 1 - source_y),
                ExifOrientation::FlipVertical => (source_x, height - 1 - source_y),
                ExifOrientation::Transpose => (source_y, source_x),
                ExifOrientation::Rotate90Clockwise => (height - 1 - source_y, source_x),
                ExifOrientation::Transverse => (height - 1 - source_y, width - 1 - source_x),
                ExifOrientation::Rotate90CounterClockwise => (source_y, width - 1 - source_x),
            };
            let source_start = source_y as usize * stride + source_x as usize * pixel_bytes;
            let dest_start = (dest_y as usize * out_width as usize + dest_x as usize) * pixel_bytes;
            output[dest_start..dest_start + pixel_bytes]
                .copy_from_slice(&pixels[source_start..source_start + pixel_bytes]);
        }
    }

    Ok((output, out_width, out_height))
}

// ---------------------------------------------------------------------------
// Shared: tile & encode
// ---------------------------------------------------------------------------

const GAIN_TILE_SIZE: u32 = 512;

/// Copy one logical gain-map tile into a full-size HEVC input tile. Edge pixels
/// are replicated only to the right and bottom, so the top-left origin remains
/// identical to the source raster and the ImageGrid can crop the padded tail.
fn build_padded_gain_tile(
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    stride: usize,
    x0: u32,
    y0: u32,
) -> Result<Vec<u8>, String> {
    if width == 0 || height == 0 || pixel_bytes == 0 || x0 >= width || y0 >= height {
        return Err("gain-map tile has invalid geometry".into());
    }
    let packed_row = width as usize * pixel_bytes;
    if stride < packed_row {
        return Err("gain-map tile stride is smaller than a packed row".into());
    }
    let required_len = stride
        .checked_mul(height as usize)
        .ok_or("gain-map tile input size overflow")?;
    if pixels.len() < required_len {
        return Err("gain-map tile input is shorter than its declared geometry".into());
    }

    let tw = GAIN_TILE_SIZE.min(width - x0);
    let th = GAIN_TILE_SIZE.min(height - y0);
    let tile_row_stride = GAIN_TILE_SIZE as usize * pixel_bytes;
    let copy_len = tw as usize * pixel_bytes;
    let mut tile = vec![0u8; GAIN_TILE_SIZE as usize * tile_row_stride];

    for ty in 0..th {
        let src = (y0 + ty) as usize * stride + x0 as usize * pixel_bytes;
        let dst = ty as usize * tile_row_stride;
        tile[dst..dst + copy_len].copy_from_slice(&pixels[src..src + copy_len]);
        for tx in tw..GAIN_TILE_SIZE {
            let dst_col = dst + tx as usize * pixel_bytes;
            let src_last = src + copy_len - pixel_bytes;
            tile[dst_col..dst_col + pixel_bytes]
                .copy_from_slice(&pixels[src_last..src_last + pixel_bytes]);
        }
    }
    for ty in th..GAIN_TILE_SIZE {
        let src_row = (y0 + th - 1) as usize * stride + x0 as usize * pixel_bytes;
        let dst = ty as usize * tile_row_stride;
        tile[dst..dst + copy_len].copy_from_slice(&pixels[src_row..src_row + copy_len]);
        for tx in tw..GAIN_TILE_SIZE {
            let dst_col = dst + tx as usize * pixel_bytes;
            let src_last = src_row + copy_len - pixel_bytes;
            tile[dst_col..dst_col + pixel_bytes]
                .copy_from_slice(&pixels[src_last..src_last + pixel_bytes]);
        }
    }

    Ok(tile)
}

fn tile_and_encode(
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    stride: usize, // bytes per row of the input pixel buffer
    parsed: &ParsedSource,
    oppo_compat: OppoCompat,
) -> Result<(Vec<Vec<u8>>, Vec<u32>, u32, u32, Vec<u8>), String> {
    let tile_size = GAIN_TILE_SIZE;
    let cols = ((width + tile_size - 1) / tile_size).max(1);
    let rows = ((height + tile_size - 1) / tile_size).max(1);
    let mut tile_payloads: Vec<Vec<u8>> = Vec::with_capacity((rows * cols) as usize);
    let mut gain_hvcc: Vec<u8> = Vec::new();

    let total_tiles = rows * cols;
    let mut tile_index: u32 = 0;
    crate::progress::set_progress(3, 0, total_tiles);

    // Build all padded tiles first, then encode them in ONE x265 session.
    // Session reuse avoids per-tile encoder open/close (~6.6x faster on a
    // 48-tile UHDR gain map) while keyint=1 keeps every tile an independent
    // keyframe with its own VPS/SPS/PPS.
    let mut padded: Vec<Vec<u8>> = Vec::with_capacity(total_tiles as usize);
    for row in 0..rows {
        for col in 0..cols {
            let x0 = col * tile_size;
            let y0 = row * tile_size;
            padded.push(build_padded_gain_tile(
                pixels, width, height, pixel_bytes, stride, x0, y0,
            )?);
            tile_index += 1;
            crate::progress::set_progress(3, tile_index, total_tiles);
        }
    }

    let tile_refs: Vec<&[u8]> = padded.iter().map(|t| t.as_slice()).collect();
    // 4:2:0 gain maps are only required for OPPO-compatible output (OPPO
    // Gallery reads 4:2:0 only). When OPPO compat is off, keep 4:4:4 for the
    // best chroma precision — this is also what Windows/Android originally
    // produced.
    let use_420 = oppo_compat.wants_oppo_compat();
    let batch_streams = crate::hevc::x265_encode_tiles(
        &tile_refs,
        tile_size,
        tile_size,
        pixel_bytes,
        use_420,
    )
    .map_err(|e| format!("HEVC batch encode: {e}"))?;
    debug_assert_eq!(batch_streams.len(), total_tiles as usize);

    for (i, hevc_bs) in batch_streams.iter().enumerate() {
        // Extract hvcC from the first tile's byte-stream HEVC (before
        // length-prefix conversion). extract_hvcc_config searches for
        // 00 00 00 01 start codes, which only exist in byte-stream format.
        if gain_hvcc.is_empty() {
            // Monochrome (gray) gain maps encode as chroma_format_idc=0.
            // 4:2:0 (OPPO output) is chroma 1; 4:4:4 RGB is chroma 3.
            let hvc_chroma = if pixel_bytes == 1 {
                0u8
            } else if use_420 {
                1u8
            } else {
                3u8
            };
            gain_hvcc = crate::hevc::extract_hvcc_config_with_chroma(hevc_bs, hvc_chroma)
                .unwrap_or_default();
        }

        // Convert from byte-stream (00 00 00 01 start codes) to length-prefixed
        // format (4-byte big-endian NAL length). ISOBMFF with hvcC requires
        // length-prefixed NAL units in mdat.
        //
        // Strip VPS/SPS/PPS (and SEI) from EVERY tile, including tile 0, so
        // each gain-map tile is a pure IDR slice — exactly what libheif (the
        // Python reference) writes. The decoder config lives only in hvcC;
        // Android's gain-map path (Google Photos, OPPO gallery) fails to apply
        // a tile that carries its own parameter sets.
        #[cfg(not(xdremux_ffmpeg_fallback))]
        let idr_bs = crate::hevc::drop_parameter_nals(hevc_bs);
        #[cfg(xdremux_ffmpeg_fallback)]
        let idr_bs = hevc_bs.to_vec();
        tile_payloads.push(crate::hevc::hevc_byte_stream_to_length_prefixed(&idr_bs));

        crate::progress::set_progress(3, (i + 1) as u32, total_tiles);
    }

    let first_new = (parsed.max_src_id + 1).max(2);
    let tile_ids: Vec<u32> = (0..tile_payloads.len())
        .map(|i| first_new + i as u32)
        .collect();

    Ok((tile_payloads, tile_ids, cols, rows, gain_hvcc))
}

fn assign_new_ids(parsed: &ParsedSource, num_tiles: u32) -> (u32, u32, u32, u32) {
    let first_new = (parsed.max_src_id + 1).max(2);
    let gain_grid_id = first_new + num_tiles;
    let tmap_id = gain_grid_id + 1;
    let xmp_id = gain_grid_id + 2;
    let group_id = gain_grid_id + 3;
    (gain_grid_id, tmap_id, xmp_id, group_id)
}

// ---------------------------------------------------------------------------
// Shared: assembly & write
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn assemble_and_write(
    source_data: &[u8],
    ftyp: &BoxHeader,
    meta: &BoxHeader,
    mdat: &BoxHeader,
    parsed: &ParsedSource,
    idat_opt: Option<BoxHeader>,
    source_mdat: &[u8],
    // OPPO UserComment patch. The patch only changes the Exif item's payload
    // (value appended to the item end), so cm=0 extents are adjusted with the
    // Swift `adjustedExtentForOppoUserCommentPatch` rule: before the Exif item
    // → unchanged; after → shifted by delta; the Exif item itself → length
    // grows by delta with offset kept.
    patch: Option<exif::OppoUserCommentPatch>,
    mask_width: u32,
    mask_height: u32,
    cols: u32,
    rows: u32,
    orientation: ExifOrientation,
    cfg: &OutputConfig,
    output_path: &str,
) -> Result<(), String> {
    let tile_size = GAIN_TILE_SIZE;

    // Extract hvcC from the pre-extracted gain tile HEVC config (already
    // extracted from byte-stream format before length-prefix conversion).
    let gain_hvcc_box = isobmff::make_box(b"hvcC", &cfg.gain_hvcc);

    // Find source's first colr property index (ICC profile, primary color).
    // Gain tiles and primary items reference this.
    let first_colr_idx = parsed
        .props
        .iter()
        .position(|p| p.ptype == "colr")
        .map(|i| i as u32 + 1);

    // Find source's first hvcC property index (primary HEVC config).
    let _first_hvcc_idx = parsed
        .props
        .iter()
        .position(|p| p.ptype == "hvcC")
        .map(|i| i as u32 + 1);

    // The primary item's associated `irot`, when present, is authoritative.
    // Otherwise synthesize the ImageIO-compatible rotation from EXIF.
    let primary_irot_idx = item_property_index(parsed, parsed.primary_id, "irot");
    let primary_ispe_idx = item_property_index(parsed, parsed.primary_id, "ispe")
        .ok_or("primary item has no ispe property association")?;
    let primary_ispe = parsed
        .props
        .get(primary_ispe_idx as usize - 1)
        .ok_or("primary ispe property index is invalid")?;
    let generated_irot = isobmff::make_irot_box(orientation.irot_quarter_turns_ccw());
    let selected_irot = primary_irot_idx
        .and_then(|index| parsed.props.get(index as usize - 1))
        .map(|property| property.raw.as_slice())
        .unwrap_or(generated_irot.as_slice());
    let tmap_ispe_box =
        isobmff::make_imageio_canonical_tmap_ispe_box(&primary_ispe.raw, selected_irot)?;

    // Build ipco (source + new properties, matching Python reference order)
    let (ipco_start, ipco_end) = parsed
        .ipco_box_raw
        .as_ref()
        .map(|b| (b.data_start, b.data_end))
        .unwrap_or((0, 0));
    let mut ipco = source_data[ipco_start..ipco_end].to_vec();
    let mut next_property_index = parsed.props.len() as u32;
    let mut append_property = |property: &[u8]| {
        next_property_index += 1;
        ipco.extend_from_slice(property);
        next_property_index
    };
    // auxC property stays in ipco (ISO 21496-1 signaling) even though the
    // Python/Swift reference does not associate it in ipma.
    let _auxc_i = append_property(AUX_C_BOX);
    let irot_i = append_property(&generated_irot);
    let pq_colr_i = append_property(COLR_BT2020_PQ_BOX);
    let srgb_colr_i = append_property(COLR_SRGB_BOX);
    let pixi10_i = append_property(PIXI_RGB10_BOX);
    let base_clli_i = append_property(&cfg.base_clli);
    let tmap_clli_i = append_property(&cfg.tmap_clli);
    // Gain map pixi always declares RGB, matching the Python reference
    // (write_heic_passthrough appends PIXI_RGB8_BOX for the gain map even
    // when the underlying data is monochrome). Google Photos' Ultra HDR
    // detection keys on the declared channel count: a pixi of 1 (mono)
    // makes it refuse the gain-map item, while RGB is accepted.
    let gain_pixi_i = append_property(PIXI_RGB8_BOX);
    let gain_tile_colr_i = if cfg.oppo_rgb {
        append_property(COLR_UNSPECIFIED_BT601_BOX)
    } else {
        srgb_colr_i
    };
    let gm_hvcc_i = append_property(&gain_hvcc_box);
    let gm_grid_ispe_i = append_property(&isobmff::make_ispe_box(
        mask_width.max(1),
        mask_height.max(1),
    ));
    let gm_tile_ispe_i = append_property(&isobmff::make_ispe_box(tile_size, tile_size));
    let tmap_ispe_i = if tmap_ispe_box == primary_ispe.raw {
        primary_ispe_idx
    } else {
        append_property(&tmap_ispe_box)
    };

    // Build ipma — rebuild from parsed entries, augmenting primary grid's
    // associations to match Python reference (Apple ImageIO requirement).
    let colr_prof = first_colr_idx.unwrap_or(1);
    let irot_pick = primary_irot_idx.unwrap_or(irot_i);
    let mut ipma_body = Vec::new();
    let total_entries = parsed.ipma_entries.len() + cfg.tile_payloads.len() + 2;
    isobmff::write_u32be(total_entries as u32, &mut ipma_body);

    for entry in &parsed.ipma_entries {
        let mut assocs = entry.associations.clone();
        if entry.item_id == parsed.primary_id {
            // The primary grid references the source ICC colour profile
            // (matching Swift/ImageIO), the base clli, and a rotation so
            // ImageIO/Google identify the file as an ISO 21496-1 gain-map image.
            if !assocs.iter().any(|(idx, _)| *idx == colr_prof) {
                assocs.push((colr_prof, true));
            }
            if !assocs.iter().any(|(idx, _)| *idx == base_clli_i) {
                assocs.push((base_clli_i, false));
            }
            if !assocs.iter().any(|(idx, _)| *idx == irot_pick) {
                assocs.push((irot_pick, true));
            }
        }
        ipma_body.extend_from_slice(&isobmff::make_ipma_entry(
            entry.item_id,
            &assocs,
            parsed.ipma_flags,
        ));
    }

    // Gain tiles (hvc1 items): hvcC(e) + ispe(e) + a colour box matching the
    // Swift/ImageIO reference (BT.601 nclx for OPPO RGB gain maps).
    for tid in &cfg.tile_ids {
        ipma_body.extend_from_slice(&isobmff::make_ipma_entry(
            *tid,
            &[
                (gm_tile_ispe_i, true),
                (gain_tile_colr_i, true),
                (gm_hvcc_i, true),
            ],
            parsed.ipma_flags,
        ));
    }
    // Gain grid: ispe(grid)(e) + colr(e) + pixi(e) + irot(e), matching the
    // Python/Swift reference. (No auxC association here; the auxC property is
    // still present in ipco for ISO 21496-1 signaling.)
    let irot_pick = primary_irot_idx.unwrap_or(irot_i);
    ipma_body.extend_from_slice(&isobmff::make_ipma_entry(
        cfg.gain_grid_id,
        &[
            (gm_grid_ispe_i, true),
            (gain_tile_colr_i, true),
            (gain_pixi_i, true),
            (irot_pick, true),
        ],
        parsed.ipma_flags,
    ));
    // tmap: PQ colr(e) + pixi10(e) + ispe(e) + tmap clli + irot(e),
    // matching Python/Swift.
    ipma_body.extend_from_slice(&isobmff::make_ipma_entry(
        cfg.tmap_id,
        &[
            (pq_colr_i, true),
            (pixi10_i, true),
            (tmap_ispe_i, true),
            (tmap_clli_i, false),
            (irot_pick, true),
        ],
        parsed.ipma_flags,
    ));

    let ipma_header = &source_data[parsed.ipma_box.data_start..parsed.ipma_box.data_start + 4]; // version+flags only
    let mut ipma_full = ipma_header.to_vec();
    ipma_full.extend_from_slice(&ipma_body);

    // Build iinf
    let mut infes: Vec<Vec<u8>> = parsed.items.iter().map(|it| it.raw_infe.clone()).collect();
    let tile_itype = if cfg.oppo_rgb { "hvc1" } else { "hvc1" };
    for tid in &cfg.tile_ids {
        infes.push(isobmff::make_infe_box(*tid, tile_itype, 1));
    }
    infes.push(isobmff::make_infe_box(cfg.gain_grid_id, "grid", 1));
    infes.push(isobmff::make_infe_box(cfg.tmap_id, "tmap", 0));
    infes.push(isobmff::make_mime_infe_box(cfg.xmp_id, 1));
    let iinf_box = isobmff::make_iinf_box(parsed.iinf_version, &infes);

    // Build iref
    let had_iref = parsed.refs.iter().any(|r| r.rtype != "grpl");
    let mut output_refs: Vec<IrefEntry> = parsed
        .refs
        .iter()
        .filter(|r| r.rtype != "grpl")
        .cloned()
        .collect();

    // Python/Swift reference behaviour: keep the source EXIF cdsc reference
    // untouched and add a SEPARATE cdsc entry pointing at [primary, tmap].
    // (The Rust code previously merged tmap into the source entry in-place,
    // which differs from the reference and makes Android's MediaExtractor
    // refuse the file.)
    let mut extra_cdsc: Vec<IrefEntry> = Vec::new();
    for r in &mut output_refs {
        if r.rtype == "cdsc" {
            let is_exif = parsed
                .items
                .iter()
                .any(|it| it.item_id == r.from && it.itype == "Exif");
            if is_exif {
                extra_cdsc.push(IrefEntry {
                    rtype: "cdsc".into(),
                    from: r.from,
                    to: vec![parsed.primary_id, cfg.tmap_id],
                });
                r.to = vec![parsed.primary_id];
            }
        }
    }
    output_refs.extend(extra_cdsc);

    if !cfg.tile_ids.is_empty() {
        output_refs.push(IrefEntry {
            rtype: "dimg".into(),
            from: cfg.gain_grid_id,
            to: cfg.tile_ids.clone(),
        });
    }
    output_refs.push(IrefEntry {
        rtype: "dimg".into(),
        from: cfg.tmap_id,
        to: vec![parsed.primary_id, cfg.gain_grid_id],
    });
    // NOTE: the Python/Swift reference does not emit an `auxl` reference. It
    // relies on the tmap/auxC items + grpl/altr grouping alone for ISO 21496-1
    // signaling; adding auxl was a Rust-only deviation.
    output_refs.push(IrefEntry {
        rtype: "cdsc".into(),
        from: cfg.xmp_id,
        to: vec![parsed.primary_id, cfg.tmap_id],
    });
    let use_ver1 = output_refs
        .iter()
        .any(|r| r.from > 0xffff || r.to.iter().any(|&id| id > 0xffff));
    let iref_v = if use_ver1 { 1u8 } else { parsed.iref_version };

    // Build idat
    // Always keep the source idat payload. In OPPO mode the source file's idat
    // may contain an 8-byte QTI wrapper, but source items with construction_method=1
    // still reference their data at offsets within the original idat. Discarding
    // the old idat breaks those items' extents, corrupting EXIF and grid configs.
    // Instead we append the new payloads (tmap, XMP, grid box) after the old idat,
    // exactly as the Swift writeHybridPrimaryPassthrough does.
    let old_idat: &[u8] = if let Some(ref idat) = idat_opt {
        &source_data[idat.data_start..idat.data_end]
    } else {
        &[]
    };
    let _idat_base = old_idat.len();
    // Order matches the Python/Swift reference: the gain-map grid box comes
    // immediately after the retained source idat, then tmap, then XMP. Android's
    // MediaExtractor resolves the gain-map item before the metadata items.
    let mut idat = old_idat.to_vec();
    let grid_box =
        isobmff::make_grid_box(tile_size, tile_size, rows, cols, mask_width, mask_height);
    let grid_off = idat.len();
    idat.extend_from_slice(&grid_box[8..]);
    let tmap_off = idat.len();
    idat.extend_from_slice(&cfg.tmap_payload);
    let xmp_off = idat.len();
    idat.extend_from_slice(&cfg.xmp_bytes);

    // iloc
    let mut all_iloc: Vec<IlocEntry> = parsed.iloc_entries.clone();
    let source_iloc_count = all_iloc.len();
    for (i, tile) in cfg.tile_payloads.iter().enumerate() {
        all_iloc.push(IlocEntry {
            item_id: cfg.tile_ids[i],
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, tile.len() as u64)],
        });
    }
    all_iloc.push(IlocEntry {
        item_id: cfg.gain_grid_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(grid_off as u64, (grid_box.len() - 8) as u64)],
    });
    all_iloc.push(IlocEntry {
        item_id: cfg.tmap_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(tmap_off as u64, cfg.tmap_payload.len() as u64)],
    });
    all_iloc.push(IlocEntry {
        item_id: cfg.xmp_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(xmp_off as u64, cfg.xmp_bytes.len() as u64)],
    });

    // --- PASS 1: placeholder iloc ---
    let pass1_iloc = isobmff::make_iloc_box(&all_iloc);
    let meta_kids = isobmff::parse_boxes(source_data, meta.data_start + 4, meta.data_end);
    let meta_part1 = assemble_meta(
        source_data,
        meta,
        &meta_kids,
        parsed.primary_id,
        parsed.pitm_version,
        &iinf_box,
        &pass1_iloc,
        &ipco,
        &ipma_full,
        &output_refs,
        had_iref,
        iref_v,
        &idat,
        cfg.group_id,
        cfg.tmap_id,
        parsed.primary_id,
    );

    let ftyp_box = isobmff::make_ftyp_box(&source_data[ftyp.data_start..ftyp.data_end]);
    let between = &source_data[meta.box_start + meta.size..mdat.box_start];
    let new_mdat_data_start = ftyp_box.len() + meta_part1.len() + between.len() + 8; // +8 for mdat box header

    // --- Fix iloc offsets ---
    // `mdat.data_start` is the source mdat content start; `new_mdat_data_start`
    // is the new mdat content start. Source items are byte-for-byte copies, but
    // the OPPO UserComment patch only grew the Exif item's payload. Each cm=0
    // extent is adjusted with the Swift `adjustedExtentForOppoUserCommentPatch`
    // rule, then shifted by `file_delta` into the new file layout.
    let file_delta = new_mdat_data_start as i64 - mdat.data_start as i64;
    let mut final_iloc: Vec<IlocEntry> = all_iloc
        .iter()
        .enumerate()
        .map(|(index, e)| {
            if e.construction_method == 0 {
                // Only source cm=0 extents carry real offsets that shift under
                // the UserComment patch. Newly appended gain tiles use offset 0
                // placeholders (their real offsets are fixed below), so they
                // must not run through adjusted_extent_for_patch.
                if index < source_iloc_count {
                    IlocEntry {
                        item_id: e.item_id,
                        construction_method: e.construction_method,
                        data_reference_index: e.data_reference_index,
                        extents: e
                            .extents
                            .iter()
                            .map(|(off, len)| {
                                let (adj_off, adj_len) = exif::adjusted_extent_for_patch(
                                    *off,
                                    *len,
                                    patch.as_ref(),
                                )
                                .expect("OPPO UserComment patch crosses an item extent boundary");
                                let shifted = adj_off as i64 + file_delta;
                                ((shifted as u64), adj_len)
                            })
                            .collect(),
                    }
                } else {
                    IlocEntry {
                        item_id: e.item_id,
                        construction_method: e.construction_method,
                        data_reference_index: e.data_reference_index,
                        extents: e.extents.clone(),
                    }
                }
            } else {
                e.clone()
            }
        })
        .collect();
    // Fix tile offsets: they come after source mdat
    let mut toff = new_mdat_data_start + source_mdat.len();
    for (i, tile) in cfg.tile_payloads.iter().enumerate() {
        if let Some(entry) = final_iloc.iter_mut().find(|e| e.item_id == cfg.tile_ids[i]) {
            entry.extents = vec![(toff as u64, tile.len() as u64)];
        }
        toff += tile.len();
    }
    let pass2_iloc = isobmff::make_iloc_box(&final_iloc);

    // --- PASS 2: final meta ---
    let final_meta = assemble_meta(
        source_data,
        meta,
        &meta_kids,
        parsed.primary_id,
        parsed.pitm_version,
        &iinf_box,
        &pass2_iloc,
        &ipco,
        &ipma_full,
        &output_refs,
        had_iref,
        iref_v,
        &idat,
        cfg.group_id,
        cfg.tmap_id,
        parsed.primary_id,
    );

    // Build mdat
    let mut mdat_payload = source_mdat.to_vec();
    for tile in &cfg.tile_payloads {
        mdat_payload.extend_from_slice(tile);
    }
    let mdat_box = isobmff::make_box(b"mdat", &mdat_payload);

    // Write
    let mut out = Vec::new();
    out.extend_from_slice(&ftyp_box);
    out.extend_from_slice(&final_meta);
    out.extend_from_slice(between);
    out.extend_from_slice(&mdat_box);

    // Preserve OPPO/QTI/FileExtendedContainer metadata using the configured
    // policy (watermark-only, compact, portrait filtering, or full tail).
    if let Some(tail) = crate::container::get_oppo_tail(source_data, cfg.tail_policy) {
        out.extend_from_slice(&tail);
    }

    std::fs::write(output_path, &out).map_err(|e| format!("write error: {e}"))?;
    Ok(())
}

fn find<'a>(boxes: &'a [BoxHeader], btype: &[u8; 4]) -> Result<&'a BoxHeader, String> {
    boxes
        .iter()
        .find(|b| &b.btype == btype)
        .ok_or_else(|| format!("{} missing", String::from_utf8_lossy(btype)))
}

/// Return the first property of `property_type` explicitly associated with an
/// item. Looking at the primary item's IPMA associations avoids accidentally
/// selecting a tile `ispe` from elsewhere in the property container.
fn item_property_index(parsed: &ParsedSource, item_id: u32, property_type: &str) -> Option<u32> {
    let entry = parsed
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == item_id)?;
    entry.associations.iter().find_map(|(index, _)| {
        parsed
            .props
            .get(index.checked_sub(1)? as usize)
            .filter(|property| property.ptype == property_type)
            .map(|_| *index)
    })
}

#[allow(clippy::too_many_arguments)]
fn assemble_meta(
    source: &[u8],
    meta: &BoxHeader,
    meta_kids: &[BoxHeader],
    primary_id: u32,
    pitm_version: u8,
    iinf_box: &[u8],
    iloc_box: &[u8],
    ipco: &[u8],
    ipma: &[u8],
    refs: &[IrefEntry],
    _had_iref: bool,
    iref_version: u8,
    idat: &[u8],
    group_id: u32,
    tmap_id: u32,
    _primary_id: u32,
) -> Vec<u8> {
    let idat_box = isobmff::make_box(b"idat", idat);
    let iref_box = isobmff::make_iref_full_box(iref_version, refs);
    let ipco_box = isobmff::make_box(b"ipco", ipco);
    let ipma_box = isobmff::make_box(b"ipma", ipma);
    let mut iprp = Vec::new();
    iprp.extend_from_slice(&ipco_box);
    iprp.extend_from_slice(&ipma_box);
    let iprp_box = isobmff::make_box(b"iprp", &iprp);
    let grpl_box = isobmff::make_grpl_altr_box(group_id, tmap_id, primary_id);

    let meta_ver = &source[meta.data_start..meta.data_start + 4];
    let mut parts: Vec<Vec<u8>> = Vec::new();
    let mut shown_iref = false;
    let mut shown_idat = false;

    for kid in meta_kids {
        match &kid.btype {
            b"hdlr" => {
                parts.push(source[kid.box_start..kid.box_start + kid.size].to_vec());
                if !meta_kids.iter().any(|k| &k.btype == b"dinf") {
                    parts.push(DINF_BOX.to_vec());
                }
            }
            b"dinf" => parts.push(source[kid.box_start..kid.box_start + kid.size].to_vec()),
            b"pitm" => parts.push(isobmff::make_pitm_box(pitm_version, primary_id)),
            b"iinf" => parts.push(iinf_box.to_vec()),
            b"iloc" => parts.push(iloc_box.to_vec()),
            b"iprp" => parts.push(iprp_box.clone()),
            b"iref" => {
                parts.push(iref_box.clone());
                shown_iref = true;
            }
            b"idat" => {
                parts.push(idat_box.clone());
                shown_idat = true;
            }
            b"grpl" => { /* drop old grpl */ }
            _ => parts.push(source[kid.box_start..kid.box_start + kid.size].to_vec()),
        }
    }
    if !shown_iref {
        parts.push(iref_box);
    }
    if !shown_idat {
        parts.push(idat_box);
    }
    parts.push(grpl_box);

    let mut payload = meta_ver.to_vec();
    for p in &parts {
        payload.extend_from_slice(p);
    }
    isobmff::make_box(b"meta", &payload)
}

// ---------------------------------------------------------------------------
// OPPO compat helper
// ---------------------------------------------------------------------------

impl OppoCompat {
    /// Whether this mode wants OPPO-oriented output (RGB gain map, 142B tmap,
    /// BT.2020 PQ colr).
    fn wants_oppo_rgb(self) -> bool {
        self.wants_oppo_compat()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orient_gainmap_applies_all_exif_transforms() {
        // Two 3-pixel rows with one byte of padding each. The transform must
        // ignore the padding and emit a tightly packed raster.
        let input = [1, 2, 3, 99, 4, 5, 6, 99];
        let cases = [
            (ExifOrientation::Normal, (3, 2), vec![1, 2, 3, 4, 5, 6]),
            (
                ExifOrientation::FlipHorizontal,
                (3, 2),
                vec![3, 2, 1, 6, 5, 4],
            ),
            (ExifOrientation::Rotate180, (3, 2), vec![6, 5, 4, 3, 2, 1]),
            (
                ExifOrientation::FlipVertical,
                (3, 2),
                vec![4, 5, 6, 1, 2, 3],
            ),
            (ExifOrientation::Transpose, (2, 3), vec![1, 4, 2, 5, 3, 6]),
            (
                ExifOrientation::Rotate90Clockwise,
                (2, 3),
                vec![4, 1, 5, 2, 6, 3],
            ),
            (ExifOrientation::Transverse, (2, 3), vec![6, 3, 5, 2, 4, 1]),
            (
                ExifOrientation::Rotate90CounterClockwise,
                (2, 3),
                vec![3, 6, 2, 5, 1, 4],
            ),
        ];

        for (orientation, dimensions, expected) in cases {
            let (output, width, height) =
                orient_gainmap_pixels(&input, 3, 2, 1, 4, orientation).unwrap();
            assert_eq!((width, height), dimensions, "{orientation:?}");
            assert_eq!(output, expected, "{orientation:?}");
        }
    }

    #[test]
    fn orient_gainmap_preserves_multibyte_pixels() {
        let input = [1, 2, 3, 4, 5, 6];
        let (output, width, height) =
            orient_gainmap_pixels(&input, 2, 1, 3, 6, ExifOrientation::FlipHorizontal).unwrap();
        assert_eq!((width, height), (2, 1));
        assert_eq!(output, vec![4, 5, 6, 1, 2, 3]);
    }

    #[test]
    fn edge_tiles_preserve_origin_and_pad_only_bottom_right() {
        let width = 513u32;
        let height = 515u32;
        let pixels: Vec<u8> = (0..height)
            .flat_map(|y| (0..width).map(move |x| ((y * 31 + x * 17) % 251) as u8))
            .collect();
        let at = |x: u32, y: u32| pixels[(y * width + x) as usize];

        let origin = build_padded_gain_tile(&pixels, width, height, 1, width as usize, 0, 0)
            .expect("origin tile");
        assert_eq!(origin[0], at(0, 0));
        assert_eq!(origin[511 * GAIN_TILE_SIZE as usize + 511], at(511, 511));

        let edge = build_padded_gain_tile(
            &pixels,
            width,
            height,
            1,
            width as usize,
            GAIN_TILE_SIZE,
            GAIN_TILE_SIZE,
        )
        .expect("bottom-right edge tile");
        let row = GAIN_TILE_SIZE as usize;
        assert_eq!(edge[0], at(512, 512));
        assert_eq!(edge[2 * row], at(512, 514));
        assert_eq!(edge[row - 1], at(512, 512), "right edge is replicated");
        assert_eq!(edge[2 * row + row - 1], at(512, 514));
        assert_eq!(
            edge[(row - 1) * row],
            at(512, 514),
            "bottom edge is replicated"
        );
        assert_eq!(edge[row * row - 1], at(512, 514));

        let grid = isobmff::make_grid_box(GAIN_TILE_SIZE, GAIN_TILE_SIZE, 2, 2, width, height);
        assert_eq!(&grid[10..12], &[1, 1], "two rows and columns");
        assert_eq!(isobmff::read_u16be(&grid, 12), width as u16);
        assert_eq!(isobmff::read_u16be(&grid, 14), height as u16);
    }

    /// Build a minimal valid ISOBMFF HEIC buffer for testing.
    fn make_minimal_heic() -> Vec<u8> {
        make_minimal_heic_with_exif_orientation(None)
    }

    fn make_minimal_heic_with_exif_orientation(orientation: Option<u16>) -> Vec<u8> {
        let mut out = Vec::new();
        let exif_blob = orientation.map(heif_exif_blob);

        // ftyp
        let mut ftyp_payload = Vec::new();
        ftyp_payload.extend_from_slice(b"heic");
        isobmff::write_u32be(0, &mut ftyp_payload);
        ftyp_payload.extend_from_slice(b"heic");
        ftyp_payload.extend_from_slice(b"mif1");
        out.extend_from_slice(&isobmff::make_box(b"ftyp", &ftyp_payload));

        // ipco with ispe
        let mut ipco = Vec::new();
        ipco.extend_from_slice(&isobmff::make_ispe_box(512, 256));
        let ipco_box = isobmff::make_box(b"ipco", &ipco);

        // ipma
        let mut ipma_payload = vec![0u8; 4];
        isobmff::write_u32be(1, &mut ipma_payload);
        ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(1, &[(1, true)], 0));
        let ipma_box = isobmff::make_box(b"ipma", &ipma_payload);

        let mut iprp = Vec::new();
        iprp.extend_from_slice(&ipco_box);
        iprp.extend_from_slice(&ipma_box);
        let iprp_box = isobmff::make_box(b"iprp", &iprp);

        let infe1 = isobmff::make_infe_box(1, "hvc1", 0);
        let mut iinf_payload = vec![0, 0, 0, 0];
        isobmff::write_u16be(if exif_blob.is_some() { 2 } else { 1 }, &mut iinf_payload);
        iinf_payload.extend_from_slice(&infe1);
        if exif_blob.is_some() {
            iinf_payload.extend_from_slice(&isobmff::make_infe_box(2, "Exif", 0));
        }
        let iinf_box = isobmff::make_box(b"iinf", &iinf_payload);

        let pitm_box = isobmff::make_pitm_box(0, 1);

        let mut iloc_entries = vec![IlocEntry {
            item_id: 1,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, 4)],
        }];
        if let Some(blob) = &exif_blob {
            iloc_entries.push(IlocEntry {
                item_id: 2,
                construction_method: 1,
                data_reference_index: 0,
                extents: vec![(0, blob.len() as u64)],
            });
        }
        let iloc = isobmff::make_iloc_box(&iloc_entries);
        let idat_box = isobmff::make_box(b"idat", exif_blob.as_deref().unwrap_or(&[]));
        let hdlr = isobmff::make_box(b"hdlr", &[0u8; 8]);

        let mut meta_kids = Vec::new();
        meta_kids.extend_from_slice(&hdlr);
        meta_kids.extend_from_slice(&pitm_box);
        meta_kids.extend_from_slice(&iinf_box);
        meta_kids.extend_from_slice(&iloc);
        meta_kids.extend_from_slice(&iprp_box);
        meta_kids.extend_from_slice(&idat_box);
        let mut meta_payload = vec![0u8; 4];
        meta_payload.extend_from_slice(&meta_kids);
        out.extend_from_slice(&isobmff::make_box(b"meta", &meta_payload));

        out.extend_from_slice(&isobmff::make_box(b"mdat", &[0u8; 4]));

        out
    }

    fn heif_exif_blob(orientation: u16) -> Vec<u8> {
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

        let mut blob = 6u32.to_be_bytes().to_vec();
        blob.extend_from_slice(b"Exif\0\0");
        blob.extend_from_slice(&tiff);
        blob
    }

    #[test]
    fn write_lhdr_minimal_smoke() {
        let source = make_minimal_heic();
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5;
        meta[2] = 144.0;
        meta[5] = -1.0;
        meta[18] = 10.0;
        meta[19] = 6.0;
        meta[29] = 200.0;
        meta[32] = 30000.0;

        let tmp = std::env::temp_dir().join("xdremux_test_m3_output.heic");
        let result = write_lhdr_iso_output(
            &source,
            &mask,
            4,
            4,
            &meta,
            3.0,
            OppoCompat::Off,
            OppoCameraTail::default_for_compat(OppoCompat::Off),
            false,
            tmp.to_str().unwrap(),
        );
        if let Err(ref e) = result {
            eprintln!("write_lhdr_iso_output failed: {e}");
        }
        if let Ok(()) = result {
            let written = std::fs::read(&tmp).unwrap();
            assert!(written.len() > 100, "output should be > 100 bytes");
            let boxes = isobmff::parse_boxes(&written, 0, written.len());
            assert!(boxes.iter().any(|b| &b.btype == b"ftyp"), "ftyp missing");
            assert!(boxes.iter().any(|b| &b.btype == b"meta"), "meta missing");
            assert!(boxes.iter().any(|b| &b.btype == b"mdat"), "mdat missing");
            let _ = std::fs::remove_file(&tmp);
        }
    }

    fn associated_property<'a>(
        meta: &'a isobmff::ParsedMeta,
        item_id: u32,
        property_type: &str,
    ) -> &'a isobmff::PropertyInfo {
        let association = meta
            .ipma_entries
            .iter()
            .find(|entry| entry.item_id == item_id)
            .unwrap_or_else(|| panic!("item {item_id} has no property associations"));
        let (property_index, _) = association
            .associations
            .iter()
            .find(|(index, _)| {
                meta.props
                    .iter()
                    .any(|property| property.index == *index && property.ptype == property_type)
            })
            .unwrap_or_else(|| panic!("item {item_id} has no {property_type} property"));
        meta.props
            .iter()
            .find(|property| property.index == *property_index)
            .expect("associated property is present in ipco")
    }

    fn write_minimal_lhdr_for_properties(oppo_compat: OppoCompat) -> isobmff::ParsedMeta {
        let source = make_minimal_heic();
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5;
        meta[2] = 144.0;
        meta[5] = -1.0;
        meta[18] = 10.0;
        meta[19] = 6.0;
        meta[29] = 200.0;
        meta[32] = 30000.0;

        let unique = format!(
            "xdremux_test_gain_properties_{}_{}.heic",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock is after the Unix epoch")
                .as_nanos(),
        );
        let tmp = std::env::temp_dir().join(unique);
        write_lhdr_iso_output(
            &source,
            &mask,
            4,
            4,
            &meta,
            3.0,
            oppo_compat,
            OppoCameraTail::default_for_compat(oppo_compat),
            false,
            tmp.to_str().expect("temporary path is valid UTF-8"),
        )
        .expect("writer accepts a minimal LHDR source");

        let written = std::fs::read(&tmp).expect("read generated HEIC");
        std::fs::remove_file(&tmp).expect("remove generated HEIC");
        isobmff::parse_source_meta(&written).expect("parse generated HEIC metadata")
    }

    #[test]
    fn gain_map_properties_match_iso_and_oppo_channel_layouts() {
        // Both the clean (ISO) and OPPO paths declare the gain map pixi as RGB
        // (matching the Python reference), even when the clean gain-map data
        // is monochrome — Google Photos keys on the declared channel count.
        let mono = write_minimal_lhdr_for_properties(OppoCompat::Off);
        let mono_grid_id = mono
            .items
            .iter()
            .find(|item| item.itype == "grid")
            .expect("generated gain grid")
            .item_id;
        assert_eq!(
            associated_property(&mono, mono_grid_id, "pixi").raw,
            isobmff::PIXI_RGB8_BOX
        );
        assert_eq!(
            associated_property(&mono, mono_grid_id, "colr").raw,
            isobmff::COLR_SRGB_BOX
        );
        let mono_tile_id = mono
            .refs
            .iter()
            .find(|reference| reference.rtype == "dimg" && reference.from == mono_grid_id)
            .and_then(|reference| reference.to.first())
            .copied()
            .expect("mono gain grid references a tile");
        assert_eq!(
            associated_property(&mono, mono_tile_id, "colr").raw,
            isobmff::COLR_SRGB_BOX
        );

        let rgb = write_minimal_lhdr_for_properties(OppoCompat::On);
        let rgb_grid_id = rgb
            .items
            .iter()
            .find(|item| item.itype == "grid")
            .expect("generated RGB gain grid")
            .item_id;
        assert_eq!(
            associated_property(&rgb, rgb_grid_id, "pixi").raw,
            isobmff::PIXI_RGB8_BOX
        );
        assert_eq!(
            associated_property(&rgb, rgb_grid_id, "colr").raw,
            isobmff::COLR_UNSPECIFIED_BT601_BOX
        );
        let rgb_tile_id = rgb
            .refs
            .iter()
            .find(|reference| reference.rtype == "dimg" && reference.from == rgb_grid_id)
            .and_then(|reference| reference.to.first())
            .copied()
            .expect("RGB gain grid references a tile");
        assert_eq!(
            associated_property(&rgb, rgb_tile_id, "colr").raw,
            isobmff::COLR_UNSPECIFIED_BT601_BOX
        );
    }

    #[test]
    fn strict_tmap_is_written_as_a_65_byte_item() {
        let source = make_minimal_heic();
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5;
        meta[2] = 144.0;
        meta[5] = -1.0;
        meta[18] = 10.0;
        meta[19] = 6.0;
        meta[29] = 200.0;
        meta[32] = 30000.0;

        let unique = format!(
            "xdremux_test_strict_tmap_{}_{}.heic",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock is after the Unix epoch")
                .as_nanos(),
        );
        let tmp = std::env::temp_dir().join(unique);
        write_lhdr_iso_output(
            &source,
            &mask,
            4,
            4,
            &meta,
            3.0,
            OppoCompat::Off,
            OppoCameraTail::default_for_compat(OppoCompat::Off),
            true,
            tmp.to_str().expect("temporary path is valid UTF-8"),
        )
        .expect("writer accepts strict tmap output");

        let written = std::fs::read(&tmp).expect("read generated HEIC");
        std::fs::remove_file(&tmp).expect("remove generated HEIC");
        let parsed = isobmff::parse_source_meta(&written).expect("parse generated HEIC metadata");
        let tmap_id = parsed
            .items
            .iter()
            .find(|item| item.itype == "tmap")
            .expect("generated tmap item")
            .item_id;
        let tmap_extent = parsed
            .iloc_entries
            .iter()
            .find(|entry| entry.item_id == tmap_id)
            .and_then(|entry| entry.extents.first())
            .expect("tmap item extent");
        assert_eq!(tmap_extent.1, 65);
    }

    #[test]
    fn write_lhdr_uses_exif_orientation_for_irot_and_tmap_dimensions() {
        let source = make_minimal_heic_with_exif_orientation(Some(6));
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5;
        meta[2] = 144.0;
        meta[5] = -1.0;
        meta[18] = 10.0;
        meta[19] = 6.0;
        meta[29] = 200.0;
        meta[32] = 30000.0;

        let unique = format!(
            "xdremux_test_exif_orientation_{}_{}.heic",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock is after the Unix epoch")
                .as_nanos(),
        );
        let tmp = std::env::temp_dir().join(unique);
        write_lhdr_iso_output(
            &source,
            &mask,
            4,
            4,
            &meta,
            3.0,
            OppoCompat::Off,
            OppoCameraTail::default_for_compat(OppoCompat::Off),
            false,
            tmp.to_str().expect("temporary path is valid UTF-8"),
        )
        .expect("writer accepts a valid HEIC with EXIF orientation");

        let written = std::fs::read(&tmp).expect("read generated HEIC");
        let parsed = isobmff::parse_source_meta(&written).expect("parse generated HEIC metadata");
        let primary_irot = associated_property(&parsed, parsed.primary_id, "irot");
        assert_eq!(isobmff::irot_quarter_turns(&primary_irot.raw).unwrap(), 3);

        let tmap_id = parsed
            .items
            .iter()
            .find(|item| item.itype == "tmap")
            .expect("generated tmap item")
            .item_id;
        let tmap_irot = associated_property(&parsed, tmap_id, "irot");
        assert_eq!(isobmff::irot_quarter_turns(&tmap_irot.raw).unwrap(), 3);
        let tmap_ispe = associated_property(&parsed, tmap_id, "ispe");
        assert_eq!(
            isobmff::ispe_dimensions(&tmap_ispe.raw).unwrap(),
            (256, 512)
        );

        std::fs::remove_file(&tmp).expect("remove generated HEIC");
    }

    #[test]
    fn parse_heic_roundtrip() {
        let source = make_minimal_heic();
        let top = isobmff::parse_boxes(&source, 0, source.len());
        assert!(top.iter().any(|b| &b.btype == b"ftyp"));
        assert!(top.iter().any(|b| &b.btype == b"meta"));
        assert!(top.iter().any(|b| &b.btype == b"mdat"));
    }

    #[test]
    fn prepare_assemble_split_matches_direct_lhdr_write() {
        // The split path (prepare → yuv tiles → assemble) must produce a
        // working ISO output for the same minimal LHDR source as the direct
        // writer, and the YUV tile buffer must be non-empty with the expected
        // per-tile 4:2:0 geometry.
        let source = make_minimal_heic();
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5;
        meta[2] = 144.0;
        meta[5] = -1.0;
        meta[18] = 10.0;
        meta[19] = 6.0;
        meta[29] = 200.0;
        meta[32] = 30000.0;

        // Compensate for tile padding: a 4x4 gain map gets tiled/padded to
        // 512x512 with edge replication; encode with the gray path's own tile.
        let (prepared, yuv) = prepare_lhdr_tiles(
            &source,
            &mask,
            4,
            4,
            &meta,
            3.0,
            OppoCompat::Off,
            OppoCameraTail::default_for_compat(OppoCompat::Off),
            false,
        )
        .expect("prepare_lhdr_tiles succeeds");
        assert_eq!(prepared.rows, 1);
        assert_eq!(prepared.cols, 1);
        assert_eq!(prepared.gain_width, 4);
        assert_eq!(prepared.gain_height, 4);
        // One 512x512 tile, gray → Y(512²) + U(256²) + V(256²)
        let per_tile = 512 * 512 + 256 * 256 + 256 * 256;
        assert_eq!(yuv.len(), per_tile, "single gray tile in 4:2:0 YUV");

        // Encode the tile back with the same x265 path and reassemble.
        // The split path hardcodes hvcC chroma=1 (MediaCodec only does 4:2:0),
        // so re-encode the tile as 4:2:0 gray to keep SPS and hvcC consistent.
        let tile = yuv.clone();
        std::env::set_var("XDREMUX_GM_420", "1");
        let hevc = crate::hevc::encode_hevc_tile_gray(&tile[..512 * 512], 512, 512)
            .expect("re-encode prepared Y tile");
        std::env::remove_var("XDREMUX_GM_420");
        assert!(
            hevc.len() > 100,
            "tile stream should contain NALs (got {} bytes)",
            hevc.len()
        );
        let streams: Vec<&[u8]> = vec![hevc.as_slice()];
        let tmp = std::env::temp_dir().join("xdremux_split_assemble_test.heic");
        let (edr, gm) = assemble_prepared_tiles(&prepared, &streams, tmp.to_str().unwrap())
            .expect("assemble_prepared_tiles succeeds");
        assert!(edr > 0.0);
        assert!(gm > 0.0);

        let written = std::fs::read(&tmp).unwrap();
        assert!(written.len() > 100, "output should be > 100 bytes");
        let tmp_c = std::ffi::CString::new(tmp.to_str().unwrap()).unwrap();
        assert!(
            crate::xdremux_verify_output(tmp_c.as_ptr()),
            "output verifies as ISO HDR"
        );
        let _ = std::fs::remove_file(&tmp);
    }
}
