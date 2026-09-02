fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        match xdremux_core::motion_photo::parse_motion_photo(&data) {
            Ok(Some(a)) => {
                let name = path.split('/').last().unwrap();
                println!("{name}: MOTION pts={}s vendor_meta={}", a.presentation_timestamp_us.unwrap_or(0) as f64/1e6, a.vendor_metadata.is_some());
            }
            Ok(None) => println!("{}: not motion", path.split('/').last().unwrap()),
            Err(e) => println!("{}: ERR {e}", path.split('/').last().unwrap()),
        }
    }
}
