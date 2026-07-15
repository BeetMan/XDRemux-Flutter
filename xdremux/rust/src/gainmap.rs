//! Gain map pixel reconstruction — ported from XDRemux Swift.
//!
//! Reconstructs an ISO 21496-1 gain map image from the LHDR mask
//! and EDR scale using an empirical LUT chain model.
//!
//! ## Algorithm
//!
//! ```text
//! lin_gray = lut0[mask/255 * 1000]              // exponent 0.625
//! if lin_gray < knee → boosted = 1.0
//! else:
//!   t      = (lin_gray - knee) / knee_range
//!   linear = lut1[t * 1000]                      // exponent 2.2
//!   boosted = lut2[linear * 1000]                // headroom curve
//! gainmap = lut3[min(boosted, 8.0) * 1000]      // log2 scale
//! output  = clamp(round(gainmap), 0, 255)
//! ```
//!
//! ## LUT definitions
//!
//! | LUT  | Entries | Function |
//! |------|---------|----------|
//! | lut0 | 1001    | x^0.625  |
//! | lut1 | 1001    | x^2.2    |
//! | lut2 | 1001    | (x * headroom_scale + 1.0)^2.2 |
//! | lut3 | 8001    | log2_scale * log2(clamp(x, 1.0, max_boost)) |

/// Parameters computed from EDR scale and version.
#[derive(Debug, Clone)]
pub struct GainMapParams {
    pub knee: f32,
    pub knee_range: f32,
    pub headroom_scale: f32,
    pub max_boost: f32,
    pub log2_scale: f32,
}

/// Build a lookup table of `count` entries sampled at i/1000.
fn make_lut(count: usize, f: impl Fn(f64) -> f64) -> Vec<f32> {
    (0..count)
        .map(|i| f(i as f64 / 1000.0) as f32)
        .collect()
}

/// Align `value` up to the next multiple of `alignment`.
fn align_up(value: usize, alignment: usize) -> usize {
    (value + alignment - 1) / alignment * alignment
}

// ---------------------------------------------------------------------------
// Knee point — early LHDR Reinhard tone-mapping
// ---------------------------------------------------------------------------

/// Compute the Reinhard tone-mapping knee point for early LHDR (version < 3.0).
///
/// Uses the exact same f32 constants as `edr.rs` and the Swift production
/// reference (`EDRScaleResolver.getKneePoint()`).
pub fn get_knee_point(edr: f32) -> f32 {
    let scale = edr;
    let inv_gamma = 0.45454543828964233_f32;
    let t = 1.0_f32 / (scale * 100.0_f32);
    let k = 1.0_f32 - t;

    let p1 = scale.powf(inv_gamma);
    let div1 = 1.0_f32 / p1;
    let x_norm = (0.9800000190734863_f32 - t) / k;
    let p2 = x_norm.powf(inv_gamma);
    let y = (p2 * 1.003937005996704_f32 - div1) / (1.0_f32 - div1);

    if !y.is_finite() || y <= 0.0 {
        return f32::NAN;
    }

    let p3 = y.powf(inv_gamma);
    if !p3.is_finite() || p3 == 1.0 {
        return f32::NAN;
    }

    let knee_raw = p3.mul_add(255.0_f32, -254.0_f32);
    let knee_adj = knee_raw / (p3 - 1.0_f32);
    let mut result = knee_adj.round();
    if result <= 0.0 {
        result = knee_raw;
    }
    result / 255.0_f32
}

// ---------------------------------------------------------------------------
// Gain map parameters
// ---------------------------------------------------------------------------

/// Compute gain map parameters from EDR scale and version.
pub fn gain_map_params(edr_scale: f32, edr_version: f32) -> GainMapParams {
    let gamma_factor = (1.0_f32 / edr_scale).powf(1.0_f32 / 2.2_f32);
    let headroom_scale = (1.0_f32 - gamma_factor) / gamma_factor.max(0.001_f32);
    let max_boost = if edr_scale > 1.0 { edr_scale } else { 2.0_f32 };
    let log2_scale = if edr_scale > 1.0 {
        255.0_f32 / edr_scale.log2()
    } else {
        0.0_f32
    };

    let knee = if edr_version >= 3.0 {
        0.0_f32
    } else {
        get_knee_point(edr_scale)
    };
    let knee_range = 1.0_f32 - knee;

    GainMapParams {
        knee,
        knee_range,
        headroom_scale,
        max_boost,
        log2_scale,
    }
}

