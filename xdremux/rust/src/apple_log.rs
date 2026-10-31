//! Apple Log transfer function and Linear Thumbnail code generation.
//!
//! The Photographic Styles `aux:linearthumbnail` item does not store sRGB or
//! linear-light RGB in the Styles case: it stores **Apple Log codes**, which
//! the Photos style picker decodes back to scene linear before tone mapping.
//! Ported from upstream `21Z121Z1/XDRemux`
//! (`crates/xdremux-engine/src/apple_photographic_styles.rs`, macOS 26A434
//! consumer constants), keeping the exact same constants and boundary rules.
//!
//! Current port scope (deliberate, see `docs/modules/styles-pipeline.md`):
//!
//! - the decoder side is verified against the macOS exponential branch;
//! - the camera-side quadratic toe is **not** applied (the consumer decoder does
//!   not invert it, so applying it would double-count);
//! - codes are produced at 16-bit precision here; the encoder currently writes
//!   8-bit 4:2:0 HEVC, so [`thumbnail_codes_8bit`] is the interim quantization
//!   until a Main10 (10-bit) x265 build lands.

/// `A` from `code = A * log2(linear + B) + C`.
#[allow(clippy::excessive_precision)]
pub const APPLE_LOG_A: f64 = 0.085_504_792_630_672_45;
/// `B` (log toe lift) from `code = A * log2(linear + B) + C`.
#[allow(clippy::excessive_precision)]
pub const APPLE_LOG_B: f64 = 0.009_640_520_438_551_903;
/// `C` from `code = A * log2(linear + B) + C`.
#[allow(clippy::excessive_precision)]
pub const APPLE_LOG_C: f64 = 0.693_369_448_184_967;

/// Linear light -> Apple Log code in `[0, 1]`.
///
/// Values whose lifted linear sample is not strictly positive (including the
/// `-B` boundary and NaN) clamp to code 0; codes above 1 clamp to 1.
pub fn encode(linear: f64) -> f64 {
    let lifted = linear + APPLE_LOG_B;
    if lifted.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
        return 0.0;
    }
    (APPLE_LOG_A * lifted.log2() + APPLE_LOG_C).clamp(0.0, 1.0)
}

/// Apple Log code -> linear light (macOS exponential branch, `G = 1`).
///
/// `L = 2^((code - C) / A) - B`. The code is clamped to `[0, 1]` first, which
/// is the range the encoder can store.
pub fn decode(code: f64) -> f64 {
    let code = code.clamp(0.0, 1.0);
    2.0_f64.powf((code - APPLE_LOG_C) / APPLE_LOG_A) - APPLE_LOG_B
}

/// sRGB electro-optical transfer function (display code -> linear light).
///
/// `heif-oxide` returns display-ready sRGB, so the thumbnail generator has to
/// undo that transfer before applying Apple Log; otherwise the Photos consumer
/// would decode log over sRGB-encoded samples (double transfer, washed-out
/// preview).
pub fn srgb_to_linear(value: f64) -> f64 {
    if value <= 0.040_45 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
}

/// 8-bit sRGB display sample -> linear light.
pub fn srgb8_to_linear(sample: u8) -> f64 {
    srgb_to_linear(f64::from(sample) / 255.0)
}

fn check_raster(linear_rgb: &[f32], baseline_exposure: f32) -> Result<(), String> {
    if linear_rgb.is_empty() || !linear_rgb.len().is_multiple_of(3) {
        return Err(format!(
            "Apple Log thumbnail raster must be non-empty RGB, got {} samples",
            linear_rgb.len()
        ));
    }
    if !baseline_exposure.is_finite() || baseline_exposure <= 0.0 {
        return Err(format!(
            "Apple Log thumbnail baseline exposure must be finite and > 0, got {baseline_exposure}"
        ));
    }
    Ok(())
}

/// Encode a linear RGB raster as 16-bit Apple Log codes.
///
/// Each channel is divided by the Styles `styleData` baseline exposure (plist
/// key 4) before the log curve — the consumer multiplies it back after decode.
/// This is the precision the native Main10 thumbnail uses; it is kept here so
/// the 8-bit interim path and a future 10-bit encoder share one transfer.
pub fn thumbnail_codes(linear_rgb: &[f32], baseline_exposure: f32) -> Result<Vec<u16>, String> {
    check_raster(linear_rgb, baseline_exposure)?;
    let exposure = f64::from(baseline_exposure);
    linear_rgb
        .iter()
        .enumerate()
        .map(|(index, &value)| {
            if !value.is_finite() {
                return Err(format!(
                    "Apple Log thumbnail sample {index} is not finite: {value}"
                ));
            }
            let linear = f64::from(value) / exposure;
            Ok((encode(linear) * 65_535.0).round() as u16)
        })
        .collect()
}

