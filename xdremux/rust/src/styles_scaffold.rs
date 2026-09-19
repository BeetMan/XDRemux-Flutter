//! Scaffold writer (R3b): turn a Rust standard-output HEIC into a
//! scaffold-equivalent base that Photos accepts for Apple Photographic
//! Styles editing.
//!
//! R3a (docs/research/rust-crossplatform-applefeatures.md 附录 A) identified
//! the delta between the Rust standard base (rejected by Photos after a
//! styles graft) and the Swift pipeline's ImageIO-produced semantic scaffold
//! (accepted). This module closes that delta without re-encoding pixel data:
//!
//!   1. pixi [8,8,8] declared on the primary grid (the passthrough primary
//!      tiles are already 8-bit SDR; the scaffold merely declares it).
//!   2. clli associated to the primary tiles (non-essential, like ImageIO).
//!   3. Semantic sky matte item: mono 8-bit HEVC single-frame item with
//!      auxC `urn:com:apple:photo:2020:aux:semanticskymatte`, auxl →
//!      [primary, tmap]. Matte content is all-zero ("no sky"); R4 will
//!      replace it with a real segmentation (MediaPipe).
//!   4. Two XMP mime items: dates XMP (cdsc → [primary, tmap]) and the
//!      semanticSegmentationMatte version XMP (cdsc → matte).
//!   5. Apple MakerNote injected into the Exif item ("Apple iOS" header,
//!      tag 43 photo UUID, tag 84 runtime-flags bplist) via TIFF surgery,
//!      and the Exif item marked hidden.
//!
//! Deliberately NOT done (deferred, pending Photos acceptance):
//!   - Re-encoding the primary/gain-map tiles with ImageIO's encoder
//!     settings (the golden scaffold re-encodes; content is identical 8-bit
//!     SDR, so we keep the passthrough bitstreams).

#[cfg(test)]
#[path = "styles_scaffold_tests.rs"]
mod tests;

use crate::isobmff::{self, IlocEntry, IpmaEntry, IrefEntry, ParsedMeta};

use crate::styles_graft::{find_top, idat_payload, top_level_boxes};

/// One IPRP property we append to ipco.
struct NewProp {
    raw: Vec<u8>,
    /// 1-based index assigned after appending.
    index: u32,
}

