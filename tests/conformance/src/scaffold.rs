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

use xdremux_core::isobmff::{
    self, IlocEntry, IpmaEntry, IrefEntry, ParsedMeta,
};

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
    let std_meta =
        isobmff::parse_source_meta(standard).map_err(|e| format!("meta parse: {e}"))?;
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
                eprintln!("ispe idx={} len={} head={:02x?}", p.index, p.raw.len(), &p.raw[..p.raw.len().min(20)]);
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
    let x265_matte = |w: u32, h: u32, use_420: bool, chroma: u8| -> Result<(Vec<u8>, Vec<u8>), String> {
        let pixels = vec![0u8; (w * h) as usize];
        let refs: Vec<&[u8]> = vec![&pixels];
        let stream = xdremux_core::hevc::x265_encode_tiles(&refs, w, h, 1, use_420)
            .map_err(|e| format!("matte HEVC encode: {e}"))?
            .into_iter().next().ok_or("matte encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, chroma)
            .ok_or("matte hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        Ok((xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc))
    };
    let (matte_stream, matte_hvcc) = if let Ok(raw_path) = std::env::var("XSCAFFOLD_MATTE_RAW") {
        // Real matte bitmap (raw gray8, matte_w x matte_h), e.g. from the
        // `sky-matte` subcommand's SegFormer output.
        let raw = std::fs::read(&raw_path).map_err(|e| format!("matte raw: {e}"))?;
        if raw.len() != (matte_w * matte_h) as usize {
            return Err(format!(
                "matte raw size {} != {}x{}", raw.len(), matte_w, matte_h
            ));
        }
        let refs: Vec<&[u8]> = vec![&raw];
        let stream = xdremux_core::hevc::x265_encode_tiles(&refs, matte_w, matte_h, 1, false)
            .map_err(|e| format!("matte HEVC encode: {e}"))?
            .into_iter().next().ok_or("matte encode produced no stream")?;
        let hvcc = xdremux_core::hevc::extract_hvcc_config_with_chroma(&stream, 0)
            .ok_or("matte hvcC extraction failed")?;
        let idr = xdremux_core::hevc::drop_parameter_nals(&stream);
        (xdremux_core::hevc::hevc_byte_stream_to_length_prefixed(&idr), hvcc)
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
    let exif_payload = item_payload(standard, &std_meta, exif_item.item_id)
        .ok_or("Exif item payload missing")?;
    let (datetime, offset_time) = exif_datetime(&exif_payload)
        .unwrap_or_else(|| ("1970:01:01 00:00:00".to_string(), "+00:00".to_string()));
    let dates_xmp = build_dates_xmp(&datetime, &offset_time);
    let matte_xmp = build_matte_xmp();

    // ---- 4. Exif rewrite: inject Apple MakerNote ------------------------
    let maker_note = build_maker_note();
    let new_exif_payload = inject_maker_note(&exif_payload, &maker_note)
        .map_err(|e| format!("Exif MakerNote injection: {e}"))?;

    // ---- 5. New item IDs -----------------------------------------------
    let mut next_id = std_meta
        .items
        .iter()
        .map(|i| i.item_id)
        .max()
        .unwrap_or(1)
        + 1;
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
    let mut add_prop = |raw: Vec<u8>, appended: &mut Vec<NewProp>, next_index: &mut u32| -> u32 {
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

    let std_mdat_payload =
        standard[std_mdat_hdr.data_start..std_mdat_hdr.data_end].to_vec();
    let mut appended_mdat = Vec::new();
    let exif_rel_off = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&new_exif_payload);
    let matte_rel_off = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&matte_stream);

    // ---- 11. ipco rebuild ------------------------------------------------
    let mut new_ipco: Vec<u8> = std_meta
        .props
        .iter()
        .flat_map(|p| p.raw.clone())
        .collect();
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
        0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30, 0xd8, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x09, 0x0b, 0x09, 0x51, 0x37, 0x51, 0x33, 0x51, 0x34, 0x51, 0x30, 0x51, 0x35, 0x51, 0x31, 0x51, 0x36, 0x51, 0x32, 0x10, 0x00, 0x10, 0x01, 0x10, 0x04, 0x08, 0x19, 0x1b, 0x1d, 0x1f, 0x21, 0x23, 0x25, 0x27, 0x29, 0x2b, 0x2d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f,
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
    if exif.len() < 12 {
        return None;
    }
    let off = u32::from_be_bytes([exif[0], exif[1], exif[2], exif[3]]) as usize;
    let start = 4 + off;
    if start + 8 > exif.len() {
        return None;
    }
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
        let b = if self.0 { v.to_be_bytes() } else { v.to_le_bytes() };
        out.copy_from_slice(&b);
    }
    fn put_u32(self, out: &mut [u8], v: u32) {
        let b = if self.0 { v.to_be_bytes() } else { v.to_le_bytes() };
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
        5 | 10 | 12 => Some(8),
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
    if base + 2 > tiff.len() {
        return None;
    }
    let count = bo.u16(&tiff[base..base + 2]) as usize;
    let entries_start = base + 2;
    if entries_start + count * 12 + 4 > tiff.len() {
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
        let payload_offset = type_size(typ)
            .and_then(|ts| {
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

/// Insert the Apple MakerNote (tag 0x927c) into the ExifIFD of an Exif item
/// payload, fixing every offset that points past the insertion point.
pub(crate) fn inject_maker_note(exif: &[u8], maker_note: &[u8]) -> Result<Vec<u8>, String> {
    let prefix_len = 4 + u32::from_be_bytes([exif[0], exif[1], exif[2], exif[3]]) as usize;
    if exif.len() < prefix_len + 8 {
        return Err("Exif item too short".into());
    }
    let tiff = exif[prefix_len..].to_vec();
    let (bo, ifd0_off) = tiff_header(&tiff).ok_or("bad TIFF header")?;

    let (ifd0_entries, _) = read_ifd(&tiff, bo, ifd0_off).ok_or("bad IFD0")?;
    let exif_ifd_off = ifd0_entries
        .iter()
        .find(|e| e.tag == 0x8769)
        .map(|e| bo.u32(&tiff[e.value_field_pos..e.value_field_pos + 4]))
        .ok_or("no ExifIFD pointer")?;
    let (exif_entries, _) = read_ifd(&tiff, bo, exif_ifd_off).ok_or("bad ExifIFD")?;
    if let Some(existing) = exif_entries.iter().find(|e| e.tag == 0x927c) {
        // The source camera's own MakerNote (e.g. OPPO's JSON blob) — replace
        // it with the Apple MakerNote: patch the entry in place and append
        // the new payload at the end of the TIFF (old bytes become dead
        // space). No insertion, so no offset fixups are needed.
        let mut patched = tiff.clone();
        let mn_off = patched.len() as u32;
        let vp = existing.value_field_pos;
        bo.put_u16(&mut patched[vp - 6..vp - 4], 7); // type = undefined
        bo.put_u32(&mut patched[vp - 4..vp], maker_note.len() as u32);
        bo.put_u32(&mut patched[vp..vp + 4], mn_off);
        patched.extend_from_slice(maker_note);
        let mut result = exif[..prefix_len].to_vec();
        result.extend_from_slice(&patched);
        return Ok(result);
    }

    // Insertion point: inside ExifIFD, at the sorted position for 0x927c.
    let insert_entry_idx = exif_entries
        .iter()
        .position(|e| e.tag > 0x927c)
        .unwrap_or(exif_entries.len());
    let insert_pos = exif_ifd_off as usize + 2 + insert_entry_idx * 12;

    // MakerNote goes at the end of the (shifted) TIFF.
    let maker_note_off = tiff.len() as u32 + 12; // +12 for the inserted entry

    // Build the new entry bytes.
    let mut new_entry = vec![0u8; 12];
    bo.put_u16(&mut new_entry[0..2], 0x927c);
    bo.put_u16(&mut new_entry[2..4], 7); // undefined
    bo.put_u32(&mut new_entry[4..8], maker_note.len() as u32);
    bo.put_u32(&mut new_entry[8..12], maker_note_off);

    // Collect all IFD offsets to fix. IFD0 + ExifIFD + GPS IFD + IFD1 chain.
    let mut ifd_offsets = vec![ifd0_off, exif_ifd_off];
    if let Some(gps) = ifd0_entries.iter().find(|e| e.tag == 0x8825) {
        ifd_offsets.push(bo.u32(&tiff[gps.value_field_pos..gps.value_field_pos + 4]));
    }
    let (_, ifd1_off) = read_ifd(&tiff, bo, ifd0_off).unwrap();
    if ifd1_off != 0 {
        ifd_offsets.push(ifd1_off);
    }

    let mut patched = tiff.clone();

    // 1. Bump ExifIFD entry count.
    let cnt_pos = exif_ifd_off as usize;
    let old_count = bo.u16(&patched[cnt_pos..cnt_pos + 2]);
    bo.put_u16(&mut patched[cnt_pos..cnt_pos + 2], old_count + 1);

    // 2. Fix every offset >= insert_pos by +12.
    let shift_after = insert_pos as u32;
    for &ioff in &ifd_offsets {
        let (entries, next_pos) = match read_ifd(&tiff, bo, ioff) {
            Some(v) => v,
            None => continue,
        };
        for e in &entries {
            // Pointer tags (IFD offsets stored in the value field).
            if matches!(e.tag, 0x8769 | 0x8825 | 0x014a) && e.typ == 4 {
                let v = bo.u32(&tiff[e.value_field_pos..e.value_field_pos + 4]);
                if v >= shift_after {
                    bo.put_u32(&mut patched[e.value_field_pos..e.value_field_pos + 4], v + 12);
                }
                continue;
            }
            if let Some(po) = e.payload_offset {
                if po >= shift_after {
                    bo.put_u32(&mut patched[e.value_field_pos..e.value_field_pos + 4], po + 12);
                }
            }
        }
        // next-IFD pointer.
        let np = ioff as usize + 2 + entries.len() * 12;
        if next_pos >= shift_after && next_pos != 0 {
            bo.put_u32(&mut patched[np..np + 4], next_pos + 12);
        }
    }

    // 3. Splice: patched[..insert_pos] + new_entry + patched[insert_pos..] + maker_note.
    let mut out = Vec::with_capacity(patched.len() + 12 + maker_note.len());
    out.extend_from_slice(&patched[..insert_pos]);
    out.extend_from_slice(&new_entry);
    out.extend_from_slice(&patched[insert_pos..]);
    out.extend_from_slice(maker_note);

    // Reassemble the Exif item payload with its original prefix.
    let mut result = exif[..prefix_len].to_vec();
    result.extend_from_slice(&out);
    Ok(result)
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
            out.push(TailEntrySpec { name: n, offset: o, length: l });
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
