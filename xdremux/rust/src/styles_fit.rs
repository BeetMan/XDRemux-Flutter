//! Per-image Photographic Styles fits: key 1 (local quadratic lattice) and
//! key 3 (monotonic global tone curve).
//!
//! Replaces the identity `styleData` the native writer used to emit (gap
//! doc `docs/research/styles-upstream-20261024-gap.md` P1-1 / P1-2). Ported
//! from upstream `21Z121Z1/XDRemux` `bb66981b`
//! (`crates/xdremux-engine/src/apple_photographic_styles.rs`:
//! `apple_style_revert_local_data`, `apple_style_monotonic_global_tone_curve`)
//! with the `73804f5c` GTC read-back correction, rewritten for this crate (no
//! `half` dependency, `String` errors).
//!
//! Both fits read the same pixel pair, in display order and at Linear
//! Thumbnail geometry:
//!
//! - `primary`: the displayed primary, sRGB-decoded to linear light (the
//!   "styled" image remove-style starts from);
//! - `thumbnail`: the consumer's `S` code, i.e. the scene-linear thumbnail
//!   divided by `styleData` key 4 (baseline exposure) and multiplied by key
//!   `h` (base gain), clamped to `[0, 1]`.
//!
//! Direction matters: remove-style applies key 1 to the displayed primary and
//! must land on the thumbnail code. A forward primary-to-styled residual would
//! point the other way.

/// Polynomial terms per channel: `[1, R, G, B, R², RG, RB, G², GB, B²]`.
pub const POLYNOMIAL_COUNT: usize = 10;
pub const CHANNEL_COUNT: usize = 3;
/// f16 values per key-1 block (`POLYNOMIAL_COUNT × CHANNEL_COUNT`).
pub const BLOCK_VALUE_COUNT: usize = POLYNOMIAL_COUNT * CHANNEL_COUNT;
pub const GRID_WIDTH: usize = 12;
pub const GRID_HEIGHT: usize = 9;
pub const PLANE_COUNT: usize = 8;
/// 12 × 9 × 8 = 864 blocks, matching `STYLE_DATA_BLOCKS`.
pub const TILE_COUNT: usize = GRID_WIDTH * GRID_HEIGHT * PLANE_COUNT;
/// 864 × 30 × 2 = 51840 bytes.
pub const STYLE_DATA_BYTE_COUNT: usize = TILE_COUNT * BLOCK_VALUE_COUNT * 2;
/// Wire size of the key-3 GTC: 257 count + 256 nodes + repeated last node.
pub const GTC_BYTE_COUNT: usize = 516;
const GTC_NODE_COUNT: usize = 256;

/// Block indices that are 1.0 in the identity block (R→R, G→G, B→B).
const IDENTITY_INDICES: [usize; 3] = [3, 7, 11];
const LINEAR_BOUND: f64 = 1.0 / 8.0;
const QUADRATIC_BOUND: f64 = 1.0 / 16.0;

/// Fitted key-3 resource plus what the consumer will read back from it.
#[derive(Debug, Clone)]
pub struct GlobalToneCurve {
    /// 516-byte wire resource (key "3").
    pub data: Vec<u8>,
    /// The 256 nodes as the consumer decodes them (fixed 65535 scale, inverse
    /// sRGB), so statistics describe the written LUT, not the pre-quantized fit.
    pub linear_samples: Vec<f32>,
    /// RMSE of `GTC(thumbnail)` against `primary` over every channel sample.
    pub fit_rmse: f64,
    /// Bins that held at least one sample (the rest are interpolated).
    pub populated_bins: usize,
}

fn check_pair(thumbnail: &[f32], primary: &[f32]) -> Result<(), String> {
    if thumbnail.is_empty()
        || thumbnail.len() != primary.len()
        || !thumbnail.len().is_multiple_of(CHANNEL_COUNT)
        || thumbnail.iter().any(|v| !v.is_finite())
        || primary.iter().any(|v| !v.is_finite())
    {
        return Err(format!(
            "styles fit: invalid RGB pair ({} thumbnail / {} primary samples)",
            thumbnail.len(),
            primary.len()
        ));
    }
    Ok(())
}

