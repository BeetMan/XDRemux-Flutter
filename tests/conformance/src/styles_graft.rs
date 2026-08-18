//! Research R2: graft Apple Photographic Styles graph items from a
//! Swift-generated golden styles HEIC onto a Rust-generated standard ISO
//! HDR output of the same photo.
//!
//! This is the "identity writer" milestone of the Rust cross-platform
//! port (docs/research/rust-crossplatform-applefeatures.md §6 R2): it
//! proves the Rust standard output can carry the complete Styles graph
//! (styleMetadata URI item, style delta grid + tiles, linear thumbnail,
//! iref/iprp wiring) without any Apple framework. Scene-bundle math (R3)
//! and semantic mattes (R4) are intentionally out of scope - their
//! payloads are copied verbatim from the golden file.
//!
//! The algorithm mirrors the upstream Swift graft writer
//! (ApplePhotographicStylesPipeline, "meta layout is size stable"
//! two-pass build) but operates on Rust output structures.

use std::collections::HashMap;

use xdremux_core::isobmff::{self, BoxHeader, IlocEntry, IrefEntry, IpmaEntry, ParsedMeta};

/// Result summary printed by the CLI.
pub struct GraftSummary {
    pub delta_tile_ids: Vec<u32>,
    pub delta_grid_id: u32,
    pub linear_thumbnail_id: u32,
    pub style_metadata_id: u32,
    pub appended_properties: usize,
    pub output_bytes: usize,
}

