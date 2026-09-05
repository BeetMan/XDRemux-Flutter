fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        match xdremux_core::motion_photo::parse_motion_photo(&data) {
            Ok(Some(asset)) => println!(
                "{path}: MOTION PHOTO kind={} items={}",
                asset.source_kind,
                asset.items.len()
            ),
            Ok(None) => println!("{path}: NOT a motion photo"),
            Err(e) => println!("{path}: ERR {e}"),
        }
    }
}
