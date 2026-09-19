use xdremux_core::isobmff;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let data = std::fs::read(&path).unwrap();
    let meta = isobmff::parse_source_meta(&data).unwrap();
    for item in &meta.items {
        let raw = String::from_utf8_lossy(&item.raw_infe);
        let auxc = {
            let mut s = String::new();
            if let Some(e) = meta.ipma_entries.iter().find(|e| e.item_id == item.item_id) {
                for (idx,_) in &e.associations {
                    if let Some(p) = meta.props.iter().find(|p| p.index==*idx) {
                        if p.ptype=="auxC" { s = String::from_utf8_lossy(&p.raw).trim_matches(char::from(0)).trim_start_matches(|c:char| c.is_ascii_digit()||c=='\0').to_string(); }
                    }
                }
            }
            s
        };
        if !auxc.contains("semantic") && !auxc.contains("aux") { continue; }
        // dims + pixi + data length
        let mut dims = String::new(); let mut pixi = String::new();
        if let Some(e) = meta.ipma_entries.iter().find(|e| e.item_id == item.item_id) {
            for (idx,_) in &e.associations {
                if let Some(p) = meta.props.iter().find(|p| p.index==*idx) {
                    if p.ptype=="ispe" { if let Ok((w,h))=isobmff::ispe_dimensions(&p.raw){dims=format!("{}x{}",w,h);} }
                    if p.ptype=="pixi" { if let Some(&ch)=p.raw.last(){ pixi = format!("{}ch", ch); } }
                }
            }
        }
        let dlen = meta.iloc_entries.iter().find(|e| e.item_id==item.item_id).map(|e| e.extents.iter().map(|x| x.1).sum::<u64>()).unwrap_or(0);
        println!("id={:3} {:10} {:6} {:>7}B  {}", item.item_id, dims, pixi, dlen, auxc.split("aux:").last().unwrap_or(&auxc));
    }
}
