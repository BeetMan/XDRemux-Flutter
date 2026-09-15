//! Photographic Styles 3 — inject the 12 per-part `2026:photo:aux:semantic*`
//! matte items into an existing converted HEIC.
//!
//! Native iPhone captures always carry twelve 768×576 8-bit HEVC matte items
//! (nose / skin v2 / non-face skin / lips / teeth v2 / person / glasses v2 /
//! eyebrows / tattoo / hands / ears / face skin), each declared with its own
//! `auxC` property and referenced `auxl → [primary, tmap]`. Converted output
//! lacks all of them; this module adds zero-content (black) placeholders with
//! the exact native contract so the PS3 style editor can locate the parts.
//!
//! Container surgery mirrors `texture_styles::inject_texture_styles`: rebuild
//! iinf / iloc / iref / ipma / ipco, grow mdat, shift construction=0 extents.

use crate::hevc::{
    drop_parameter_nals, extract_hvcc_config_with_chroma, hevc_byte_stream_to_length_prefixed,
    x265_encode_tiles,
};
use crate::isobmff;

pub const SEMANTIC_MATTE_URNS: &[&str] = &[
    "tag:apple.com,2026:photo:aux:semanticnosematte",
    "tag:apple.com,2026:photo:aux:semanticskinmattev2",
    "tag:apple.com,2026:photo:aux:semanticnonfaceskinmatte",
    "tag:apple.com,2026:photo:aux:semanticlipsmatte",
    "tag:apple.com,2026:photo:aux:semanticteethmattev2",
    "tag:apple.com,2026:photo:aux:semanticpersonmatte",
    "tag:apple.com,2026:photo:aux:semanticglassesmattev2",
    "tag:apple.com,2026:photo:aux:semanticeyebrowsmatte",
    "tag:apple.com,2026:photo:aux:semantictattoomatte",
    "tag:apple.com,2026:photo:aux:semantichandsmatte",
    "tag:apple.com,2026:photo:aux:semanticearsmatte",
    "tag:apple.com,2026:photo:aux:semanticfaceskinmatte",
];

const MATTE_W: u32 = 768;
const MATTE_H: u32 = 576;

fn make_box(btype: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + payload.len());
    out.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    out.extend_from_slice(btype);
    out.extend_from_slice(payload);
    out
}

