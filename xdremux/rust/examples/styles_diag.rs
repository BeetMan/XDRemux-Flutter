use std::env;

fn main() {
    let path = env::args().nth(1).expect("usage: styles_diag <file.heic>");
    let data = std::fs::read(&path).expect("read failed");
    println!("file: {} ({} bytes)", path, data.len());

    // Top-level boxes
    let top = xdremux_core::isobmff::parse_boxes(&data, 0, data.len());
    for b in &top {
        println!(
            "top box {} size={} offset={}",
            String::from_utf8_lossy(&b.btype),
            b.size,
            b.box_start
        );
    }

    // Meta structure
    match xdremux_core::isobmff::parse_source_meta(&data) {
        Ok(meta) => {
            println!("primary_id={} pitm_version={}", meta.primary_id, meta.pitm_version);
            println!("items:");
            for item in &meta.items {
                let extent: u64 = meta
                    .iloc_entries
                    .iter()
                    .filter(|e| e.item_id == item.item_id)
                    .flat_map(|e| e.extents.iter())
                    .map(|&(_, len)| len)
                    .sum();
                println!(
                    "  id={} type={} flags={} data_len={}",
                    item.item_id, item.itype, item.flags, extent
                );
            }
            println!("refs:");
            for r in &meta.refs {
                println!("  {} from={} to={:?}", r.rtype, r.from, r.to);
            }
            println!("props:");
            for p in &meta.props {
                println!(
                    "  idx={} type={} len={}",
                    p.index,
                    p.ptype,
                    p.raw.len()
                );
            }

            // ipma associations for key items + anything carrying auxC
            let key_items = [10081u32, 10108, 10136, 10173, 10140, 10174, 10176, 10109, 10137];
            println!("ipma associations:");
            for e in &meta.ipma_entries {
                let has_auxc = e.associations.iter().any(|&(idx, _)| {
                    meta.props
                        .iter()
                        .find(|p| p.index == idx)
                        .map(|p| p.ptype == "auxC")
                        .unwrap_or(false)
                });
                if key_items.contains(&e.item_id) || has_auxc {
                    let desc: Vec<String> = e
                        .associations
                        .iter()
                        .map(|&(idx, essential)| {
                            let ptype = meta
                                .props
                                .iter()
                                .find(|p| p.index == idx)
                                .map(|p| p.ptype.clone())
                                .unwrap_or_else(|| "?".to_string());
                            format!("{idx}:{ptype}{}", if essential { "!" } else { "" })
                        })
                        .collect();
                    println!("  item {} -> [{}]", e.item_id, desc.join(", "));
                }
            }

            // ispe values
            println!("ispe values:");
            for p in &meta.props {
                if p.ptype == "ispe" {
                    if let Ok((w, h)) = xdremux_core::isobmff::ispe_dimensions(&p.raw) {
                        println!("  idx={} {}x{}", p.index, w, h);
                    }
                }
            }

            // auxC strings
            println!("auxC values:");
            for p in &meta.props {
                if p.ptype == "auxC" {
                    let s = String::from_utf8_lossy(&p.raw);
                    println!("  idx={} {}", p.index, s.trim_matches('\0'));
                }
            }

            // grid payloads
            let read_item = |item_id: u32| -> Option<Vec<u8>> {
                let entry = meta.iloc_entries.iter().find(|e| e.item_id == item_id)?;
                let mut out = Vec::new();
                for &(off, len) in &entry.extents {
                    let start = off as usize;
                    let end = start + len as usize;
                    if end > data.len() {
                        return None;
                    }
                    out.extend_from_slice(&data[start..end]);
                }
                Some(out)
            };
            println!("grids:");
            for gid in [10081u32, 10108, 10136, 10173] {
                if let Some(entry) = meta.iloc_entries.iter().find(|e| e.item_id == gid) {
                    println!("  grid {} extents={:?}", gid, entry.extents);
                }
                if let Some(g) = read_item(gid) {
                    println!("  grid {} payload={:02x?}", gid, g);
                }
            }
        }
        Err(e) => println!("parse_source_meta error: {e}"),
    }

    // heif-oxide decode test
    match heif_oxide::decode_bytes(&data) {
        Ok(img) => println!(
            "heif-oxide decode primary: {}x{} ({}ch {}bit)",
            img.width,
            img.height,
            img.channels(),
            img.bit_depth()
        ),
        Err(e) => println!("heif-oxide decode primary FAILED: {e}"),
    }
}