/// Encode a linear RGB raster as 8-bit Apple Log codes (interim path).
///
/// Only the top `[0.0, 0.6946]` of the code range is used for SDR content
/// (linear 1.0 maps to code `A*log2(1+B)+C`), so this is a preview-grade
/// quantization; the planned Main10 encoder removes that limitation.
pub fn thumbnail_codes_8bit(linear_rgb: &[f32], baseline_exposure: f32) -> Result<Vec<u8>, String> {
    let codes = thumbnail_codes(linear_rgb, baseline_exposure)?;
    Ok(codes
        .into_iter()
        .map(|code| ((u32::from(code) + 128) / 257) as u8)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_match_the_upstream_consumer() {
        assert_eq!(APPLE_LOG_A, 0.085_504_792_630_672_45);
        assert_eq!(APPLE_LOG_B, 0.009_640_520_438_551_903);
        assert_eq!(APPLE_LOG_C, 0.693_369_448_184_967);
    }

    #[test]
    fn encode_decode_round_trip_within_code_precision() {
        // Code 1.0 is the top of the log range (~linear 12); above that the
        // encoder clamps, so the round trip is only defined below it.
        for linear in [0.0, 0.01, 0.18, 0.5, 1.0, 4.0, 8.0] {
            let code = encode(linear);
            let back = decode(code);
            if linear > 0.02 {
                assert!(
                    (back - linear).abs() <= linear * 0.01 + 1e-4,
                    "round trip failed for {linear}: code {code}, back {back}"
                );
            }
        }
    }

    #[test]
    fn encode_clamps_at_both_ends() {
        assert_eq!(encode(-1.0), 0.0);
        assert_eq!(encode(f64::NAN), 0.0);
        assert_eq!(encode(1.0e9), 1.0);
        // Exactly at the negative lift boundary there is no representable code.
        assert_eq!(encode(-APPLE_LOG_B), 0.0);
    }

    #[test]
    fn sdr_white_maps_to_the_expected_code_fraction() {
        // linear 1.0 -> A*log2(1+B)+C, i.e. the SDR top of the log code range.
        let code = encode(1.0);
        let expected = APPLE_LOG_A * (1.0 + APPLE_LOG_B).log2() + APPLE_LOG_C;
        assert!((code - expected).abs() < 1e-15);
        assert!((code - 0.694).abs() < 0.002, "unexpected white code {code}");
    }

    #[test]
    fn srgb_endpoints_are_preserved() {
        assert!((srgb_to_linear(0.0)).abs() < 1e-12);
        assert!((srgb_to_linear(1.0) - 1.0).abs() < 1e-12);
        // Mid grey 0.5 sRGB is ~0.2140 linear.
        assert!((srgb_to_linear(0.5) - 0.214_041_4).abs() < 1e-6);
        assert!((srgb8_to_linear(255) - 1.0).abs() < 1e-12);
    }

    #[test]
    fn thumbnail_codes_divide_by_baseline_exposure() {
        // The same linear sample at a larger exposure encodes to a lower code.
        let low = thumbnail_codes(&[1.0, 1.0, 1.0], 1.0).unwrap();
        let high = thumbnail_codes(&[1.0, 1.0, 1.0], 4.0).unwrap();
        assert!(low[0] > high[0]);
        assert_eq!(low.len(), 3);
        // White at exposure 1 -> code 0.694 -> 16-bit 45,500ish.
        assert!((i32::from(low[0]) - 45_500).abs() < 200);
    }

    #[test]
    fn thumbnail_codes_8bit_quantize_in_the_log_domain() {
        let codes = thumbnail_codes_8bit(&[1.0, 0.0, 4.0], 1.0).unwrap();
        // Apple Log puts black at the lift floor (linear 0 -> code ~0.121,
        // because the curve is log2(linear + B)), so 8-bit black is ~31, not 0.
        assert!(
            (i32::from(codes[1]) - 31).abs() <= 1,
            "black code {}",
            codes[1]
        );
        // White -> code 0.6946 -> ~177; HDR 4x -> higher but not clipped to 255.
        assert!(
            (i32::from(codes[0]) - 177).abs() <= 1,
            "white code {}",
            codes[0]
        );
        assert!(codes[2] > codes[0]);
        assert!(codes[2] < 255);
    }

    #[test]
    fn invalid_inputs_are_rejected() {
        assert!(thumbnail_codes(&[], 1.0).is_err());
        assert!(thumbnail_codes(&[1.0, 2.0], 1.0).is_err());
        assert!(thumbnail_codes(&[1.0], 0.0).is_err());
        assert!(thumbnail_codes(&[1.0], f32::NAN).is_err());
        assert!(thumbnail_codes(&[f32::NAN, 0.0, 0.0], 1.0).is_err());
    }
}