/// include mask bits: 1=delta tiles, 2=delta grid, 4=linear thumbnail,
/// 8=styleMetadata, 16=sky matte (+ XMP mime sidecar). Default 31 (all).
/// Env XGRAFT_INCLUDE overrides for bisection research.
fn include_mask() -> u32 {
    std::env::var("XGRAFT_INCLUDE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(31)
}

pub fn graft_styles(standard: &[u8], golden: &[u8]) -> Result<(Vec<u8>, GraftSummary), String> {
    let include = include_mask();
    // ---- 1. Parse both files ------------------------------------------
    let std_top = top_level_boxes(standard)?;
    let gold_top = top_level_boxes(golden)?;
    let std_meta_hdr = find_top(&std_top, b"meta").ok_or("standard: no meta box")?;
    let gold_meta_hdr = find_top(&gold_top, b"meta").ok_or("golden: no meta box")?;
    let std_mdat_hdr = find_top(&std_top, b"mdat").ok_or("standard: no mdat box")?;
    let _gold_mdat_hdr = find_top(&gold_top, b"mdat").ok_or("golden: no mdat box")?;

    let std_meta = isobmff::parse_source_meta(standard)
        .map_err(|e| format!("standard meta parse: {e}"))?;
    let gold_meta = isobmff::parse_source_meta(golden)
        .map_err(|e| format!("golden meta parse: {e}"))?;

    // idat payloads (construction-method-1 item data)
    let std_idat = idat_payload(standard, &std_meta_hdr).unwrap_or_default();
    let gold_idat = idat_payload(golden, &gold_meta_hdr)
        .ok_or("golden: no idat box (styles grid/bplist live there)")?;

    // ---- 2. Identify the Styles items in the golden file --------------
    let primary_g = gold_meta.primary_id;
    let tmap_g = gold_meta
        .items
        .iter()
        .find(|i| i.itype == "tmap")
        .map(|i| i.item_id)
        .ok_or("golden: no tmap item")?;
    let style_meta_g = golden_item_with_infe_text(&gold_meta, b"styleMetadata")
        .ok_or("golden: no styleMetadata item")?;
    // Semantic sky matte aux item + its XMP mime sidecar (golden Styles
    // files carry these; test whether ImageIO's styles path requires them).
    let sky_g = gold_meta
        .ipma_entries
        .iter()
        .find(|e| {
            e.associations.iter().any(|(idx, _)| {
                gold_meta
                    .props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.raw.windows(b"semanticskymatte".len()).any(|w| w == b"semanticskymatte"))
                    .unwrap_or(false)
            })
        })
        .map(|e| e.item_id);
    let sky_mime_g = sky_g.and_then(|sky| {
        gold_meta
            .refs
            .iter()
            .find(|r| r.rtype == "cdsc" && r.to == vec![sky])
            .map(|r| r.from)
    });

    // auxl entries targeting {primary, tmap} come from the gain-map grid,
    // the styles delta grid and the linear thumbnail.
    let mut auxl_froms: Vec<u32> = gold_meta
        .refs
        .iter()
        .filter(|r| r.rtype == "auxl" && r.to.len() == 2)
        .filter(|r| r.to.contains(&primary_g) && r.to.contains(&tmap_g))
        .map(|r| r.from)
        .collect();
    auxl_froms.retain(|id| *id != style_meta_g);

    let props_of = |id: u32| -> Vec<Vec<u8>> {
        gold_meta
            .ipma_entries
            .iter()
            .find(|e| e.item_id == id)
            .map(|e| {
                e.associations
                    .iter()
                    .filter_map(|(idx, _)| gold_meta.props.iter().find(|p| p.index == *idx))
                    .map(|p| p.raw.clone())
                    .collect()
            })
            .unwrap_or_default()
    };
    let has_styledeltamap_urn = |id: u32| {
        props_of(id)
            .iter()
            .any(|p| p.windows(b"styledeltamap".len()).any(|w| w == b"styledeltamap"))
    };

    let item_type = |id: u32| -> Option<&str> {
        gold_meta.items.iter().find(|i| i.item_id == id).map(|i| i.itype.as_str())
    };

    let delta_grid_g = *auxl_froms
        .iter()
        .find(|id| item_type(**id) == Some("grid") && has_styledeltamap_urn(**id))
        .ok_or("golden: no styledeltamap grid item")?;
    // The auxl set also contains the semantic sky matte (and the gain-map
    // grid) - identify the linear thumbnail by its auxC URN, not by
    // exclusion.
    let linear_g = *auxl_froms
        .iter()
        .find(|id| {
            props_of(**id)
                .iter()
                .any(|p| p.windows(b"linearthumbnail".len()).any(|w| w == b"linearthumbnail"))
        })
        .ok_or("golden: no linear thumbnail auxl item")?;
    let delta_tiles_g: Vec<u32> = gold_meta
        .refs
        .iter()
        .filter(|r| r.rtype == "dimg" && r.from == delta_grid_g)
        .flat_map(|r| r.to.clone())
        .collect();
    if delta_tiles_g.is_empty() {
        return Err("golden: delta grid has no dimg tiles".into());
    }

    // ---- 3. Extract payloads from the golden file ---------------------
    let gold_iloc = |id: u32| -> Option<&IlocEntry> {
        gold_meta.iloc_entries.iter().find(|e| e.item_id == id)
    };
    let mdat_bytes = |entry: &IlocEntry| -> Result<Vec<u8>, String> {
        if entry.construction_method != 0 || entry.extents.len() != 1 {
            return Err("expected a single mdat extent".into());
        }
        let (off, len) = entry.extents[0];
        let start = off as usize;
        let end = start + len as usize;
        if end > golden.len() {
            return Err("golden mdat extent out of range".into());
        }
        Ok(golden[start..end].to_vec())
    };
    let idat_bytes = |entry: &IlocEntry| -> Result<Vec<u8>, String> {
        if entry.construction_method != 1 || entry.extents.len() != 1 {
            return Err("expected a single idat extent".into());
        }
        let (off, len) = entry.extents[0];
        let start = off as usize;
        let end = start + len as usize;
        if end > gold_idat.len() {
            return Err("golden idat extent out of range".into());
        }
        Ok(gold_idat[start..end].to_vec())
    };

    let include_sky = include & 16 != 0 && sky_g.is_some();
    let delta_tile_payloads: Vec<Vec<u8>> = delta_tiles_g
        .iter()
        .map(|id| gold_iloc(*id).map(&mdat_bytes).transpose().map(|o| o.unwrap()))
        .collect::<Result<_, _>>()?;
    let delta_grid_payload =
        idat_bytes(gold_iloc(delta_grid_g).ok_or("golden: delta grid has no iloc")?)?;
    let linear_payload =
        mdat_bytes(gold_iloc(linear_g).ok_or("golden: linear thumb has no iloc")?)?;
    let sky_payload = if include_sky {
        Some(mdat_bytes(gold_iloc(sky_g.unwrap()).ok_or("golden: sky matte has no iloc")?)?)
    } else {
        None
    };
    let sky_mime_payload = if include_sky {
        sky_mime_g
            .and_then(|m| gold_iloc(m))
            .map(|e| idat_bytes(e))
            .transpose()?
    } else {
        None
    };
    let style_metadata_payload =
        idat_bytes(gold_iloc(style_meta_g).ok_or("golden: styleMetadata has no iloc")?)?;

    // ---- 4. Renumber: fresh item ids in the standard file -------------
    let primary_s = std_meta.primary_id;
    let tmap_s = std_meta
        .items
        .iter()
        .find(|i| i.itype == "tmap")
        .map(|i| i.item_id)
        .ok_or("standard: no tmap item")?;
    // Fresh item ids must avoid not only existing item ids but also group
    // ids (grpl/altr) - they share one namespace in HEIF. A delta tile
    // numbered into an existing altr group_id makes ImageIO misresolve the
    // gain-map graph (empirically: HDR detection breaks).
    let max_group_id = find_child(standard, &std_meta_hdr, b"grpl")
        .map(|grpl| {
            isobmff::parse_boxes(standard, grpl.data_start, grpl.data_end)
                .iter()
                .filter(|b| &b.btype == b"altr")
                .map(|altr| {
                    // FullBox: version/flags(4) then group_id (u32, v0) or
                    // u32 (v1 uses u32 too)
                    isobmff::read_u32be(standard, altr.data_start + 4)
                })
                .max()
                .unwrap_or(0)
        })
        .unwrap_or(0);
    let base_id: u32 = std::env::var("XGRAFT_BASE_ID")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| {
            let max_item = std_meta.items.iter().map(|i| i.item_id).max().unwrap_or(0);
            max_item.max(max_group_id) + 1
        });
    let mut next_id = base_id;
    let mut fresh = |next_id: &mut u32| {
        let id = *next_id;
        *next_id += 1;
        id
    };
    let delta_tile_ids: Vec<u32> =
        (0..delta_tiles_g.len()).map(|_| fresh(&mut next_id)).collect();
    let delta_grid_id = fresh(&mut next_id);
    let linear_thumbnail_id = fresh(&mut next_id);
    let style_metadata_id = fresh(&mut next_id);
    let sky_id = fresh(&mut next_id);
    let sky_mime_id = fresh(&mut next_id);

    let mut id_map: HashMap<u32, u32> = HashMap::new();
    for (old, new) in delta_tiles_g.iter().zip(delta_tile_ids.iter()) {
        id_map.insert(*old, *new);
    }
    id_map.insert(delta_grid_g, delta_grid_id);
    id_map.insert(linear_g, linear_thumbnail_id);
    id_map.insert(style_meta_g, style_metadata_id);
    if include_sky {
        id_map.insert(sky_g.unwrap(), sky_id);
        if let Some(m) = sky_mime_g {
            id_map.insert(m, sky_mime_id);
        }
    }

    // ---- 5. Properties: append golden boxes, remap ipma ----------------
    let std_iprp = find_child(standard, &std_meta_hdr, b"iprp")
        .ok_or("standard: no iprp box")?;
    let std_ipco = find_child(standard, &std_iprp, b"ipco")
        .ok_or("standard: no ipco box")?;
    let std_ipco_kids =
        isobmff::parse_boxes(standard, std_ipco.data_start, std_ipco.data_end); // ipco is not a FullBox
    let std_ipco_raw = standard[std_ipco.data_start..std_ipco.data_end].to_vec();
    let mut property_count = std_ipco_kids.len() as u32;

    let mut new_ipco = std_ipco_raw.clone();
    let mut new_ipma_entries: Vec<IpmaEntry> = Vec::new();
    // Dedup: the golden file shares one property set across all delta
    // tiles; appending 30 verbatim copies inflates ipco and (empirically)
    // confuses ImageIO. Map identical raw boxes to one index.
    let mut prop_index_by_bytes: Vec<(Vec<u8>, u32)> = std_ipco_kids
        .iter()
        .enumerate()
        .map(|(i, k)| {
            (standard[k.box_start..k.box_start + k.size].to_vec(), (i + 1) as u32)
        })
        .collect();
    let mut append_item_props = |item_id: u32, golden_item: u32| {
        let mut associations = Vec::new();
        if let Some(entry) = gold_meta.ipma_entries.iter().find(|e| e.item_id == golden_item) {
            for (idx, essential) in &entry.associations {
                if let Some(prop) = gold_meta.props.iter().find(|p| p.index == *idx) {
                    let raw = &prop.raw;
                    let index = if let Some((_, existing)) =
                        prop_index_by_bytes.iter().find(|(bytes, _)| bytes == raw)
                    {
                        *existing
                    } else {
                        new_ipco.extend_from_slice(raw);
                        property_count += 1;
                        prop_index_by_bytes.push((raw.clone(), property_count));
                        property_count
                    };
                    associations.push((index, *essential));
                }
            }
        }
        if !associations.is_empty() {
            new_ipma_entries.push(IpmaEntry { item_id, associations });
        }
    };
    let notile_ipma = std::env::var("XGRAFT_NOTILE_IPMA").is_ok();
    if include & 1 != 0 && !notile_ipma {
        for (old_tile, new_tile) in delta_tiles_g.iter().zip(delta_tile_ids.iter()) {
            append_item_props(*new_tile, *old_tile);
        }
    }
    if include & 2 != 0 {
        append_item_props(delta_grid_id, delta_grid_g);
    }
    if include & 4 != 0 {
        append_item_props(linear_thumbnail_id, linear_g);
    }
    if include_sky {
        append_item_props(sky_id, sky_g.unwrap());
    }

    // ---- 6. iinf: standard infes + patched golden infes ----------------
    let std_infes: Vec<Vec<u8>> = std_meta.items.iter().map(|i| i.raw_infe.clone()).collect();
    let mut new_infes: Vec<Vec<u8>> = std_infes.clone();
    let mut extra_old_ids: Vec<u32> = delta_tiles_g.clone();
    extra_old_ids.extend_from_slice(&[delta_grid_g, linear_g, style_meta_g]);
    if include_sky {
        extra_old_ids.push(sky_g.unwrap());
        if let Some(m) = sky_mime_g {
            extra_old_ids.push(m);
        }
    }
    for old_id in extra_old_ids.iter().copied() {
        let bit = if delta_tiles_g.contains(&old_id) {
            1
        } else if old_id == delta_grid_g {
            2
        } else if old_id == linear_g {
            4
        } else if old_id == style_meta_g {
            8
        } else {
            16
        };
        if include & bit == 0 {
            continue;
        }
        let item = gold_meta
            .items
            .iter()
            .find(|i| i.item_id == old_id)
            .ok_or("golden item missing from iinf")?;
        let new_id = id_map[&old_id];
        new_infes.push(patch_infe_id(&item.raw_infe, new_id)?);
    }

    // ---- 7. iref additions --------------------------------------------
    // Research variant: mimic the golden styles file, where the gain-map
    // grid has no auxC association and no auxl edge (the tmap item's dimg
    // wiring alone links it). Env-gated for bisection.
    let golden_style_gainmap = std::env::var("XGRAFT_GOLDEN_STYLE_GAINMAP").is_ok();
    let gainmap_grid_s = std_meta
        .refs
        .iter()
        .find(|r| {
            r.rtype == "auxl" && r.to.contains(&primary_s) && r.to.contains(&tmap_s)
        })
        .map(|r| r.from);
    let mut new_refs: Vec<IrefEntry> = std_meta
        .refs
        .iter()
        .filter(|r| {
            !(golden_style_gainmap
                && r.rtype == "auxl"
                && Some(r.from) == gainmap_grid_s)
        })
        .cloned()
        .collect();
    if include & 1 != 0 && include & 2 != 0 {
        new_refs.push(IrefEntry {
            rtype: "dimg".into(),
            from: delta_grid_id,
            to: delta_tile_ids.clone(),
        });
    }
    if include & 2 != 0 {
        new_refs.push(IrefEntry {
            rtype: "auxl".into(),
            from: delta_grid_id,
            to: vec![primary_s, tmap_s],
        });
    }
    if include & 4 != 0 {
        new_refs.push(IrefEntry {
            rtype: "auxl".into(),
            from: linear_thumbnail_id,
            to: vec![primary_s, tmap_s],
        });
    }
    if include & 8 != 0 {
        new_refs.push(IrefEntry {
            rtype: "cdsc".into(),
            from: style_metadata_id,
            to: vec![primary_s, tmap_s],
        });
    }
    if include_sky {
        new_refs.push(IrefEntry {
            rtype: "auxl".into(),
            from: sky_id,
            to: vec![primary_s, tmap_s],
        });
        if sky_mime_g.is_some() {
            new_refs.push(IrefEntry {
                rtype: "cdsc".into(),
                from: sky_mime_id,
                to: vec![sky_id],
            });
        }
    }

    // ---- 8. iloc / idat / mdat payloads --------------------------------
    let std_mdat_payload = standard[std_mdat_hdr.data_start..std_mdat_hdr.data_end].to_vec();

    // idat: standard payload + delta grid + bplist (construction 1).
    let delta_grid_offset = std_idat.len() as u64;
    let delta_grid_len = delta_grid_payload.len() as u64;
    let style_metadata_offset = delta_grid_offset + delta_grid_len;
    let style_metadata_len = style_metadata_payload.len() as u64;
    let mut new_idat = std_idat;
    if include & 2 != 0 {
        new_idat.extend_from_slice(&delta_grid_payload);
    }
    if include & 8 != 0 {
        new_idat.extend_from_slice(&style_metadata_payload);
    }
    let sky_mime_offset = new_idat.len() as u64;
    let sky_mime_len = sky_mime_payload.as_ref().map(|p| p.len() as u64).unwrap_or(0);
    if include_sky {
        if let Some(p) = &sky_mime_payload {
            new_idat.extend_from_slice(p);
        }
    }

    // mdat additions (construction 0): delta tiles then the linear thumb.
    let mut appended_mdat = Vec::<u8>::new();
    let mut tile_extents = Vec::<(u64, u64)>::new();
    if include & 1 != 0 {
        for payload in &delta_tile_payloads {
            let len = payload.len() as u64;
            tile_extents.push((appended_mdat.len() as u64, len));
            appended_mdat.extend_from_slice(payload);
        }
    }
    let linear_extent_offset = appended_mdat.len() as u64;
    let linear_extent_len = linear_payload.len() as u64;
    if include & 4 != 0 {
        appended_mdat.extend_from_slice(&linear_payload);
    }
    let sky_extent_offset = appended_mdat.len() as u64;
    let sky_extent_len = sky_payload.as_ref().map(|p| p.len() as u64).unwrap_or(0);
    if include_sky {
        appended_mdat.extend_from_slice(sky_payload.as_ref().unwrap());
    }

    // ---- 9. Size-stable two-pass assembly ------------------------------
    let infes_for_build: &[Vec<u8>] = &new_infes;
    let ipco_for_build: &[u8] = &new_ipco;
    let ipma_for_build: &[IpmaEntry] = &new_ipma_entries;
    let build = |iloc_entries: &[IlocEntry]| -> Vec<u8> {
        build_output(
            if golden_style_gainmap { gainmap_grid_s } else { None },
            standard,
            &std_top,
            &std_meta_hdr,
            &std_mdat_hdr,
            &std_meta,
            infes_for_build,
            iloc_entries,
            ipco_for_build,
            ipma_for_build,
            &new_refs,
            &new_idat,
            &std_mdat_payload,
            &appended_mdat,
        )
    };

    // Pass 1: placeholder offsets to learn the final mdat data start.
    let mut placeholder_iloc = std_meta.iloc_entries.clone();
    let mut zero_extents = |entries: &mut Vec<IlocEntry>| {
        let active_tiles: Vec<u32> = if include & 1 != 0 {
            delta_tile_ids.clone()
        } else {
            Vec::new()
        };
        let mut extras: Vec<u32> = active_tiles;
        if include & 2 != 0 {
            extras.push(delta_grid_id);
        }
        if include & 4 != 0 {
            extras.push(linear_thumbnail_id);
        }
        if include & 8 != 0 {
            extras.push(style_metadata_id);
        }
        if include_sky {
            extras.push(sky_id);
            if sky_mime_g.is_some() {
                extras.push(sky_mime_id);
            }
        }
        for id in extras {
            entries.push(IlocEntry {
                item_id: id,
                construction_method: if id == delta_grid_id
                    || id == style_metadata_id
                    || id == sky_mime_id
                {
                    1
                } else {
                    0
                },
                data_reference_index: 0,
                extents: vec![(0, 0)],
            });
        }
    };
    zero_extents(&mut placeholder_iloc);
    let preliminary = build(&placeholder_iloc);
    let prelim_meta_size = find_top(&top_level_boxes(&preliminary).unwrap(), b"meta")
        .map(|h| h.size)
        .unwrap_or(0);
    let mut prefix = 0usize;
    for hdr in &std_top {
        if hdr.box_start == std_mdat_hdr.box_start {
            break;
        }
        prefix += if hdr.box_start == std_meta_hdr.box_start {
            prelim_meta_size
        } else {
            hdr.size
        };
    }
    let new_mdat_data_start = prefix + 8;

    // Pass 2: final iloc entries with real offsets.
    // The meta box grew, so every construction-0 extent that pointed into
    // the mdat payload must shift by the mdat data-start delta (mirrors the
    // upstream graft's shouldShift logic).
    let file_delta = new_mdat_data_start as i64 - std_mdat_hdr.data_start as i64;
    let mut final_iloc: Vec<IlocEntry> = std_meta
        .iloc_entries
        .iter()
        .map(|entry| {
            let extents = entry
                .extents
                .iter()
                .map(|&(offset, length)| {
                    let off = offset as i64;
                    let shift = entry.construction_method == 0
                        && off >= std_mdat_hdr.data_start as i64
                        && off < std_mdat_hdr.data_end as i64;
                    let new_off = if shift { off + file_delta } else { off };
                    (new_off as u64, length)
                })
                .collect();
            IlocEntry { extents, ..entry.clone() }
        })
        .collect();
    for (entry, (rel_off, len)) in delta_tile_ids.iter().zip(tile_extents.iter()) {
        final_iloc.push(IlocEntry {
            item_id: *entry,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(
                (new_mdat_data_start + std_mdat_payload.len()) as u64 + rel_off,
                *len,
            )],
        });
    }
    if include & 2 != 0 {
        final_iloc.push(IlocEntry {
            item_id: delta_grid_id,
            construction_method: 1,
            data_reference_index: 0,
            extents: vec![(delta_grid_offset, delta_grid_len)],
        });
    }
    if include & 4 != 0 {
        final_iloc.push(IlocEntry {
            item_id: linear_thumbnail_id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(
                (new_mdat_data_start + std_mdat_payload.len()) as u64 + linear_extent_offset,
                linear_extent_len,
            )],
        });
    }
    if include & 8 != 0 {
        final_iloc.push(IlocEntry {
            item_id: style_metadata_id,
            construction_method: 1,
            data_reference_index: 0,
            extents: vec![(style_metadata_offset, style_metadata_len)],
        });
    }
    if include_sky {
        final_iloc.push(IlocEntry {
            item_id: sky_id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(
                (new_mdat_data_start + std_mdat_payload.len()) as u64 + sky_extent_offset,
                sky_extent_len,
            )],
        });
        if sky_mime_g.is_some() {
            final_iloc.push(IlocEntry {
                item_id: sky_mime_id,
                construction_method: 1,
                data_reference_index: 0,
                extents: vec![(sky_mime_offset, sky_mime_len)],
            });
        }
    }

    let output = build(&final_iloc);

    // ---- 10. Sanity: original mdat prefix unchanged ---------------------
    let out_mdat = find_top(&top_level_boxes(&output)?, b"mdat").ok_or("output: no mdat")?;
    let out_payload = &output[out_mdat.data_start..out_mdat.data_end];
    if &out_payload[..std_mdat_payload.len()] != std_mdat_payload.as_slice() {
        return Err("base mdat payload changed while grafting styles".into());
    }

    Ok((
        output.clone(),
        GraftSummary {
            delta_tile_ids,
            delta_grid_id,
            linear_thumbnail_id,
            style_metadata_id,
            appended_properties: new_ipma_entries
                .iter()
                .map(|e| e.associations.len())
                .sum(),
            output_bytes: output.len(),
        },
    ))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

