/// Dump one HEIF item payload by id (research tool).
fn main() {
    let path = std::env::args().nth(1).expect("path");
    let id: u32 = std::env::args().nth(2).expect("item id").parse().expect("id");
    let out = std::env::args().nth(3).expect("out");
    let d = std::fs::read(&path).unwrap();
    let m = xdremux_core::isobmff::parse_source_meta(&d).expect("meta");
    let e = m
        .iloc_entries
        .iter()
        .find(|e| e.item_id == id)
        .unwrap_or_else(|| panic!("item {id} not found"));
    let mut blob = Vec::new();
    for (off, len) in &e.extents {
        let s = *off as usize;
        blob.extend_from_slice(&d[s..s + *len as usize]);
    }
    std::fs::write(&out, &blob).unwrap();
    println!("item {id} -> {out} ({} bytes, {} extents)", blob.len(), e.extents.len());
}
