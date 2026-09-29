//! Produce a PS3 availability probe: graft a StyleStateOverride into a
//! styles-only converted HEIC, then inject the Standard texture_styles item.
//!
//! Usage: styles_ps3_probe <input.heic> <output.heic> <key0> <tag5> [seed]

use xdremux_core::styles_native::{replace_style_metadata, StyleStateOverride};
use xdremux_core::texture_styles::inject_texture_styles;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        return Err("usage: styles_ps3_probe <input> <output> <key0> <tag5> [seed]".into());
    }
    let input = &args[1];
    let output = &args[2];
    let key0: u64 = args[3].parse().map_err(|e| format!("key0: {e}"))?;
    let tag5: u64 = args[4].parse().map_err(|e| format!("tag5: {e}"))?;
    let seed: u64 = if args.len() > 5 {
        args[5].parse().map_err(|e| format!("seed: {e}"))?
    } else {
        104
    };

    let data = std::fs::read(input).map_err(|e| format!("read: {e}"))?;
    let mut state = StyleStateOverride::identity();
    state.key0 = key0;
    state.tag5 = tag5;
    let grafted = replace_style_metadata(&data, &state)?;
    let patched = inject_texture_styles(&grafted, seed)?;
    std::fs::write(output, patched).map_err(|e| format!("write: {e}"))?;
    println!("OK: {input} -> {output} (key0={key0}, tag5={tag5}, seed={seed})");
    Ok(())
}