pub(crate) fn top_level_boxes(data: &[u8]) -> Result<Vec<BoxHeader>, String> {
    let boxes = isobmff::parse_boxes(data, 0, data.len());
    if boxes.is_empty() {
        return Err("no top-level boxes".into());
    }
    Ok(boxes)
}

pub(crate) fn find_top(boxes: &[BoxHeader], btype: &[u8; 4]) -> Option<BoxHeader> {
    boxes.iter().find(|b| &b.btype == btype).cloned()
}

fn find_child(data: &[u8], parent: &BoxHeader, btype: &[u8; 4]) -> Option<BoxHeader> {
    // meta is a FullBox (children start after 4-byte version/flags);
    // plain containers (iprp/ipco) start children at data_start.
    let is_fullbox = parent.btype == *b"meta";
    let start = parent.data_start + if is_fullbox { 4 } else { 0 };
    isobmff::parse_boxes(data, start, parent.box_start + parent.size)
        .into_iter()
        .find(|b| &b.btype == btype)
}

pub(crate) fn idat_payload(data: &[u8], meta: &BoxHeader) -> Option<Vec<u8>> {
    find_child(data, meta, b"idat")
        .map(|h| data[h.data_start..h.data_end].to_vec())
}

fn golden_item_with_infe_text(meta: &ParsedMeta, text: &[u8]) -> Option<u32> {
    meta.items
        .iter()
        .find(|i| i.raw_infe.windows(text.len()).any(|w| w == text))
        .map(|i| i.item_id)
}

