fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        let t = std::time::Instant::now();
        match heif_oxide::decode_bytes(&data) {
            Ok(img) => {
                let (kind, n) = match &img.pixels {
                    heif_oxide::Pixels::Rgb8(v) => ("Rgb8", v.len()),
                    heif_oxide::Pixels::Rgba8(v) => ("Rgba8", v.len()),
                    heif_oxide::Pixels::Rgb16(v) => ("Rgb16", v.len()),
                    heif_oxide::Pixels::Rgba16(v) => ("Rgba16", v.len()),
                    _ => ("other", 0),
                };
                println!(
                    "OK   {}x{} {} n={} in {:?}  {}",
                    img.width,
                    img.height,
                    kind,
                    n,
                    t.elapsed(),
                    path.rsplit('/').next().unwrap()
                );
            }
            Err(e) => println!("FAIL {:?} : {}", e, path.rsplit('/').next().unwrap()),
        }
    }
}