/// Build the shared per-channel global tone curve for key "3".
///
/// The consumer samples one 256-node curve independently on each channel at
/// `S` (no luminance reduction, no percentile normalization). Each bin holds
/// the mean primary value of the samples whose half-quantized code lands
/// there; empty bins are interpolated from observed neighbours; the curve is
/// then made monotone with pool-adjacent-violators. No parametric family and
/// no forced `(0,0)` / `(1,1)` endpoints.
///
/// Wire layout: count 257, 256 sRGB-encoded nodes on the 65534 scale, then the
/// last node repeated. The consumer reads nodes back on a fixed 65535 scale
/// with inverse sRGB and neither normalizes endpoints nor reads the repeated
/// word (`73804f5c`).
pub fn monotonic_global_tone_curve(
    thumbnail: &[f32],
    primary: &[f32],
) -> Result<GlobalToneCurve, String> {
    check_pair(thumbnail, primary)?;
    let mut sums = vec![0.0_f64; GTC_NODE_COUNT];
    let mut counts = vec![0.0_f64; GTC_NODE_COUNT];
    for (&input, &output) in thumbnail.iter().zip(primary) {
        let index = gtc_node_index(input);
        sums[index] += f64::from(output.clamp(0.0, 1.0));
        counts[index] += 1.0;
    }
    let populated_bins = counts.iter().filter(|c| **c > 0.0).count();
    if populated_bins == 0 {
        return Err("styles fit: GTC has no populated bin".into());
    }
    let values = interpolate_observed_bins(&sums, &counts);
    let fitted = isotonic_curve(&values, &counts);

    let mut data = Vec::with_capacity(GTC_BYTE_COUNT);
    data.extend_from_slice(&257_u16.to_le_bytes());
    for &linear in &fitted {
        data.extend_from_slice(&encode_gtc_node(linear).to_le_bytes());
    }
    let last = *fitted.last().unwrap_or(&0.0);
    data.extend_from_slice(&encode_gtc_node(last).to_le_bytes());

    let linear_samples = decode_global_tone_curve(&data)?;
    let mapped = apply_global_tone_curve(thumbnail, &linear_samples);
    let fit_rmse = rmse(&mapped, primary);
    Ok(GlobalToneCurve {
        data,
        linear_samples,
        fit_rmse,
        populated_bins,
    })
}

/// Decode a 516-byte key-3 resource the way the consumer does.
pub fn decode_global_tone_curve(data: &[u8]) -> Result<Vec<f32>, String> {
    if data.len() != GTC_BYTE_COUNT || u16::from_le_bytes([data[0], data[1]]) != 257 {
        return Err(format!("styles fit: GTC resource is not 257/516 ({} bytes)", data.len()));
    }
    Ok(data[2..2 + GTC_NODE_COUNT * 2]
        .chunks_exact(2)
        .map(|word| {
            let encoded = f64::from(u16::from_le_bytes([word[0], word[1]])) / 65_535.0;
            crate::apple_log::srgb_to_linear(encoded) as f32
        })
        .collect())
}

/// Sample the 256 linear GTC nodes at `code` with the consumer's half
/// coordinate (`code * 255` rounded through f16, clamp-to-edge, linear).
pub fn sample_gtc_linear(samples: &[f32], code: f32) -> f32 {
    if samples.len() != GTC_NODE_COUNT {
        return 0.0;
    }
    let scaled = round_through_f16(code.clamp(0.0, 1.0) * 255.0).clamp(0.0, 255.0);
    let lower = scaled.floor() as usize;
    let upper = (lower + 1).min(GTC_NODE_COUNT - 1);
    let fraction = scaled - lower as f32;
    samples[lower] * (1.0 - fraction) + samples[upper] * fraction
}

/// Apply the shared GTC to every channel code.
pub fn apply_global_tone_curve(codes: &[f32], samples: &[f32]) -> Vec<f32> {
    codes.iter().map(|&c| sample_gtc_linear(samples, c)).collect()
}

fn gtc_node_index(code: f32) -> usize {
    round_through_f16(code.clamp(0.0, 1.0) * 255.0)
        .round()
        .clamp(0.0, 255.0) as usize
}

fn encode_gtc_node(linear: f32) -> u16 {
    let encoded = srgb_encode(f64::from(linear).clamp(0.0, 1.0)).clamp(0.0, 1.0);
    (encoded * 65_534.0).round().clamp(0.0, 65_534.0) as u16
}

fn interpolate_observed_bins(sums: &[f64], counts: &[f64]) -> Vec<f64> {
    let populated: Vec<usize> = (0..counts.len()).filter(|&i| counts[i] > 0.0).collect();
    let mean = |i: usize| sums[i] / counts[i];
    (0..sums.len())
        .map(|index| {
            if counts[index] > 0.0 {
                return mean(index);
            }
            let lower = populated.iter().copied().rev().find(|&c| c < index);
            let upper = populated.iter().copied().find(|&c| c > index);
            match (lower, upper) {
                (Some(l), Some(u)) => {
                    let t = (index - l) as f64 / (u - l) as f64;
                    mean(l) * (1.0 - t) + mean(u) * t
                }
                (Some(l), None) => mean(l),
                (None, Some(u)) => mean(u),
                (None, None) => 0.0,
            }
        })
        .collect()
}

/// Weighted pool-adjacent-violators (non-decreasing). Empty bins weigh 1.
fn isotonic_curve(values: &[f64], counts: &[f64]) -> Vec<f32> {
    struct Block {
        lower: usize,
        upper: usize,
        weight: f64,
        weighted_value: f64,
    }
    let mean = |b: &Block| b.weighted_value / b.weight.max(f64::MIN_POSITIVE);
    let mut blocks: Vec<Block> = Vec::with_capacity(values.len());
    for (index, &value) in values.iter().enumerate() {
        let weight = if counts[index] > 0.0 { counts[index] } else { 1.0 };
        blocks.push(Block {
            lower: index,
            upper: index,
            weight,
            weighted_value: weight * value.clamp(0.0, 1.0),
        });
        while blocks.len() >= 2 && mean(&blocks[blocks.len() - 2]) > mean(&blocks[blocks.len() - 1])
        {
            let right = blocks.pop().unwrap();
            let left = blocks.last_mut().unwrap();
            left.upper = right.upper;
            left.weight += right.weight;
            left.weighted_value += right.weighted_value;
        }
    }
    let mut fitted = vec![0.0_f32; values.len()];
    for block in &blocks {
        fitted[block.lower..=block.upper].fill(mean(block).clamp(0.0, 1.0) as f32);
    }
    for index in 1..fitted.len() {
        fitted[index] = fitted[index].max(fitted[index - 1]);
    }
    fitted
}

