//! Native styles writer (R3c): generate the full Apple Photographic Styles
//! payload in Rust — no Swift golden oracle.
//!
//! Runs on top of `scaffold` (R3b): standard output → scaffold equivalent →
//! styles payload, all in one call.
//!
//! Payload layout mirrors the golden Swift identity output:
//!   - delta map: 6×5 grid of 512×512 neutral tiles (embedded golden IDR
//!     slice + hvcC — content-neutral, photo-independent), auxC
//!     `tag:apple.com,2023:photo:aux:styledeltamap`, output dims ≈ 0.703×
//!     primary (formula verified only at 4096×3512).
//!   - linear thumbnail: quarter-res item, auxC `…:linearthumbnail`.
//!     PLACEHOLDER: black frame (Rust has no HEVC decoder for the primary);
//!     only affects the style-picker preview, not the gate (unverified).
//!   - styles sky matte: zero mono item + matte XMP sidecar (same approach
//!     as scaffold.rs; real segmentation is R4).
//!   - styleMetadata `uri ` item: native bplist with identity styleData
//!     (864 blocks × 30 f16, 1.0 at [3,7,11] — verified fixed across the
//!     two available goldens, both 4096×3512).
//!
//! Photo-dependent bplist fields that are currently REFERENCE VALUES from
//! the golden sample (need image decode to compute — blocked on a decoder):
//!   - "i" gain range, "h" headroom, "6" histogram stats, "c"/"d" LUTs.

use xdremux_core::isobmff::{
    self, IlocEntry, IpmaEntry, IrefEntry, ParsedMeta,
};

use crate::bplist::BplistWriter;
use crate::scaffold;
use crate::styles_consts::{DELTA_HVCC_BOX, DELTA_TILE, FIELD_3, FIELD_C, FIELD_D};
use crate::styles_graft::{find_top, top_level_boxes};

const STYLE_DATA_BLOCKS: usize = 864;
const DELTA_ROWS: u32 = 5;
const DELTA_COLS: u32 = 6;
const DELTA_TILE_SIZE: u32 = 512;

pub fn styles_native(standard: &[u8]) -> Result<Vec<u8>, String> {
    let scaffolded = scaffold::scaffold(standard)?;
    assemble_styles(&scaffolded)
}