/// Encode one zero-content matte and return (length-prefixed HEVC, hvcC).
fn black_matte() -> Result<(Vec<u8>, Vec<u8>), String> {
    let pixels = vec![0u8; (MATTE_W * MATTE_H) as usize];
    let refs: Vec<&[u8]> = vec![&pixels];
    let stream = x265_encode_tiles(&refs, MATTE_W, MATTE_H, 1, false)
        .map_err(|e| format!("matte HEVC encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("matte encode produced no stream")?;
    let hvcc = extract_hvcc_config_with_chroma(&stream, 0)
        .ok_or("matte hvcC extraction failed")?;
    let idr = drop_parameter_nals(&stream);
    Ok((hevc_byte_stream_to_length_prefixed(&idr), hvcc))
}

/// Inject the 12 semantic part-matte items into `data`.
pub fn inject_semantic_mattes(data: &[u8]) -> Result<Vec<u8>, String> {
    if data
        .windows(SEMANTIC_MATTE_URNS[0].len())
        .any(|w| w == SEMANTIC_MATTE_URNS[0].as_bytes())
    {
        return Err("semantic mattes already present".into());
    }

    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta_box = top
        .iter()
        .find(|b| b.btype == *b"meta")
        .ok_or("meta box not found")?;
    let content_start = meta_box.data_start + 4;
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
    let iprp = children.iter().find(|b| b.btype == *b"iprp").ok_or("iprp not found")?;
    let pitm = children
        .iter()
        .find(|b| b.btype == *b"pitm")
        .ok_or("pitm not found")?;

    let parsed = isobmff::parse_source_meta(data)?;
    let pitm_id = isobmff::parse_pitm(data, pitm);
    let id_exists = |id: u32| parsed.items.iter().any(|i| i.item_id == id);
    let primary_id = if pitm_id != 0 && id_exists(pitm_id) {
        pitm_id
    } else {
        parsed
            .items
            .iter()
            .find(|i| i.itype == "grid")
            .map(|i| i.item_id)
            .ok_or("no grid item")?
    };
    let tmap_id = parsed
        .items
        .iter()
        .find(|i| i.itype == "tmap")
        .map(|i| i.item_id);

    // ---- 1. Encode the shared black matte ------------------------------
    let (matte_stream, matte_hvcc) = black_matte()?;
    let n = SEMANTIC_MATTE_URNS.len();

    // ---- 2. New item ids -------------------------------------------------
    let next_id = parsed
        .items
        .iter()
        .map(|i| i.item_id)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    let matte_ids: Vec<u32> = (0..n as u32).map(|i| next_id + i).collect();

    // ---- 3. iinf rebuild --------------------------------------------------
    let iinf_items = isobmff::parse_iinf(data, iinf)?;
    let iinf_version = data[iinf.data_start];
    let entry_count_pos = iinf.data_start + 4;
    let count_size = if iinf_version == 0 { 2 } else { 4 };
    let mut new_iinf_body = data[iinf.data_start..iinf.data_start + 4].to_vec();
    let entry_count_end = entry_count_pos + count_size;
    new_iinf_body
        .extend_from_slice(&(iinf_items.len() as u64 + n as u64).to_be_bytes()[8 - count_size..]);
    new_iinf_body.extend_from_slice(&data[entry_count_end..(iinf.box_start + iinf.size)]);
    for &id in &matte_ids {
        new_iinf_body.extend_from_slice(&isobmff::make_infe_box(id, "hvc1", 1));
    }
    let new_iinf = make_box(b"iinf", &new_iinf_body);
    let d_iinf = new_iinf.len() as i64 - iinf.size as i64;

    // ---- 4. ipco rebuild (shared + per-matte auxC props) ------------------
    let mut next_index = parsed.props.iter().map(|p| p.index).max().unwrap_or(0) + 1;
    let mut new_props: Vec<Vec<u8>> = Vec::new();
    let mut prop = |raw: Vec<u8>, next_index: &mut u32| -> u32 {
        let idx = *next_index;
        *next_index += 1;
        new_props.push(raw);
        idx
    };
    let ispe_idx = prop(isobmff::make_ispe_box(MATTE_W, MATTE_H), &mut next_index);
    let pixi_idx = prop(isobmff::PIXI_MONO8_BOX.to_vec(), &mut next_index);
    let hvcc_idx = prop(make_box(b"hvcC", &matte_hvcc), &mut next_index);
    let auxc_idxs: Vec<u32> = SEMANTIC_MATTE_URNS
        .iter()
        .map(|urn| {
            let mut payload = vec![0u8, 0, 0, 0]; // FullBox version+flags
            payload.extend_from_slice(urn.as_bytes());
            payload.push(0);
            prop(make_box(b"auxC", &payload), &mut next_index)
        })
        .collect();
    let mut new_ipco: Vec<u8> = parsed
        .props
        .iter()
        .flat_map(|p| p.raw.clone())
        .collect();
    for p in &new_props {
        new_ipco.extend_from_slice(p);
    }
    let new_ipco = make_box(b"ipco", &new_ipco);
    // iprp wraps ipco + ipma; rebuild after ipma below.
    let ipco = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end)
        .into_iter()
        .find(|b| b.btype == *b"ipco")
        .ok_or("ipco not found")?;
    let ipma = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end)
        .into_iter()
        .find(|b| b.btype == *b"ipma")
        .ok_or("ipma not found")?;
    let d_ipco = new_ipco.len() as i64 - ipco.size as i64;

    // ---- 5. ipma rebuild --------------------------------------------------
    // Serialize ver0/flags0 (u16 ids, 1-byte assocs). New entries: ispe,
    // pixi, auxC(essential), hvcC(essential) — mirrors the native matte.
    let ipma_ver = data[ipma.data_start];
    let mut ipma_flags = data[ipma.data_start + 3];
    let mut entries = parsed.ipma_entries.clone();
    for (i, &id) in matte_ids.iter().enumerate() {
        entries.push(isobmff::IpmaEntry {
            item_id: id,
            associations: vec![
                (ispe_idx, false),
                (pixi_idx, false),
                (auxc_idxs[i], true),
                (hvcc_idx, true),
            ],
        });
    }
    // 1-byte associations cap the property index at 127; upgrade to 2-byte
    // associations when the new auxC indexes exceed that.
    if auxc_idxs.iter().any(|i| *i > 127) {
        ipma_flags |= 2;
    }
    let mut new_ipma_payload: Vec<u8> = vec![ipma_ver, 0, 0, ipma_flags];
    new_ipma_payload.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for e in &entries {
        new_ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(
            e.item_id,
            &e.associations,
            ipma_flags as u32,
        ));
    }
    let new_ipma = make_box(b"ipma", &new_ipma_payload);
    let new_iprp: Vec<u8> = {
        // keep original iprp children order, swap ipco/ipma
        let mut body: Vec<u8> = Vec::new();
        for child in isobmff::parse_boxes(data, iprp.data_start, iprp.data_end) {
            if child.btype == *b"ipco" {
                body.extend_from_slice(&new_ipco);
            } else if child.btype == *b"ipma" {
                body.extend_from_slice(&new_ipma);
            } else {
                body.extend_from_slice(&data[child.box_start..child.data_end]);
            }
        }
        make_box(b"iprp", &body)
    };
    let d_ipma = new_ipma.len() as i64 - ipma.size as i64;
    let d_iprp = new_iprp.len() as i64 - iprp.size as i64;

    // ---- 6. iref rebuild (12 auxl → [primary, tmap]) ----------------------
    let mut d_iref: i64 = 0;
    let new_iref = if let Some(iref_box) = iref {
        let body = data[iref_box.data_start..(iref_box.box_start + iref_box.size)].to_vec();
        if body[0] != 0 {
            return Err(format!("unsupported iref version {}", body[0]));
        }
        let mut new_body = body.clone();
        for &id in &matte_ids {
            let mut auxl = Vec::new();
            auxl.extend_from_slice(&(id as u16).to_be_bytes());
            // SDR captures have no tmap; the auxl degrades to [primary].
            let targets: Vec<u32> = match tmap_id {
                Some(tid) if tid != primary_id => vec![primary_id, tid],
                _ => vec![primary_id],
            };
            auxl.extend_from_slice(&(targets.len() as u16).to_be_bytes());
            for t in &targets {
                auxl.extend_from_slice(&(*t as u16).to_be_bytes());
            }
            new_body.extend_from_slice(&make_box(b"auxl", &auxl));
        }
        let b = make_box(b"iref", &new_body);
        d_iref = b.len() as i64 - iref_box.size as i64;
        b
    } else {
        make_box(b"iref", &[])
    };

    // ---- 7. iloc rebuild (shift cm0, append 12 entries) -------------------
    let iloc_entries = isobmff::parse_iloc(data, iloc)?;
    let mdat = top
        .iter()
        .find(|b| b.btype == *b"mdat")
        .ok_or("mdat box not found")?;
    let mdat_end = mdat.box_start + mdat.size;
    let payload_len = (matte_stream.len() * n) as i64;
    // Two-pass: measure iloc growth (base fields + 12 new entries) before
    // computing the matte payload offsets.
    let build_entries = |delta_total: i64, payload_abs: u64| -> Vec<isobmff::IlocEntry> {
        let mut v: Vec<isobmff::IlocEntry> = Vec::with_capacity(iloc_entries.len() + n);
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
        for (i, &id) in matte_ids.iter().enumerate() {
            v.push(isobmff::IlocEntry {
                item_id: id,
                construction_method: 0,
                data_reference_index: 0,
                extents: vec![(
                    payload_abs + (i as u64) * matte_stream.len() as u64,
                    matte_stream.len() as u64,
                )],
            });
        }
        v
    };
    let probe = isobmff::make_iloc_box(&build_entries(d_iinf + d_iprp + d_iref, 0));
    let d_iloc = probe.len() as i64 - iloc.size as i64;
    let delta_total = d_iinf + d_iprp + d_iref + d_iloc;
    let payload_abs = (mdat_end as i64 + delta_total) as u64;
    let new_iloc = isobmff::make_iloc_box(&build_entries(delta_total, payload_abs));

    // ---- 8. Assemble -------------------------------------------------------
    let mut new_meta_body = data[meta_box.data_start..content_start].to_vec();
    for child in &children {
        if child.btype == *b"iinf" {
            new_meta_body.extend_from_slice(&new_iinf);
        } else if child.btype == *b"iloc" {
            new_meta_body.extend_from_slice(&new_iloc);
        } else if child.btype == *b"iref" {
            new_meta_body.extend_from_slice(&new_iref);
        } else if child.btype == *b"iprp" {
            new_meta_body.extend_from_slice(&new_iprp);
        } else {
            new_meta_body.extend_from_slice(&data[child.box_start..child.data_end]);
        }
    }
    let new_meta = make_box(b"meta", &new_meta_body);

    // Grow mdat and place the 12 matte payloads inside it.
    let mut mdat_bytes = data[mdat.box_start..mdat_end].to_vec();
    let declared = u32::from_be_bytes([mdat_bytes[0], mdat_bytes[1], mdat_bytes[2], mdat_bytes[3]]);
    let grown = mdat.size as u64 + (matte_stream.len() * n) as u64;
    if declared == 1 {
        mdat_bytes[8..16].copy_from_slice(&grown.to_be_bytes());
    } else {
        if grown > u32::MAX as u64 {
            return Err("mdat growth exceeds 32-bit size".into());
        }
        mdat_bytes[0..4].copy_from_slice(&(grown as u32).to_be_bytes());
    }

    let mut out = Vec::with_capacity(data.len() + delta_total as usize + matte_stream.len() * n);
    out.extend_from_slice(&data[..meta_box.box_start]);
    out.extend_from_slice(&new_meta);
    out.extend_from_slice(&data[meta_box.box_start + meta_box.size as usize..mdat.box_start]);
    out.extend_from_slice(&mdat_bytes);
    for _ in 0..n {
        out.extend_from_slice(&matte_stream);
    }
    out.extend_from_slice(&data[mdat_end..]);
    Ok(out)
}