/// Fit key "1" per 12×9 spotlight cell and per brightness plane
/// (remove-style local quadratic).
///
/// Payload order is x-major `((x * 9 + y) * 8 + plane)`, each block the 10×3
/// quadratic `[1, R, G, B, R², RG, RB, G², GB, B²]` × RGB. Plane weights use
/// `b = 0.5 * (mean + max)` with Gaussian centres `(k + 1) / 9`, `σ = 2.5`
/// (the `inputIsLinear = false` consumer); spatial weights are bilinear over
/// the default spotlight coordinate. The solved value is a residual added to
/// identity, clamped to ±1/8 (constant/linear) and ±1/16 (quadratic), so an
/// unchanged image stays the identity transform. A tiny ridge only stabilizes
/// underdetermined cells (they fall back to identity); it is not a scene
/// calibration.
pub fn revert_local_style_data(
    width: usize,
    height: usize,
    styled_rgb: &[f32],
    recovered_rgb: &[f32],
) -> Result<Vec<u8>, String> {
    let value_count = width
        .checked_mul(height)
        .and_then(|p| p.checked_mul(CHANNEL_COUNT))
        .ok_or("styles fit: key1 raster size overflows")?;
    if width == 0 || height == 0 || styled_rgb.len() != value_count {
        return Err(format!(
            "styles fit: key1 raster is not {width}x{height} RGB ({} samples)",
            styled_rgb.len()
        ));
    }
    check_pair(recovered_rgb, styled_rgb)?;

    const P: usize = POLYNOMIAL_COUNT;
    let mut normal = vec![0.0_f64; TILE_COUNT * P * P];
    let mut rhs = vec![0.0_f64; TILE_COUNT * BLOCK_VALUE_COUNT];
    let mut plane_weights = [0.0_f64; PLANE_COUNT];
    for y in 0..height {
        let row_weights = spotlight_weights(y, height, GRID_HEIGHT);
        for x in 0..width {
            let offset = (y * width + x) * CHANNEL_COUNT;
            let styled = rgb_at(styled_rgb, offset);
            let recovered = rgb_at(recovered_rgb, offset);
            let basis = quadratic_basis(styled);
            let plane_sum = brightness_plane_weights(styled, &mut plane_weights);
            if plane_sum <= 0.0 {
                continue;
            }
            let column_weights = spotlight_weights(x, width, GRID_WIDTH);
            for &(cell_y, y_weight) in &row_weights {
                for &(cell_x, x_weight) in &column_weights {
                    let spatial = x_weight * y_weight;
                    if spatial <= 0.0 {
                        continue;
                    }
                    for (plane, &plane_weight) in plane_weights.iter().enumerate() {
                        let weight = spatial * plane_weight / plane_sum;
                        if weight <= 0.0 {
                            continue;
                        }
                        let tile = tile_index(cell_x, cell_y, plane);
                        let normal_cell = &mut normal[tile * P * P..(tile + 1) * P * P];
                        let rhs_cell =
                            &mut rhs[tile * BLOCK_VALUE_COUNT..(tile + 1) * BLOCK_VALUE_COUNT];
                        for row in 0..P {
                            let weighted = weight * basis[row];
                            // Upper triangle only; mirrored before the solve.
                            for column in row..P {
                                normal_cell[row * P + column] += weighted * basis[column];
                            }
                            for channel in 0..CHANNEL_COUNT {
                                rhs_cell[row * CHANNEL_COUNT + channel] +=
                                    weighted * (recovered[channel] - styled[channel]);
                            }
                        }
                    }
                }
            }
        }
    }

    let mut out = Vec::with_capacity(STYLE_DATA_BYTE_COUNT);
    for tile in 0..TILE_COUNT {
        let cell = &normal[tile * P * P..(tile + 1) * P * P];
        let mut matrix = vec![0.0_f64; P * P];
        for row in 0..P {
            for column in 0..P {
                let (r, c) = if column < row { (column, row) } else { (row, column) };
                matrix[row * P + column] = cell[r * P + c];
            }
        }
        let trace: f64 = (0..P).map(|t| matrix[t * P + t]).sum();
        let ridge = (trace / P as f64 * 1e-5).max(1e-9);
        for term in 0..P {
            // Quadratic terms get a 10× stronger ridge than constant/linear.
            matrix[term * P + term] += ridge * if term >= 4 { 10.0 } else { 1.0 };
        }
        let mut block = [0.0_f64; BLOCK_VALUE_COUNT];
        for channel in 0..CHANNEL_COUNT {
            let vector: Vec<f64> = (0..P)
                .map(|term| rhs[tile * BLOCK_VALUE_COUNT + term * CHANNEL_COUNT + channel])
                .collect();
            let solution = solve_linear_system(&matrix, &vector).unwrap_or_else(|| vec![0.0; P]);
            for (term, value) in solution.into_iter().enumerate() {
                let index = term * CHANNEL_COUNT + channel;
                let bound = coefficient_bound(index);
                block[index] = value.clamp(-bound, bound);
            }
        }
        for (index, delta) in block.iter().enumerate() {
            let identity = if IDENTITY_INDICES.contains(&index) { 1.0 } else { 0.0 };
            let value = identity + *delta as f32;
            out.extend_from_slice(&crate::linear_thumbnail::f32_to_f16(value).to_le_bytes());
        }
    }
    Ok(out)
}