// ---------------------------------------------------------------------------
// Pixel reconstruction
// ---------------------------------------------------------------------------

/// Reconstruct gain map pixels from a grayscale LHDR mask.
///
/// The gain map output has rows aligned to 256 bytes (ISO 21496-1 requirement).
/// Output dimensions: `width` × `height` pixels, `align_up(width, 256)` bytes
/// per row.
///
/// # Arguments
///
/// * `mask` — Raw grayscale bytes, `height * bytes_per_row` elements.
/// * `width` — Mask width in pixels.
/// * `height` — Mask height in pixels.
/// * `bytes_per_row` — Stride of the mask (may differ from `width` for alignment).
/// * `edr_scale` — EDR scale factor from `edr_scale_calculator`.
/// * `edr_version` — `f[0]` from LHDR metadata.
pub fn reconstruct(
    mask: &[u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
    edr_scale: f32,
    edr_version: f32,
) -> Vec<u8> {
    let params = gain_map_params(edr_scale, edr_version);

    // Build LUTs
    let lut0 = make_lut(1001, |x: f64| x.powf(0.625));
    let lut1 = make_lut(1001, |x: f64| x.powf(2.2));
    let hs = params.headroom_scale as f64;
    let lut2 = make_lut(1001, move |x: f64| (x.mul_add(hs, 1.0_f64)).powf(2.2));
    let ls = params.log2_scale as f64;
    let mb = params.max_boost as f64;
    let lut3 = make_lut(8001, move |x: f64| {
        if x <= 0.0 {
            0.0
        } else {
            let clamped = x.clamp(1.0, mb);
            ls * clamped.log2()
        }
    });

    let output_bytes_per_row = align_up(width, 256);
    let mut output = vec![0u8; output_bytes_per_row * height];

    let knee = params.knee;
    let knee_range = params.knee_range;

    for y in 0..height {
        let in_row_start = y * bytes_per_row;
        let out_row_start = y * output_bytes_per_row;

        for x in 0..width {
            let mask_value = mask[in_row_start + x] as f64 / 255.0;

            let idx0 = (mask_value * 1000.0) as usize;
            let lin_gray = lut0[idx0.min(1000)] as f64;

            let boosted: f64 = if lin_gray < knee as f64 {
                1.0
            } else {
                let t = (lin_gray - knee as f64) / knee_range as f64;
                let idx1 = (t * 1000.0) as usize;
                let linear = lut1[idx1.min(1000)] as f64;
                let idx2 = (linear * 1000.0) as usize;
                lut2[idx2.min(1000)] as f64
            };

            let idx3 = if boosted < 1.0 {
                1000
            } else {
                ((boosted.min(8.0) * 1000.0) as usize).min(8000)
            };

            let log_gain = lut3[idx3] as f64;
            output[out_row_start + x] = (log_gain.round() as i32).clamp(0, 255) as u8;
        }
    }

    output
}

/// Convenience wrapper that uses width as bytes_per_row (tightly packed mask).
pub fn reconstruct_tight(
    mask: &[u8],
    width: usize,
    height: usize,
    edr_scale: f32,
    edr_version: f32,
) -> Vec<u8> {
    reconstruct(mask, width, height, width, edr_scale, edr_version)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lut_1001_entries_correct_size() {
        let lut = make_lut(1001, |x| x);
        assert_eq!(lut.len(), 1001);
    }

    #[test]
    fn lut_8001_entries_correct_size() {
        let lut = make_lut(8001, |x| x);
        assert_eq!(lut.len(), 8001);
    }

    #[test]
    fn lut0_first_last() {
        let lut = make_lut(1001, |x: f64| x.powf(0.625));
        assert!((lut[0] - 0.0).abs() < 0.001);
        assert!((lut[1000] - 1.0).abs() < 0.001);
    }

    #[test]
    fn lut1_monotonic() {
        let lut = make_lut(1001, |x: f64| x.powf(2.2));
        for i in 1..lut.len() {
            assert!(lut[i] >= lut[i - 1], "lut1 not monotonic at index {i}");
        }
    }

    #[test]
    fn knee_point_edr_3() {
        let knee = get_knee_point(3.0);
        assert!(knee.is_finite(), "knee should be finite for edr=3.0");
        assert!(knee >= 0.0 && knee <= 1.0, "knee={knee} out of [0,1]");
    }

    #[test]
    fn knee_point_edr_2() {
        let knee = get_knee_point(2.0);
        assert!(knee.is_finite(), "knee should be finite for edr=2.0");
    }

    #[test]
    fn params_version_ge3_no_knee() {
        let p = gain_map_params(3.5, 3.5);
        assert_eq!(p.knee, 0.0);
        assert!((p.knee_range - 1.0).abs() < 0.001);
    }

    #[test]
    fn params_version_lt3_has_knee() {
        let p = gain_map_params(3.0, 2.5);
        assert!(p.knee > 0.0, "early LHDR should have knee > 0");
    }

    #[test]
    fn reconstruct_uniform_mask() {
        // 128×128 mask with all pixels = 128 (mid-gray)
        let width = 128;
        let height = 128;
        let mask = vec![128u8; width * height];
        let output = reconstruct_tight(&mask, width, height, 3.0, 3.5);
        assert_eq!(output.len(), align_up(width, 256) * height);
        // All output pixels are u8, in range by construction
        // Mid-gray mask + EDR 3.0 should produce non-zero gain map
        let _sum: u64 = output.iter().map(|&v| v as u64).take(width * height).sum();
        // Most pixels should have some gain
        let non_zero = output.iter().filter(|&&v| v > 0).count();
        assert!(non_zero > 0, "gain map should have non-zero pixels for mid-gray");
    }

    #[test]
    fn reconstruct_zero_mask() {
        let width = 64;
        let height = 64;
        let mask = vec![0u8; width * height];
        let output = reconstruct_tight(&mask, width, height, 3.0, 3.5);
        assert_eq!(output.len(), align_up(width, 256) * height);
        // All zero mask → all zero gain map (lut3[0] = 0)
        for &v in output.iter().take(width * height) {
            assert_eq!(v, 0, "zero mask should produce zero gain map");
        }
    }

    #[test]
    fn output_row_alignment() {
        for w in [1, 63, 64, 128, 255, 256, 257, 512] {
            let height = 4;
            let mask = vec![128u8; w * height];
            let output = reconstruct_tight(&mask, w, height, 3.0, 3.5);
            let expected_row = align_up(w, 256);
            assert_eq!(output.len(), expected_row * height, "width={w}");
        }
    }

    #[test]
    fn reconstruct_bright_mask_higher_output() {
        // Bright mask (240) should produce higher gain map values than dark mask (16)
        let width = 64;
        let height = 64;
        let dark = vec![16u8; width * height];
        let bright = vec![240u8; width * height];
        let out_dark = reconstruct_tight(&dark, width, height, 3.0, 3.5);
        let out_bright = reconstruct_tight(&bright, width, height, 3.0, 3.5);
        let sum_dark: u64 = out_dark.iter().map(|&v| v as u64).sum();
        let sum_bright: u64 = out_bright.iter().map(|&v| v as u64).sum();
        assert!(
            sum_bright >= sum_dark,
            "bright mask should produce >= gain than dark mask"
        );
    }

    #[test]
    fn early_lhdr_knee_produces_valid_output() {
        let width = 32;
        let height = 32;
        let mask = vec![128u8; width * height];
        // Early LHDR: version < 3.0
        let output = reconstruct_tight(&mask, width, height, 3.0, 2.5);
        // Should not panic, and output should be valid
        assert_eq!(output.len(), align_up(width, 256) * height);
    }
}
