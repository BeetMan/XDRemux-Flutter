// JPEG → tiled grid HEIC via container_build (Phase 2a).
use xdremux_core::container_build::build_heic_grid;
use xdremux_core::jpeg_decode::decode_jpeg_to_rgb;

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 3 {
        return Err("usage: build_test <jpeg-in> <heic-out>".into());
    }
    let jpeg = std::fs::read(&a[1]).map_err(|e| format!("read: {e}"))?;
    let (rgb, w, h) = decode_jpeg_to_rgb(&jpeg).map_err(|e| format!("jpeg decode: {e}"))?;
    println!("decoded {}x{}", w, h);
    let with_exif = std::env::var("NO_EXIF").is_err();
    let built = build_heic_grid(&rgb, w, h, with_exif)?;
    std::fs::write(&a[2], &built.data).map_err(|e| format!("write: {e}"))?;
    println!(
        "OK {} -> {} (grid {}x{}, {} tiles)",
        a[1],
        a[2],
        built.cols,
        built.rows,
        built.cols * built.rows
    );
    Ok(())
}