fn rgb_at(rgb: &[f32], offset: usize) -> [f64; 3] {
    [
        f64::from(rgb[offset]),
        f64::from(rgb[offset + 1]),
        f64::from(rgb[offset + 2]),
    ]
}

fn tile_index(cell_x: usize, cell_y: usize, plane: usize) -> usize {
    (cell_x * GRID_HEIGHT + cell_y) * PLANE_COUNT + plane
}

/// Fill the 8 Gaussian brightness-plane weights; returns their sum.
fn brightness_plane_weights(rgb: [f64; 3], weights: &mut [f64; PLANE_COUNT]) -> f64 {
    let mean = (rgb[0] + rgb[1] + rgb[2]) / 3.0;
    let peak = rgb[0].max(rgb[1]).max(rgb[2]);
    let brightness = 0.5 * (mean + peak);
    let mut sum = 0.0;
    for (plane, weight) in weights.iter_mut().enumerate() {
        let center = (plane as f64 + 1.0) / (PLANE_COUNT as f64 + 1.0);
        let distance = (brightness - center) * PLANE_COUNT as f64;
        *weight = (-0.5 * (distance / 2.5).powi(2)).exp();
        sum += *weight;
    }
    sum
}

fn quadratic_basis([r, g, b]: [f64; 3]) -> [f64; POLYNOMIAL_COUNT] {
    [1.0, r, g, b, r * r, r * g, r * b, g * g, g * b, b * b]
}

fn spotlight_weights(pixel: usize, extent: usize, count: usize) -> [(usize, f64); 2] {
    let coordinate = spotlight_coordinate(pixel, extent, count) * count as f64;
    let lower = coordinate.floor().clamp(0.0, (count - 1) as f64) as usize;
    let upper = (lower + 1).min(count - 1);
    let fraction = if lower == upper {
        0.0
    } else {
        (coordinate - lower as f64).clamp(0.0, 1.0)
    };
    [(lower, 1.0 - fraction), (upper, fraction)]
}

fn spotlight_coordinate(pixel: usize, extent: usize, count: usize) -> f64 {
    if extent == 0 || count == 0 {
        return 0.0;
    }
    let cells = (extent as f64 / count as f64).ceil();
    let pitch = if (cells as usize).is_multiple_of(2) {
        cells
    } else {
        cells + 1.0
    };
    let first = pitch / 2.0 - 1.0;
    let last = first + pitch * (count as f64 - 1.0);
    let span = (pitch * (count as f64 - 1.0)).max(1.0);
    let position = (pixel as f64).clamp(first, last);
    (0.5 + (position - first) * (count as f64 - 1.0) / span) / count as f64
}

fn coefficient_bound(block_index: usize) -> f64 {
    if block_index / CHANNEL_COUNT >= 4 {
        QUADRATIC_BOUND
    } else {
        LINEAR_BOUND
    }
}

/// Gauss–Jordan with partial pivoting; `None` when singular.
fn solve_linear_system(matrix: &[f64], vector: &[f64]) -> Option<Vec<f64>> {
    let n = vector.len();
    if matrix.len() != n * n {
        return None;
    }
    let mut a: Vec<Vec<f64>> = (0..n)
        .map(|row| {
            let mut values = matrix[row * n..(row + 1) * n].to_vec();
            values.push(vector[row]);
            values
        })
        .collect();
    for pivot in 0..n {
        let best = (pivot..n).max_by(|&l, &r| a[l][pivot].abs().total_cmp(&a[r][pivot].abs()))?;
        if a[best][pivot].abs() <= 1e-12 {
            return None;
        }
        a.swap(best, pivot);
        let divisor = a[pivot][pivot];
        for value in a[pivot][pivot..=n].iter_mut() {
            *value /= divisor;
        }
        let pivot_row = a[pivot].clone();
        for (row, values) in a.iter_mut().enumerate() {
            if row == pivot {
                continue;
            }
            let factor = values[pivot];
            for (value, p) in values[pivot..=n].iter_mut().zip(&pivot_row[pivot..=n]) {
                *value -= factor * p;
            }
        }
    }
    Some(a.into_iter().map(|row| row[n]).collect())
}

fn srgb_encode(linear: f64) -> f64 {
    if linear <= 0.003_130_8 {
        linear * 12.92
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    }
}

/// IEEE half -> f32.
pub fn f16_to_f32(bits: u16) -> f32 {
    let sign = if bits & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exp = i32::from((bits >> 10) & 0x1f);
    let frac = f32::from(bits & 0x3ff);
    match exp {
        0 => sign * frac * 2f32.powi(-24),
        31 if frac == 0.0 => sign * f32::INFINITY,
        31 => f32::NAN,
        _ => sign * (1.0 + frac / 1024.0) * 2f32.powi(exp - 15),
    }
}

