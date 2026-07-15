//! EDR scale calculator — f32 precision throughout, matching Swift `Float`.
//!
//! Two models based on device generation and scene detection:
//! - **Early LHDR** (version < 3.0): density-curve model with face-strength
//!   and highlight adjustments, computed at f32 precision.
//! - **Main path** (version >= 3.0): sigmoid path for legacy scenes or
//!   linear path for modern ones.
//!
//! Output is always clamped to `[1.0, 7.9]`.

/// Compute EDR scale from a 36-float LHDR metadata block.
///
/// All arithmetic uses `f32` (single precision), matching the Swift
/// production reference. Constants are the f32-rounded values also
/// produced by Python's `_f32()` round-trip.
pub fn edr_scale_calculator(f: &[f32]) -> f32 {
    // Guard: version < 2.0 has no gain map
    if f[0] < 2.0 {
        return 1.0;
    }

    // Route to early-LHDR path for version < 3.0
    if f[0] < 3.0 {
        return float32_early_lhdr_scale(f);
    }

    // Precomputed bypass — OPPO sometimes stores the final EDR directly
    if f[33] >= 1.0 {
        return f[33];
    }

    // Invalid raw gain → no HDR
    if f[32] <= 0.0 {
        return 1.0;
    }

    let f23 = f[23];
    let f24 = f[24];
    let f29 = f[29].max(1.0);
    let f32v = f[32];
    let cfg = (f[34] as i32) == 1;

    if f23 <= 0.99 {
        // ---- SIGMOID PATH (legacy scenes) ----
        let exp_arg = f32v.mul_add(-0.1175, -6.829);
        let mut edr = 780.3 / (exp_arg.exp2() + 1.0) - 772.3;

        if f24 > 0.0 {
            let factor = if f24 < 1.0 { f24 } else { 1.0 / f24 };
            edr = (edr - 1.0).mul_add(factor, 1.0);
        }

        if f29 >= 200.0 {
            let s4 = edr.abs().sqrt().abs() - 1.0;
            if f29 >= 320.0 {
                edr = s4.mul_add(1.34, 1.0);
            } else {
                let mid_factor = f29.mul_add(-0.0205, 7.9);
                edr = s4.mul_add(mid_factor, 1.0);
            }
        } else {
            let s4 = edr.abs().sqrt().abs() - 1.0;
            edr = s4.mul_add(3.8, 1.0);
        }

        if cfg {
            edr = (edr.abs().sqrt().abs() - 1.0).mul_add(1.3, 1.0);
        } else if f24 > 0.0 {
            let adj = (edr.abs().sqrt().abs() - 1.0).mul_add(1.85, 1.0);
            if f29 > 320.0 {
                edr = (adj - 1.0).mul_add(0.8, 1.0);
            } else {
                edr = adj;
            }
        } else if f29 > 320.0 {
            edr = (edr - 1.0).mul_add(0.8, 1.0);
        }

        return edr.clamp(1.0, 7.9);
    }

    // ---- MAIN PATH (linear mapping, version >= 3.0) ----
    let norm_gain = (f32v * 1023.0) / 65535.0;
    let scaled = ((norm_gain * 63.0 + 1.0).log2()) / f29 * 100.0;

    let edr = if f29 <= 210.0 {
        scaled.mul_add(0.3456, 1.824)
    } else if f29 > 340.0 {
        scaled.mul_add(0.1046, 1.878)
    } else {
        scaled.mul_add(0.5883, 1.401)
    };

    edr.clamp(1.0, 7.9)
}

// ---------------------------------------------------------------------------
// Early LHDR (version < 3.0) — f32-precision density-curve model
// ---------------------------------------------------------------------------

fn float32_early_lhdr_scale(f: &[f32]) -> f32 {
    // Same guards as main entry (they're re-checked because the early path
    // can be called directly from `edr_scale_calculator`).
    if f[0] < 2.0 {
        return 1.0;
    }

    // f[33] precomputed bypass
    if f[33] >= 1.0 {
        return f[33];
    }

    let raw_gain = f[32];
    if raw_gain <= 0.0 {
        return 1.0;
    }

    let face_strength = f[24];
    let highlight = f[29];

    // Core density curve: edr = 780.3 / (exp2(raw_gain * k + b) + 1) - 772.3
    let mut edr = raw_gain.mul_add(-0.1175, -6.829).exp2();
    edr = 780.3 / (edr + 1.0);
    edr += -772.3;

    // Face-strength adjustment
    let face_adjusted = if face_strength > 0.0 {
        let factor = if face_strength < 1.0 {
            face_strength
        } else {
            1.0 / face_strength
        };
        (edr - 1.0).mul_add(factor, 1.0)
    } else {
        edr
    };

    let sqrt_term = face_adjusted.sqrt().abs() - 1.0;

    // Highlight-dependent adjustment
    let highlight_adjusted = if highlight >= 200.0 {
        if highlight >= 320.0 {
            sqrt_term.mul_add(1.34, 1.0)
        } else {
            let mid_factor = highlight.mul_add(-0.0205, 7.9);
            sqrt_term.mul_add(mid_factor, 1.0)
        }
    } else {
        sqrt_term.mul_add(3.8, 1.0)
    };

    // f[34] == 1.401298464324817e-45 (smallest positive f32 subnormal)
    // → CFG flag set via the subnormal sentinel
    if f[34].to_bits() == 1 {
        let cfg_term = highlight_adjusted.sqrt().abs() - 1.0;
        return cfg_term.mul_add(1.3, 1.0);
    }

    if face_strength > 0.0 {
        let face_term = highlight_adjusted.sqrt().abs() - 1.0;
        let adjusted = face_term.mul_add(1.85, 1.0);
        if highlight <= 320.0 {
            return adjusted;
        }
        return (adjusted - 1.0).mul_add(0.8, 1.0);
    }

    if highlight <= 320.0 {
        return highlight_adjusted;
    }
    (highlight_adjusted - 1.0).mul_add(0.8, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// If f[33] holds a precomputed EDR scale, it should be returned as-is.
    #[test]
    fn precomputed_bypass() {
        // version=3.1, precomputed=4.2 at index 33
        let mut f = [0.0_f32; 36];
        f[0] = 3.1;
        f[33] = 4.2;
        let result = edr_scale_calculator(&f);
        assert!((result - 4.2).abs() < 0.001);
    }

    /// Version < 2.0 (no gain map) must return 1.0.
    #[test]
    fn version_below_2_returns_one() {
        let mut f = [0.0_f32; 36];
        f[0] = 1.5;
        f[32] = 500.0;
        let result = edr_scale_calculator(&f);
        assert!((result - 1.0).abs() < 0.001);
    }

    /// Zero raw gain must return 1.0.
    #[test]
    fn zero_raw_gain_returns_one() {
        let mut f = [0.0_f32; 36];
        f[0] = 3.5;
        f[32] = 0.0;
        f[33] = 0.0;
        let result = edr_scale_calculator(&f);
        assert!((result - 1.0).abs() < 0.001);
    }

    /// Output must always be within [1.0, 7.9].
    #[test]
    fn output_clamped_to_range() {
        let mut f = [0.0_f32; 36];
        f[0] = 3.5;
        f[23] = 1.0; // main path (not sigmoid)
        f[29] = 500.0; // high highlight
        f[32] = 65535.0; // max raw gain
        f[33] = 0.0;
        let result = edr_scale_calculator(&f);
        assert!(result >= 1.0, "below clamp: {}", result);
        assert!(result <= 7.9, "above clamp: {}", result);
    }
}