fn patch_infe_id(raw: &[u8], new_id: u32) -> Result<Vec<u8>, String> {
    if new_id > u16::MAX as u32 {
        return Err("fresh item id exceeds 16-bit infe range".into());
    }
    let mut out = raw.to_vec();
    let version = out.get(8).copied().unwrap_or(0);
    let id_offset = match version {
        2 => 12,
        3 => 12,
        _ => return Err(format!("unsupported infe version {version}")),
    };
    if out.len() < id_offset + 2 {
        return Err("infe box too short".into());
    }
    // v3 uses a 32-bit id; both layouts start the id at byte 12.
    if version == 3 {
        out[id_offset..id_offset + 4].copy_from_slice(&new_id.to_be_bytes());
    } else {
        out[id_offset..id_offset + 2]
            .copy_from_slice(&(new_id as u16).to_be_bytes());
    }
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
/// pub(crate) wrapper so scaffold.rs can reuse the assembly logic.
#[allow(clippy::too_many_arguments)]
pub(crate) fn build_output_pub(
    drop_auxc_for: Option<u32>,
    standard: &[u8],
    std_top: &[BoxHeader],
    std_meta_hdr: &BoxHeader,
    std_mdat_hdr: &BoxHeader,
    std_meta: &ParsedMeta,
    new_infes: &[Vec<u8>],
    iloc_entries: &[IlocEntry],
    new_ipco: &[u8],
    new_ipma_entries: &[IpmaEntry],
    new_refs: &[IrefEntry],
    new_idat: &[u8],
    std_mdat_payload: &[u8],
    appended_mdat: &[u8],
) -> Vec<u8> {
    build_output(
        drop_auxc_for,
        standard,
        std_top,
        std_meta_hdr,
        std_mdat_hdr,
        std_meta,
        new_infes,
        iloc_entries,
        new_ipco,
        new_ipma_entries,
        new_refs,
        new_idat,
        std_mdat_payload,
        appended_mdat,
    )
}

fn build_output(
    drop_auxc_for: Option<u32>,
    standard: &[u8],
    std_top: &[BoxHeader],
    std_meta_hdr: &BoxHeader,
    std_mdat_hdr: &BoxHeader,
    std_meta: &ParsedMeta,
    new_infes: &[Vec<u8>],
    iloc_entries: &[IlocEntry],
    new_ipco: &[u8],
    new_ipma_entries: &[IpmaEntry],
    new_refs: &[IrefEntry],
    new_idat: &[u8],
    std_mdat_payload: &[u8],
    appended_mdat: &[u8],
) -> Vec<u8> {
    let iinf_box = isobmff::make_iinf_box(std_meta.iinf_version, new_infes);
    let iloc_box = isobmff::make_iloc_box(iloc_entries);
    let ipco_box = isobmff::make_box(b"ipco", new_ipco);
    let ipma_payload = build_ipma_filtered(std_meta, new_ipma_entries, drop_auxc_for);
    let ipma_box = isobmff::make_box(b"ipma", &ipma_payload);
    let mut iprp = Vec::new();
    iprp.extend_from_slice(&ipco_box);
    iprp.extend_from_slice(&ipma_box);
    let iprp_box = isobmff::make_box(b"iprp", &iprp);
    let iref_box = isobmff::make_iref_full_box(0, new_refs);
    let idat_box = isobmff::make_box(b"idat", new_idat);

    // Rebuild meta children in the original order, replacing the
    // rewritten boxes.
    let meta_kids = isobmff::parse_boxes(
        standard,
        std_meta_hdr.data_start + 4, // meta is a FullBox
        std_meta_hdr.box_start + std_meta_hdr.size,
    );
    let mut meta_payload = standard[std_meta_hdr.data_start..std_meta_hdr.data_start + 4].to_vec();
    let mut shown_iref = false;
    let mut shown_idat = false;
    for kid in &meta_kids {
        match &kid.btype {
            b"iinf" => meta_payload.extend_from_slice(&iinf_box),
            b"iloc" => meta_payload.extend_from_slice(&iloc_box),
            b"iprp" => meta_payload.extend_from_slice(&iprp_box),
            b"iref" => {
                meta_payload.extend_from_slice(&iref_box);
                shown_iref = true;
            }
            b"idat" => {
                meta_payload.extend_from_slice(&idat_box);
                shown_idat = true;
            }
            _ => meta_payload
                .extend_from_slice(&standard[kid.box_start..kid.box_start + kid.size]),
        }
    }
    if !shown_iref {
        meta_payload.extend_from_slice(&iref_box);
    }
    if !shown_idat {
        meta_payload.extend_from_slice(&idat_box);
    }
    let meta_box = isobmff::make_box(b"meta", &meta_payload);

    let mut final_mdat = std_mdat_payload.to_vec();
    final_mdat.extend_from_slice(appended_mdat);
    let mdat_box = isobmff::make_box(b"mdat", &final_mdat);

    let mut out = Vec::new();
    for hdr in std_top {
        if hdr.box_start == std_meta_hdr.box_start {
            out.extend_from_slice(&meta_box);
        } else if hdr.box_start == std_mdat_hdr.box_start {
            out.extend_from_slice(&mdat_box);
        } else {
            out.extend_from_slice(&standard[hdr.box_start..hdr.box_start + hdr.size]);
        }
    }
    out
}

fn build_ipma_filtered(
    std_meta: &ParsedMeta,
    extra: &[IpmaEntry],
    drop_auxc_for: Option<u32>,
) -> Vec<u8> {
    let mut owned: Vec<IpmaEntry> = std_meta.ipma_entries.clone();
    if let Some(item) = drop_auxc_for {
        if let Some(entry) = owned.iter_mut().find(|e| e.item_id == item) {
            entry.associations.retain(|(idx, _)| {
                std_meta
                    .props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.ptype != "auxC")
                    .unwrap_or(true)
            });
        }
    }
    build_ipma_entries(std_meta, &owned, extra)
}

