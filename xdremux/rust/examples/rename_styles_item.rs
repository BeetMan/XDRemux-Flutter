//! Rename probe: change the styles item's infe item_name from
//! 'styleMetadata' to 'metadata' (native Apple naming) and shift
//! construction=0 iloc extents for the shrunken meta. Tests whether the
//! iOS 27 style editor looks the styles item up by name.
//!
//! Usage: rename_styles_item <input.heic> <output.heic>

use xdremux_core::isobmff;
use xdremux_core::isobmff::make_iloc_box;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: rename_styles_item <input> <output>".into());
    }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let top = isobmff::parse_boxes(&data, 0, data.len());
    let meta = top
        .iter()
        .find(|b| b.btype == *b"meta")
        .ok_or("no meta box")?;
    let kids = isobmff::parse_boxes(&data, meta.data_start + 4, meta.data_end);
    let iinf = kids
        .iter()
        .find(|b| b.btype == *b"iinf")
        .ok_or("no iinf box")?;
    let iloc = kids
        .iter()
        .find(|b| b.btype == *b"iloc")
        .ok_or("no iloc box")?;

    const OLD: &[u8] = b"styleMetadata\0";
    const NEW: &[u8] = b"metadata\0";
    let delta: i64 = -((OLD.len() - NEW.len()) as i64); // -5

    // Locate the styles infe inside iinf and rebuild it shorter.
    // iinf body: version(1)+flags(3) + entry_count(2|4), then infe children.
    let iinf_ver = data[iinf.data_start];
    let entries_off = iinf.data_start + 4 + if iinf_ver >= 1 { 4 } else { 2 };
    let mut new_iinf: Vec<u8> = data[iinf.data_start..entries_off].to_vec();
    let mut renamed = false;
    for child in isobmff::parse_boxes(&data, entries_off, iinf.data_end) {
        if child.btype == *b"infe" {
            let body = &data[child.data_start..child.data_end];
            if let Some(rel) = body.windows(OLD.len()).position(|w| w == OLD) {
                let mut nb: Vec<u8> = Vec::with_capacity(body.len() + delta as usize);
                nb.extend_from_slice(&body[..rel]);
                nb.extend_from_slice(NEW);
                nb.extend_from_slice(&body[rel + OLD.len()..]);
                let total = nb.len() as u32 + 8;
                new_iinf.extend_from_slice(&total.to_be_bytes());
                new_iinf.extend_from_slice(b"infe");
                new_iinf.extend_from_slice(&nb);
                renamed = true;
                continue;
            }
        }
        new_iinf.extend_from_slice(&data[child.box_start..child.data_end]);
    }
    if !renamed {
        return Err("no styleMetadata infe found".into());
    }
    let new_iinf_total = new_iinf.len() as u32 + 8;
    let mut iinf_box: Vec<u8> = Vec::with_capacity(new_iinf.len() + 8);
    iinf_box.extend_from_slice(&new_iinf_total.to_be_bytes());
    iinf_box.extend_from_slice(b"iinf");
    iinf_box.extend_from_slice(&new_iinf);
    let new_iinf = iinf_box;

    // Shift construction=0 extents by delta.
    let mut entries = isobmff::parse_iloc(&data, iloc)?;
    for e in entries.iter_mut() {
        if (e.construction_method & 0xF) == 0 {
            for ext in e.extents.iter_mut() {
                ext.0 = (ext.0 as i64 + delta) as u64;
            }
        }
    }
    let new_iloc = make_iloc_box(&entries);

    // Rebuild meta children in order.
    let mut new_meta_body: Vec<u8> = Vec::new();
    for child in &kids {
        if child.btype == *b"iinf" {
            new_meta_body.extend_from_slice(&new_iinf);
        } else if child.btype == *b"iloc" {
            new_meta_body.extend_from_slice(&new_iloc);
        } else {
            new_meta_body.extend_from_slice(&data[child.box_start..child.data_end]);
        }
    }
    let mut new_meta: Vec<u8> = Vec::with_capacity(new_meta_body.len() + 12);
    new_meta.extend_from_slice(&((new_meta_body.len() as u32) + 12).to_be_bytes());
    new_meta.extend_from_slice(b"meta");
    new_meta.extend_from_slice(&data[meta.data_start..meta.data_start + 4]); // version/flags
    new_meta.extend_from_slice(&new_meta_body);

    let mut out = Vec::with_capacity((data.len() as i64 + delta) as usize);
    out.extend_from_slice(&data[..meta.box_start]);
    out.extend_from_slice(&new_meta);
    out.extend_from_slice(&data[meta.data_end..]);

    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: renamed styles item -> {}", args[2]);
    Ok(())
}
