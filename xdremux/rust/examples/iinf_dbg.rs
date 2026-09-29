fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let top = xdremux_core::isobmff::parse_boxes(&data, 0, data.len());
    let meta = top.iter().find(|b| b.btype == *b"meta").unwrap();
    let iinf = xdremux_core::isobmff::parse_boxes(&data, meta.data_start + 4, meta.data_end)
        .into_iter().find(|b| b.btype == *b"iinf").unwrap();
    println!("iinf size {}", iinf.size);
    match xdremux_core::isobmff::parse_iinf(&data, &iinf) {
        Ok(items) => {
            println!("parsed {} items", items.len());
            let max = items.iter().map(|i| i.item_id).max().unwrap_or(0);
            println!("max id {}", max);
            for i in items.iter() {
                if i.item_id > 1000 { println!("  GARBAGE id {} type {:?} raw_infe {}", i.item_id, i.itype, hex(&i.raw_infe)); }
            }
            fn hex(b: &[u8]) -> String { b.iter().map(|x| format!("{:02x}", x)).collect() }
        }
        Err(e) => println!("parse_iinf ERR: {e}"),
    }
}
