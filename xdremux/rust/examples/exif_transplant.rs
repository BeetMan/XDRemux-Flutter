// Transplant an Exif item payload (raw bytes incl. prefix) from one HEIC
// into another, replacing the target's Exif item entirely.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: exif_transplant <donor-heic> <target-heic> <out-heic>");
        std::process::exit(2);
    }
    let donor = std::fs::read(&args[1]).unwrap();
    let mut target = std::fs::read(&args[2]).unwrap();
    // donor Exif payload via the public reader
    let payload = xdremux_core::isobmff_write::read_exif_payload(&donor)
        .unwrap()
        .expect("donor has no Exif item");
    // find target's Exif item id
    let meta = xdremux_core::isobmff::parse_source_meta(&target).unwrap();
    let exif_id = meta
        .items
        .iter()
        .find(|it| it.itype == "Exif")
        .map(|it| it.item_id)
        .expect("target has no Exif item");
    xdremux_core::isobmff_write::replace_item_payload(&mut target, exif_id, None, &payload)
        .expect("replace exif payload");
    std::fs::write(&args[3], &target).unwrap();
    println!("transplanted exif ({} bytes) -> {}", payload.len(), args[3]);
}
