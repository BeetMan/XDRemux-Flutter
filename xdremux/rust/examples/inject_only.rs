//! Pure injection probe: only add the texture_styles item, no grafting.
use xdremux_core::texture_styles::inject_texture_styles;
fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let out = inject_texture_styles(&data, 104)?;
    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: {} -> {}", args[1], args[2]);
    Ok(())
}
