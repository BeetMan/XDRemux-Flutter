//! Debug: build a style-metadata plist with stats overrides and dump internals.
use xdremux_core::styles_native::{StyleStateOverride, SemanticFlags};

fn main() {
    let mut state = StyleStateOverride::identity();
    state.stats = Some(vec![
        ("ToneMappedImage", [0.0658, 0.6513, 0.0804, 0.1213, 0.3294, 0.4661, 0.5611, 0.6758, 0.693]),
        ("LinearImage", [0.0055, 0.3817, 0.0072, 0.0137, 0.0886, 0.184, 0.2751, 0.4143, 0.4381]),
    ]);
    state.key7 = Some(SemanticFlags { people_ratio: 0.0, skin_ratio: 0.0, person_masks_valid_hint: 0.0 });
    let plist = xdremux_core::styles_native::debug_build(&state);
    std::fs::write("/tmp/debug_style.plist", &plist).unwrap();
    println!("plist bytes: {}", plist.len());
}
