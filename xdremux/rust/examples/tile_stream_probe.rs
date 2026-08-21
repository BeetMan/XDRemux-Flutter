fn main() {
    // Solid dark-gray tile (16,16,16) — the value that crushes to 0 in the
    // final decode. Encode via the same path the watermark restore uses.
    let rgb = vec![16u8; 512 * 512 * 3];
    let planes: Vec<&[u8]> = vec![&rgb];
    let streams = xdremux_core::hevc::x265_encode_tiles(&planes, 512, 512, 3, true).unwrap();
    std::fs::write("C:/Users/Beet/AppData/Local/Temp/android-issue/tile16.h265", &streams[0]).unwrap();
    println!("wrote {} bytes", streams[0].len());
}