fn assemble_styles(base: &[u8]) -> Result<Vec<u8>, String> {
    // ---- parse the scaffolded base -------------------------------------
    let top = top_level_boxes(base)?;
    let meta_hdr = find_top(&top, b"meta").ok_or("no meta box")?;
    let mdat_hdr = find_top(&top, b"mdat").ok_or("no mdat box")?;
    let meta = isobmff::parse_source_meta(base).map_err(|e| format!("meta parse: {e}"))?;

    let primary = meta.primary_id;
    let tmap = meta
        .items
        .iter()
        .find(|i| i.itype == "tmap")
        .map(|i| i.item_id)
        .ok_or("no tmap item")?;
    let (pw, ph) = primary_dims(&meta, primary)?;

    // ---- new item ids (clear of grpl/altr group ids) -------------------
    let mut next_id = meta.items.iter().map(|i| i.item_id).max().unwrap_or(1) + 1;
    let max_group = crate::scaffold::max_group_id_pub(base, &meta_hdr).unwrap_or(0);
    if next_id <= max_group {
        next_id = max_group + 1;
    }
    let delta_tile_ids: Vec<u32> = (0..DELTA_ROWS * DELTA_COLS)
        .map(|i| next_id + i)
        .collect();
    let delta_grid_id = next_id + DELTA_ROWS * DELTA_COLS;
    let linear_id = delta_grid_id + 1;
    let style_meta_id = linear_id + 1;

    // ---- existing sky matte detection (dedup) --------------------------
    // The scaffold stage already emits a zero sky matte + XMP sidecar;
    // re-adding one here duplicated the item. When the base already carries
    // a sky matte, REUSE that item: replace its payload + hvcC association
    // instead of appending a new item/mime/refs trio. (Mirrors the pipeline
    // fix in xdremux/rust/src/styles_native.rs.)
    let sky_urn = b"urn:com:apple:photo:2020:aux:semanticskymatte";
    let existing_sky: Option<u32> = meta.ipma_entries.iter().find_map(|e| {
        let has_sky_auxc = e.associations.iter().any(|(idx, _)| {
            meta.props
                .iter()
                .find(|p| p.index == *idx)
                .map(|p| p.ptype == "auxC" && p.raw.windows(sky_urn.len()).any(|w| w == sky_urn))
                .unwrap_or(false)
        });
        if has_sky_auxc {
            Some(e.item_id)
        } else {
            None
        }
    });
    let (sky_id, sky_mime_id, add_sky_items) = match existing_sky {
        Some(id) => (id, 0, false),
        None => (style_meta_id + 1, style_meta_id + 2, true),
    };

    // ---- encode payloads ------------------------------------------------
    // Sky matte (styles stage): x265 mono, same as the scaffold stage
    // (ImageIO accepts length-prefixed pure-IDR x265 mono). Diagnostic:
    // XSTYLES_SKY_STREAM / XSTYLES_SKY_HVCC swap in another (e.g. golden
    // real Vision) matte for Photos-behaviour bisection.
    let (matte_w, matte_h) = ((pw / 2) & !1, (ph / 2) & !1);
    let env_sky_stream = std::env::var("XSTYLES_SKY_STREAM").ok()
        .map(|p| std::fs::read(p).expect("sky stream file"));
    let env_sky_hvcc = std::env::var("XSTYLES_SKY_HVCC").ok()
        .map(|p| std::fs::read(p).expect("sky hvcc file"));
    let (sky_stream, sky_hvcc) = if let Ok(raw_path) = std::env::var("XSTYLES_SKY_RAW") {
        // Real matte bitmap (raw gray8, matte_w x matte_h), e.g. SegFormer.
        let raw = std::fs::read(&raw_path).map_err(|e| format!("sky raw: {e}"))?;
        if raw.len() != (matte_w * matte_h) as usize {
            return Err(format!(
                "sky raw size {} != {}x{}", raw.len(), matte_w, matte_h
            ));
        }
        let refs: Vec<&[u8]> = vec![&raw];
        let stream = xdremux_core::hevc::x265_encode_tiles(&refs, matte_w, matte_h, 1, false)
            .map_err(|e| format!("sky matte encode: {e}"))?
            .into_iter().next().ok_or("sky matte encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 0)
            .ok_or("sky hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        (xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc)
    } else if env_sky_stream.is_some() || env_sky_hvcc.is_some() {
        let pixels = vec![0u8; (matte_w * matte_h) as usize];
        let refs: Vec<&[u8]> = vec![&pixels];
        let stream = xdremux_core::hevc::x265_encode_tiles(&refs, matte_w, matte_h, 1, false)
            .map_err(|e| format!("sky matte encode: {e}"))?
            .into_iter().next().ok_or("sky matte encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 0)
            .ok_or("sky hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        let stream = xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr);
        (env_sky_stream.unwrap_or(stream), env_sky_hvcc.unwrap_or(hvcc))
    } else {
        let pixels = vec![0u8; (matte_w * matte_h) as usize];
        let refs: Vec<&[u8]> = vec![&pixels];
        let stream = xdremux_core::hevc::x265_encode_tiles(&refs, matte_w, matte_h, 1, false)
            .map_err(|e| format!("sky matte encode: {e}"))?
            .into_iter().next().ok_or("sky matte encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 0)
            .ok_or("sky hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        (xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc)
    };

    // Linear thumbnail placeholder: black RGB at quarter resolution.
    // Diagnostic: XSTYLES_LINEAR_STREAM / XSTYLES_LINEAR_HVCC swap in a real
    // (e.g. golden) thumbnail for Photos-behaviour bisection.
    let lt_w = pw / 4;
    let lt_h = ph / 4;
    let env_lt_stream = std::env::var("XSTYLES_LINEAR_STREAM").ok()
        .map(|p| std::fs::read(p).expect("linear stream file"));
    let env_lt_hvcc = std::env::var("XSTYLES_LINEAR_HVCC").ok()
        .map(|p| std::fs::read(p).expect("linear hvcc file"));
    let (linear_stream, linear_hvcc) = if env_lt_stream.is_some() || env_lt_hvcc.is_some() {
        let black = vec![0u8; (lt_w * lt_h * 3) as usize];
        let black_refs: Vec<&[u8]> = vec![&black];
        let stream = xdremux_core::hevc::x265_encode_tiles(&black_refs, lt_w, lt_h, 3, false)
            .map_err(|e| format!("linear thumb encode: {e}"))?
            .into_iter()
            .next()
            .ok_or("linear thumb encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 3)
            .ok_or("linear hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        let stream = xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr);
        (env_lt_stream.unwrap_or(stream), env_lt_hvcc.unwrap_or(hvcc))
    } else {
        let black = vec![0u8; (lt_w * lt_h * 3) as usize];
        let black_refs: Vec<&[u8]> = vec![&black];
        let stream = xdremux_core::hevc::x265_encode_tiles(&black_refs, lt_w, lt_h, 3, false)
            .map_err(|e| format!("linear thumb encode: {e}"))?
            .into_iter()
            .next()
            .ok_or("linear thumb encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 3)
            .ok_or("linear hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        (xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc)
    };

    // ---- style metadata bplist ------------------------------------------
    let bplist = build_style_metadata();

    // ---- iinf ------------------------------------------------------------
    let mut new_infes: Vec<Vec<u8>> = meta.items.iter().map(|i| i.raw_infe.clone()).collect();
    for id in &delta_tile_ids {
        new_infes.push(isobmff::make_infe_box(*id, "hvc1", 1));
    }
    new_infes.push(isobmff::make_infe_box(delta_grid_id, "grid", 1));
    new_infes.push(isobmff::make_infe_box(linear_id, "hvc1", 1));
    new_infes.push(make_style_meta_infe(style_meta_id));
    if add_sky_items {
        new_infes.push(isobmff::make_infe_box(sky_id, "hvc1", 1));
    }
    new_infes.push(make_xmp_infe(sky_mime_id));

    // ---- ipco ------------------------------------------------------------
    let mut next_index = meta.props.iter().map(|p| p.index).max().unwrap_or(0) + 1;
    let mut new_props: Vec<Vec<u8>> = Vec::new();
    let mut add_prop = |raw: Vec<u8>| -> u32 {
        let idx = next_index;
        next_index += 1;
        new_props.push(raw);
        idx
    };
    let find_prop = |ptype: &str, pred: &dyn Fn(&[u8]) -> bool| -> Option<u32> {
        meta.props
            .iter()
            .find(|p| p.ptype == ptype && pred(&p.raw))
            .map(|p| p.index)
    };
    let colr_idx = find_prop("colr", &|_| true).ok_or("no colr property")?;
    let irot_idx = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .and_then(|e| {
            e.associations.iter().find(|(idx, _)| {
                meta.props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.ptype == "irot")
                    .unwrap_or(false)
            })
        })
        .map(|(idx, _)| *idx);
    let pixi10_idx = find_prop("pixi", &|raw| raw == isobmff::PIXI_RGB10_BOX)
        .unwrap_or_else(|| add_prop(isobmff::PIXI_RGB10_BOX.to_vec()));
    let pixi_mono_idx = find_prop("pixi", &|raw| raw == isobmff::PIXI_MONO8_BOX)
        .unwrap_or_else(|| add_prop(isobmff::PIXI_MONO8_BOX.to_vec()));
    let ispe512_idx = find_prop("ispe", &|raw| {
        raw.len() >= 20 && &raw[12..16] == &512u32.to_be_bytes() && &raw[16..20] == &512u32.to_be_bytes()
    })
    .unwrap_or_else(|| add_prop(isobmff::make_ispe_box(512, 512)));

    // Delta grid dims: 0.703× primary (golden ratio at 4096×3512).
    let delta_w = ((pw as u64 * 2880 + 2048) / 4096) as u32;
    let delta_h = ((ph as u64 * 2470 + 1756) / 3512) as u32;
    let ispe_delta_idx = add_prop(isobmff::make_ispe_box(delta_w, delta_h));
    let auxc_delta_idx = add_prop(make_auxc_box(b"tag:apple.com,2023:photo:aux:styledeltamap"));
    let ispe_lt_idx = add_prop(isobmff::make_ispe_box(lt_w, lt_h));
    let auxc_lt_idx = add_prop(make_auxc_box(b"tag:apple.com,2023:photo:aux:linearthumbnail"));
    let hvcc_lt_idx = add_prop(isobmff::make_box(b"hvcC", &linear_hvcc));
    let ispe_sky_idx = add_prop(isobmff::make_ispe_box(matte_w, matte_h));
    let auxc_sky_idx = add_prop(make_auxc_box(b"urn:com:apple:photo:2020:aux:semanticskymatte"));
    let hvcc_sky_idx = add_prop(isobmff::make_box(b"hvcC", &sky_hvcc));
    let hvcc_delta_idx = add_prop(DELTA_HVCC_BOX.to_vec());

    // ---- ipma ------------------------------------------------------------
    // Extra entries ONLY (build_output chains them onto the source entries;
    // passing a cloned full list here previously doubled every entry).
    let mut ipma_entries: Vec<IpmaEntry> = Vec::new();
    for id in &delta_tile_ids {
        ipma_entries.push(IpmaEntry {
            item_id: *id,
            associations: vec![(ispe512_idx, true), (colr_idx, true), (hvcc_delta_idx, true)],
        });
    }
    let mut delta_grid_assocs = vec![
        (colr_idx, true),
        (ispe_delta_idx, false),
        (pixi10_idx, false),
        (auxc_delta_idx, true),
    ];
    if let Some(ir) = irot_idx {
        delta_grid_assocs.push((ir, true));
    }
    ipma_entries.push(IpmaEntry {
        item_id: delta_grid_id,
        associations: delta_grid_assocs,
    });
    let mut lt_assocs = vec![
        (ispe_lt_idx, true),
        (pixi10_idx, false),
        (hvcc_lt_idx, true),
        (auxc_lt_idx, true),
    ];
    if let Some(ir) = irot_idx {
        lt_assocs.push((ir, true));
    }
    ipma_entries.push(IpmaEntry {
        item_id: linear_id,
        associations: lt_assocs,
    });
    let mut sky_assocs = vec![
        (ispe_sky_idx, false),
        (pixi_mono_idx, false),
        (auxc_sky_idx, true),
        (hvcc_sky_idx, true),
    ];
    if let Some(ir) = irot_idx {
        sky_assocs.push((ir, true));
    }
    if add_sky_items {
        ipma_entries.push(IpmaEntry {
            item_id: sky_id,
            associations: sky_assocs.clone(),
        });
    }
    // Reuse path: rewrite the base ipma entry for the existing sky matte
    // via ipma_base_override (same association set).
    let sky_ipma_override: Option<IpmaEntry> = if add_sky_items {
        None
    } else {
        Some(IpmaEntry {
            item_id: sky_id,
            associations: sky_assocs,
        })
    };

    // ---- iref ------------------------------------------------------------
    let mut new_refs = meta.refs.clone();
    new_refs.push(IrefEntry {
        rtype: "dimg".into(),
        from: delta_grid_id,
        to: delta_tile_ids.clone(),
    });
    new_refs.push(IrefEntry {
        rtype: "auxl".into(),
        from: delta_grid_id,
        to: vec![primary, tmap],
    });
    new_refs.push(IrefEntry {
        rtype: "auxl".into(),
        from: linear_id,
        to: vec![primary, tmap],
    });
    if add_sky_items {
        new_refs.push(IrefEntry {
            rtype: "auxl".into(),
            from: sky_id,
            to: vec![primary, tmap],
        });
    }
    if add_sky_items {
        new_refs.push(IrefEntry {
            rtype: "cdsc".into(),
            from: sky_mime_id,
            to: vec![sky_id],
        });
    }
    new_refs.push(IrefEntry {
        rtype: "cdsc".into(),
        from: style_meta_id,
        to: vec![primary, tmap],
    });

    // ---- payloads ----------------------------------------------------------
    let std_idat = crate::styles_graft::idat_payload(base, &meta_hdr).unwrap_or_default();
    // grid item payload = compact ImageGrid (8 bytes, no box header).
    let mut grid_payload = vec![0u8, 0, (DELTA_ROWS - 1) as u8, (DELTA_COLS - 1) as u8];
    grid_payload.extend_from_slice(&(delta_w as u16).to_be_bytes());
    grid_payload.extend_from_slice(&(delta_h as u16).to_be_bytes());

    let mut new_idat = std_idat;
    let grid_off = new_idat.len() as u64;
    new_idat.extend_from_slice(&grid_payload);
    let grid_len = grid_payload.len() as u64;
    let bplist_off = new_idat.len() as u64;
    let bplist_len = bplist.len() as u64;
    new_idat.extend_from_slice(&bplist);
    let mut sky_mime_off = 0u64;
    let mut sky_mime_len = 0u64;
    if add_sky_items {
        let sky_mime_payload = crate::scaffold::matte_xmp_pub();
        sky_mime_off = new_idat.len() as u64;
        sky_mime_len = sky_mime_payload.len() as u64;
        new_idat.extend_from_slice(&sky_mime_payload);
    }

    let std_mdat_payload = base[mdat_hdr.data_start..mdat_hdr.data_end].to_vec();
    let mut appended_mdat = Vec::new();
    let mut tile_rel_offsets = Vec::new();
    for _ in &delta_tile_ids {
        tile_rel_offsets.push(appended_mdat.len() as u64);
        appended_mdat.extend_from_slice(DELTA_TILE);
    }
    let linear_rel = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&linear_stream);
    let sky_rel = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&sky_stream);

    // ---- ipco rebuild -------------------------------------------------------
    let mut new_ipco: Vec<u8> = meta.props.iter().flat_map(|p| p.raw.clone()).collect();
    for raw in &new_props {
        new_ipco.extend_from_slice(raw);
    }

    // ---- two-pass assembly --------------------------------------------------
    // Reuse path: rewrite the base ipma entry for the existing sky matte.
    let ipma_base_override: Option<Vec<IpmaEntry>> = sky_ipma_override.map(|patched| {
        let mut list = meta.ipma_entries.clone();
        if let Some(entry) = list.iter_mut().find(|e| e.item_id == sky_id) {
            *entry = patched;
        }
        list
    });
    let build = |iloc_entries: &[IlocEntry]| -> Vec<u8> {
        crate::styles_graft::build_output_pub(
            None,
            ipma_base_override.as_deref(),
            base,
            &top,
            &meta_hdr,
            &mdat_hdr,
            &meta,
            &new_infes,
            iloc_entries,
            &new_ipco,
            &ipma_entries,
            &new_refs,
            &new_idat,
            &std_mdat_payload,
            &appended_mdat,
        )
    };

    let mut placeholder_iloc = meta.iloc_entries.clone();
    // Reuse path: drop the base iloc entry for the existing sky matte FIRST
    // (its payload is replaced by the appended one). Must precede the
    // placeholder pushes so the two-pass iloc entry sets match exactly.
    if !add_sky_items {
        placeholder_iloc.retain(|e| e.item_id != sky_id);
    }
    // The sky placeholder must exist in BOTH paths so the placeholder iloc
    // matches the final iloc entry set (two-pass meta size stability).
    let mut new_item_ids: Vec<u32> = delta_tile_ids.clone();
    new_item_ids.extend([delta_grid_id, linear_id, style_meta_id, sky_id]);
    if add_sky_items {
        new_item_ids.push(sky_mime_id);
    }
    for id in new_item_ids {
        placeholder_iloc.push(IlocEntry {
            item_id: id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, 0)],
        });
    }
    let preliminary = build(&placeholder_iloc);
    let prelim_meta_size = find_top(&top_level_boxes(&preliminary)?, b"meta")
        .map(|h| h.size)
        .unwrap_or(0);
    let mut prefix = 0usize;
    for hdr in &top {
        if hdr.box_start == mdat_hdr.box_start {
            break;
        }
        prefix += if hdr.box_start == meta_hdr.box_start {
            prelim_meta_size
        } else {
            hdr.size
        };
    }
    let new_mdat_data_start = prefix + 8;
    let file_delta = new_mdat_data_start as i64 - mdat_hdr.data_start as i64;
    let appended_abs = (new_mdat_data_start + std_mdat_payload.len()) as u64;

    let mut final_iloc: Vec<IlocEntry> = meta
        .iloc_entries
        .iter()
        .filter(|entry| add_sky_items || entry.item_id != sky_id)
        .map(|entry| {
            let extents = entry
                .extents
                .iter()
                .map(|&(offset, length)| {
                    let off = offset as i64;
                    let shift = entry.construction_method == 0
                        && off >= mdat_hdr.data_start as i64
                        && off < mdat_hdr.data_end as i64;
                    let new_off = if shift { off + file_delta } else { off };
                    (new_off as u64, length)
                })
                .collect();
            IlocEntry {
                extents,
                ..entry.clone()
            }
        })
        .collect();
    for (id, rel) in delta_tile_ids.iter().zip(tile_rel_offsets.iter()) {
        final_iloc.push(IlocEntry {
            item_id: *id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(appended_abs + rel, DELTA_TILE.len() as u64)],
        });
    }
    final_iloc.push(IlocEntry {
        item_id: delta_grid_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(grid_off, grid_len)],
    });
    final_iloc.push(IlocEntry {
        item_id: linear_id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(appended_abs + linear_rel, linear_stream.len() as u64)],
    });
    final_iloc.push(IlocEntry {
        item_id: style_meta_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(bplist_off, bplist_len)],
    });
    final_iloc.push(IlocEntry {
        item_id: sky_id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(appended_abs + sky_rel, sky_stream.len() as u64)],
    });
    if add_sky_items {
        final_iloc.push(IlocEntry {
            item_id: sky_mime_id,
            construction_method: 1,
            data_reference_index: 0,
            extents: vec![(sky_mime_off, sky_mime_len)],
        });
    }

    Ok(build(&final_iloc))
}

