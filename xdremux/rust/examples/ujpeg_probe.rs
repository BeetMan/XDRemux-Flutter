fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        print!("{path}: ffd8={} ", data.starts_with(&[0xFF, 0xD8]));
        match xdremux_core::uhdr_jpeg::parse(&data) {
            Ok(Some(info)) => println!(
                "UHDR-JPEG ok floats={} gainmap={}",
                info.meta_floats.len(),
                info.gainmap_jpeg.len()
            ),
            Ok(None) => println!("not-ultra-hdr-jpeg (Ok None)"),
            Err(e) => println!("parse ERR {e}"),
        }
    }
}
