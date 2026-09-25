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

/// Encode a face-region mask (the face box filled, everything else black) as
/// a length-prefixed HEVC stream plus its hvcC, using the same encoder path as
/// `black_matte`.
pub fn face_matte(
    w: u32,
    h: u32,
    face_roi: [f64; 4],
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let mut pixels = vec![0u8; (w * h) as usize];
    let (fx, fy, fw, fh) = (
        (face_roi[0] * w as f64) as i64,
        (face_roi[1] * h as f64) as i64,
        (face_roi[2] * w as f64) as i64,
        (face_roi[3] * h as f64) as i64,
    );
    for y in 0..h as i64 {
        for x in 0..w as i64 {
            if x >= fx && x < fx + fw && y >= fy && y < fy + fh {
                pixels[(y * w as i64 + x) as usize] = 255;
            }
        }
    }
    let refs: Vec<&[u8]> = vec![&pixels];
    let stream = x265_encode_tiles(&refs, w, h, 1, false)
        .map_err(|e| format!("face matte HEVC encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("face matte encode produced no stream")?;
    let hvcc = extract_hvcc_config_with_chroma(&stream, 0)
        .ok_or("face matte hvcC extraction failed")?;
    let idr = drop_parameter_nals(&stream);
    Ok((hevc_byte_stream_to_length_prefixed(&idr), hvcc))
}

/// The fsincMattes XMP that names the instance mask. Apple ships this as its
/// own `mime` item beside the mask pixels (item 157/158 in IMG_0004).
fn instance_mask_xmp(key: &str) -> Vec<u8> {
    format!(
        r#"<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:fsincMattes="http://ns.apple.com/fsinc/1.0/">
         <fsincMattes:InstanceMaskReferenceKey>{key}</fsincMattes:InstanceMaskReferenceKey>
         <fsincMattes:FSINCMatteVersion>0</fsincMattes:FSINCMatteVersion>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
"#
    )
    .into_bytes()
}

/// Inject one FSINC instance mask: an `hvc1` item carrying the face-region
/// pixels plus its `mime` XMP declaration. Apple stores them as a pair with
/// no iref and no auxC (items 157/158 in IMG_0004), so the person data's
/// `instanceMaskReferenceKey` finally points at something real.
pub fn inject_instance_mask(
    data: &[u8],
    face_roi: [f64; 4],
    mask_w: u32,
    mask_h: u32,
) -> Result<(Vec<u8>, String), String> {
    // The person data always carries the reference; what must be absent is the
    // XMP declaration that gives the key its mask.
    if data.windows(11).any(|w| w == b"fsincMattes") {
        return Err("instance mask already present".into());
    }
    let key = "FSINCInstanceMask9".to_string();
    let (matte_stream, matte_hvcc) = face_matte(mask_w, mask_h, face_roi)?;

    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta_box = top.iter().find(|b| b.btype == *b"meta").ok_or("meta box not found")?;
    let content_start = meta_box.data_start + 4;
    let content_end = meta_box.box_start + meta_box.size as usize;
    let children = isobmff::parse_boxes(data, content_start, content_end);
    let iinf = children.iter().find(|b| b.btype == *b"iinf").ok_or("iinf not found")?;
    let iloc = children.iter().find(|b| b.btype == *b"iloc").ok_or("iloc not found")?;
    let iprp = children.iter().find(|b| b.btype == *b"iprp").ok_or("iprp not found")?;

    let parsed = isobmff::parse_source_meta(data)?;
    let next_id = parsed.items.iter().map(|i| i.item_id).max().unwrap_or(0) + 1;
    let (mask_id, xmp_id) = (next_id, next_id + 1);

    // ---- iinf: append two entries ---------------------------------------
    let iinf_items = isobmff::parse_iinf(data, iinf)?;
    let iinf_version = data[iinf.data_start];
    let count_size = if iinf_version == 0 { 2 } else { 4 };
    let entry_start = iinf.data_start + 4 + count_size;
    let entry_end = iinf.box_start + iinf.size as usize;
    let mut new_iinf_body = data[iinf.data_start..entry_start].to_vec();
    new_iinf_body[..4].copy_from_slice(&data[iinf.data_start..iinf.data_start + 4]);
    new_iinf_body.truncate(4);
    new_iinf_body
        .extend_from_slice(&(iinf_items.len() as u64 + 2).to_be_bytes()[8 - count_size..]);
    new_iinf_body.extend_from_slice(&data[entry_start..entry_end]);
    // Non-primary items carry the hidden flag (0x1), exactly like Apple's
    // aux items. Without it the mask reads as a displayable image and the
    // decoder refuses the file.
    new_iinf_body.extend_from_slice(&isobmff::make_infe_box(mask_id, "hvc1", 1));
    new_iinf_body.extend_from_slice(&isobmff::make_mime_infe_box_named(xmp_id, 1, ""));
    let new_iinf = make_box(b"iinf", &new_iinf_body);

    // ---- ipco: + ispe + hvcC; ipma: + one entry --------------------------
    let sub = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end);
    let ipco = sub.iter().find(|b| b.btype == *b"ipco").ok_or("ipco not found")?;
    let ipma = sub.iter().find(|b| b.btype == *b"ipma").ok_or("ipma not found")?;
    // Count ipco children by walking bytes: the property indices we append must
    // continue the existing 1-based numbering exactly.
    let mut prop_base = 0usize;
    {
        let mut q = ipco.data_start;
        let end = ipco.box_start + ipco.size as usize;
        while q + 8 <= end {
            let sz = u32::from_be_bytes([data[q], data[q + 1], data[q + 2], data[q + 3]]) as usize;
            if sz < 8 {
                break;
            }
            prop_base += 1;
            q += sz;
        }
    }
    let ispe_idx = (prop_base + 1) as u32;
    let hvcc_idx = (prop_base + 2) as u32;
    let mut new_ipco_body = data[ipco.data_start..ipco.box_start + ipco.size as usize].to_vec();
    new_ipco_body.extend_from_slice(&isobmff::make_ispe_box(mask_w, mask_h));
    new_ipco_body.extend_from_slice(&make_box(b"hvcC", &matte_hvcc));
    let new_ipco = make_box(b"ipco", &new_ipco_body);

    let mut ipma_flags = data[ipma.data_start + 3];
    if hvcc_idx > 127 {
        ipma_flags |= 2;
    }
    let mut entries = parsed.ipma_entries.clone();
    entries.push(isobmff::IpmaEntry {
        item_id: mask_id,
        associations: vec![(ispe_idx, false), (hvcc_idx, true)],
    });
    let mut new_ipma_payload = vec![data[ipma.data_start], 0, 0, ipma_flags];
    new_ipma_payload.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for e in &entries {
        new_ipma_payload
            .extend_from_slice(&isobmff::make_ipma_entry(e.item_id, &e.associations, ipma_flags as u32));
    }
    let new_ipma = make_box(b"ipma", &new_ipma_payload);

    // ---- iloc: shift existing extents, append two -----------------------
    let xmp = instance_mask_xmp(&key);
    let d_iinf = new_iinf.len() as i64 - iinf.size as i64;
    let d_iprp = (new_ipco.len() as i64 - ipco.size as i64) + (new_ipma.len() as i64 - ipma.size as i64);
    let mdat = top.iter().find(|b| b.btype == *b"mdat").ok_or("mdat not found")?;
    let mdat_end = (mdat.box_start + mdat.size) as i64;
    let payload_len = (matte_stream.len() + xmp.len()) as i64;

    // iloc itself grows by two entries, and that shift applies to everything
    // after it — mdat included. Measure it first: the entry count is fixed, so
    // the box size does not depend on the offset values.
    // `make_iloc_box` sizes its offset/length fields from the values present, so
    // measuring with zero offsets under-counts the growth. Build once with a
    // plausible payload offset, measure the real box, then rebuild.
    let shift_0 = d_iinf + d_iprp;
    let measure = |payload_guess: u64| -> Vec<isobmff::IlocEntry> {
        let mut v: Vec<isobmff::IlocEntry> = Vec::new();
        for mut e in isobmff::parse_iloc(data, iloc).unwrap_or_default() {
            for ext in e.extents.iter_mut() {
                if (e.construction_method & 0xF) == 0 {
                    let past = (ext.0 as i64) >= mdat_end;
                    ext.0 = (ext.0 as i64 + shift_0 + if past { payload_len } else { 0 }) as u64;
                }
            }
            v.push(e);
        }
        v.push(isobmff::IlocEntry {
            item_id: mask_id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(payload_guess, matte_stream.len() as u64)],
        });
        v.push(isobmff::IlocEntry {
            item_id: xmp_id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(payload_guess + matte_stream.len() as u64, xmp.len() as u64)],
        });
        v
    };
    let d_iloc = isobmff::make_iloc_box(&measure(mdat_end as u64 + shift_0 as u64)).len() as i64
        - iloc.size as i64;
    let head_delta = d_iinf + d_iprp + d_iloc;

    let mut out_entries: Vec<isobmff::IlocEntry> = Vec::new();
    for mut e in isobmff::parse_iloc(data, iloc)? {
        for ext in e.extents.iter_mut() {
            if (e.construction_method & 0xF) == 0 {
                let past = (ext.0 as i64) >= mdat_end;
                ext.0 = (ext.0 as i64 + head_delta + if past { payload_len } else { 0 }) as u64;
            }
        }
        out_entries.push(e);
    }
    let payload_abs = (mdat_end + head_delta) as u64;
    out_entries.push(isobmff::IlocEntry {
        item_id: mask_id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(payload_abs, matte_stream.len() as u64)],
    });
    out_entries.push(isobmff::IlocEntry {
        item_id: xmp_id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(payload_abs + matte_stream.len() as u64, xmp.len() as u64)],
    });
    let new_iloc = isobmff::make_iloc_box(&out_entries);

    // ---- splice ----------------------------------------------------------
    // Rebuild meta rather than copying its header: the children below grew, and
    // a stale box size makes every later box (mdat included) unparseable.
    // meta carries a 4-byte version/flags before its children.
    let mut meta_body = data[content_start - 4..content_start].to_vec();
    let mut out = Vec::with_capacity(data.len() + payload_len as usize + 4096);
    out.extend_from_slice(&data[..meta_box.box_start]);
    for child in &children {
        match &child.btype {
            b"iinf" => meta_body.extend_from_slice(&new_iinf),
            b"iloc" => meta_body.extend_from_slice(&new_iloc),
            b"iprp" => {
                let mut body = Vec::new();
                for s in &sub {
                    match &s.btype {
                        b"ipco" => body.extend_from_slice(&new_ipco),
                        b"ipma" => body.extend_from_slice(&new_ipma),
                        _ => body.extend_from_slice(&data[s.box_start..s.box_start + s.size as usize]),
                    }
                }
                meta_body.extend_from_slice(&make_box(b"iprp", &body));
            }
            _ => meta_body
                .extend_from_slice(&data[child.box_start..child.box_start + child.size as usize]),
        }
    }
    out.extend_from_slice(&make_box(b"meta", &meta_body));
    out.extend_from_slice(&data[content_end..mdat.box_start]);
    // Rebuild mdat too: its payload grew by the mask and the XMP.
    let mdat_payload_len = (mdat.size as usize - (mdat.data_start - mdat.box_start))
        + matte_stream.len()
        + xmp.len();
    out.extend_from_slice(&make_box(b"mdat", &Vec::new()));
    // make_box writes an 8-byte header; replace it with the true size.
    let hdr_at = out.len() - 8;
    out[hdr_at..hdr_at + 4].copy_from_slice(&((mdat_payload_len + 8) as u32).to_be_bytes());
    out.extend_from_slice(&data[mdat.data_start..mdat_end as usize]);
    out.extend_from_slice(&matte_stream);
    out.extend_from_slice(&xmp);
    out.extend_from_slice(&data[(mdat.box_start + mdat.size) as usize..]);

    // Self-check: the container must still walk cleanly top to bottom. Shipping
    // a corrupt file costs someone a round trip, so refuse to return one.
    {
        let mut off = 0usize;
        while off + 8 <= out.len() {
            let sz = u32::from_be_bytes([out[off], out[off + 1], out[off + 2], out[off + 3]]) as usize;
            if sz < 8 || off + sz > out.len() {
                return Err(format!("instance mask: box walk broke at offset {off}"));
            }
            off += sz;
        }
        if off != out.len() {
            return Err(format!(
                "instance mask: box walk ended at {off} of {}",
                out.len()
            ));
        }
    }
    Ok((out, key))
}