fn round_through_f16(value: f32) -> f32 {
    f16_to_f32(crate::linear_thumbnail::f32_to_f16(value))
}

fn rmse(actual: &[f32], expected: &[f32]) -> f64 {
    let sum: f64 = actual
        .iter()
        .zip(expected)
        .map(|(&a, &e)| (f64::from(a) - f64::from(e.clamp(0.0, 1.0))).powi(2))
        .sum();
    (sum / actual.len().max(1) as f64).sqrt()
}

/// Inputs for [`fit_style_state`]: the display-order linear pair at Linear
/// Thumbnail geometry, before the baseline-exposure / base-gain scaling.
#[derive(Debug, Clone)]
pub struct StyleFitRaster {
    pub width: usize,
    pub height: usize,
    /// Primary, sRGB-decoded to linear light (interleaved RGB).
    pub primary_linear: Vec<f32>,
    /// Scene-linear thumbnail (primary × gain map when one was applied).
    pub scene_linear: Vec<f32>,
}

/// Per-image key 1 + key 3, fitted on one raster.
#[derive(Debug, Clone)]
pub struct FittedStyleState {
    pub style_data: Vec<u8>,
    pub global_tone_curve: GlobalToneCurve,
}

/// Fit key 1 and key 3 for the plist that carries `baseline_exposure` (key 4)
/// and `base_gain` (key `h`). Those two scalars define the consumer's `S`, so
/// they must be the values written into the same file.
pub fn fit_style_state(
    raster: &StyleFitRaster,
    baseline_exposure: f64,
    base_gain: f64,
) -> Result<FittedStyleState, String> {
    if !(baseline_exposure.is_finite() && baseline_exposure > 0.0 && base_gain.is_finite()) {
        return Err(format!(
            "styles fit: invalid scale (baseline {baseline_exposure}, base gain {base_gain})"
        ));
    }
    let scale = base_gain / baseline_exposure;
    let thumbnail: Vec<f32> = raster
        .scene_linear
        .iter()
        .map(|&v| (f64::from(v) * scale).clamp(0.0, 1.0) as f32)
        .collect();
    let global_tone_curve = monotonic_global_tone_curve(&thumbnail, &raster.primary_linear)?;
    let style_data = revert_local_style_data(
        raster.width,
        raster.height,
        &raster.primary_linear,
        &thumbnail,
    )?;
    Ok(FittedStyleState {
        style_data,
        global_tone_curve,
    })
}

/// Evaluate a key-1 payload on `styled_rgb` (interleaved linear RGB) with the
/// same spatial spotlight weights and brightness-plane weights the fit uses.
/// Stored half values already include the identity diagonal, so this is the
/// remove-style polynomial Photos applies to the displayed primary (upstream
/// `apple_style_apply_local`, PR #88). Diagnostic model only; the real
/// consumer is Photos.
pub fn apply_style_data(
    style_data: &[u8],
    width: usize,
    height: usize,
    styled_rgb: &[f32],
) -> Result<Vec<f32>, String> {
    if style_data.len() != STYLE_DATA_BYTE_COUNT || styled_rgb.len() != width * height * 3 {
        return Err("styles fit: apply_style_data geometry mismatch".into());
    }
    let coefficients: Vec<f64> = style_data
        .chunks_exact(2)
        .map(|w| f64::from(f16_to_f32(u16::from_le_bytes([w[0], w[1]]))))
        .collect();
    let mut out = Vec::with_capacity(styled_rgb.len());
    let mut plane_weights = [0.0_f64; PLANE_COUNT];
    for y in 0..height {
        let row_weights = spotlight_weights(y, height, GRID_HEIGHT);
        for x in 0..width {
            let styled = rgb_at(styled_rgb, (y * width + x) * 3);
            let basis = quadratic_basis(styled);
            let plane_sum = brightness_plane_weights(styled, &mut plane_weights);
            let column_weights = spotlight_weights(x, width, GRID_WIDTH);
            let mut result = [0.0_f64; 3];
            if plane_sum <= 0.0 {
                out.extend_from_slice(&[0.0; 3]);
                continue;
            }
            for &(cell_y, y_weight) in &row_weights {
                for &(cell_x, x_weight) in &column_weights {
                    for (plane, &plane_weight) in plane_weights.iter().enumerate() {
                        let weight = x_weight * y_weight * plane_weight / plane_sum;
                        if weight <= 0.0 {
                            continue;
                        }
                        let base = tile_index(cell_x, cell_y, plane) * BLOCK_VALUE_COUNT;
                        for (channel, value) in result.iter_mut().enumerate() {
                            let mut sum = 0.0;
                            for (term, b) in basis.iter().enumerate() {
                                sum += coefficients[base + term * CHANNEL_COUNT + channel] * b;
                            }
                            *value += weight * sum;
                        }
                    }
                }
            }
            out.extend(result.iter().map(|&v| v as f32));
        }
    }
    Ok(out)
}