pub fn scaffold(standard: &[u8]) -> Result<Vec<u8>, String> {
    // ---- 1. Parse ------------------------------------------------------
    let std_top = top_level_boxes(standard)?;
    let std_meta_hdr = find_top(&std_top, b"meta").ok_or("no meta box")?;
    let std_mdat_hdr = find_top(&std_top, b"mdat").ok_or("no mdat box")?;
    let std_meta = isobmff::parse_source_meta(standard).map_err(|e| format!("meta parse: {e}"))?;
    let std_idat = idat_payload(standard, &std_meta_hdr).unwrap_or_default();

    let primary = std_meta.primary_id;
    let tmap = std_meta
        .items
        .iter()
        .find(|i| i.itype == "tmap")
        .map(|i| i.item_id)
        .ok_or("no tmap item")?;
    let exif_item = std_meta
        .items
        .iter()
        .find(|i| i.itype == "Exif")
        .ok_or("no Exif item")?
        .clone();
    // Gain-map grid: the other dimg target of the tmap item.
    let gain_grid = std_meta
        .refs
        .iter()
        .find(|r| r.rtype == "dimg" && r.from == tmap)
        .and_then(|r| r.to.iter().copied().find(|id| *id != primary))
        .ok_or("no gain-map grid")?;
    let primary_tiles: Vec<u32> = std_meta
        .refs
        .iter()
        .find(|r| r.rtype == "dimg" && r.from == primary)
        .map(|r| r.to.clone())
        .ok_or("primary grid has no dimg tiles")?;

    // Primary dimensions from the grid's ispe.
    if std::env::var("XSCAFFOLD_DEBUG").is_ok() {
        eprintln!("primary={primary} tmap={tmap} gain_grid={gain_grid}");
        for e in &std_meta.ipma_entries {
            if e.item_id == primary {
                eprintln!("primary assocs: {:?}", e.associations);
            }
        }
        for p in &std_meta.props {
            if p.ptype == "ispe" {
                eprintln!(
                    "ispe idx={} len={} head={:02x?}",
                    p.index,
                    p.raw.len(),
                    &p.raw[..p.raw.len().min(20)]
                );
            }
        }
    }
    let (pw, ph) = primary_ispe(&std_meta, primary)?;

    // ---- 2. Sky matte (zero content) ----------------------------------
    // Half-resolution like the golden Vision matte.
    let matte_w = (pw / 2) & !1;
    let matte_h = (ph / 2) & !1;
    // Default: x265 mono zero matte, converted to in-container form (pure
    // IDR, length-prefixed). ImageIO's aux path accepts this — the earlier
    // "x265 rejected" finding was actually an annex-B-in-mdat bug. Envs:
    // XSCAFFOLD_VT_MATTE=1 embedded VT constant; XSCAFFOLD_X265_MATTE_420=1
    // (with XDREMUX_GM_420=1) 4:2:0 gray variant.
    let x265_matte =
        |w: u32, h: u32, use_420: bool, chroma: u8| -> Result<(Vec<u8>, Vec<u8>), String> {
            let pixels = vec![0u8; (w * h) as usize];
            let refs: Vec<&[u8]> = vec![&pixels];
            let stream = crate::hevc::x265_encode_tiles(&refs, w, h, 1, use_420)
                .map_err(|e| format!("matte HEVC encode: {e}"))?
                .into_iter()
                .next()
                .ok_or("matte encode produced no stream")?;
            let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, chroma)
                .ok_or("matte hvcC extraction failed")?;
            let idr = crate::hevc::drop_parameter_nals(&stream);
            Ok((crate::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc))
        };
    let (matte_stream, matte_hvcc) = if let Ok(raw_path) = std::env::var("XSCAFFOLD_MATTE_RAW") {
        // Real matte bitmap (raw gray8, matte_w x matte_h), e.g. from the
        // `sky-matte` subcommand's SegFormer output.
        let raw = std::fs::read(&raw_path).map_err(|e| format!("matte raw: {e}"))?;
        if raw.len() != (matte_w * matte_h) as usize {
            return Err(format!(
                "matte raw size {} != {}x{}",
                raw.len(),
                matte_w,
                matte_h
            ));
        }
        let refs: Vec<&[u8]> = vec![&raw];
        let stream = crate::hevc::x265_encode_tiles(&refs, matte_w, matte_h, 1, false)
            .map_err(|e| format!("matte HEVC encode: {e}"))?
            .into_iter()
            .next()
            .ok_or("matte encode produced no stream")?;
        let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, 0)
            .ok_or("matte hvcC extraction failed")?;
        let idr = crate::hevc::drop_parameter_nals(&stream);
        (crate::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc)
    } else if std::env::var("XSCAFFOLD_X265_MATTE_420").is_ok() {
        x265_matte(matte_w, matte_h, true, 1)?
    } else if std::env::var("XSCAFFOLD_VT_MATTE").is_ok() {
        (
            crate::styles_consts::ZERO_MATTE_STREAM.to_vec(),
            crate::styles_consts::ZERO_MATTE_HVCC.to_vec(),
        )
    } else {
        x265_matte(matte_w, matte_h, false, 0)?
    };

    // ---- 3. XMP payloads -----------------------------------------------
    let exif_payload =
        item_payload(standard, &std_meta, exif_item.item_id).ok_or("Exif item payload missing")?;
    let (datetime, offset_time) = exif_datetime(&exif_payload)
        .unwrap_or_else(|| ("1970:01:01 00:00:00".to_string(), "+00:00".to_string()));
    let dates_xmp = build_dates_xmp(&datetime, &offset_time);
    let matte_xmp = build_matte_xmp();

    // ---- 4. Exif rewrite: inject Apple MakerNote ------------------------
    let maker_note = compose_styles_maker_note(&exif_payload)?;
    let new_exif_payload = inject_maker_note(&exif_payload, &maker_note)
        .map_err(|e| format!("Exif MakerNote injection: {e}"))?;

    // ---- 5. New item IDs -----------------------------------------------
    let mut next_id = std_meta.items.iter().map(|i| i.item_id).max().unwrap_or(1) + 1;
    // Avoid colliding with grpl/altr group_ids (R2 bug): group ids share
    // the same namespace in some readers; bump past any group id too.
    let max_group = max_group_id(standard, &std_meta_hdr).unwrap_or(0);
    if next_id <= max_group {
        next_id = max_group + 1;
    }
    let matte_id = next_id;
    let matte_xmp_id = next_id + 1;
    let dates_xmp_id = next_id + 2;

    // ---- 6. iinf --------------------------------------------------------
    let mut new_infes: Vec<Vec<u8>> = std_meta
        .items
        .iter()
        .map(|i| {
            if i.item_id == exif_item.item_id {
                // Mark Exif hidden (ImageIO scaffold behaviour).
                isobmff::make_infe_box(i.item_id, "Exif", 1)
            } else {
                i.raw_infe.clone()
            }
        })
        .collect();
    new_infes.push(isobmff::make_infe_box(matte_id, "hvc1", 1));
    new_infes.push(make_xmp_infe(matte_xmp_id));
    new_infes.push(make_xmp_infe(dates_xmp_id));

    // ---- 7. ipco additions ----------------------------------------------
    // Reuse existing property indices where an identical box exists.
    let find_prop = |ptype: &str, pred: &dyn Fn(&[u8]) -> bool| -> Option<u32> {
        std_meta
            .props
            .iter()
            .find(|p| p.ptype == ptype && pred(&p.raw))
            .map(|p| p.index)
    };
    let mut appended: Vec<NewProp> = Vec::new();
    let mut next_index = std_meta.props.iter().map(|p| p.index).max().unwrap_or(0) + 1;
    let add_prop = |raw: Vec<u8>, appended: &mut Vec<NewProp>, next_index: &mut u32| -> u32 {
        let idx = *next_index;
        *next_index += 1;
        appended.push(NewProp { raw, index: idx });
        idx
    };

    // pixi [8,8,8] for the primary grid — reuse if present (Rust output
    // already carries it for the gain grid).
    let pixi_rgb8_idx = find_prop("pixi", &|raw: &[u8]| raw == isobmff::PIXI_RGB8_BOX)
        .unwrap_or_else(|| {
            add_prop(
                isobmff::PIXI_RGB8_BOX.to_vec(),
                &mut appended,
                &mut next_index,
            )
        });
    let pixi_mono8_idx = find_prop("pixi", &|raw: &[u8]| raw == isobmff::PIXI_MONO8_BOX)
        .unwrap_or_else(|| {
            add_prop(
                isobmff::PIXI_MONO8_BOX.to_vec(),
                &mut appended,
                &mut next_index,
            )
        });
    let auxc_sky_idx = add_prop(make_auxc_sky_box(), &mut appended, &mut next_index);
    let ispe_matte_idx = add_prop(
        isobmff::make_ispe_box(matte_w, matte_h),
        &mut appended,
        &mut next_index,
    );
    let hvcc_matte_idx = add_prop(
        isobmff::make_box(b"hvcC", &matte_hvcc),
        &mut appended,
        &mut next_index,
    );
    // clli to bind to primary tiles (reuse the primary grid's clli).
    let clli_idx = std_meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .and_then(|e| {
            e.associations.iter().find(|(idx, _)| {
                std_meta
                    .props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.ptype == "clli")
                    .unwrap_or(false)
            })
        })
        .map(|(idx, _)| *idx);
    // irot of the primary grid (mirror onto the matte, like the golden).
    let irot_idx = std_meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .and_then(|e| {
            e.associations.iter().find(|(idx, _)| {
                std_meta
                    .props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.ptype == "irot")
                    .unwrap_or(false)
            })
        })
        .map(|(idx, _)| *idx);

    // ---- 8. ipma ---------------------------------------------------------
    // Modified source entries are passed as the base override; only genuinely
    // new items go into `extra` (build_output would otherwise duplicate the
    // source entries — the doubling bug found via ipma count 151 vs 78).
    let mut ipma_base: Vec<IpmaEntry> = std_meta.ipma_entries.clone();
    for entry in ipma_base.iter_mut() {
        if entry.item_id == primary {
            // Primary grid: + pixi [8,8,8] (non-essential).
            if !entry.associations.iter().any(|(i, _)| *i == pixi_rgb8_idx) {
                entry.associations.push((pixi_rgb8_idx, false));
            }
        } else if primary_tiles.contains(&entry.item_id) {
            // Primary tiles: + clli (non-essential), like the golden.
            if let Some(ci) = clli_idx {
                if !entry.associations.iter().any(|(i, _)| *i == ci) {
                    entry.associations.push((ci, false));
                }
            }
        } else if entry.item_id == gain_grid {
            // Gain grid: pixi [8,8,8] → mono [8] (golden declares mono).
            entry.associations.retain(|(i, _)| {
                std_meta
                    .props
                    .iter()
                    .find(|p| p.index == *i)
                    .map(|p| p.ptype != "pixi")
                    .unwrap_or(true)
            });
            entry.associations.push((pixi_mono8_idx, false));
        }
    }
    let mut matte_assocs: Vec<(u32, bool)> = vec![
        (ispe_matte_idx, false),
        (pixi_mono8_idx, false),
        (auxc_sky_idx, true),
        (hvcc_matte_idx, true),
    ];
    if let Some(ir) = irot_idx {
        matte_assocs.push((ir, true));
    }
    let matte_ipma_entry = IpmaEntry {
        item_id: matte_id,
        associations: matte_assocs,
    };

    // ---- 9. iref additions ----------------------------------------------
    let mut new_refs = std_meta.refs.clone();
    new_refs.push(IrefEntry {
        rtype: "auxl".into(),
        from: matte_id,
        to: vec![primary, tmap],
    });
    new_refs.push(IrefEntry {
        rtype: "cdsc".into(),
        from: matte_xmp_id,
        to: vec![matte_id],
    });
    new_refs.push(IrefEntry {
        rtype: "cdsc".into(),
        from: dates_xmp_id,
        to: vec![primary, tmap],
    });

    // ---- 10. Payloads: idat (XMP) + mdat (matte, Exif) -------------------
    let mut new_idat = std_idat.clone();
    let dates_xmp_off = new_idat.len() as u64;
    let dates_xmp_len = dates_xmp.len() as u64;
    new_idat.extend_from_slice(&dates_xmp);
    let matte_xmp_off = new_idat.len() as u64;
    let matte_xmp_len = matte_xmp.len() as u64;
    new_idat.extend_from_slice(&matte_xmp);

    let std_mdat_payload = standard[std_mdat_hdr.data_start..std_mdat_hdr.data_end].to_vec();
    let mut appended_mdat = Vec::new();
    let exif_rel_off = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&new_exif_payload);
    let matte_rel_off = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&matte_stream);

    // ---- 11. ipco rebuild ------------------------------------------------
    let mut new_ipco: Vec<u8> = std_meta.props.iter().flat_map(|p| p.raw.clone()).collect();
    for p in &appended {
        new_ipco.extend_from_slice(&p.raw);
    }

    // ---- 12. Two-pass assembly (same size-stable trick as graft) ---------
    let build = |iloc_entries: &[IlocEntry]| -> Vec<u8> {
        crate::styles_graft::build_output_pub(
            None,
            Some(&ipma_base),
            standard,
            &std_top,
            &std_meta_hdr,
            &std_mdat_hdr,
            &std_meta,
            &new_infes,
            iloc_entries,
            &new_ipco,
            std::slice::from_ref(&matte_ipma_entry),
            &new_refs,
            &new_idat,
            &std_mdat_payload,
            &appended_mdat,
        )
    };

    let mut placeholder_iloc = std_meta.iloc_entries.clone();
    for id in [matte_id, matte_xmp_id, dates_xmp_id] {
        placeholder_iloc.push(IlocEntry {
            item_id: id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, 0)],
        });
    }
    // Exif extent may grow; keep the placeholder length generous.
    let preliminary = build(&placeholder_iloc);
    let prelim_meta_size = find_top(&top_level_boxes(&preliminary)?, b"meta")
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
    let file_delta = new_mdat_data_start as i64 - std_mdat_hdr.data_start as i64;

    let mut final_iloc: Vec<IlocEntry> = std_meta
        .iloc_entries
        .iter()
        .map(|entry| {
            if entry.item_id == exif_item.item_id {
                // Repoint Exif to the rewritten payload (appended to mdat).
                return IlocEntry {
                    item_id: entry.item_id,
                    construction_method: 0,
                    data_reference_index: 0,
                    extents: vec![(
                        (new_mdat_data_start + std_mdat_payload.len()) as u64 + exif_rel_off,
                        new_exif_payload.len() as u64,
                    )],
                };
            }
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
            IlocEntry {
                extents,
                ..entry.clone()
            }
        })
        .collect();
    final_iloc.push(IlocEntry {
        item_id: matte_id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(
            (new_mdat_data_start + std_mdat_payload.len()) as u64 + matte_rel_off,
            matte_stream.len() as u64,
        )],
    });
    final_iloc.push(IlocEntry {
        item_id: dates_xmp_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(dates_xmp_off, dates_xmp_len)],
    });
    final_iloc.push(IlocEntry {
        item_id: matte_xmp_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(matte_xmp_off, matte_xmp_len)],
    });

    Ok(build(&final_iloc))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn primary_ispe(meta: &ParsedMeta, primary: u32) -> Result<(u32, u32), String> {
    let entry = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .ok_or("primary has no ipma entry")?;
    for (idx, _) in &entry.associations {
        if let Some(p) = meta.props.iter().find(|p| p.index == *idx) {
            if p.ptype == "ispe" && p.raw.len() >= 20 {
                // raw includes the box header: size(4)+type(4)+verflags(4)
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

fn item_payload(data: &[u8], meta: &ParsedMeta, item_id: u32) -> Option<Vec<u8>> {
    let entry = meta.iloc_entries.iter().find(|e| e.item_id == item_id)?;
    if entry.construction_method != 0 {
        return None; // idat items not needed here
    }
    let &(off, len) = entry.extents.first()?;
    Some(data[off as usize..(off + len) as usize].to_vec())
}

fn make_auxc_sky_box() -> Vec<u8> {
    let mut payload = vec![0u8, 0, 0, 0]; // FullBox version+flags
    payload.extend_from_slice(b"urn:com:apple:photo:2020:aux:semanticskymatte\0");
    isobmff::make_box(b"auxC", &payload)
}

/// XMP mime infe with an empty item name (matches the golden scaffold).
fn make_xmp_infe(item_id: u32) -> Vec<u8> {
    let mut payload = vec![2u8, 0, 0, 1]; // version 2, flags = hidden
    payload.extend_from_slice(&(item_id as u16).to_be_bytes());
    payload.extend_from_slice(&[0, 0]); // protection index
    payload.extend_from_slice(b"mime");
    payload.push(0); // empty item name (matches golden scaffold)
    payload.extend_from_slice(b"application/rdf+xml\0");
    isobmff::make_box(b"infe", &payload)
}

fn build_dates_xmp(datetime: &str, offset: &str) -> Vec<u8> {
    // "2024:03:02 18:45:56" + "+08:00" → "2024-03-02T18:45:56"
    let iso = if datetime.len() >= 19 {
        format!(
            "{}-{}-{}T{}",
            &datetime[0..4],
            &datetime[5..7],
            &datetime[8..10],
            &datetime[11..19]
        )
    } else {
        "1970-01-01T00:00:00".to_string()
    };
    let _ = offset; // golden omits the offset in XMP dates
    format!(
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">\n   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n      <rdf:Description rdf:about=\"\"\n            xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n            xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\">\n         <xmp:CreateDate>{iso}</xmp:CreateDate>\n         <xmp:ModifyDate>{iso}</xmp:ModifyDate>\n         <photoshop:DateCreated>{iso}</photoshop:DateCreated>\n      </rdf:Description>\n   </rdf:RDF>\n</x:xmpmeta>\n"
    )
    .into_bytes()
}

fn build_matte_xmp() -> Vec<u8> {
    "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">\n   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n      <rdf:Description rdf:about=\"\"\n            xmlns:semanticSegmentationMatte=\"http://ns.apple.com/semanticSegmentationMatte/1.0/\">\n         <semanticSegmentationMatte:SemanticSegmentationMatteVersion>65536</semanticSegmentationMatte:SemanticSegmentationMatteVersion>\n      </rdf:Description>\n   </rdf:RDF>\n</x:xmpmeta>\n"
        .as_bytes()
        .to_vec()
}

/// The Apple MakerNote observed in the golden scaffold:
/// "Apple iOS\0\0\x01" + MM magic(2) + entries (tag 43 UUID, tag 84 flags
/// bplist) + zero terminator. Offsets are relative to the MakerNote start.
fn build_maker_note() -> Vec<u8> {
    let uuid = uuid_v4_upper();
    // 91 bytes, copied verbatim from the golden scaffold (keys '0'..'7').
    let flags_bplist: &[u8] = &[
        0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30, 0xd8, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x07, 0x08, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x09, 0x0b, 0x09, 0x51, 0x37, 0x51, 0x33, 0x51,
        0x34, 0x51, 0x30, 0x51, 0x35, 0x51, 0x31, 0x51, 0x36, 0x51, 0x32, 0x10, 0x00, 0x10, 0x01,
        0x10, 0x04, 0x08, 0x19, 0x1b, 0x1d, 0x1f, 0x21, 0x23, 0x25, 0x27, 0x29, 0x2b, 0x2d, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x2f,
    ];
    let uuid_bytes = {
        let mut u = uuid.into_bytes();
        u.push(0);
        u
    };

    // Layout: header(12) + MM+magic(4) + entry(12) + entry(12) + terminator(4)
    //         = 44, then UUID, then bplist.
    let uuid_off = 44u32;
    let bplist_off = uuid_off + uuid_bytes.len() as u32;

    let mut out = Vec::with_capacity(bplist_off as usize + flags_bplist.len());
    out.extend_from_slice(b"Apple iOS\0\0\x01");
    out.extend_from_slice(b"MM\x00\x02");
    // entry 1: tag 43 (photo UUID), ASCII
    out.extend_from_slice(&43u16.to_be_bytes());
    out.extend_from_slice(&2u16.to_be_bytes());
    out.extend_from_slice(&(uuid_bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(&uuid_off.to_be_bytes());
    // entry 2: tag 84 (runtime flags bplist), undefined
    out.extend_from_slice(&84u16.to_be_bytes());
    out.extend_from_slice(&7u16.to_be_bytes());
    out.extend_from_slice(&(flags_bplist.len() as u32).to_be_bytes());
    out.extend_from_slice(&bplist_off.to_be_bytes());
    // terminator
    out.extend_from_slice(&[0, 0, 0, 0]);
    debug_assert_eq!(out.len(), uuid_off as usize);
    out.extend_from_slice(&uuid_bytes);
    debug_assert_eq!(out.len(), bplist_off as usize);
    out.extend_from_slice(flags_bplist);
    out
}

/// Apple offsets are relative to the note, not the enclosing TIFF. The common
/// portrait template already has both Styles fields: keep that note byte-exact.
pub fn compose_styles_maker_note(exif: &[u8]) -> Result<Vec<u8>, String> {
    let styles = build_maker_note();
    let prefix = exif_prefix_len(exif)?;
    let tiff = &exif[prefix..];
    let (bo, ifd0) = tiff_header(tiff).ok_or("bad TIFF header")?;
    let (_, entries, _) = exif_directory(tiff, bo, ifd0)?;
    let Some(entry) = entries.iter().find(|e| e.tag == 0x927c) else {
        return Ok(styles);
    };
    let note = entry_bytes(tiff, entry).ok_or("invalid MakerNote bounds/type")?;
    if !note.starts_with(b"Apple iOS") {
        return Ok(styles);
    }
    merge_styles_note(note, &styles)
}

fn merge_styles_note(note: &[u8], styles: &[u8]) -> Result<Vec<u8>, String> {
    if note.get(..12) != Some(b"Apple iOS\0\0\x01") {
        return Err("unsupported Apple MakerNote header".into());
    }
    let bo = match note.get(12..14) {
        Some(b"MM") => Bo(true),
        Some(b"II") => Bo(false),
        _ => return Err("invalid Apple MakerNote byte order".into()),
    };
    let (entries, next) = read_ifd(note, bo, 14).ok_or("invalid Apple MakerNote IFD")?;
    if next != 0 {
        return Err("unsupported Apple MakerNote IFD chain".into());
    }
    let old_end = 16 + entries.len() * 12 + 4;
    for (i, entry) in entries.iter().enumerate() {
        if entries[..i].iter().any(|e| e.tag == entry.tag)
            || entry_bytes(note, entry).is_none()
            || entry.payload_offset.is_some_and(|offset| (offset as usize) < old_end)
        {
            return Err("invalid Apple MakerNote entry/bounds".into());
        }
    }
    let (required, _) = read_ifd(styles, Bo(true), 14).ok_or("invalid Styles template")?;
    if let Some(uuid) = entries.iter().find(|e| e.tag == 43) {
        let bytes = entry_bytes(note, uuid).unwrap();
        if uuid.typ != 2 || bytes.len() != 37 || bytes[36] != 0 {
            return Err("invalid Apple photo UUID".into());
        }
    }
    let complete = required.iter().all(|r| entries.iter().any(|e| {
        e.tag == r.tag && e.typ == r.typ
            && (r.tag == 43 || entry_bytes(note, e) == entry_bytes(styles, r))
    }));
    if complete {
        return Ok(note.to_vec());
    }
    let missing = required.iter().filter(|r| !entries.iter().any(|e| e.tag == r.tag)).count();
    let shift = missing * 12;
    if shift != 0 && entries.iter().any(|e| e.typ == 7 && e.payload_offset.is_some() && e.tag != 84) {
        return Err("cannot expand Apple MakerNote with unknown out-of-line UNDEFINED payload".into());
    }
    let count = u16::try_from(entries.len() + missing).map_err(|_| "too many MakerNote entries")?;
    // Only incomplete notes expand the fixed-position directory. Relocate typed
    // fields and the demonstrated self-relative tag84 plist, not opaque blobs.
    let mut out = note.to_vec();
    if shift != 0 {
        out.splice(old_end..old_end, vec![0; shift]);
    }
    let mut records: Vec<(u16, [u8; 12])> = Vec::new();
    for entry in &entries {
        let mut record: [u8; 12] = note[entry.value_field_pos - 8..entry.value_field_pos + 4].try_into().unwrap();
        if let Some(offset) = entry.payload_offset {
            bo.put_u32(&mut record[8..12], offset.checked_add(shift as u32).ok_or("MakerNote offset overflow")?);
        }
        records.push((entry.tag, record));
    }
    for required_entry in &required {
        let existing = entries.iter().find(|e| e.tag == required_entry.tag);
        // A valid existing photo UUID belongs to the photo, not this stage.
        if required_entry.tag == 43 && existing.is_some() {
            continue;
        }
        let payload = entry_bytes(styles, required_entry).ok_or("invalid Styles payload")?;
        if let Some(e) = existing {
            if e.typ == required_entry.typ && entry_bytes(note, e) == Some(payload) {
                continue;
            }
        }
        let mut record = [0u8; 12];
        bo.put_u16(&mut record[..2], required_entry.tag);
        bo.put_u16(&mut record[2..4], required_entry.typ);
        bo.put_u32(&mut record[4..8], required_entry.count);
        bo.put_u32(&mut record[8..12], u32::try_from(out.len()).map_err(|_| "MakerNote too large")?);
        out.extend_from_slice(payload);
        if let Some(r) = records.iter_mut().find(|r| r.0 == required_entry.tag) {
            r.1 = record;
        } else {
            records.push((required_entry.tag, record));
        }
    }
    records.sort_by_key(|r| r.0);
    bo.put_u16(&mut out[14..16], count);
    for (i, (_, record)) in records.iter().enumerate() {
        out[16 + i * 12..28 + i * 12].copy_from_slice(record);
    }
    out[16 + records.len() * 12..20 + records.len() * 12].fill(0);
    Ok(out)
}

fn uuid_v4_upper() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    // xorshift seeded from time + pid; good enough for a photo UUID.
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15)
        ^ (std::process::id() as u64).wrapping_mul(0x2545f4914f6cdd1d);
    let mut s = seed | 1;
    let mut next = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    let mut b = [0u8; 16];
    for chunk in b.chunks_mut(8) {
        chunk.copy_from_slice(&next().to_be_bytes());
    }
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
        b[14], b[15]
    )
}

// ---------------------------------------------------------------------------
// TIFF surgery: insert a MakerNote (tag 0x927c) into the ExifIFD
// ---------------------------------------------------------------------------

/// Parse `(DateTime, OffsetTime)` from an Exif item payload.
fn exif_datetime(exif: &[u8]) -> Option<(String, String)> {
    let tiff = tiff_slice(exif)?;
    let (bo, ifd0) = tiff_header(&tiff)?;
    let datetime = find_ascii_tag(&tiff, bo, ifd0, 0x0132)?;
    let offset = find_exif_ascii_tag(&tiff, bo, ifd0, 0x9011).unwrap_or_else(|| "+00:00".into());
    Some((datetime, offset))
}

/// Exif item payload → TIFF bytes (skip the 4-byte offset prefix + "Exif\0\0").
fn tiff_slice(exif: &[u8]) -> Option<Vec<u8>> {
    let start = exif_prefix_len(exif).ok()?;
    Some(exif[start..].to_vec())
}

#[derive(Clone, Copy)]
struct Bo(bool); // true = big endian

impl Bo {
    fn u16(self, b: &[u8]) -> u16 {
        if self.0 {
            u16::from_be_bytes([b[0], b[1]])
        } else {
            u16::from_le_bytes([b[0], b[1]])
        }
    }
    fn u32(self, b: &[u8]) -> u32 {
        if self.0 {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        }
    }
    fn put_u16(self, out: &mut [u8], v: u16) {
        let b = if self.0 {
            v.to_be_bytes()
        } else {
            v.to_le_bytes()
        };
        out.copy_from_slice(&b);
    }
    fn put_u32(self, out: &mut [u8], v: u32) {
        let b = if self.0 {
            v.to_be_bytes()
        } else {
            v.to_le_bytes()
        };
        out.copy_from_slice(&b);
    }
}

fn tiff_header(tiff: &[u8]) -> Option<(Bo, u32)> {
    if tiff.len() < 8 {
        return None;
    }
    let bo = match &tiff[0..2] {
        b"MM" => Bo(true),
        b"II" => Bo(false),
        _ => return None,
    };
    if bo.u16(&tiff[2..4]) != 42 {
        return None;
    }
    Some((bo, bo.u32(&tiff[4..8])))
}

/// Byte size of a TIFF field type.
fn type_size(t: u16) -> Option<u64> {
    match t {
        1 | 2 | 6 | 7 => Some(1),
        3 | 8 => Some(2),
        4 | 9 | 11 => Some(4),
        5 | 10 | 12 | 16 | 17 => Some(8),
        // IFD/IFD8 directory pointers require recursive offset relocation.
        // They are not ordinary numeric payloads supported by this writer.
        13 | 18 => None,
        _ => None,
    }
}

struct IfdEntry {
    tag: u16,
    typ: u16,
    count: u32,
    /// Absolute offset of the 4-byte value/offset field within the TIFF.
    value_field_pos: usize,
    /// Offset value (into TIFF) when the payload doesn't fit inline.
    payload_offset: Option<u32>,
}

fn read_ifd(tiff: &[u8], bo: Bo, ifd_off: u32) -> Option<(Vec<IfdEntry>, u32)> {
    let base = ifd_off as usize;
    let entries_start = base.checked_add(2)?;
    if entries_start > tiff.len() {
        return None;
    }
    let count = bo.u16(&tiff[base..entries_start]) as usize;
    let directory_end = entries_start.checked_add(count.checked_mul(12)?)?.checked_add(4)?;
    if directory_end > tiff.len() {
        return None;
    }
    let mut entries = Vec::with_capacity(count);
    for i in 0..count {
        let e = entries_start + i * 12;
        let tag = bo.u16(&tiff[e..e + 2]);
        let typ = bo.u16(&tiff[e + 2..e + 4]);
        let cnt = bo.u32(&tiff[e + 4..e + 8]);
        let value_field_pos = e + 8;
        let inline_capacity = 4u64;
        let payload_offset = type_size(typ).and_then(|ts| {
            if ts.saturating_mul(cnt as u64) > inline_capacity {
                Some(bo.u32(&tiff[e + 8..e + 12]))
            } else {
                None
            }
        });
        entries.push(IfdEntry {
            tag,
            typ,
            count: cnt,
            value_field_pos,
            payload_offset,
        });
    }
    let next = bo.u32(&tiff[entries_start + count * 12..entries_start + count * 12 + 4]);
    Some((entries, next))
}

fn read_ascii(tiff: &[u8], _bo: Bo, e: &IfdEntry) -> Option<String> {
    let cnt = e.count as usize;
    let bytes = if let Some(off) = e.payload_offset {
        let o = off as usize;
        if o + cnt > tiff.len() {
            return None;
        }
        &tiff[o..o + cnt]
    } else {
        if e.value_field_pos + cnt > tiff.len() {
            return None;
        }
        &tiff[e.value_field_pos..e.value_field_pos + cnt]
    };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    Some(String::from_utf8_lossy(&bytes[..end]).to_string())
}

fn find_ascii_tag(tiff: &[u8], bo: Bo, ifd_off: u32, tag: u16) -> Option<String> {
    let (entries, _) = read_ifd(tiff, bo, ifd_off)?;
    entries
        .iter()
        .find(|e| e.tag == tag)
        .and_then(|e| read_ascii(tiff, bo, e))
}

fn find_exif_ascii_tag(tiff: &[u8], bo: Bo, ifd0: u32, tag: u16) -> Option<String> {
    let (entries, _) = read_ifd(tiff, bo, ifd0)?;
    let exif_ifd = entries
        .iter()
        .find(|e| e.tag == 0x8769)
        .map(|e| bo.u32(&tiff[e.value_field_pos..e.value_field_pos + 4]))?;
    find_ascii_tag(tiff, bo, exif_ifd, tag)
}

fn exif_prefix_len(exif: &[u8]) -> Result<usize, String> {
    let offset = u32::from_be_bytes(exif.get(..4).ok_or("Exif item too short")?.try_into().unwrap());
    let prefix = 4usize.checked_add(offset as usize).ok_or("Exif offset overflow")?;
    if exif.get(prefix..).filter(|t| t.len() >= 8).is_none() {
        return Err("Exif TIFF offset out of bounds".into());
    }
    Ok(prefix)
}

fn entry_bytes<'a>(data: &'a [u8], entry: &IfdEntry) -> Option<&'a [u8]> {
    let len = usize::try_from(type_size(entry.typ)?.checked_mul(entry.count as u64)?).ok()?;
    let start = entry.payload_offset.map(|v| v as usize).unwrap_or(entry.value_field_pos);
    data.get(start..start.checked_add(len)?)
}

fn exif_directory(tiff: &[u8], bo: Bo, ifd0: u32) -> Result<(usize, Vec<IfdEntry>, u32), String> {
    let (entries, _) = read_ifd(tiff, bo, ifd0).ok_or("bad IFD0")?;
    let pointer = entries.iter().find(|e| e.tag == 0x8769 && e.typ == 4 && e.count == 1)
        .ok_or("no valid ExifIFD pointer")?;
    let offset = bo.u32(&tiff[pointer.value_field_pos..pointer.value_field_pos + 4]);
    let (entries, next) = read_ifd(tiff, bo, offset).ok_or("bad ExifIFD")?;
    Ok((pointer.value_field_pos, entries, next))
}

/// Preserve original capture EXIF for an upright, clean src.image output.
/// Only rendering-dependent fields change; MakerNote is replaced by the portrait
/// stage afterwards. Never relocate opaque camera/GPS payloads.
pub(crate) fn restore_capture_exif(
    original: &[u8], rendered: &[u8], width: u32, height: u32,
) -> Result<Vec<u8>, String> {
    let mut output = normalize_primary_orientation(original)?;
    let prefix = exif_prefix_len(&output)?;
    let (bo, ifd0) = tiff_header(&output[prefix..]).ok_or("bad TIFF header")?;
    let (entries, _) = read_ifd(&output[prefix..], bo, ifd0).ok_or("bad IFD0")?;
    for entry in &entries {
        let value = match entry.tag { 0x0100 => width, 0x0101 => height, _ => continue };
        if entry.count != 1 || !matches!(entry.typ, 3 | 4) {
            return Err("invalid primary EXIF dimension field".into());
        }
        // LONG fits both old SHORT dimensions and arbitrary output dimensions.
        let pos = prefix + entry.value_field_pos;
        bo.put_u16(&mut output[pos - 6..pos - 4], 4);
        bo.put_u32(&mut output[pos..pos + 4], value);
    }
    // The original IFD1 JPEG may show the watermark/old crop and orientation.
    // Unlink it rather than copying a stale preview into the clean output.
    let next = prefix + ifd0 as usize + 2 + entries.len() * 12;
    bo.put_u32(&mut output[next..next + 4], 0);
    for (tag, value) in [(0xa002, width), (0xa003, height)] {
        let mut bytes = [0; 4];
        bo.put_u32(&mut bytes, value);
        output = upsert_exif_field(&output, tag, 4, 1, &bytes)?;
    }
    // ColorSpace describes the rendered image, not the original watermarked
    // primary. Keep the base writer's value (or Uncalibrated if absent).
    let color = if rendered.is_empty() {
        65535
    } else {
        let rp = exif_prefix_len(rendered)?;
        let rt = &rendered[rp..];
        let (rb, ri) = tiff_header(rt).ok_or("bad rendered TIFF header")?;
        exif_directory(rt, rb, ri).ok().and_then(|(_, es, _)| {
            es.iter().find(|e| e.tag == 0xa001 && e.typ == 3 && e.count == 1)
                .map(|e| rb.u16(&rt[e.value_field_pos..e.value_field_pos + 2]))
        }).unwrap_or(65535)
    };
    let mut bytes = [0; 2];
    bo.put_u16(&mut bytes, color);
    upsert_exif_field(&output, 0xa001, 3, 1, &bytes)
}

/// Normalize only the primary IFD0 orientation after pixels have been oriented.
/// Leave thumbnail orientation and all offsets intact. An absent tag is Normal.
pub(crate) fn normalize_primary_orientation(exif: &[u8]) -> Result<Vec<u8>, String> {
    let prefix = exif_prefix_len(exif)?;
    let tiff = &exif[prefix..];
    let (bo, ifd0) = tiff_header(tiff).ok_or("bad TIFF header")?;
    let mut output = exif.to_vec();
    if ifd0 == 0 {
        return Ok(output);
    }
    let (entries, _) = read_ifd(tiff, bo, ifd0).ok_or("bad IFD0")?;
    for entry in entries.iter().filter(|e| e.tag == 0x0112) {
        if entry.count != 1 || !matches!(entry.typ, 3 | 4) {
            return Err("invalid primary EXIF Orientation field".into());
        }
        let pos = prefix + entry.value_field_pos;
        if entry.typ == 3 {
            bo.put_u16(&mut output[pos..pos + 2], 1);
        } else {
            bo.put_u32(&mut output[pos..pos + 4], 1);
        }
    }
    Ok(output)
}

/// EXIF CustomRendered is SHORT/count 1. Value 9 follows the Swift reference;
/// its Apple-specific meaning still requires device validation. Append a new
/// directory when absent, leaving all TIFF payload/thumbnail/GPS offsets intact.
pub(crate) fn set_portrait_custom_rendered(exif: &[u8]) -> Result<Vec<u8>, String> {
    let prefix = exif_prefix_len(exif)?;
    let (bo, _) = tiff_header(&exif[prefix..]).ok_or("bad TIFF header")?;
    let mut value = [0; 2];
    bo.put_u16(&mut value, 9);
    upsert_exif_field(exif, 0xa401, 3, 1, &value)
}

/// Append payloads/directories rather than shifting TIFF data: MakerNotes,
/// thumbnails, GPS and other IFDs keep their original offset bases.
pub(crate) fn inject_maker_note(exif: &[u8], maker_note: &[u8]) -> Result<Vec<u8>, String> {
    let count = u32::try_from(maker_note.len()).map_err(|_| "MakerNote too large")?;
    upsert_exif_field(exif, 0x927c, 7, count, maker_note)
}

fn upsert_exif_field(exif: &[u8], tag: u16, typ: u16, count: u32, value: &[u8]) -> Result<Vec<u8>, String> {
    let prefix = exif_prefix_len(exif)?;
    let tiff = &exif[prefix..];
    let (bo, ifd0) = tiff_header(tiff).ok_or("bad TIFF header")?;
    let (pointer, entries, next) = exif_directory(tiff, bo, ifd0)?;
    for (i, e) in entries.iter().enumerate() {
        if entry_bytes(tiff, e).is_none() {
            return Err(format!(
                "invalid Exif entry: tag {:#06x} type {} count {} value_field {:?} (entry_bytes unreadable, tiff len {})",
                e.tag, e.typ, e.count, &tiff[e.value_field_pos..e.value_field_pos + 4], tiff.len()
            ));
        }
        if entries[..i].iter().any(|previous| previous.tag == e.tag) {
            return Err(format!(
                "duplicate Exif tag {:#06x} (entry {})", e.tag, i
            ));
        }
    }
    let mut patched = tiff.to_vec();
    let mut record = [0u8; 12];
    bo.put_u16(&mut record[..2], tag);
    bo.put_u16(&mut record[2..4], typ);
    bo.put_u32(&mut record[4..8], count);
    if value.len() <= 4 {
        record[8..8 + value.len()].copy_from_slice(value);
    } else {
        if patched.len() % 2 != 0 { patched.push(0); }
        let offset = u32::try_from(patched.len()).map_err(|_| "TIFF too large")?;
        bo.put_u32(&mut record[8..12], offset);
        patched.extend_from_slice(value);
    }
    if let Some(e) = entries.iter().find(|e| e.tag == tag) {
        patched[e.value_field_pos - 8..e.value_field_pos + 4].copy_from_slice(&record);
    } else {
        let count = u16::try_from(entries.len() + 1).map_err(|_| "too many Exif entries")?;
        if patched.len() % 2 != 0 { patched.push(0); }
        let offset = u32::try_from(patched.len()).map_err(|_| "TIFF too large")?;
        bo.put_u32(&mut patched[pointer..pointer + 4], offset);
        let mut records: Vec<(u16, [u8; 12])> = entries.iter().map(|e| {
            (e.tag, tiff[e.value_field_pos - 8..e.value_field_pos + 4].try_into().unwrap())
        }).collect();
        records.push((tag, record));
        records.sort_by_key(|r| r.0);
        let mut directory = vec![0; 2 + records.len() * 12 + 4];
        bo.put_u16(&mut directory[..2], count);
        for (i, (_, record)) in records.iter().enumerate() {
            directory[2 + i * 12..14 + i * 12].copy_from_slice(record);
        }
        let end = directory.len();
        bo.put_u32(&mut directory[end - 4..], next);
        patched.extend_from_slice(&directory);
    }
    let mut out = exif[..prefix].to_vec();
    out.extend_from_slice(&patched);
    Ok(out)
}

/// pub(crate) accessor for styles_native.
pub(crate) fn max_group_id_pub(data: &[u8], meta: &isobmff::BoxHeader) -> Option<u32> {
    max_group_id(data, meta)
}

/// Minimal manifest-entry parse for callers that only need (name, offset,
/// length) from the tail JSON array.
pub(crate) struct TailEntrySpec {
    pub(crate) name: String,
    pub(crate) offset: u64,
    pub(crate) length: u64,
}
pub(crate) fn parse_manifest_entries(
    _data: &[u8],
    json_start: usize,
    json_end: usize,
) -> Option<Vec<TailEntrySpec>> {
    let text = std::str::from_utf8(&_data[json_start..=json_end]).ok()?;
    let mut out = Vec::new();
    for obj in text.split("{").skip(1) {
        let end = obj.find('}')?;
        let body = &obj[..end];
        let mut name = None;
        let mut offset = None;
        let mut length = None;
        for kv in body.split(',') {
            let kv = kv.trim();
            if let Some(v) = kv.strip_prefix("\"name\":") {
                name = Some(v.trim_matches('"').to_string());
            } else if let Some(v) = kv.strip_prefix("\"offset\":") {
                offset = v.parse().ok();
            } else if let Some(v) = kv.strip_prefix("\"length\":") {
                length = v.parse().ok();
            }
        }
        if let (Some(n), Some(o), Some(l)) = (name, offset, length) {
            out.push(TailEntrySpec {
                name: n,
                offset: o,
                length: l,
            });
        }
    }
    Some(out)
}

/// pub(crate) accessor for styles_native (styles-stage matte XMP sidecar).
pub(crate) fn matte_xmp_pub() -> Vec<u8> {
    build_matte_xmp()
}

/// Highest grpl/altr group_id in the file (to keep new item ids clear).
fn max_group_id(data: &[u8], meta: &isobmff::BoxHeader) -> Option<u32> {
    let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.box_start + meta.size);
    let grpl = kids.iter().find(|b| &b.btype == b"grpl")?;
    let mut max_id = 0u32;
    for sub in isobmff::parse_boxes(data, grpl.data_start, grpl.data_end) {
        if &sub.btype == b"altr" {
            // altr: 4 bytes version/flags then group_id (u32)
            let v = &data[sub.data_start..sub.data_end];
            if v.len() >= 8 {
                max_id = max_id.max(u32::from_be_bytes([v[4], v[5], v[6], v[7]]));
            }
        }
    }
    Some(max_id)
}

/// Re-export check helper used by main.rs.
#[allow(dead_code)]
pub fn describe() -> &'static str {
    "scaffold: R3b scaffold-equivalent writer (no pixel re-encode)"
}
