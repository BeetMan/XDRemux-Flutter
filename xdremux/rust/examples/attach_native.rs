// Full styles pipeline on an arbitrary HDR HEIC + PS3 contract injection.
use xdremux_core::semantic_mattes::inject_semantic_mattes;
use xdremux_core::styles_attach::strip_makernote;
use xdremux_core::styles_native::styles_native;

use xdremux_core::texture_styles::inject_texture_styles;

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 3 { return Err("usage: attach_native <in> <out>".into()); }
    let mut data = std::fs::read(&a[1]).map_err(|e| format!("read: {e}"))?;
    // 0. strip the native camera maker note (its signature gates the editor
    //    and the scaffold merge cannot expand it)
    strip_makernote(&mut data)?;
    // 1. full styles pipeline (styledeltamap + linear thumbnail + sky matte + styles item + maker note)
    let styled = styles_native(&data)?;
    // 2. keep the identity state (native captures keep their own if present —
    //    styles_native already wrote identity for non-style devices)
    // 3. PS3: texture_styles + 12 mattes
    let out = inject_texture_styles(&styled, 104)?;
    let out = inject_semantic_mattes(&out)?;
    std::fs::write(&a[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK {} -> {}", a[1], a[2]);
    Ok(())
}
