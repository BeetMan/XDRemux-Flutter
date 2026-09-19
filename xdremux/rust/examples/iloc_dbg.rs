fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let top = xdremux_core::isobmff::parse_boxes(&data, 0, data.len());
    let meta = top.iter().find(|b| b.btype == *b"meta").unwrap();
    let iloc = xdremux_core::isobmff::parse_boxes(&data, meta.data_start + 4, meta.data_end)
        .into_iter().find(|b| b.btype == *b"iloc").unwrap();
    let entries = xdremux_core::isobmff::parse_iloc(&data, &iloc).unwrap();
    println!("rust entries: {}", entries.len());
    let rebuilt = xdremux_core::isobmff::make_iloc_box(&entries);
    println!("old iloc size {} rebuilt {}", iloc.size, rebuilt.len());
}
