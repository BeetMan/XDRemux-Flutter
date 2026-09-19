use xdremux_core::isobmff;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let data = std::fs::read(&path).unwrap();
    let meta = isobmff::parse_source_meta(&data).unwrap();
    // find texture_styles item
    for item in &meta.items {
        let raw = String::from_utf8_lossy(&item.raw_infe);
        if raw.contains("texture_styles") {
            println!("=== texture_styles item {} ===", item.item_id);
            println!("itype: {}", item.itype);
            println!("raw_infe ({} bytes):", item.raw_infe.len());
            for chunk in item.raw_infe.chunks(16) {
                let hex: Vec<String> = chunk.iter().map(|b| format!("{:02x}", b)).collect();
                let ascii: String = chunk.iter().map(|&b| if (32..127).contains(&b) { b as char } else { '.' }).collect();
                println!("  {}  {}", hex.join(" "), ascii);
            }
            // iloc
            if let Some(e) = meta.iloc_entries.iter().find(|e| e.item_id == item.item_id) {
                for (off, len) in &e.extents {
                    println!("iloc extent: offset={} length={} construction={}", off, len, e.construction_method);
                }
            }
            // iref referencing this item
            for r in &meta.refs {
                if r.from == item.item_id || r.to.contains(&item.item_id) {
                    println!("iref {} from={} to={:?}", r.rtype, r.from, r.to);
                }
            }
            // ipma
            if let Some(ip) = meta.ipma_entries.iter().find(|e| e.item_id == item.item_id) {
                for (idx, ess) in &ip.associations {
                    if let Some(p) = meta.props.iter().find(|p| p.index == *idx) {
                        println!("ipma prop#{} type={} essential={} rawlen={}", idx, p.ptype, ess, p.raw.len());
                    }
                }
            }
        }
    }
}
