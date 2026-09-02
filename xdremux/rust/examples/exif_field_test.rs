// Field-level EXIF experiments: patch Make/Model/MakerNote in the target's
// Exif item to isolate which fields gate the Photographic Styles editor.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: exif_field_test <target-heic> <mode:make|maker|both> <out-heic>");
        std::process::exit(2);
    }
    let target_path = &args[1];
    let mode = args[2].as_str();
    let out_path = &args[3];

    let mut data = std::fs::read(target_path).unwrap();
    let meta = xdremux_core::isobmff::parse_source_meta(&data).unwrap();
    let exif_id = meta
        .items
        .iter()
        .find(|it| it.itype == "Exif")
        .map(|it| it.item_id)
        .expect("no Exif item");
    let payload = xdremux_core::isobmff_write::read_exif_payload(&data)
        .unwrap()
        .expect("no Exif payload");

    // parse TIFF (assume offset field handled: find II/MM)
    let tiff_start = if payload.starts_with(b"II") || payload.starts_with(b"MM") {
        0
    } else {
        4 + u32::from_be_bytes(payload[..4].try_into().unwrap()) as usize
    };
    let tiff = &payload[tiff_start..];
    let le = &tiff[0..2] == b"II";
    let u16 = |o: usize| -> u16 {
        let b: [u8; 2] = tiff[o..o + 2].try_into().unwrap();
        if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) }
    };
    let u32 = |o: usize| -> u32 {
        let b: [u8; 4] = tiff[o..o + 4].try_into().unwrap();
        if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) }
    };
    let ifd0 = u32(4) as usize;
    let n = u16(ifd0) as usize;

    // modify entries
    let mut tiff_out: Vec<u8> = tiff.to_vec();
    let mut set_ascii = |tag: u16, value: &[u8], tiff_out: &mut Vec<u8>| {
        for k in 0..n {
            let base = ifd0 + 2 + k * 12;
            if u16(base) == tag {
                let cnt = u32(base + 4) as usize;
                let vo = u32(base + 8) as usize;
                // value area inside tiff_out: tiff coordinates = file coords here
                if cnt >= value.len() {
                    tiff_out[vo..vo + value.len()].copy_from_slice(value);
                    tiff_out[vo + value.len()..vo + cnt].fill(0);
                } else {
                    // grow not supported in-place; truncate value
                    tiff_out[vo..vo + cnt].copy_from_slice(&value[..cnt]);
                }
            }
        }
    };
    match mode {
        // Make -> "Apple"
        "make" => set_ascii(0x010F, b"Apple\0", &mut tiff_out),
        // Model -> "iPhone 16e"
        "model" => set_ascii(0x0110, b"iPhone 16e\0", &mut tiff_out),
        "both" => {
            set_ascii(0x010F, b"Apple\0", &mut tiff_out);
            set_ascii(0x0110, b"iPhone 16e\0", &mut tiff_out);
        }
        _ => panic!("unknown mode"),
    }

    // rebuild payload with prefix
    let mut new_payload = payload[..tiff_start].to_vec();
    new_payload.extend_from_slice(&tiff_out);
    // relocate? The TIFF was edited in place (same size), so the payload is
    // still the same size — no container surgery needed, just overwrite the
    // mdat bytes at the Exif extent. Find and patch the extent directly.
    let parsed2 = xdremux_core::isobmff::parse_source_meta(&data).unwrap();
    let entry = parsed2
        .iloc_entries
        .iter()
        .find(|e| e.item_id == exif_id)
        .unwrap();
    for &(off, len) in &entry.extents {
        if entry.construction_method == 0 && len as usize == new_payload.len() {
            data[off as usize..off as usize + len as usize].copy_from_slice(&new_payload);
        } else {
            panic!("extent size mismatch; in-place patch not possible");
        }
    }
    std::fs::write(out_path, &data).unwrap();
    println!("{} written (mode={mode})", out_path);
}
