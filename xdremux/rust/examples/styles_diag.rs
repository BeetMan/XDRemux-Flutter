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

    // OPPO tail entries
    let tails = xdremux_core::container::tail_entry_names(&data);
    println!("tail entries: {:?}", tails);
    println!("has_watermark_entries={}", xdremux_core::container::has_watermark_entries(&data));

    // heif-oxide decode test
    match heif_oxide::decode_bytes(&data) {
        Ok(img) => {
            println!(
                "heif-oxide decode primary: {}x{} ({}ch {}bit)",
                img.width,
                img.height,
                img.channels(),
                img.bit_depth()
            );
            let out = std::path::Path::new(&path).with_extension("png");
            let rgba = img.to_rgba8();
            if let Ok(png) = png_encode_rgba(&rgba, img.width, img.height) {
                let _ = std::fs::write(&out, png);
                println!("wrote {}", out.display());
            }
        }
        Err(e) => println!("heif-oxide decode primary FAILED: {e}"),
    }
}

fn png_encode_rgba(rgba: &[u8], w: u32, h: u32) -> Result<Vec<u8>, String> {
    // minimal PNG encoder (RGBA8, no filtering) using stored zlib blocks
    let mut raw = Vec::with_capacity((w as usize * 4 + 1) * h as usize);
    for y in 0..h as usize {
        raw.push(0u8);
        raw.extend_from_slice(&rgba[y * w as usize * 4..(y + 1) * w as usize * 4]);
    }
    let mut zlib = Vec::new();
    zlib.extend_from_slice(&[0x78, 0x01]);
    let mut pos = 0;
    while pos < raw.len() {
        let chunk = (raw.len() - pos).min(65535);
        let fin = pos + chunk == raw.len();
        zlib.push(if fin { 1 } else { 0 });
        zlib.extend_from_slice(&(chunk as u16).to_le_bytes());
        zlib.extend_from_slice(&(!(chunk as u16)).to_le_bytes());
        zlib.extend_from_slice(&raw[pos..pos + chunk]);
        pos += chunk;
    }
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    png_chunk(&mut png, b"IHDR", &ihdr);
    png_chunk(&mut png, b"IDAT", &zlib);
    png_chunk(&mut png, b"IEND", &[]);
    Ok(png)
}

fn adler32(data: &[u8]) -> u32 {
    let mut a: u32 = 1;
    let mut b: u32 = 0;
    for &x in data {
        a = (a + x as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn png_chunk(out: &mut Vec<u8>, ctype: &[u8; 4], payload: &[u8]) {
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(ctype);
    out.extend_from_slice(payload);
    let mut crc: u32 = 0xffff_ffff;
    for &b in ctype.iter().chain(payload.iter()) {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    out.extend_from_slice(&(!crc).to_be_bytes());
}