/// Mean absolute chromaticity change between two linear RGB rasters: each
/// channel divided by its pixel's Rec. 709 luminance, averaged over channels
/// and pixels (upstream PR #88 `mean_abs_chroma_delta`). Zero means only
/// brightness moved; a pure per-pixel scale does not register.
pub fn mean_abs_chroma_delta(source: &[f32], rendered: &[f32]) -> f64 {
    const Y: [f64; 3] = [0.212_639, 0.715_169, 0.072_192];
    let luminance = |rgb: &[f32]| {
        (0..3)
            .map(|c| f64::from(rgb[c]) * Y[c])
            .sum::<f64>()
            .max(1.0e-4)
    };
    let mut total = 0.0_f64;
    let mut count = 0.0_f64;
    for (before, after) in source.chunks_exact(3).zip(rendered.chunks_exact(3)) {
        let (before_y, after_y) = (luminance(before), luminance(after));
        for c in 0..3 {
            total += (f64::from(after[c]) / after_y - f64::from(before[c]) / before_y).abs();
        }
        count += 3.0;
    }
    if count == 0.0 {
        0.0
    } else {
        total / count
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::styles_consts::FIELD_3;

    fn identity_style_data() -> Vec<u8> {
        let mut out = Vec::with_capacity(STYLE_DATA_BYTE_COUNT);
        for _ in 0..TILE_COUNT {
            for i in 0..BLOCK_VALUE_COUNT {
                let v: u16 = if IDENTITY_INDICES.contains(&i) { 0x3c00 } else { 0 };
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        out
    }

    fn rmse_raw(a: &[f32], b: &[f32]) -> f64 {
        (a.iter()
            .zip(b)
            .map(|(&x, &y)| (f64::from(x) - f64::from(y)).powi(2))
            .sum::<f64>()
            / a.len() as f64)
            .sqrt()
    }

    fn monotonic(samples: &[f32]) -> bool {
        samples.windows(2).all(|p| p[0] <= p[1])
    }

    #[test]
    fn f16_round_trip_matches_known_values() {
        assert_eq!(f16_to_f32(0x3c00), 1.0);
        assert_eq!(f16_to_f32(0xc000), -2.0);
        assert_eq!(f16_to_f32(0x0001), 2f32.powi(-24));
        for v in [0.0_f32, 0.125, -0.0625, 0.333, 254.7, 1.0 / 3.0] {
            let back = f16_to_f32(crate::linear_thumbnail::f32_to_f16(v));
            assert!((back - v).abs() <= v.abs() * 1e-3 + 1e-7, "{v} -> {back}");
        }
    }

    #[test]
    fn identity_gtc_resource_decodes_to_256_monotonic_nodes() {
        let samples = decode_global_tone_curve(FIELD_3).unwrap();
        assert_eq!(samples.len(), 256);
        assert!(monotonic(&samples));
    }

    /// Upstream `bb66981b` fixture: a sub-white quadratic target with a toe.
    /// The fitted curve is monotonic, keeps the sub-white endpoint (no
    /// normalization), reports the error of the *written* LUT, and beats the
    /// identity curve.
    #[test]
    fn gtc_fit_is_monotonic_and_beats_identity_on_quadratic_fixture() {
        let thumbnail: Vec<f32> = (0..256).flat_map(|i| [i as f32 / 255.0; 3]).collect();
        let primary: Vec<f32> = thumbnail
            .iter()
            .map(|c| 0.0002 + 0.371_23 * c * c)
            .collect();
        let curve = monotonic_global_tone_curve(&thumbnail, &primary).unwrap();
        assert_eq!(curve.data.len(), GTC_BYTE_COUNT);
        assert_eq!(&curve.data[..2], &257u16.to_le_bytes());
        assert_eq!(&curve.data[512..514], &curve.data[514..516], "last node repeats");
        assert!(monotonic(&curve.linear_samples));
        assert_eq!(curve.linear_samples, decode_global_tone_curve(&curve.data).unwrap());
        assert!(curve.linear_samples[255] < 0.4, "final node normalized to white");

        let mapped = apply_global_tone_curve(&thumbnail, &curve.linear_samples);
        let written_rmse = rmse_raw(&mapped, &primary);
        assert!((curve.fit_rmse - written_rmse).abs() < 1e-12);

        let identity = decode_global_tone_curve(FIELD_3).unwrap();
        let identity_rmse = rmse_raw(&apply_global_tone_curve(&thumbnail, &identity), &primary);
        assert!(
            curve.fit_rmse < identity_rmse * 0.05,
            "fit {} vs identity {identity_rmse}",
            curve.fit_rmse
        );
    }

    /// Upstream fixture: a hard step (crush below 0.5). PAV keeps it
    /// monotonic without smoothing the dark end or rescaling the bright end.
    #[test]
    fn gtc_fit_follows_step_fixture_without_rescaling() {
        let mut thumbnail = Vec::new();
        let mut primary = Vec::new();
        for index in 0..256 {
            let code = index as f32 / 255.0;
            let target = if code < 0.5 { 0.0 } else { code };
            for _ in 0..3 {
                thumbnail.push(code);
                primary.push(target);
            }
        }
        let curve = monotonic_global_tone_curve(&thumbnail, &primary).unwrap();
        assert!(monotonic(&curve.linear_samples));
        assert!(curve.populated_bins > 200);
        assert!(curve.linear_samples[gtc_node_index(0.2)] < 0.05);
        assert!((curve.linear_samples[gtc_node_index(0.8)] - 0.8).abs() < 0.05);
        assert!((curve.linear_samples[gtc_node_index(1.0)] - 1.0).abs() < 1e-3);
        assert_ne!(curve.data, FIELD_3);
    }

    /// Non-monotonic, noisy, sparse input: the PAV projection must still
    /// produce a non-decreasing curve and interpolate empty bins.
    #[test]
    fn gtc_fit_is_monotonic_on_noisy_sparse_input() {
        let mut thumbnail = Vec::new();
        let mut primary = Vec::new();
        let mut seed = 0x1234_5678u32;
        for i in 0..900 {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = (seed >> 8) as f32 / (1u32 << 24) as f32 - 0.5;
            // Codes only in [0.1, 0.6] → most bins are empty.
            let code = 0.1 + 0.5 * (i % 300) as f32 / 300.0;
            thumbnail.push(code);
            primary.push((0.8 * code - 0.3 * (code * 20.0).sin() * 0.05 + 0.2 * noise).max(0.0));
        }
        let curve = monotonic_global_tone_curve(&thumbnail, &primary).unwrap();
        assert!(monotonic(&curve.linear_samples));
        assert!(curve.populated_bins < 256);
        assert!(curve.linear_samples.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)));
    }

    #[test]
    fn gtc_fit_rejects_bad_pairs() {
        assert!(monotonic_global_tone_curve(&[], &[]).is_err());
        assert!(monotonic_global_tone_curve(&[0.1; 3], &[0.1; 6]).is_err());
        assert!(monotonic_global_tone_curve(&[0.1, 0.2], &[0.1, 0.2]).is_err());
        assert!(monotonic_global_tone_curve(&[f32::NAN, 0.0, 0.0], &[0.0; 3]).is_err());
    }

    /// Upstream fixture: the left half of the recovered image is 0.05 darker.
    /// key1 must be local (left cell darkens, right cell does not) and point
    /// from styled primary to recovered thumbnail.
    #[test]
    fn key1_fit_is_local_and_points_from_styled_to_recovered() {
        assert_eq!(tile_index(1, 0, 0) * BLOCK_VALUE_COUNT, GRID_HEIGHT * PLANE_COUNT * BLOCK_VALUE_COUNT);
        let (width, height) = (24, 18);
        let mut styled = vec![0.0_f32; width * height * 3];
        let mut recovered = vec![0.0_f32; width * height * 3];
        for y in 0..height {
            for x in 0..width {
                let offset = (y * width + x) * 3;
                let level = 0.25 + (x % 4) as f32 * 0.12 + (y % 3) as f32 * 0.08;
                for c in 0..3 {
                    styled[offset + c] = level;
                    recovered[offset + c] = if x < width / 2 { level - 0.05 } else { level };
                }
            }
        }
        let data = revert_local_style_data(width, height, &styled, &recovered).unwrap();
        assert_eq!(data.len(), STYLE_DATA_BYTE_COUNT);
        let read = |x, y, plane, term, channel| {
            let i = tile_index(x, y, plane) * BLOCK_VALUE_COUNT + term * CHANNEL_COUNT + channel;
            f16_to_f32(u16::from_le_bytes([data[i * 2], data[i * 2 + 1]]))
        };
        let left = read(0, 4, 3, 0, 0);
        let right = read(11, 4, 3, 0, 0);
        assert!(left < -0.01, "left residual should darken, got {left}");
        assert!(right > left + 0.01, "left {left}, right {right}");
        assert_ne!(data, identity_style_data());

        let applied = apply_style_data(&data, width, height, &styled).unwrap();
        let identity = apply_style_data(&identity_style_data(), width, height, &styled).unwrap();
        let fit_err = rmse_raw(&applied, &recovered);
        let id_err = rmse_raw(&identity, &recovered);
        assert!(fit_err < id_err * 0.5, "fit {fit_err} vs identity {id_err}");
    }

    #[test]
    fn apply_style_data_identity_preserves_rgb() {
        let rgb = [0.2_f32, 0.45, 0.7, 0.05, 0.1, 0.9, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0];
        let applied = apply_style_data(&identity_style_data(), 2, 2, &rgb).unwrap();
        for (actual, expected) in applied.iter().zip(rgb) {
            assert!((actual - expected).abs() < 1e-5, "identity moved {expected} to {actual}");
        }
        assert!(mean_abs_chroma_delta(&rgb, &applied) < 1e-6);
        assert!(apply_style_data(&identity_style_data(), 1, 1, &[0.0; 6]).is_err());
        assert!(apply_style_data(&[0; 2], 1, 1, &[0.0; 3]).is_err());
    }

    /// Upstream PR #88 fixture
    /// (`standard_key1_stays_identity_when_the_recovered_ratio_is_outside_the_box`):
    /// a gradient primary whose "thumbnail" differs by a per-channel RGB gain
    /// (warm right half, cool left half), as a gain-map ratio would. The
    /// bounded primary→thumbnail fit cannot express that ratio; the clamped
    /// cross terms repaint chromaticity when the payload is replayed on the
    /// primary. Documents the failure mode; the production decision is in
    /// `docs/modules/styles-pipeline.md` §4.1.
    #[test]
    fn key1_fit_of_rgb_gain_sample_repaints_chromaticity() {
        let (width, height) = (24, 18);
        let mut styled = Vec::with_capacity(width * height * 3);
        let mut recovered = Vec::with_capacity(width * height * 3);
        for y in 0..height {
            for x in 0..width {
                let red = 0.08 + (x as f32 / width as f32) * 0.55;
                let green = 0.05 + (y as f32 / height as f32) * 0.35;
                let blue = 0.04 + ((x + y) % 5) as f32 * 0.03;
                let scale = if x >= width / 2 {
                    [0.35_f32, 0.9, 1.8]
                } else {
                    [1.4, 0.7, 0.25]
                };
                styled.extend_from_slice(&[red, green, blue]);
                recovered.extend_from_slice(&[
                    (red * scale[0]).clamp(0.0, 1.0),
                    (green * scale[1]).clamp(0.0, 1.0),
                    (blue * scale[2]).clamp(0.0, 1.0),
                ]);
            }
        }
        let data = revert_local_style_data(width, height, &styled, &recovered).unwrap();
        let painted = apply_style_data(&data, width, height, &styled).unwrap();
        let invented = mean_abs_chroma_delta(&styled, &painted);
        assert!(invented > 0.02, "fit should repaint chromaticity, got {invented}");

        let kept = apply_style_data(&identity_style_data(), width, height, &styled).unwrap();
        let preserved = mean_abs_chroma_delta(&styled, &kept);
        assert!(preserved < 1e-3, "identity changed chromaticity by {preserved}");
    }

    #[test]
    fn key1_fit_of_unchanged_image_is_identity() {
        let (width, height) = (36, 27);
        let styled: Vec<f32> = (0..width * height * 3)
            .map(|i| ((i * 37) % 101) as f32 / 100.0)
            .collect();
        let data = revert_local_style_data(width, height, &styled, &styled).unwrap();
        assert_eq!(data, identity_style_data());
    }

    /// Synthetic scene pair shaped like the pipeline's: a gradient primary and
    /// a scene-linear thumbnail with a smooth spatial gain (brighter top-left,
    /// as an HDR gain map would give). Both fits must beat identity on the
    /// consumer model and the GTC must stay monotonic.
    #[test]
    fn fit_style_state_beats_identity_on_scene_pair() {
        let (width, height) = (96, 72);
        let mut primary = Vec::with_capacity(width * height * 3);
        let mut scene = Vec::with_capacity(width * height * 3);
        for y in 0..height {
            for x in 0..width {
                let u = x as f32 / (width - 1) as f32;
                let v = y as f32 / (height - 1) as f32;
                let rgb = [
                    0.05 + 0.85 * u * (0.6 + 0.4 * v),
                    0.05 + 0.8 * (0.5 * u + 0.5 * v),
                    0.08 + 0.7 * v * v,
                ];
                let gain = 1.0 + 1.5 * (1.0 - u) * (1.0 - v);
                for c in rgb {
                    primary.push(c);
                    scene.push(c * gain);
                }
            }
        }
        let raster = StyleFitRaster {
            width,
            height,
            primary_linear: primary.clone(),
            scene_linear: scene.clone(),
        };
        let (baseline, base_gain) = (4.0, 1.838_402_390_480_041_5);
        let fitted = fit_style_state(&raster, baseline, base_gain).unwrap();
        let s: Vec<f32> = scene
            .iter()
            .map(|&v| (f64::from(v) * base_gain / baseline).clamp(0.0, 1.0) as f32)
            .collect();

        // GTC: S -> primary.
        assert!(monotonic(&fitted.global_tone_curve.linear_samples));
        let identity_gtc = decode_global_tone_curve(FIELD_3).unwrap();
        let id_gtc_err = rmse_raw(&apply_global_tone_curve(&s, &identity_gtc), &primary);
        assert!(
            fitted.global_tone_curve.fit_rmse < id_gtc_err,
            "gtc fit {} vs identity {id_gtc_err}",
            fitted.global_tone_curve.fit_rmse
        );

        // key1: primary -> S. The residual here (S ≈ 0.46 × gain × primary)
        // exceeds the ±1/8 linear / ±1/16 quadratic coefficient bounds, so
        // the bounded fit closes only part of it; it must still clearly win.
        let applied = apply_style_data(&fitted.style_data, width, height, &primary).unwrap();
        let fit_err = rmse_raw(&applied, &s);
        let id_err = rmse_raw(&primary, &s);
        assert!(fit_err < id_err * 0.85, "key1 fit {fit_err} vs identity {id_err}");
    }

    #[test]
    fn fit_style_state_rejects_bad_scale() {
        let raster = StyleFitRaster {
            width: 2,
            height: 1,
            primary_linear: vec![0.5; 6],
            scene_linear: vec![0.5; 6],
        };
        assert!(fit_style_state(&raster, 0.0, 1.0).is_err());
        assert!(fit_style_state(&raster, 4.0, f64::NAN).is_err());
        assert!(fit_style_state(&raster, 4.0, 1.8).is_ok());
    }
}
