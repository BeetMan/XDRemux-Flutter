use xdremux_core::isobmff;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let data = std::fs::read(&path).unwrap();
    let meta = isobmff::parse_source_meta(&data).unwrap();
    for item in &meta.items {
        let raw = String::from_utf8_lossy(&item.raw_infe);
        let mut tags = Vec::new();
        for part in raw.split('\0') {
            if part.contains("apple.com") || part.contains("urn:") || part.contains("tag:") { tags.push(part.to_string()); }
        }
        // dims + auxC via ipma
        let mut dims = String::new(); let mut auxc = String::new();
        if let Some(e) = meta.ipma_entries.iter().find(|e| e.item_id == item.item_id) {
            for (idx,_) in &e.associations {
                if let Some(p) = meta.props.iter().find(|p| p.index==*idx) {
                    if p.ptype=="ispe" { if let Ok((w,h))=isobmff::ispe_dimensions(&p.raw){dims=format!("{}x{}",w,h);} }
                    if p.ptype=="auxC" { auxc = String::from_utf8_lossy(&p.raw).trim_matches(char::from(0)).trim_start_matches(|c:char| c.is_ascii_digit() || c=='\0').to_string(); }
                }
            }
        }
        println!("id={:3} type={:6} dims={:9} auxC={} tags={:?}", item.item_id, item.itype, dims, auxc, tags);
    }
}
