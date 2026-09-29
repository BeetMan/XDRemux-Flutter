//! ftyp brands probe: rewrite the compatible-brands list to the native
//! iPhone capture set (MiHA/heix/MiPr added) and shift construction=0 iloc
//! extents to match. Tests whether the iOS 27 style editor gates on brands.
//!
//! Usage: ftyp_brands <input.heic> <output.heic>

use xdremux_core::isobmff;
use xdremux_core::isobmff::make_iloc_box;

const NATIVE_BRANDS: &[&[u8; 4]] = &[
    b"mif1", b"MiHB", b"MiHA", b"heix", b"MiHE", b"MiPr", b"miaf", b"heic", b"tmap",
];

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: ftyp_brands <input> <output>".into());
    }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let top = isobmff::parse_boxes(&data, 0, data.len());
    let ftyp = top
        .iter()
        .find(|b| b.btype == *b"ftyp")
        .ok_or("no ftyp box")?;

    // Rebuild ftyp: keep major/minor, replace compatible brands.
    let mut new_ftyp: Vec<u8> = Vec::new();
    new_ftyp.extend_from_slice(&((8 + 4 + 4 + NATIVE_BRANDS.len() * 4) as u32).to_be_bytes()); // placeholder size
    new_ftyp.extend_from_slice(b"ftyp");
    new_ftyp.extend_from_slice(&data[ftyp.data_start..ftyp.data_start + 8]); // major + minor
    for b in NATIVE_BRANDS {
        new_ftyp.extend_from_slice(*b);
    }
    let delta = new_ftyp.len() as i64 - ftyp.size as i64;

    // Shift construction=0 extents by delta.
    let meta = top
        .iter()
        .find(|b| b.btype == *b"meta")
        .ok_or("no meta box")?;
    let iloc = isobmff::parse_boxes(&data, meta.data_start + 4, meta.data_end)
        .into_iter()
        .find(|b| b.btype == *b"iloc")
        .ok_or("no iloc box")?;
    let mut entries = isobmff::parse_iloc(&data, &iloc)?;
    for e in entries.iter_mut() {
        if (e.construction_method & 0xF) == 0 {
            for ext in e.extents.iter_mut() {
                ext.0 = (ext.0 as i64 + delta) as u64;
            }
        }
    }
    let new_iloc = make_iloc_box(&entries);

    let mut out = Vec::with_capacity((data.len() as i64 + delta) as usize);
    out.extend_from_slice(&new_ftyp);
    out.extend_from_slice(&data[ftyp.data_end..iloc.box_start]);
    out.extend_from_slice(&new_iloc);
    out.extend_from_slice(&data[iloc.data_end..]);
    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: {} -> {} (delta {delta})", args[1], args[2]);
    Ok(())
}
