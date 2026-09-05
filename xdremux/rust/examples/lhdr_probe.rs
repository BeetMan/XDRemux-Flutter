fn main() {
    for path in std::env::args().skip(1) {
        match xdremux_core::container::extract_lhdr(&path) {
            Ok(r) => println!(
                "{path}: OK mode={} meta_bytes={} floats={} gainmap={} mask={}",
                r.mode,
                r.meta_bytes.len(),
                r.meta_floats.len(),
                r.gainmap_data.as_ref().map(|g| g.len()).unwrap_or(0),
                r.mask_data.as_ref().map(|m| m.len()).unwrap_or(0),
            ),
            Err(e) => println!("{path}: ERR {e}"),
        }
    }
}
