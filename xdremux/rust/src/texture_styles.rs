//! Photographic Styles 3 — inject a Standard `texture_styles` item into an
//! existing HEIC so Photos offers texture/grain editing on it.
//!
//! The item is a `uri metadata` item with content type
//! `tag:apple.com,2026:photo:metadata:texture_styles`, a `metadata` item name,
//! a `cdsc` reference to the primary image, and a Standard textureInfo bplist
//! payload (Preset=Standard / CaptureType=LF / CaptureMode=Still /
//! PortTypeBack / HardwareModel=iPhone 18 Pro / TextureStylePeopleDataVersion=3 /
//! FilmGrainSeed). Mirrors the native Apple capture contract.

use crate::isobmff;
use crate::styles_bplist::BplistWriter;

pub const TEXTURE_STYLES_URI: &str = "tag:apple.com,2026:photo:metadata:texture_styles";

/// Build the Standard textureInfo bplist payload.
pub fn texture_info_payload(grain_seed: u64) -> Vec<u8> {
    let mut w = BplistWriter::new();
    let k_preset = w.add_str("Preset");
    let v_preset = w.add_str("Standard");
    let k_ctype = w.add_str("CaptureType");
    let v_ctype = w.add_str("LF");
    let k_cmode = w.add_str("CaptureMode");
    let v_cmode = w.add_str("Still");
    let k_ptype = w.add_str("PortType");
    let v_ptype = w.add_str("PortTypeBack");
    let k_hw = w.add_str("HardwareModel");
    let v_hw = w.add_str("iPhone 18 Pro");
    let k_pdv = w.add_str("TextureStylePeopleDataVersion");
    let v_pdv = w.add_int(3);
    let k_gs = w.add_str("FilmGrainSeed");
    let v_gs = w.add_int(grain_seed);
    let top = w.add_dict(&[
        (k_preset, v_preset),
        (k_ctype, v_ctype),
        (k_cmode, v_cmode),
        (k_ptype, v_ptype),
        (k_hw, v_hw),
        (k_pdv, v_pdv),
        (k_gs, v_gs),
    ]);
    w.finish(top)
}

fn make_box(btype: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + payload.len());
    out.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    out.extend_from_slice(btype);
    out.extend_from_slice(payload);
    out
}

/// Find an item's `ispe` dimensions via ipma association.
fn item_ispe(meta: &isobmff::ParsedMeta, item_id: u32) -> Option<(u32, u32)> {
    let assoc = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == item_id)?;
    assoc.associations.iter().find_map(|(index, _)| {
        meta.props
            .iter()
            .find(|p| p.index == *index && p.ptype == "ispe")
            .and_then(|p| isobmff::ispe_dimensions(&p.raw).ok())
    })
}

