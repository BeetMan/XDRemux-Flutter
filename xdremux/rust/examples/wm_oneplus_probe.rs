use std::fs;

fn primary_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    let parsed = xdremux_core::isobmff::parse_source_meta(data).ok()?;
    let top = xdremux_core::isobmff::parse_boxes(data, 0, data.len());
    let meta = top.iter().find(|b| &b.btype == b"meta")?;
    let kids = xdremux_core::isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
    let iprp = kids.iter().find(|b| &b.btype == b"iprp")?;
    let props = xdremux_core::isobmff::parse_iprp_properties(data, iprp).ok()?;
    // ipma associations for the primary item
    let assoc: Vec<u32> = parsed
        .ipma_entries
        .iter()
        .find(|e| e.item_id == parsed.primary_id)?
        .associations
        .iter()
        .map(|(i, _)| *i)
        .collect();
    for p in &props {
        if !assoc.contains(&p.index) {
            continue;
        }
        if &p.raw[4..8] == b"ispe" && p.raw.len() >= 20 {
            let w = xdremux_core::isobmff::read_u32be(&p.raw, 12);
            let h = xdremux_core::isobmff::read_u32be(&p.raw, 16);
            return Some((w, h));
        }
    }
    None
}

fn main() {
    for path in std::env::args().skip(1) {
        let data = fs::read(&path).unwrap();
        let name = std::path::Path::new(&path)
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        let has_wm = xdremux_core::container::has_watermark_entries(&data);
        let dims = primary_dimensions(&data);
        let wm_len =
            xdremux_core::container::extract_tail_entry(&data, "watermark").map(|v| v.len());
        let cfg = xdremux_core::container::extract_tail_entry(&data, "watermark.config");
        let cfg_hex = cfg.as_ref().map(|v| {
            v[..v.len().min(24)]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        });
        print!("{name}: dims={dims:?} has_wm={has_wm} watermark_len={wm_len:?} config={cfg_hex:?}");
        if let Some((w, h)) = dims {
            let rect = xdremux_core::container::watermark_canvas_rect(&data, w, h);
            let overlay = xdremux_core::container::watermark_overlay_rect(&data, w, h);
            print!(" canvas={rect:?} overlay={overlay:?}");
        }
        println!();
    }
}
