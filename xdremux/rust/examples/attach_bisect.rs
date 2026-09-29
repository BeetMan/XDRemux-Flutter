// Bisect probe: selectively attach styles/texture/mattes to a 16e capture.
// usage: attach_bisect <in> <out> <texture|styles|mattes|all|all-stripnote> [spoof-model]
use xdremux_core::isobmff_write::replace_item_payload;
use xdremux_core::semantic_mattes::inject_semantic_mattes;
use xdremux_core::styles_attach::{strip_makernote, STYLES_URI};
use xdremux_core::styles_native::{build_style_metadata_with, StyleStateOverride};
use xdremux_core::texture_styles::{inject_uri_metadata_item, texture_info_payload, TEXTURE_STYLES_URI};

fn exif_payload_of(data: &[u8], exif_id: u32) -> Option<Vec<u8>> {
    let parsed = xdremux_core::isobmff::parse_source_meta(data).ok()?;
    let loc = parsed.iloc_entries.iter().find(|e| e.item_id == exif_id)?;
    match loc.construction_method & 0xF {
        0 => {
            let (o, l) = *loc.extents.first()?;
            data.get(o as usize..(o + l) as usize).map(|s| s.to_vec())
        }
        1 => {
            let top = xdremux_core::isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| b.btype == *b"meta")?;
            let idat = xdremux_core::isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end)
                .into_iter()
                .find(|b| b.btype == *b"idat")?;
            let blob = &data[idat.data_start..idat.data_end];
            let (o, l) = *loc.extents.first()?;
            blob.get(o as usize..(o + l) as usize).map(|s| s.to_vec())
        }
        _ => None,
    }
}

fn spoof_model(payload: &[u8], model: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = payload.to_vec();
    let prefix = 10usize;
    let tiff_off = prefix;
    let be = out[tiff_off] == b'M';
    let rd = |b: &[u8]| if be { u32::from_be_bytes([b[0],b[1],b[2],b[3]]) } else { u32::from_le_bytes([b[0],b[1],b[2],b[3]]) };
    let ifd0 = rd(&out[tiff_off+4..tiff_off+8]) as usize + tiff_off;
    let n = u16::from_be_bytes([out[ifd0], out[ifd0+1]]) as usize;
    for i in 0..n {
        let e = ifd0 + 2 + i * 12;
        let tag = u16::from_be_bytes([out[e], out[e+1]]);
        if tag == 0x0110 {
            let cnt = u32::from_be_bytes([out[e+4],out[e+5],out[e+6],out[e+7]]) as usize;
            let off = rd(&out[e+8..e+12]) as usize + tiff_off;
            let mut v = model.to_vec(); v.push(0);
            v.resize(cnt, 0);
            out[off..off+cnt].copy_from_slice(&v);
            return Ok(out);
        }
    }
    Err("no Model tag".into())
}

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 { return Err("usage: attach_bisect <in> <out> <mode> [spoof-model]".into()); }
    let data = std::fs::read(&a[1]).map_err(|e| format!("read: {e}"))?;
    // mode: letters s/t/m (styles/texture/mattes) + optional n (Apple maker
    // note upsert) + optional -stripnote prefix.
    let mode = a[3].as_str();
    let mut out = data.clone();
    if mode == "stripnote" {
        // strip the native maker note only (no injections)
        strip_makernote(&mut out)?;
        std::fs::write(&a[2], out).map_err(|e| format!("write: {e}"))?;
        println!("OK {} -> {} (stripnote)", a[1], a[2]);
        return Ok(());
    }
    if mode.ends_with("-stripnote") {
        strip_makernote(&mut out)?;
    }
    let base_mode = mode.strip_suffix("-stripnote").unwrap_or(mode);
    if base_mode.contains('t') {
        let p = texture_info_payload(104);
        out = inject_uri_metadata_item(&out, TEXTURE_STYLES_URI, &p)?;
    }
    if base_mode.contains('s') {
        let p = build_style_metadata_with(&StyleStateOverride::identity());
        out = inject_uri_metadata_item(&out, STYLES_URI, &p)?;
    }
    if base_mode.contains('n') {
        let parsed = xdremux_core::isobmff::parse_source_meta(&out).map_err(|e| e.to_string())?;
        let exif_id = parsed.items.iter().find(|i| i.itype == "Exif").map(|i| i.item_id).ok_or("no exif")?;
        let payload = exif_payload_of(&out, exif_id).ok_or("no exif payload")?;
        let note = xdremux_core::styles_scaffold::compose_styles_maker_note(&payload)?;
        let merged = xdremux_core::styles_attach::upsert_for_probe(&payload, &note)?;
        if merged != payload { replace_item_payload(&mut out, exif_id, None, &merged)?; }
    }
    if base_mode.contains('m') {
        out = inject_semantic_mattes(&out)?;
    }
    if a.len() > 4 && a[4] == "spoof" {
        let parsed = xdremux_core::isobmff::parse_source_meta(&out).map_err(|e| e.to_string())?;
        let exif_id = parsed.items.iter().find(|i| i.itype == "Exif").map(|i| i.item_id).ok_or("no exif")?;
        let payload = exif_payload_of(&out, exif_id).ok_or("no exif payload")?;
        let patched = spoof_model(&payload, b"iPhone 18 Pro")?;
        replace_item_payload(&mut out, exif_id, None, &patched)?;
    }
    std::fs::write(&a[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK {} -> {} ({})", a[1], a[2], mode);
    Ok(())
}