fn make_uri_metadata_infe(item_id: u32, uri: &str) -> Vec<u8> {
    // version=2, flags=1, item_id(u16), protection_index(u16), item_type="uri ",
    // item_name="metadata\0", content_type=<uri>\0
    let mut payload = vec![2u8, 0, 0, 1];
    payload.extend_from_slice(&(item_id as u16).to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(b"uri ");
    payload.extend_from_slice(b"metadata\0");
    payload.extend_from_slice(uri.as_bytes());
    payload.push(0);
    make_box(b"infe", &payload)
}

/// Inject a `uri metadata` item with the given URI and payload into `data`.
pub fn inject_uri_metadata_item(
    data: &[u8],
    uri: &str,
    payload: &[u8],
) -> Result<Vec<u8>, String> {
    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta_box = top
        .iter()
        .find(|b| b.btype == *b"meta")
        .ok_or("meta box not found")?;
    let content_start = meta_box.data_start + 4; // meta FullBox: + version/flags
    let content_end = meta_box.box_start + meta_box.size as usize;
    let children = isobmff::parse_boxes(data, content_start, content_end);

    let iinf = children
        .iter()
        .find(|b| b.btype == *b"iinf")
        .ok_or("iinf not found")?;
    let iloc = children
        .iter()
        .find(|b| b.btype == *b"iloc")
        .ok_or("iloc not found")?;
    let iref = children.iter().find(|b| b.btype == *b"iref");
    let pitm = children
        .iter()
        .find(|b| b.btype == *b"pitm")
        .ok_or("pitm not found")?;

    // The texture_styles cdsc content-describes the MAIN IMAGE (a grid item).
    // Our own outputs can carry primary_id=0, so resolve the largest-ispe grid
    // item instead, falling back to pitm primary_id when it names a real item.
    let parsed = isobmff::parse_source_meta(data)?;
    let pitm_id = isobmff::parse_pitm(data, pitm);
    let id_exists = |id: u32| parsed.items.iter().any(|i| i.item_id == id);
    let main_image_id = if pitm_id != 0 && id_exists(pitm_id) {
        pitm_id
    } else {
        parsed
            .items
            .iter()
            .filter(|i| i.itype == "grid")
            .max_by_key(|i| {
                let (w, h) = item_ispe(&parsed, i.item_id).unwrap_or((0, 0));
                (w as u64) * (h as u64)
            })
            .map(|i| i.item_id)
            .unwrap_or(pitm_id)
    };
    let primary_id = main_image_id;

    // Parse iinf entries (keep full boxes for re-emit) and find next free id.
    let iinf_items = isobmff::parse_iinf(data, iinf)?;
    let next_id = iinf_items
        .iter()
        .map(|i| i.item_id)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    let iinf_version = data[iinf.data_start];
    let entry_count_pos = iinf.data_start + 4;
    let count_size = if iinf_version == 0 { 2 } else { 4 };

    let new_infe = make_uri_metadata_infe(next_id, uri);

    // Rebuild iinf body: version/flags + (count+1) + existing infe boxes + new infe.
    let mut new_iinf_body = data[iinf.data_start..iinf.data_start + 4].to_vec();
    let entry_count_end = entry_count_pos + count_size;
    new_iinf_body.extend_from_slice(&(iinf_items.len() as u64 + 1).to_be_bytes()[8 - count_size..]);
    new_iinf_body.extend_from_slice(&data[entry_count_end..(iinf.box_start + iinf.size)]);
    new_iinf_body.extend_from_slice(&new_infe);
    let new_iinf = make_box(b"iinf", &new_iinf_body);
    let d_iinf = new_iinf.len() as i64 - iinf.size as i64;

    // Rebuild iref: append cdsc entry. Native Apple captures reference the
    // primary grid AND the tmap item (texture_styles applies to the composed
    // grid + its tile map), so mirror that contract when a tmap exists.
    let tmap_id = parsed.items.iter().find(|i| i.itype == "tmap").map(|i| i.item_id);
    let mut to_ids: Vec<u32> = vec![primary_id];
    if let Some(tid) = tmap_id {
        if tid != primary_id {
            to_ids.push(tid);
        }
    }
    let mut d_iref: i64 = 0;
    let new_iref = if let Some(iref_box) = iref {
        let mut body = data[iref_box.data_start..(iref_box.box_start + iref_box.size)].to_vec();
        let id_size_4 = body[0] >= 1;
        let write_id = |v: u32| {
            if id_size_4 {
                v.to_be_bytes().to_vec()
            } else {
                (v as u16).to_be_bytes().to_vec()
            }
        };
        let mut cdsc = Vec::new();
        let mut cdsc_payload = Vec::new();
        cdsc_payload.extend_from_slice(&write_id(next_id));
        cdsc_payload.extend_from_slice(&(to_ids.len() as u16).to_be_bytes());
        for id in &to_ids {
            cdsc_payload.extend_from_slice(&write_id(*id));
        }
        cdsc.extend_from_slice(&((8 + cdsc_payload.len()) as u32).to_be_bytes());
        cdsc.extend_from_slice(b"cdsc");
        cdsc.extend_from_slice(&cdsc_payload);
        body.extend_from_slice(&cdsc);
        let b = make_box(b"iref", &body);
        d_iref = b.len() as i64 - iref_box.size as i64;
        b
    } else {
        make_box(b"iref", &[])
    };

    // Rebuild iloc: bump construction=0 extents by delta; append new entry.
    // The payload is placed INSIDE mdat (native Apple captures keep the
    // texture_styles item data within mdat; a trailing extent after mdat is
    // rejected by Photos and leaves the style editor "unavailable").
    let mdat = top
        .iter()
        .find(|b| b.btype == *b"mdat")
        .ok_or("mdat box not found")?;
    let mdat_end = mdat.box_start + mdat.size;
    let iloc_entries = isobmff::parse_iloc(data, iloc)?;
    // Two-pass: the iloc growth (4-byte base fields on every entry + the new
    // entry) must be known before the new entry's payload offset can be
    // computed. Sizes are identical across passes, so pass 1 measures.
    let payload_len = payload.len() as i64;
    let build_entries = |delta_total: i64, payload_abs: u64| -> Vec<isobmff::IlocEntry> {
        let mut v: Vec<isobmff::IlocEntry> = Vec::with_capacity(iloc_entries.len() + 1);
        for mut e in iloc_entries.clone() {
            for ext in e.extents.iter_mut() {
                if (e.construction_method & 0xF) == 0 {
                    let past_mdat = (ext.0 as i64) >= mdat_end as i64;
                    let shift = delta_total + if past_mdat { payload_len } else { 0 };
                    ext.0 = (ext.0 as i64 + shift) as u64;
                }
            }
            v.push(e);
        }
        v.push(isobmff::IlocEntry {
            item_id: next_id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(payload_abs, payload.len() as u64)],
        });
        v
    };
    let probe = isobmff::make_iloc_box(&build_entries(d_iinf + d_iref, 0));
    let d_iloc = probe.len() as i64 - iloc.size as i64;
    let delta_total = d_iinf + d_iref + d_iloc;
    let payload_abs = (mdat_end as i64 + delta_total) as u64;
    let new_iloc = isobmff::make_iloc_box(&build_entries(delta_total, payload_abs));

    // Rebuild meta with the new children.
    let mut new_meta_body = data[meta_box.data_start..content_start].to_vec();
    for child in &children {
        if child.btype == *b"iinf" {
            new_meta_body.extend_from_slice(&new_iinf);
        } else if child.btype == *b"iloc" {
            new_meta_body.extend_from_slice(&new_iloc);
        } else if child.btype == *b"iref" {
            new_meta_body.extend_from_slice(&new_iref);
        } else {
            new_meta_body.extend_from_slice(&data[child.box_start..(child.box_start + child.size)]);
        }
    }
    let new_meta = make_box(b"meta", &new_meta_body);

    // Patch the mdat size so the payload lands inside it.
    let mut mdat_bytes = data[mdat.box_start..mdat_end].to_vec();
    let declared = u32::from_be_bytes([mdat_bytes[0], mdat_bytes[1], mdat_bytes[2], mdat_bytes[3]]);
    let grown = mdat.size as u64 + payload.len() as u64;
    if declared == 1 {
        mdat_bytes[8..16].copy_from_slice(&grown.to_be_bytes());
    } else {
        if grown > u32::MAX as u64 {
            return Err("mdat growth exceeds 32-bit size".into());
        }
        mdat_bytes[0..4].copy_from_slice(&(grown as u32).to_be_bytes());
    }

    let mut out =
        Vec::with_capacity(data.len() + delta_total as usize + payload.len());
    out.extend_from_slice(&data[..meta_box.box_start]);
    out.extend_from_slice(&new_meta);
    out.extend_from_slice(&data[meta_box.box_start + meta_box.size as usize..mdat.box_start]);
    out.extend_from_slice(&mdat_bytes);
    out.extend_from_slice(&payload);
    out.extend_from_slice(&data[mdat_end..]);
    Ok(out)
}

/// Inject a Standard texture_styles item into `data` (an XDRemux converted
/// HEIC). Rebuilds iinf/iloc/iref and shifts absolute (construction=0) iloc
/// extents by the meta growth; idat (construction=1) extents stay relative.
/// Returns the patched file bytes.
pub fn inject_texture_styles(data: &[u8], grain_seed: u64) -> Result<Vec<u8>, String> {
    let payload = texture_info_payload(grain_seed);
    inject_uri_metadata_item(data, TEXTURE_STYLES_URI, &payload)
}
