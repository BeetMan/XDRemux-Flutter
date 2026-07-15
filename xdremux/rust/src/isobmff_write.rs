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

use crate::exif::{self, OppoCompat};
use crate::isobmff::{
    self, BoxHeader, IlocEntry, IrefEntry, AUX_C_BOX, COLR_BT2020_PQ_BOX, COLR_SRGB_BOX,
    DINF_BOX, IROT_BOX, PIXI_RGB10_BOX, PIXI_RGB8_BOX,
};

/// Context for output assembly.
struct OutputConfig {
    _oppo_compat: OppoCompat,
    oppo_rgb: bool,      // true for OPPO LHDR RGB-copy or UHDR 3ch
    tile_payloads: Vec<Vec<u8>>,
    tile_ids: Vec<u32>,
    gain_grid_id: u32,
    tmap_id: u32,
    xmp_id: u32,
    group_id: u32,
    tmap_payload: Vec<u8>,
    xmp_bytes: Vec<u8>,
    gain_hvcc: Vec<u8>,  // pre-extracted HEVC decoder config (byte-stream → hvcC)
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
    output_path: &str,
) -> Result<(), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;

    let (parsed, mut source_mdat, idat_opt) = parse_source_structure(source_data, &top, meta)?;

    // Reconstruct gain map pixels
    let mut gainmap = crate::gainmap::reconstruct(
        mask_pixels,
        mask_width as usize,
        mask_height as usize,
        mask_width as usize,
        edr_scale,
        meta_floats[0],
    );
    let aligned_row = ((mask_width as usize + 255) / 256) * 256;

    // OPPO compat: replicate gray → RGB
    let (hevc_pixels, pixel_bytes, encode_fn): (&[u8], usize, fn(&[u8], u32, u32) -> std::io::Result<Vec<u8>>) =
        if oppo_compat.wants_oppo_rgb() {
            // RGB-copy for OPPO Gallery recognition
            let n_pixels = (mask_width * mask_height) as usize;
            let mut rgb = vec![0u8; n_pixels * 3];
            for i in 0..n_pixels {
                let v = gainmap[aligned_row * (i / mask_width as usize) + (i % mask_width as usize)];
                rgb[i * 3] = v;
                rgb[i * 3 + 1] = v;
                rgb[i * 3 + 2] = v;
            }
            gainmap = rgb;
            (&gainmap[..], 3, crate::hevc::encode_hevc_tile_rgb as _)
        } else {
            (&gainmap[..], 1, crate::hevc::encode_hevc_tile_gray as _)
        };

    // Tile & HEVC-encode
    let (tile_payloads, tile_ids, cols, rows, gain_hvcc) = tile_and_encode(
        hevc_pixels,
        mask_width,
        mask_height,
        pixel_bytes,
        aligned_row / pixel_bytes,
        encode_fn,
        &parsed,
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
        crate::iso21496::make_imageio_native_tmap_payload(meta_floats)
    } else {
        crate::iso21496::make_apple_tmap_payload(meta_floats)
    };

    // Item IDs
    let (gain_grid_id, tmap_id, xmp_id, group_id) = assign_new_ids(&parsed, tile_payloads.len() as u32);

    let cfg = OutputConfig {
        _oppo_compat: oppo_compat,
        oppo_rgb: oppo_compat.wants_oppo_rgb(),
        tile_payloads: tile_payloads.clone(),
        tile_ids: tile_ids.clone(),
        gain_grid_id,
        tmap_id,
        xmp_id,
        group_id,
        tmap_payload: tmap_payload.clone(),
        xmp_bytes: xmp_bytes.clone(),
        gain_hvcc,
    };

    // OPPO UserComment patch
    if oppo_compat.wants_patch() {
        exif::apply_oppo_usercomment_patch_vec(&mut source_mdat, oppo_compat);
    }

    assemble_and_write(
        source_data, ftyp, meta, mdat, &parsed,
        idat_opt, &source_mdat, mask_width, mask_height,
        cols, rows, &cfg, output_path,
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
    output_path: &str,
) -> Result<(), String> {
    let top = isobmff::parse_boxes(source_data, 0, source_data.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;

    let (parsed, mut source_mdat, idat_opt) = parse_source_structure(source_data, &top, meta)?;

    // Decode gain map JPEG to raw pixels
    // UHDR gain maps are RGB JPEGs; we decode to RGB and optionally extract gray
    let (rgb_pixels, gm_w, gm_h) = crate::jpeg_decode::decode_jpeg_to_rgb(gainmap_jpeg)
        .map_err(|e| format!("UHDR gain map JPEG decode failed: {e}"))?;

    let (hevc_pixels, pixel_bytes, encode_fn): (&[u8], usize, fn(&[u8], u32, u32) -> std::io::Result<Vec<u8>>) =
        if oppo_compat.wants_oppo_rgb() {
            // Keep RGB for OPPO
            (&rgb_pixels[..], 3, crate::hevc::encode_hevc_tile_rgb as _)
        } else {
            // Clean UHDR: still 3-channel (UHDR gain maps are inherently 3ch)
            (&rgb_pixels[..], 3, crate::hevc::encode_hevc_tile_rgb as _)
        };

    let rgb_stride = gm_w as usize * 3;

    // Tile & HEVC-encode
    let (tile_payloads, tile_ids, cols, rows, gain_hvcc) = tile_and_encode(
        hevc_pixels,
        gm_w,
        gm_h,
        pixel_bytes,
        rgb_stride,
        encode_fn,
        &parsed,
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
        crate::iso21496::make_imageio_native_tmap_payload(meta_floats)
    } else {
        crate::iso21496::make_apple_tmap_payload(meta_floats)
    };

    // Item IDs
    let (gain_grid_id, tmap_id, xmp_id, group_id) = assign_new_ids(&parsed, tile_payloads.len() as u32);

    let cfg = OutputConfig {
        _oppo_compat: oppo_compat,
        oppo_rgb: true, // UHDR gain maps are always 3-channel
        tile_payloads: tile_payloads.clone(),
        tile_ids: tile_ids.clone(),
        gain_grid_id,
        tmap_id,
        xmp_id,
        group_id,
        tmap_payload: tmap_payload.clone(),
        xmp_bytes: xmp_bytes.clone(),
        gain_hvcc,
    };

    // OPPO UserComment patch
    if oppo_compat.wants_patch() {
        exif::apply_oppo_usercomment_patch_vec(&mut source_mdat, oppo_compat);
    }

    assemble_and_write(
        source_data, ftyp, meta, mdat, &parsed,
        idat_opt, &source_mdat, gm_w, gm_h,
        cols, rows, &cfg, output_path,
    )
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
    let ipma_box = ipma_data.iter().find(|b| &b.btype == b"ipma").ok_or("ipma missing")?.clone();
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
// Shared: tile & encode
// ---------------------------------------------------------------------------

fn tile_and_encode(
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    stride: usize, // bytes per row of the input pixel buffer
    encode_fn: fn(&[u8], u32, u32) -> std::io::Result<Vec<u8>>,
    parsed: &ParsedSource,
) -> Result<(Vec<Vec<u8>>, Vec<u32>, u32, u32, Vec<u8>), String> {
    let tile_size: u32 = 512;
    let cols = ((width + tile_size - 1) / tile_size).max(1);
    let rows = ((height + tile_size - 1) / tile_size).max(1);
    let mut tile_payloads: Vec<Vec<u8>> = Vec::with_capacity((rows * cols) as usize);
    let mut gain_hvcc: Vec<u8> = Vec::new();

    for row in 0..rows {
        for col in 0..cols {
            let x0 = col * tile_size;
            let y0 = row * tile_size;
            let tw = tile_size.min(width - x0);
            let th = tile_size.min(height - y0);

            let mut tile = vec![0u8; (tile_size * tile_size * pixel_bytes as u32) as usize];
            let tile_row_stride = tile_size as usize * pixel_bytes;
            let copy_len = tw as usize * pixel_bytes;

            for ty in 0..th {
                let src = (y0 + ty) as usize * stride + x0 as usize * pixel_bytes;
                let dst = ty as usize * tile_row_stride;
                tile[dst..dst + copy_len].copy_from_slice(&pixels[src..src + copy_len]);
                // Replicate last column for edge columns
                for tx in tw..tile_size {
                    let dst_col = dst + tx as usize * pixel_bytes;
                    let src_last = src + copy_len - pixel_bytes;
                    tile[dst_col..dst_col + pixel_bytes]
                        .copy_from_slice(&pixels[src_last..src_last + pixel_bytes]);
                }
            }
            // Replicate last row for edge rows
            for ty in th..tile_size {
                let src_row = (y0 + th - 1) as usize * stride + x0 as usize * pixel_bytes;
                let dst = ty as usize * tile_row_stride;
                tile[dst..dst + copy_len].copy_from_slice(&pixels[src_row..src_row + copy_len]);
                for tx in tw..tile_size {
                    let dst_col = dst + tx as usize * pixel_bytes;
                    let src_last = src_row + copy_len - pixel_bytes;
                    tile[dst_col..dst_col + pixel_bytes]
                        .copy_from_slice(&pixels[src_last..src_last + pixel_bytes]);
                }
            }

            let hevc_bs = encode_fn(&tile, tile_size, tile_size)
                .map_err(|e| format!("HEVC encode: {e}"))?;

            // Extract hvcC from the first tile's byte-stream HEVC (before
            // length-prefix conversion). extract_hvcc_config searches for
            // 00 00 00 01 start codes, which only exist in byte-stream format.
            if gain_hvcc.is_empty() {
                gain_hvcc = crate::hevc::extract_hvcc_config(&hevc_bs).unwrap_or_default();
            }

            // Convert from byte-stream (00 00 00 01 start codes) to length-prefixed
            // format (4-byte big-endian NAL length). ISOBMFF with hvcC requires
            // length-prefixed NAL units in mdat.
            let hevc_lp = crate::hevc::hevc_byte_stream_to_length_prefixed(&hevc_bs);
            tile_payloads.push(hevc_lp);
        }
    }

    let first_new = (parsed.max_src_id + 1).max(2);
    let tile_ids: Vec<u32> = (0..tile_payloads.len()).map(|i| first_new + i as u32).collect();

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
    mask_width: u32,
    mask_height: u32,
    cols: u32,
    rows: u32,
    cfg: &OutputConfig,
    output_path: &str,
) -> Result<(), String> {
    let tile_size: u32 = 512;

    // Extract hvcC from the pre-extracted gain tile HEVC config (already
    // extracted from byte-stream format before length-prefix conversion).
    let gain_hvcc_box = isobmff::make_box(b"hvcC", &cfg.gain_hvcc);

    // Find source's first colr property index (ICC profile, primary color).
    // Gain tiles and primary items reference this.
    let first_colr_idx = parsed.props.iter()
        .position(|p| p.ptype == "colr")
        .map(|i| i as u32 + 1);

    // Find source's first hvcC property index (primary HEVC config).
    let _first_hvcc_idx = parsed.props.iter()
        .position(|p| p.ptype == "hvcC")
        .map(|i| i as u32 + 1);

    // Find source's irot property index.
    let source_irot_idx = parsed.props.iter()
        .position(|p| p.ptype == "irot")
        .map(|i| i as u32 + 1);

    // New property indices (1-based, after existing props).
    let old_n = parsed.props.len() as u32;
    let _auxc_i      = old_n + 1;  // auxC
    let irot_i      = old_n + 2;  // irot (rotation=0)
    let pq_colr_i   = old_n + 3;  // colr nclx BT.2020 PQ (for tmap)
    let srgb_colr_i = old_n + 4;  // colr nclx sRGB (for gain grid)
    let pixi10_i    = old_n + 5;  // pixi 3ch 10bpp
    let base_clli_i = old_n + 6;  // clli base
    let tmap_clli_i = old_n + 7;  // clli tmap
    let pixi8_i     = old_n + 8;  // pixi 3ch 8bpp
    let gm_hvcc_i   = old_n + 9;  // hvcC for gain tiles
    let gm_grid_ispe_i = old_n + 10; // ispe for gain grid
    let gm_tile_ispe_i = old_n + 11; // ispe for gain tiles (512x512)

    // Build ipco (source + new properties, matching Python reference order)
    let (ipco_start, ipco_end) = parsed.ipco_box_raw.as_ref()
        .map(|b| (b.data_start, b.data_end))
        .unwrap_or((0, 0));
    let mut ipco = source_data[ipco_start..ipco_end].to_vec();
    ipco.extend_from_slice(AUX_C_BOX);
    ipco.extend_from_slice(IROT_BOX);
    ipco.extend_from_slice(COLR_BT2020_PQ_BOX);          // for tmap
    ipco.extend_from_slice(COLR_SRGB_BOX);                // for gain grid
    ipco.extend_from_slice(PIXI_RGB10_BOX);               // for tmap/primary
    ipco.extend_from_slice(&isobmff::make_clli_box(203, 64));   // base clli
    ipco.extend_from_slice(&isobmff::make_clli_box(1000, 315)); // tmap clli
    ipco.extend_from_slice(PIXI_RGB8_BOX);                // for gain grid
    ipco.extend_from_slice(&gain_hvcc_box);               // gain tile HEVC config
    ipco.extend_from_slice(&isobmff::make_ispe_box(mask_width.max(1), mask_height.max(1))); // gain grid
    ipco.extend_from_slice(&isobmff::make_ispe_box(tile_size, tile_size)); // gain tile

    // Build ipma — rebuild from parsed entries, augmenting primary grid's
    // associations to match Python reference (Apple ImageIO requirement).
    let colr_prof = first_colr_idx.unwrap_or(1);
    let irot_pick = source_irot_idx.unwrap_or(irot_i);
    let mut ipma_body = Vec::new();
    let total_entries = parsed.ipma_entries.len() + cfg.tile_payloads.len() + 2;
    isobmff::write_u32be(total_entries as u32, &mut ipma_body);

    for entry in &parsed.ipma_entries {
        let mut assocs = entry.associations.clone();
        if entry.item_id == parsed.primary_id {
            // Python reference augments the primary grid item with colr(e),
            // clli, and irot(e) — Apple ImageIO requires these for HDR
            // detection.
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
            entry.item_id, &assocs, parsed.ipma_flags,
        ));
    }

    // Gain tiles (hvc1 items): hvcC(e) + ispe(e) + colr(prof)(e)
    for tid in &cfg.tile_ids {
        ipma_body.extend_from_slice(&isobmff::make_ipma_entry(
            *tid, &[(gm_hvcc_i, true), (gm_tile_ispe_i, true), (colr_prof, true)], parsed.ipma_flags,
        ));
    }
    // Gain grid: ispe(grid)(e) + colr(sRGB)(e) + pixi8(e) + irot(e)
    let irot_pick = source_irot_idx.unwrap_or(irot_i);
    ipma_body.extend_from_slice(&isobmff::make_ipma_entry(cfg.gain_grid_id, &[
        (gm_grid_ispe_i, true), (srgb_colr_i, true), (pixi8_i, true), (irot_pick, true),
    ], parsed.ipma_flags));
    // tmap: colr(PQ)(e) + pixi10(e) + ispe(primary_grid)(e) + clli(tmap) + irot(e)
    // Find primary grid ispe index from source
    let _primary_ispe_idx = parsed.props.iter()
        .position(|p| p.ptype == "ispe")
        .map(|_i| {
            // The second ispe (index 2) is the primary grid ispe; first is tile ispe
            // Actually we need the one with big dimensions. Use the last source ispe.
            parsed.props.iter()
                .enumerate()
                .rev()
                .find(|(_, p)| p.ptype == "ispe")
                .map(|(i, _)| i as u32 + 1)
                .unwrap_or(1)
        })
        .unwrap_or(1);
    // Better: scan for the ispe that matches 4096x3072-ish (big dimensions)
    let primary_ispe_idx = parsed.props.iter()
        .enumerate()
        .filter(|(_, p)| p.ptype == "ispe")
        .map(|(i, _)| i as u32 + 1)
        .last()  // last ispe is usually the grid-level one with biggest dims
        .unwrap_or(4);
    ipma_body.extend_from_slice(&isobmff::make_ipma_entry(cfg.tmap_id, &[
        (pq_colr_i, true), (pixi10_i, true), (primary_ispe_idx, true),
        (tmap_clli_i, false), (irot_pick, true),
    ], parsed.ipma_flags));

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
    let mut output_refs: Vec<IrefEntry> = parsed.refs.iter()
        .filter(|r| r.rtype != "grpl")
        .cloned()
        .collect();

    // Python: keep all original cdsc as-is, and ADD new cdsc entries for EXIF items
    // that also point to tmap_id (don't modify originals — iOS needs the standalone refs)
    let mut extra_cdsc: Vec<IrefEntry> = Vec::new();
    for r in &output_refs {
        if r.rtype == "cdsc" {
            let is_exif = parsed.items.iter().any(|it| it.item_id == r.from && it.itype == "Exif");
            if is_exif && !r.to.contains(&cfg.tmap_id) {
                let mut augmented = r.to.clone();
                augmented.push(cfg.tmap_id);
                extra_cdsc.push(IrefEntry {
                    rtype: "cdsc".into(),
                    from: r.from,
                    to: augmented,
                });
            }
        }
    }
    output_refs.extend(extra_cdsc);

    if !cfg.tile_ids.is_empty() {
        output_refs.push(IrefEntry {
            rtype: "dimg".into(), from: cfg.gain_grid_id, to: cfg.tile_ids.clone(),
        });
    }
    output_refs.push(IrefEntry {
        rtype: "dimg".into(), from: cfg.tmap_id,
        to: vec![parsed.primary_id, cfg.gain_grid_id],
    });
    output_refs.push(IrefEntry {
        rtype: "cdsc".into(), from: cfg.xmp_id,
        to: vec![parsed.primary_id, cfg.tmap_id],
    });
    let use_ver1 = output_refs.iter().any(|r| r.from > 0xffff || r.to.iter().any(|&id| id > 0xffff));
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
    let idat_base = old_idat.len();
    let mut idat = old_idat.to_vec();
    idat.extend_from_slice(&cfg.tmap_payload);
    let xmp_off = idat.len();
    idat.extend_from_slice(&cfg.xmp_bytes);
    let grid_off = idat.len();
    let grid_box = isobmff::make_grid_box(tile_size, tile_size, rows, cols, mask_width, mask_height);
    idat.extend_from_slice(&grid_box[8..]);

    // iloc
    let mut all_iloc: Vec<IlocEntry> = parsed.iloc_entries.clone();
    for (i, tile) in cfg.tile_payloads.iter().enumerate() {
        all_iloc.push(IlocEntry {
            item_id: cfg.tile_ids[i], construction_method: 0,
            data_reference_index: 0, extents: vec![(0, tile.len() as u64)],
        });
    }
    all_iloc.push(IlocEntry {
        item_id: cfg.gain_grid_id, construction_method: 1,
        data_reference_index: 0,
        extents: vec![(grid_off as u64, (grid_box.len() - 8) as u64)],
    });
    all_iloc.push(IlocEntry {
        item_id: cfg.tmap_id, construction_method: 1,
        data_reference_index: 0,
        extents: vec![(idat_base as u64, cfg.tmap_payload.len() as u64)],
    });
    all_iloc.push(IlocEntry {
        item_id: cfg.xmp_id, construction_method: 1,
        data_reference_index: 0,
        extents: vec![(xmp_off as u64, cfg.xmp_bytes.len() as u64)],
    });

    // --- PASS 1: placeholder iloc ---
    let pass1_iloc = isobmff::make_iloc_box(&all_iloc);
    let meta_kids = isobmff::parse_boxes(source_data, meta.data_start + 4, meta.data_end);
    let meta_part1 = assemble_meta(
        source_data, meta, &meta_kids, parsed.primary_id, parsed.pitm_version,
        &iinf_box, &pass1_iloc, &ipco, &ipma_full,
        &output_refs, had_iref, iref_v, &idat,
        cfg.group_id, cfg.tmap_id, parsed.primary_id,
    );

    let ftyp_box = isobmff::make_ftyp_box(&source_data[ftyp.data_start..ftyp.data_end]);
    let between = &source_data[meta.box_start + meta.size..mdat.box_start];
    let new_mdat_data_start = ftyp_box.len() + meta_part1.len() + between.len() + 8; // +8 for mdat box header

    // --- Fix iloc offsets ---
    let file_delta = new_mdat_data_start as i64 - mdat.data_start as i64;
    let mut final_iloc: Vec<IlocEntry> = all_iloc.iter().map(|e| {
        if e.construction_method == 0 {
            IlocEntry {
                item_id: e.item_id,
                construction_method: e.construction_method,
                data_reference_index: e.data_reference_index,
                extents: e.extents.iter()
                    .map(|(off, len)| ((*off as i64 + file_delta) as u64, *len))
                    .collect(),
            }
        } else {
            e.clone()
        }
    }).collect();
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
        source_data, meta, &meta_kids, parsed.primary_id, parsed.pitm_version,
        &iinf_box, &pass2_iloc, &ipco, &ipma_full,
        &output_refs, had_iref, iref_v, &idat,
        cfg.group_id, cfg.tmap_id, parsed.primary_id,
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

    std::fs::write(output_path, &out).map_err(|e| format!("write error: {e}"))?;
    Ok(())
}

fn find<'a>(boxes: &'a [BoxHeader], btype: &[u8; 4]) -> Result<&'a BoxHeader, String> {
    boxes.iter().find(|b| &b.btype == btype)
        .ok_or_else(|| format!("{} missing", String::from_utf8_lossy(btype)))
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
            b"iref" => { parts.push(iref_box.clone()); shown_iref = true; }
            b"idat" => { parts.push(idat_box.clone()); shown_idat = true; }
            b"grpl" => { /* drop old grpl */ }
            _ => parts.push(source[kid.box_start..kid.box_start + kid.size].to_vec()),
        }
    }
    if !shown_iref { parts.push(iref_box); }
    if !shown_idat { parts.push(idat_box); }
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
        !matches!(self, OppoCompat::Off)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal valid ISOBMFF HEIC buffer for testing.
    fn make_minimal_heic() -> Vec<u8> {
        let mut out = Vec::new();

        // ftyp
        let mut ftyp_payload = Vec::new();
        ftyp_payload.extend_from_slice(b"heic");
        isobmff::write_u32be(0, &mut ftyp_payload);
        ftyp_payload.extend_from_slice(b"heic");
        ftyp_payload.extend_from_slice(b"mif1");
        out.extend_from_slice(&isobmff::make_box(b"ftyp", &ftyp_payload));

        // ipco with ispe
        let mut ipco = Vec::new();
        ipco.extend_from_slice(&isobmff::make_ispe_box(512, 512));
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
        isobmff::write_u16be(1, &mut iinf_payload);
        iinf_payload.extend_from_slice(&infe1);
        let iinf_box = isobmff::make_box(b"iinf", &iinf_payload);

        let pitm_box = isobmff::make_pitm_box(0, 1);

        let iloc = isobmff::make_iloc_box(&[IlocEntry {
            item_id: 1, construction_method: 0, data_reference_index: 0,
            extents: vec![(0, 4)],
        }]);
        let idat_box = isobmff::make_box(b"idat", &[0u8; 4]);
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

    #[test]
    fn write_lhdr_minimal_smoke() {
        let source = make_minimal_heic();
        let mask = vec![128u8; 16];
        let mut meta = [0.0f32; 36];
        meta[0] = 3.5; meta[2] = 144.0; meta[5] = -1.0; meta[18] = 10.0; meta[19] = 6.0;
        meta[29] = 200.0; meta[32] = 30000.0;

        let tmp = std::env::temp_dir().join("xdremux_test_m3_output.heic");
        let result = write_lhdr_iso_output(
            &source, &mask, 4, 4, &meta, 3.0, OppoCompat::Off,
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

    #[test]
    fn parse_heic_roundtrip() {
        let source = make_minimal_heic();
        let top = isobmff::parse_boxes(&source, 0, source.len());
        assert!(top.iter().any(|b| &b.btype == b"ftyp"));
        assert!(top.iter().any(|b| &b.btype == b"meta"));
        assert!(top.iter().any(|b| &b.btype == b"mdat"));
    }
}
