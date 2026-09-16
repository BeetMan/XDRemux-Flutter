fn main() {
    let path = std::env::args().nth(1).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let tiff = xdremux_core::styles_attach::extract_exif_tiff(&bytes).unwrap();
    println!("tiff len {}", tiff.len());
    println!("before: {:?}", xdremux_core::exif::parse_exif_orientation(&tiff));
    let mut t = tiff.clone();
    let changed = xdremux_core::exif::normalize_tiff_orientation(&mut t);
    println!("normalize changed={} ", changed);
    println!("after:  {:?}", xdremux_core::exif::parse_exif_orientation(&t));
    // dump the first bytes to see the IFD0 layout
    println!("header {:02x?}", &t[..8]);
    let be = t[0] == b'M';
    let off = if be { u32::from_be_bytes(t[4..8].try_into().unwrap()) } else { u32::from_le_bytes(t[4..8].try_into().unwrap()) } as usize;
    println!("ifd0 at {} (be={})", off, be);
    let n = if be { u16::from_be_bytes(t[off..off+2].try_into().unwrap()) } else { u16::from_le_bytes(t[off..off+2].try_into().unwrap()) };
    println!("ifd0 entries {}", n);
    for i in 0..n as usize {
        let e = off + 2 + i*12;
        let tag = if be { u16::from_be_bytes(t[e..e+2].try_into().unwrap()) } else { u16::from_le_bytes(t[e..e+2].try_into().unwrap()) };
        if tag == 0x0112 || tag == 0x8769 {
            println!("  entry {} tag {:#06x} raw {:02x?}", i, tag, &t[e..e+12]);
        }
    }
}
