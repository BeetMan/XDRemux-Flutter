//! Probe: inject the 12 zero-content 2026 semantic part-matte items.
use xdremux_core::semantic_mattes::inject_semantic_mattes;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: matte_inject <input> <output>".into());
    }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let out = inject_semantic_mattes(&data)?;
    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: {} -> {}", args[1], args[2]);
    Ok(())
}
