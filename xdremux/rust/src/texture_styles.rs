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
    let v_hw = w.add_str("iPhone19,2");
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

/// One detected face in the Texture Style person contract.
///
/// Field meanings and the statistics recipes are documented in
/// `docs/research/person-data-reverse-engineering.md`.
/// Apple's face-landmark layout identifier (their 76-point scheme). Written
/// verbatim; changing it would tell Photos the landmarks mean something else.
const FACE_LANDMARK_TYPE: u64 = 1785383;

/// `faceID` is a UUID string in Apple's own files. Generate a stable one from
/// the instance index so the same face keeps its identity across rebuilds.
fn face_uuid(index: i64) -> String {
    format!("00000000-0000-4000-8000-{:012x}", (index as u64) & 0xffff_ffff_ffff)
}

#[derive(Debug, Clone)]
pub struct PersonInstance {
    pub face_id: i64,
    /// Normalised rects as (x, y, width, height).
    pub face_roi: [f64; 4],
    pub face_skin_roi: [f64; 4],
    pub instance_roi: [f64; 4],
    pub scaling_roi: [f64; 4],
    pub yaw: f64,
    pub pitch: f64,
    pub roll: f64,
    /// (x, y, error) per landmark; the contract expects 76.
    pub landmarks: Vec<(f64, f64, f64)>,
    /// SkinSmoothingStandalone.
    pub skin_colour: [f64; 3],
    /// Optional: Apple omits it for some faces (2/24 in our samples).
    pub skin_roughness: Option<f64>,
    pub skin_skip: bool,
    /// Mattify.
    pub mattify_colour: [f64; 3],
    pub mattify_highlights_ratio: f64,
    /// UnderEyeBrightening.
    pub left_eye_colour: [f64; 3],
    pub right_eye_colour: [f64; 3],
    pub left_eye_luma_var: f64,
    pub right_eye_luma_var: f64,
    pub left_eye_bimodal: bool,
    pub right_eye_bimodal: bool,
}

/// textureInfo bplist with the person data block attached.
pub fn texture_info_payload_with_people(grain_seed: u64, people: &[PersonInstance]) -> Vec<u8> {
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
    let v_hw = w.add_str("iPhone19,2");
    let k_pdv = w.add_str("TextureStylePeopleDataVersion");
    let v_pdv = w.add_int(3);
    let k_gs = w.add_str("FilmGrainSeed");
    let v_gs = w.add_int(grain_seed);

    let k_people = w.add_str("TextureStylePostProcessedPeopleData");
    let mut person_refs = Vec::with_capacity(people.len());
    for p in people {
        person_refs.push(write_person(&mut w, p));
    }
    let v_people = w.add_array(&person_refs);

    let top = w.add_dict(&[
        (k_preset, v_preset),
        (k_ctype, v_ctype),
        (k_cmode, v_cmode),
        (k_ptype, v_ptype),
        (k_hw, v_hw),
        (k_pdv, v_pdv),
        (k_gs, v_gs),
        (k_people, v_people),
    ]);
    w.finish(top)
}

fn write_rect(w: &mut BplistWriter, r: [f64; 4]) -> usize {
    let (kx, ky, kw, kh) = (
        w.add_str("x"),
        w.add_str("y"),
        w.add_str("width"),
        w.add_str("height"),
    );
    let (vx, vy, vw, vh) = (
        w.add_real(r[0]),
        w.add_real(r[1]),
        w.add_real(r[2]),
        w.add_real(r[3]),
    );
    w.add_dict(&[(kx, vx), (ky, vy), (kw, vw), (kh, vh)])
}

fn write_colour(w: &mut BplistWriter, name: &str, c: [f64; 3]) -> (usize, usize) {
    let k = w.add_str(name);
    let vals: Vec<usize> = c.iter().map(|v| w.add_real(*v)).collect();
    (k, w.add_array(&vals))
}

