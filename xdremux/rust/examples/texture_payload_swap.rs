//! PS3 payload-content probe: replace the texture_styles item's payload in a
//! HEIC that already carries one (e.g. a native iPhone 18 Pro capture) with
//! our synthesized Standard payload. Used to test which payload fields the
//! iOS 27 style editor requires.
//!
//! Usage: texture_payload_swap <input.heic> <output.heic> [grain_seed]

use xdremux_core::isobmff;
use xdremux_core::isobmff_write::replace_item_payload;
use xdremux_core::texture_styles::texture_info_payload;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        return Err("usage: texture_payload_swap <input> <output> [seed]".into());
    }
    let data = std::fs::read(&args[1]).map_err(|e| format!("read: {e}"))?;
    let seed: u64 = args.get(3).map(|s| s.parse().unwrap_or(104)).unwrap_or(104);

    let parsed = isobmff::parse_source_meta(&data)?;
    let item_id = parsed
        .items
        .iter()
        .find(|i| i.raw_infe.windows(14).any(|w| w == b"texture_styles"))
        .map(|i| i.item_id)
        .ok_or("no texture_styles item in input")?;

    let mut out = data.clone();
    replace_item_payload(&mut out, item_id, None, &texture_info_payload(seed))?;
    std::fs::write(&args[2], out).map_err(|e| format!("write: {e}"))?;
    println!("OK: swapped texture_styles payload of item {item_id} -> {}", args[2]);
    Ok(())
}
