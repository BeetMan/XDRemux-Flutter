use std::env;

fn read_item(data: &[u8], meta: &xdremux_core::isobmff::ParsedMeta, item_id: u32) -> Option<Vec<u8>> {
    let entry = meta.iloc_entries.iter().find(|e| e.item_id == item_id)?;
    let &(off, len) = entry.extents.first()?;
    data.get(off as usize..(off + len) as usize).map(|p| p.to_vec())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: compare_edof <input_huawei.heic>");
        return;
    }
    let data = std::fs::read(&args[1]).expect("read file");
    let meta = xdremux_core::isobmff::parse_source_meta(&data).expect("parse meta");
    
    println!("Primary item ID: {}", meta.primary_id);
    for e in &meta.ipma_entries {
        if e.item_id == 15 || e.item_id == 35 {
            println!("ipma for {}: {:?}", e.item_id, e.associations);
        }
    }
    let edof_item = meta.items.iter().find(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"edof"));
    println!("Edof item: {:?}", edof_item.map(|i| i.item_id));

    // Read RfDataB
    let rf_item = meta.items.iter().find(|i| i.itype == "mime" && i.raw_infe.windows(7).any(|w| w == b"RfDataB"));
    if let Some(rf) = rf_item {
        let payload = read_item(&data, &meta, rf.item_id).unwrap();
        let raw_plane = &payload[64..64 + 1024 * 768];
        let min = *raw_plane.iter().min().unwrap();
        let max = *raw_plane.iter().max().unwrap();
        let mut sorted = raw_plane.to_vec();
        sorted.sort_unstable();
        let median = sorted[sorted.len() / 2];
        let p10 = sorted[sorted.len() / 10];
        let p90 = sorted[sorted.len() * 9 / 10];
        println!("RfDataB plane: min={}, max={}, median={}, p10={}, p90={}", min, max, median, p10, p90);
    }
}