fn write_person(w: &mut BplistWriter, p: &PersonInstance) -> usize {
    let mut e: Vec<(usize, usize)> = Vec::new();

    let k = w.add_str("faceID");
    e.push((k, w.add_int(p.face_id as u64)));
    let k = w.add_str("faceSkinROI");
    e.push((k, write_rect(w, p.face_skin_roi)));
    let k = w.add_str("faceROI");
    e.push((k, write_rect(w, p.face_roi)));
    let k = w.add_str("instanceROI");
    e.push((k, write_rect(w, p.instance_roi)));
    let k = w.add_str("faceROIAndLandmarksROIRelativeScalingROI");
    e.push((k, write_rect(w, p.scaling_roi)));

    let (k, v) = (w.add_str("faceYaw"), w.add_real(p.yaw));
    e.push((k, v));
    let (k, v) = (w.add_str("facePitch"), w.add_real(p.pitch));
    e.push((k, v));
    let (k, v) = (w.add_str("faceRoll"), w.add_real(p.roll));
    e.push((k, v));
    let (k, v) = (w.add_str("faceLandmarkType"), w.add_int(1));
    e.push((k, v));
    let (k, v) = (w.add_str("faceUnitOfAngle"), w.add_int(1));
    e.push((k, v));
    let (k, v) = (
        w.add_str("instanceMaskReferenceKey"),
        w.add_str("FSINCInstanceMask9"),
    );
    e.push((k, v));

    // faceLandmarks: [{point:{x,y}, error}, ...]
    let k_lm = w.add_str("faceLandmarks");
    let mut lms = Vec::with_capacity(p.landmarks.len());
    for (x, y, err) in &p.landmarks {
        let (kpx, kpy) = (w.add_str("x"), w.add_str("y"));
        let (vpx, vpy) = (w.add_real(*x), w.add_real(*y));
        let kpoint = w.add_str("point");
        let vpoint = w.add_dict(&[(kpx, vpx), (kpy, vpy)]);
        let kerr = w.add_str("error");
        let verr = w.add_real(*err);
        lms.push(w.add_dict(&[(kpoint, vpoint), (kerr, verr)]));
    }
    e.push((k_lm, w.add_array(&lms)));

    // imageStats
    let k_stats = w.add_str("imageStats");
    let mut blocks: Vec<(usize, usize)> = Vec::new();

    let k_b = w.add_str("SkinSmoothingStandalone");
    let mut sb = Vec::new();
    let k = w.add_str("faceID");
    sb.push((k, w.add_int(p.face_id as u64)));
    sb.push(write_colour(w, "SkinSmoothAverageFaceColour", p.skin_colour));
    if let Some(r) = p.skin_roughness {
        let (k, v) = (w.add_str("SkinSmoothFaceRoughness"), w.add_real(r));
        sb.push((k, v));
    }
    let (k, v) = (w.add_str("SkinSmoothSkipPerson"), w.add_bool(p.skin_skip));
    sb.push((k, v));
    blocks.push((k_b, w.add_dict(&sb)));

    let k_b = w.add_str("Mattify");
    let mut mb = Vec::new();
    let k = w.add_str("faceID");
    mb.push((k, w.add_int(p.face_id as u64)));
    mb.push(write_colour(w, "AverageFaceColor", p.mattify_colour));
    let (k, v) = (
        w.add_str("HighlightsToMaskRatio"),
        w.add_real(p.mattify_highlights_ratio),
    );
    mb.push((k, v));
    let (k, v) = (w.add_str("SkipPerson"), w.add_bool(false));
    mb.push((k, v));
    blocks.push((k_b, w.add_dict(&mb)));

    let k_b = w.add_str("UnderEyeBrightening");
    let mut ub = Vec::new();
    let k = w.add_str("faceID");
    ub.push((k, w.add_int(p.face_id as u64)));
    ub.push(write_colour(w, "LeftEyeAverageColor", p.left_eye_colour));
    ub.push(write_colour(w, "RightEyeAverageColor", p.right_eye_colour));
    let (k, v) = (w.add_str("LeftEyeLumaVariance"), w.add_real(p.left_eye_luma_var));
    ub.push((k, v));
    let (k, v) = (
        w.add_str("RightEyeLumaVariance"),
        w.add_real(p.right_eye_luma_var),
    );
    ub.push((k, v));
    let (k, v) = (w.add_str("LeftEyeIsBiModal"), w.add_bool(p.left_eye_bimodal));
    ub.push((k, v));
    let (k, v) = (w.add_str("RightEyeIsBiModal"), w.add_bool(p.right_eye_bimodal));
    ub.push((k, v));
    blocks.push((k_b, w.add_dict(&ub)));

    e.push((k_stats, w.add_dict(&blocks)));
    w.add_dict(&e)
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
    inject_texture_styles_payload(data, &payload)
}

