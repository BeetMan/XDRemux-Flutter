fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        let top = xdremux_core::isobmff::parse_boxes(&data, 0, data.len());
        let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
        let kids = xdremux_core::isobmff::parse_boxes(&data, meta.data_start + 4, meta.data_end);
        let iloc = kids.iter().find(|b| &b.btype == b"iloc").unwrap();
        let iinf = kids.iter().find(|b| &b.btype == b"iinf").unwrap();
        let mdat = top.iter().find(|b| &b.btype == b"mdat").unwrap();
        let items = xdremux_core::isobmff::parse_iinf(&data, iinf).unwrap();
        let entries = xdremux_core::isobmff::parse_iloc(&data, iloc).unwrap();
        let name = std::path::Path::new(&path).file_name().unwrap().to_string_lossy().to_string();
        for it in &items {
            if it.itype == "Exif" {
                let e = entries.iter().find(|e| e.item_id == it.item_id).unwrap();
                let mut payload = Vec::new();
                for &(off, len) in &e.extents {
                    let start = off as usize;
                    let end = start + len as usize;
                    if end <= data.len() { payload.extend_from_slice(&data[start..end]); }
                }
                if payload.len() < 14 { println!("{name}: Exif too short"); continue; }
                let off = u32::from_be_bytes(payload[0..4].try_into().unwrap()) as usize;
                let tiff = 4 + off;
                let le = payload.get(tiff..tiff+2) == Some(b"II");
                let ifd0 = tiff + 8;
                let cnt = read16(&payload, ifd0, le) as usize;
                let mut gps_abs = None; let mut exif_abs = None;
                for i in 0..cnt {
                    let eo = ifd0 + 2 + i*12;
                    if eo + 12 > payload.len() { break; }
                    let tag = read16(&payload, eo, le);
                    if tag == 0x8825 { gps_abs = Some(tiff + read32(&payload, eo+8, le) as usize); }
                    if tag == 0x8769 { exif_abs = Some(tiff + read32(&payload, eo+8, le) as usize); }
                }
                let gps_count = gps_abs.map(|g| read16(&payload, g, le)).unwrap_or(0);
                let mut uc = None;
                if let Some(ef) = exif_abs {
                    let ec = read16(&payload, ef, le) as usize;
                    for i in 0..ec {
                        let eo = ef + 2 + i*12;
                        if eo + 12 > payload.len() { break; }
                        if read16(&payload, eo, le) == 0x9286 {
                            let c = read32(&payload, eo+4, le) as usize;
                            let vo = read32(&payload, eo+8, le) as usize;
                            let vs = if c > 4 { tiff + vo } else { eo + 8 };
                            if vs + c <= payload.len() {
                                uc = Some(String::from_utf8_lossy(&payload[vs..vs+c]).to_string());
                            }
                        }
                    }
                }
                println!("{name}: Exif_len={} GPS_IFD={:?} ({} entries) UC={:?}", payload.len(), gps_abs.map(|g| g - tiff), gps_count, uc);
            }
        }
    }
}
fn read16(d: &[u8], o: usize, le: bool) -> u16 {
    let b: [u8;2] = d[o..o+2].try_into().unwrap();
    if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) }
}
fn read32(d: &[u8], o: usize, le: bool) -> u32 {
    let b: [u8;4] = d[o..o+4].try_into().unwrap();
    if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) }
}
