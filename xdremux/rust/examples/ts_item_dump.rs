use xdremux_core::isobmff;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let out = args.get(2);
    let data = std::fs::read(path).expect("read");
    let top = isobmff::parse_boxes(&data, 0, data.len());
    let meta_box = top.iter().find(|b| b.btype == *b"meta").expect("meta");
    let cs = meta_box.box_start + 8 + 4;
    let ce = meta_box.box_start + meta_box.size as usize;
    let children = isobmff::parse_boxes(&data, cs, ce);
    let iinf = children.iter().find(|b| b.btype == *b"iinf").expect("iinf");
    let items = isobmff::parse_iinf(&data, iinf).expect("iinf parse");
    let iloc = children.iter().find(|b| b.btype == *b"iloc").expect("iloc");
    let entries = isobmff::parse_iloc(&data, iloc).expect("iloc parse");
    for it in &items {
        let raw = String::from_utf8_lossy(&it.raw_infe);
        if raw.contains("texture_styles") {
            if let Some(e) = entries.iter().find(|e| e.item_id == it.item_id) {
                if let Some((off, len)) = e.extents.first() {
                    let s = *off as usize;
                    let payload = &data[s..s + *len as usize];
                    if let Some(o) = out {
                        std::fs::write(o, payload).unwrap();
                        println!("wrote {} bytes to {}", len, o);
                    } else {
                        println!("item {} ({} bytes)", it.item_id, len);
                    }
                }
            }
        }
    }
}
