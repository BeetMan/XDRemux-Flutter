fn main() {
    let data = std::fs::read("/tmp/lp-nostyle/大师 3x_iso.heic").unwrap();
    let payload = xdremux_core::isobmff_write::read_exif_payload(&data)
        .unwrap()
        .expect("no exif payload");
    println!("payload len {}", payload.len());
    let tiff = &payload[10..];
    let le = &tiff[0..2] == b"II";
    let u16v = |t: &[u8], o: usize| -> u16 {
        let b: [u8; 2] = t[o..o + 2].try_into().unwrap();
        if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) }
    };
    let u32v = |t: &[u8], o: usize| -> u32 {
        let b: [u8; 4] = t[o..o + 4].try_into().unwrap();
        if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) }
    };
    let ifd0 = u32v(tiff, 4) as usize;
    let n = u16v(tiff, ifd0) as usize;
    let mut exif_off = None;
    for k in 0..n {
        let e = ifd0 + 2 + k * 12;
        if u16v(tiff, e) == 0x8769 {
            exif_off = Some(u32v(tiff, e + 8) as usize);
        }
    }
    let exif_off = exif_off.expect("no ExifIFD");
    let en = u16v(tiff, exif_off) as usize;
    for k in 0..en {
        let e = exif_off + 2 + k * 12;
        if u16v(tiff, e) == 0x927C {
            let cnt = u32v(tiff, e + 4) as usize;
            let vo = u32v(tiff, e + 8) as usize;
            let note = &tiff[vo..vo + cnt];
            println!("makernote len {} head: {:02x?}", cnt, &note[..16.min(note.len())]);
            println!("starts with Apple iOS: {}", note.starts_with(b"Apple iOS\0\0\x01"));
            return;
        }
    }
    println!("no 0x927C in ExifIFD");
}
