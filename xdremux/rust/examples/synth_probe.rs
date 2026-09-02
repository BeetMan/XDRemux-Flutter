fn main() {
    let source = std::fs::read("/Users/beet/Downloads/动态照片/大师 3x.jpg").unwrap();
    let info = xdremux_core::uhdr_jpeg::parse(&source).unwrap().unwrap();
    let synth = xdremux_core::uhdr_jpeg::synthesize_source_container(&source, &info, false).unwrap();
    std::fs::write("/tmp/synth-container.heic", &synth).unwrap();
    println!("synth size {}", synth.len());
    match heif_oxide::decode_bytes(&synth) {
        Ok(img) => println!("heif-oxide decode OK: {}x{}", img.width, img.height),
        Err(e) => println!("heif-oxide decode ERR: {e:?}"),
    }
}