fn build_ipma(std_meta: &ParsedMeta, extra: &[IpmaEntry]) -> Vec<u8> {
    build_ipma_entries(std_meta, &std_meta.ipma_entries.clone(), extra)
}

fn build_ipma_entries(std_meta: &ParsedMeta, base: &[IpmaEntry], extra: &[IpmaEntry]) -> Vec<u8> {
    // Keep the source ipma version/flags; rebuild all entries (16-bit ids).
    let version = if std_meta.ipma_flags & 0x1 != 0 { 1 } else { 0 };
    let flags = std_meta.ipma_flags & !0x1;
    let entries: Vec<&IpmaEntry> = base.iter().chain(extra.iter()).collect();
    let mut payload = vec![
        version,
        ((flags >> 16) & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
        (flags & 0xff) as u8,
    ];
    isobmff::write_u32be(entries.len() as u32, &mut payload); // placeholder count for v1
    if version == 0 {
        payload.truncate(4);
        isobmff::write_u32be(entries.len() as u32, &mut payload);
    }
    for entry in entries {
        isobmff::write_u16be(entry.item_id as u16, &mut payload);
        payload.push(entry.associations.len() as u8);
        for (idx, essential) in &entry.associations {
            let mut byte = (*idx as u8) & 0x7f;
            if *essential {
                byte |= 0x80;
            }
            payload.push(byte);
        }
    }
    payload
}


/// Debug/bisect: rebuild the file's meta with zero additions and verify the
/// output stays byte-equivalent for ImageIO.
pub fn rewrite_meta_passthrough(data: &[u8]) -> Result<Vec<u8>, String> {
    let top = top_level_boxes(data)?;
    let meta_hdr = find_top(&top, b"meta").ok_or("no meta")?;
    let mdat_hdr = find_top(&top, b"mdat").ok_or("no mdat")?;
    let meta = isobmff::parse_source_meta(data).map_err(|e| format!("{e}"))?;
    let idat = idat_payload(data, &meta_hdr).unwrap_or_default();
    let mdat_payload = data[mdat_hdr.data_start..mdat_hdr.data_end].to_vec();

    let std_iprp = find_child(data, &meta_hdr, b"iprp").ok_or("no iprp")?;
    let std_ipco = find_child(data, &std_iprp, b"ipco").ok_or("no ipco")?;
    let ipco_raw = data[std_ipco.data_start..std_ipco.data_start + std_ipco.size - 8].to_vec();

    let infes: Vec<Vec<u8>> = meta.items.iter().map(|i| i.raw_infe.clone()).collect();
    let refs = meta.refs.clone();

    // two-pass like graft: meta may grow/shrink from reserialization
    let build = |iloc: &[IlocEntry]| {
        build_output(
            None, data, &top, &meta_hdr, &mdat_hdr, &meta, &infes, iloc,
            &ipco_raw, &[], &refs, &idat, &mdat_payload, &[],
        )
    };
    let prelim = build(&meta.iloc_entries);
    let prelim_meta_size = find_top(&top_level_boxes(&prelim).unwrap(), b"meta").unwrap().size;
    let mut prefix = 0usize;
    for hdr in &top {
        if hdr.box_start == mdat_hdr.box_start { break; }
        prefix += if hdr.box_start == meta_hdr.box_start { prelim_meta_size } else { hdr.size };
    }
    let new_mdat_start = prefix + 8;
    let delta = new_mdat_start as i64 - mdat_hdr.data_start as i64;
    let final_iloc: Vec<IlocEntry> = meta.iloc_entries.iter().map(|e| IlocEntry {
        extents: e.extents.iter().map(|&(o, l)| {
            let oo = o as i64;
            let shift = e.construction_method == 0 && oo >= mdat_hdr.data_start as i64 && oo < mdat_hdr.data_end as i64;
            ((if shift { oo + delta } else { oo }) as u64, l)
        }).collect(),
        ..e.clone()
    }).collect();
    Ok(build(&final_iloc))
}