// ---------------------------------------------------------------------------
// style metadata bplist
// ---------------------------------------------------------------------------

/// Identity styleData: 864 blocks × 30 f16 values, 1.0 at [3,7,11].
fn identity_style_data() -> Vec<u8> {
    let mut out = Vec::with_capacity(STYLE_DATA_BLOCKS * 30 * 2);
    for _ in 0..STYLE_DATA_BLOCKS {
        for i in 0..30u32 {
            let v: u16 = if matches!(i, 3 | 7 | 11) {
                0x3c00 // f16 1.0
            } else {
                0
            };
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
    out
}

fn build_style_metadata() -> Vec<u8> {
    let mut w = BplistWriter::new();

    // Golden field order: 0, f, 1, j, g, 4, i, 6, c, k, h, 2, 5, 3, e, 7, d
    let k0 = w.add_str("0");
    let v0 = w.add_int(15);
    let kf = w.add_str("f");
    let vf = w.add_int(32);
    let k1 = w.add_str("1");
    let style_data = identity_style_data();
    let v1 = w.add_data(&style_data);
    let kj = w.add_str("j");
    let vj = w.add_real(1.0);
    let kg = w.add_str("g");
    let vg = w.add_int(1278226536);
    let k4 = w.add_str("4");
    let v4 = w.add_real(4.0);
    let ki = w.add_str("i");
    let vi = {
        // Reference gain-range values from the golden sample; per-photo
        // computation needs gain-map decode (TODO: derive at convert time).
        let kmin = w.add_str("OriginalRangeMin");
        let vmin = w.add_real(0.0);
        let kmax = w.add_str("OriginalRangeMax");
        let vmax = w.add_real(0.0762939453125);
        let kgain = w.add_str("Gain");
        let vgain = w.add_real(7.353515625);
        w.add_dict(&[(kmin, vmin), (kmax, vmax), (kgain, vgain)])
    };
    let k6 = w.add_str("6");
    let v6 = build_stats_dict(&mut w);
    let kc = w.add_str("c");
    let vc = w.add_data(FIELD_C);
    let kk = w.add_str("k");
    let vk = w.add_bool(false);
    let kh = w.add_str("h");
    let vh = w.add_real(1.8384023904800415);
    let k2 = w.add_str("2");
    let v2 = w.add_bool(true);
    let k5 = w.add_str("5");
    let v5 = w.add_int(2);
    let k3 = w.add_str("3");
    let v3 = w.add_data(FIELD_3);
    let ke = w.add_str("e");
    let ve = w.add_int(32);
    let k7 = w.add_str("7");
    let v7 = {
        let kpm = w.add_str("PersonMasksValidHint");
        let vpm = w.add_real(-1.0);
        let ksr = w.add_str("SkinRatio");
        let vsr = w.add_real(0.0);
        let kpr = w.add_str("PeopleRatio");
        let vpr = w.add_real(0.0);
        w.add_dict(&[(kpm, vpm), (ksr, vsr), (kpr, vpr)])
    };
    let kd = w.add_str("d");
    let vd = w.add_data(FIELD_D);

    let top = w.add_dict(&[
        (k0, v0),
        (kf, vf),
        (k1, v1),
        (kj, vj),
        (kg, vg),
        (k4, v4),
        (ki, vi),
        (k6, v6),
        (kc, vc),
        (kk, vk),
        (kh, vh),
        (k2, v2),
        (k5, v5),
        (k3, v3),
        (ke, ve),
        (k7, v7),
        (kd, vd),
    ]);
    w.finish(top)
}

/// Scene statistics ("6"). Identity path: person/skin segment histograms are
/// legitimately zero; ToneMappedImage/LinearImage carry reference values from
/// the golden sample (per-photo computation needs a decoder — TODO).
fn build_stats_dict(w: &mut BplistWriter) -> usize {
    let zero_stats = |w: &mut BplistWriter| -> usize {
        let entries = [
            ("highKey", 1.0f64),
            ("p75", 0.0),
            ("p25", 0.0),
            ("blackPoint", 0.0),
            ("p02", 0.0),
            ("p50", 0.0),
            ("whitePoint", 0.0),
            ("p10", 0.0),
            ("p98", 0.0),
        ];
        let refs: Vec<(usize, usize)> = entries
            .iter()
            .map(|(k, v)| (w.add_str(k), w.add_real(*v)))
            .collect();
        w.add_dict(&refs)
    };
    let golden_tone_mapped = |w: &mut BplistWriter| -> usize {
        let entries = [
            ("p02", 0.0055912993848323805),
            ("p98", 1.0064338445663452),
            ("p10", 0.016773898154497147),
            ("blackPoint", 0.0),
            ("p75", 0.24042586982250214),
            ("highKey", 0.5505164861679077),
            ("whitePoint", 0.0),
            ("p50", 0.08946079015731809),
            ("p25", 0.0279564969241619),
        ];
        let refs: Vec<(usize, usize)> = entries
            .iter()
            .map(|(k, v)| (w.add_str(k), w.add_real(*v)))
            .collect();
        w.add_dict(&refs)
    };
    let golden_linear = |w: &mut BplistWriter| -> usize {
        let entries = [
            ("blackPoint", 0.0),
            ("whitePoint", 0.0),
            ("p02", 0.00032384536461904645),
            ("p50", 0.0032384535297751427),
            ("highKey", 0.9925689101219177),
            ("p98", 0.04630988836288451),
            ("p75", 0.009391515515744686),
            ("p25", 0.0009715360938571393),
            ("p10", 0.0006476907292380929),
        ];
        let refs: Vec<(usize, usize)> = entries
            .iter()
            .map(|(k, v)| (w.add_str(k), w.add_real(*v)))
            .collect();
        w.add_dict(&refs)
    };

    let entries: Vec<(usize, usize)> = [
        ("LinearImagePersonSegmentBased", zero_stats(w)),
        ("ToneMappedImageRedChannelSkinBased", zero_stats(w)),
        ("ToneMappedImagePersonSegmentBased", zero_stats(w)),
        ("LinearGTCImage", zero_stats(w)),
        ("ToneMappedImage", golden_tone_mapped(w)),
        ("ToneMappedImageGreenChannelSkinBased", zero_stats(w)),
        ("LinearImage", golden_linear(w)),
        ("LinearImageSkinBased", zero_stats(w)),
        ("ToneMappedImageBlueChannelSkinBased", zero_stats(w)),
        ("ToneMappedImageSkinBased", zero_stats(w)),
    ]
    .into_iter()
    .map(|(k, v)| (w.add_str(k), v))
    .collect();
    w.add_dict(&entries)
}

// ---------------------------------------------------------------------------
// small builders
// ---------------------------------------------------------------------------

fn primary_dims(meta: &ParsedMeta, primary: u32) -> Result<(u32, u32), String> {
    let entry = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .ok_or("primary has no ipma entry")?;
    for (idx, _) in &entry.associations {
        if let Some(p) = meta.props.iter().find(|p| p.index == *idx) {
            if p.ptype == "ispe" && p.raw.len() >= 20 {
                let w = u32::from_be_bytes([p.raw[12], p.raw[13], p.raw[14], p.raw[15]]);
                let h = u32::from_be_bytes([p.raw[16], p.raw[17], p.raw[18], p.raw[19]]);
                if w > 512 && h > 512 {
                    return Ok((w, h));
                }
            }
        }
    }
    Err("primary ispe not found".into())
}

fn make_auxc_box(urn: &[u8]) -> Vec<u8> {
    let mut payload = vec![0u8, 0, 0, 0];
    payload.extend_from_slice(urn);
    payload.push(0);
    isobmff::make_box(b"auxC", &payload)
}

fn make_style_meta_infe(item_id: u32) -> Vec<u8> {
    let mut payload = vec![2u8, 0, 0, 1]; // version 2, hidden
    payload.extend_from_slice(&(item_id as u16).to_be_bytes());
    payload.extend_from_slice(&[0, 0]);
    payload.extend_from_slice(b"uri ");
    payload.extend_from_slice(b"styleMetadata\0");
    payload.extend_from_slice(b"tag:apple.com,2023:photo:metadata:styles\0");
    isobmff::make_box(b"infe", &payload)
}

fn make_xmp_infe(item_id: u32) -> Vec<u8> {
    let mut payload = vec![2u8, 0, 0, 1];
    payload.extend_from_slice(&(item_id as u16).to_be_bytes());
    payload.extend_from_slice(&[0, 0]);
    payload.extend_from_slice(b"mime");
    payload.push(0);
    payload.extend_from_slice(b"application/rdf+xml\0");
    isobmff::make_box(b"infe", &payload)
}
