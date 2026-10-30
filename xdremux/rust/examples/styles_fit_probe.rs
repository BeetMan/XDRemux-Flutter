//! Measure the per-image key 1 / key 3 fits against identity on real files.
//!
//! Usage: `cargo run --release -p xdremux-core --example styles_fit_probe -- <a.heic> [...]`
//!
//! Decodes the primary like the Styles writer does (no gain map), fits with
//! the identity plist's key 4 / h, and prints RMSE on the consumer model the
//! fit assumes. Not a Photos verdict: device A/B is still required.

use xdremux_core::styles_fit::{
    apply_global_tone_curve, apply_style_data, decode_global_tone_curve, fit_style_state,
};
use xdremux_core::styles_native::StyleStateOverride;

fn rmse(a: &[f32], b: &[f32]) -> f64 {
    (a.iter()
        .zip(b)
        .map(|(&x, &y)| (f64::from(x) - f64::from(y.clamp(0.0, 1.0))).powi(2))
        .sum::<f64>()
        / a.len() as f64)
        .sqrt()
}

fn main() {
    let identity = StyleStateOverride::identity();
    let identity_gtc = decode_global_tone_curve(&identity.gtc).expect("identity GTC");
    println!("file\tgtc_fit\tgtc_identity\tgtc_monotonic\tkey1_fit\tkey1_identity");
    for path in std::env::args().skip(1) {
        let bytes = std::fs::read(&path).expect("read input");
        let out = match xdremux_core::linear_thumbnail::generate_linear_thumbnail_and_light_maps(
            &bytes,
            0,
            1,
            identity.tag4 as f32,
        ) {
            Ok(out) => out,
            Err(e) => {
                println!("{path}\terror: {e}");
                continue;
            }
        };
        let raster = &out.fit_raster;
        let fitted = fit_style_state(raster, identity.tag4, identity.tag_h).expect("fit");
        let scale = identity.tag_h / identity.tag4;
        let s: Vec<f32> = raster
            .scene_linear
            .iter()
            .map(|&v| (f64::from(v) * scale).clamp(0.0, 1.0) as f32)
            .collect();
        let gtc = &fitted.global_tone_curve;
        let gtc_identity = rmse(&apply_global_tone_curve(&s, &identity_gtc), &raster.primary_linear);
        let monotonic = gtc.linear_samples.windows(2).all(|p| p[0] <= p[1]);
        let applied = apply_style_data(
            &fitted.style_data,
            raster.width,
            raster.height,
            &raster.primary_linear,
        )
        .expect("apply key1");
        let key1_fit = rmse(&applied, &s);
        let key1_identity = rmse(&raster.primary_linear, &s);
        println!(
            "{path}\t{:.5}\t{gtc_identity:.5}\t{monotonic}\t{key1_fit:.5}\t{key1_identity:.5}",
            gtc.fit_rmse
        );
    }
}
