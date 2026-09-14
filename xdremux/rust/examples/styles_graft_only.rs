//! Graft-only probe: replace the styleMetadata payload with our identity
//! state (no texture_styles injection). Used to test whether the iOS 27
//! texture/grain editor requires the native styles state.
//!
//! Usage: styles_graft_only <input.heic> <output.heic> <key0> <tag5>

use xdremux_core::styles_native::{replace_style_metadata, StyleStateOverride};

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        return Err("usage: styles_graft_only <input> <output> <key0> <tag5>".into());
    }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let key0: u64 = args[3].parse().map_err(|e| format!("key0: {e}"))?;
    let tag5: u64 = args[4].parse().map_err(|e| format!("tag5: {e}"))?;
    let mut state = StyleStateOverride::identity();
    state.key0 = key0;
    state.tag5 = tag5;
    let out = replace_style_metadata(&data, &state)?;
    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: {} -> {} (key0={key0}, tag5={tag5})", args[1], args[2]);
    Ok(())
}