/// Same, but with the person block filled in (skin smoothing / mattify /
/// under-eye statistics). See `crate::face_detect::build_person_instances`.
pub fn inject_texture_styles_with_people(
    data: &[u8],
    grain_seed: u64,
    people: &[PersonInstance],
) -> Result<Vec<u8>, String> {
    let payload = texture_info_payload_with_people(grain_seed, people);
    inject_texture_styles_payload(data, &payload)
}

fn inject_texture_styles_payload(data: &[u8], payload: &[u8]) -> Result<Vec<u8>, String> {
    inject_uri_metadata_item(data, TEXTURE_STYLES_URI, &payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_person() -> PersonInstance {
        PersonInstance {
            face_id: 0,
            face_roi: [0.34, 0.31, 0.074, 0.098],
            face_skin_roi: [0.30, 0.24, 0.145, 0.193],
            instance_roi: [0.24, 0.04, 0.52, 0.64],
            scaling_roi: [0.023, 0.0, 0.955, 1.0],
            yaw: -0.33,
            pitch: 0.40,
            roll: 0.14,
            landmarks: (0..76).map(|i| (0.4 + i as f64 * 0.001, 0.3, 0.01)).collect(),
            skin_colour: [0.7547, 0.5409, 0.4437],
            skin_roughness: Some(0.02579),
            skin_skip: false,
            mattify_colour: [0.749, 0.5412, 0.4431],
            mattify_highlights_ratio: 0.0,
            left_eye_colour: [0.8252, 0.6069, 0.488],
            right_eye_colour: [0.606, 0.4299, 0.354],
            left_eye_luma_var: 0.0326,
            right_eye_luma_var: 0.0124,
            left_eye_bimodal: true,
            right_eye_bimodal: false,
        }
    }

    /// The generated payload must be a bplist whose top dict carries the person
    /// block, so a downstream reader (Apple Photos, or plistlib for tests) can
    /// parse it.
    #[test]
    fn people_payload_is_a_parseable_bplist() {
        let payload = texture_info_payload_with_people(203, &[sample_person()]);
        assert!(payload.starts_with(b"bplist00"));
        assert_eq!(&payload[..8], b"bplist00");
        // Every key we publish must appear as a UTF-16BE-ish ASCII run in the
        // object table.
        for key in [
            "Preset",
            "TextureStylePeopleDataVersion",
            "TextureStylePostProcessedPeopleData",
            "faceLandmarks",
            "faceROI",
            "faceSkinROI",
            "faceYaw",
            "instanceMaskReferenceKey",
            "imageStats",
            "SkinSmoothingStandalone",
            "SkinSmoothAverageFaceColour",
            "SkinSmoothFaceRoughness",
            "Mattify",
            "UnderEyeBrightening",
            "LeftEyeAverageColor",
        ] {
            assert!(
                payload.windows(key.len()).any(|w| w == key.as_bytes()),
                "missing key {key}"
            );
        }
    }

    /// Roughness is optional: Apple omits it for some faces (2/24 in our
    /// samples), so the writer must cope without it.
    #[test]
    fn people_payload_tolerates_missing_roughness() {
        let mut p = sample_person();
        p.skin_roughness = None;
        let payload = texture_info_payload_with_people(203, &[p]);
        assert!(payload.starts_with(b"bplist00"));
        assert!(!payload
            .windows("SkinSmoothFaceRoughness".len())
            .any(|w| w == b"SkinSmoothFaceRoughness"));
    }
}
