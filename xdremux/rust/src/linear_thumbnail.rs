//! Real Linear Thumbnail generation (`tag:apple.com,2023:photo:aux:linearthumbnail`).
//!
//! Native spec: a HEVC preview in **Apple Log code space**, stored in the
//! primary's coded orientation with the primary's `irot`, long edge capped at
//! 1024 and both edges forced even. Our generation path:
//!
//! 1. decode the primary (grid-aware, orientation-applied, sRGB) via
//!    heif-oxide — 8-bit sources yield `Rgb8`, 10/12-bit yield `Rgb16`;
//! 2. undo the display rotation so storage matches the primary's coded frame
//!    (the aux item inherits `irot`);
//! 3. sRGB decode to linear light, resize in the linear domain with the
//!    upstream `fitted_even_dimensions` geometry (aspect preserved, no crop,
//!    no upscale);
//! 4. divide by the Styles baseline exposure (`styleData` plist key 4), apply
//!    the Apple Log curve, and encode 8-bit 4:2:0 HEVC.
//!
//! Remaining gaps vs native (tracked in `docs/modules/styles-pipeline.md`):
//! the encoder is 8-bit (MAIN10 would remove the code-range quantization), and
//! no gain map is applied because the port has no HEVC decoder for the tmap
//! grid, so the thumbnail carries SDR range only.

#[derive(Debug, Clone)]
pub struct LinearThumbnailOutput {
    pub stream: Vec<u8>,
    pub hvcc: Vec<u8>,
    pub light_c: Vec<u8>,
    pub light_d: Vec<u8>,
    /// Stored thumbnail width (long edge <= 1024, even).
    pub width: u32,
    /// Stored thumbnail height (even).
    pub height: u32,
    /// HEVC bit depth of the encoded stream: 10 when the optional Main10
    /// encoder was linked, 8 for the Apple Log interim path.
    pub bit_depth: u8,
    /// Display-order linear primary / scene pair at thumbnail geometry, the
    /// input of the per-image key 1 / key 3 fits (`styles_fit`).
    pub fit_raster: crate::styles_fit::StyleFitRaster,
}

/// Generate the linear thumbnail HEVC stream + hvcC for a converted HEIC.
///
/// `rotate_cw_quarter_turns` is the primary's `irot` value (quarter turns
/// CCW applied at display time): heif-oxide returns the display-oriented
/// image, and the stored thumbnail must undo that rotation (rotate CW by
/// the same amount) so the inherited `irot` renders it upright again.
/// `baseline_exposure` is the Styles `styleData` plist key 4 value written into
/// the same file; the Apple Log code is relative to it.
/// Returns `(length-prefixed stream, hvcC box payload, width, height)`.
pub fn generate_linear_thumbnail(
    source_heic: &[u8],
    rotate_cw_quarter_turns: u32,
    baseline_exposure: f32,
) -> Result<(Vec<u8>, Vec<u8>, u32, u32), String> {
    generate_linear_thumbnail_and_light_maps(
        source_heic,
        rotate_cw_quarter_turns,
        1,
        baseline_exposure,
    )
    .map(|out| (out.stream, out.hvcc, out.width, out.height))
}

/// Borrowed ISO 21496 gain-map luma plane, at whatever resolution the source
/// carries  it (base resolution or half of it).
///
/// Path 3 of `docs/research/gainmap-decode-feasibility-20261025.md`: the
/// conversion pipeline already holds the reconstructed gain map in memory, so
/// the linear thumbnail can apply HDR headroom without decoding the HEVC-coded
/// gain-map item.
#[derive(Debug, Clone, Copy)]
pub struct GainMapPlane<'a> {
    pub luma: &'a [u8],
    pub width: u32,
    pub height: u32,
    /// Linear gain corresponding to code 0 (>= 1.0 when headroom exists).
    pub min_gain: f32,
    /// Linear gain corresponding to code 255.
    pub max_gain: f32,
}

impl GainMapPlane<'_> {
    /// Linear gain for `code` in `0..=255`.
    pub fn gain_from_code(&self, code: u8) -> f32 {
        let span = (self.max_gain - self.min_gain).max(0.0);
        (self.min_gain + span * (f32::from(code) / 255.0)).max(0.0)
    }

    /// Gain at base-image pixel `(x, y)` in a `base_width × base_height`
    /// raster, by nearest-neighbour lookup in the (smaller) gain-map plane.
    pub fn gain_at(&self, x: u32, y: u32, base_width: u32, base_height: u32) -> f32 {
        if self.luma.is_empty() || self.width == 0 || self.height == 0
            || base_width == 0 || base_height == 0
        {
            return 1.0;
        }
        let gx = ((u64::from(x) * u64::from(self.width)) / u64::from(base_width))
            .min(u64::from(self.width - 1)) as usize;
        let gy = ((u64::from(y) * u64::from(self.height)) / u64::from(base_height))
            .min(u64::from(self.height - 1)) as usize;
        let index = gy * self.width as usize + gx;
        match self.luma.get(index) {
            Some(&code) => self.gain_from_code(code),
            None => 1.0,
        }
    }
}

/// Owned counterpart of [`GainMapPlane`] for callers that must outlive the
/// borrow (the conversion pipeline decodes the gain map before writing the
/// output, then hands it to the thumbnail generator).
#[derive(Debug, Clone)]
pub struct OwnedGainMap {
    pub luma: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub min_gain: f32,
    pub max_gain: f32,
}

impl OwnedGainMap {
    pub fn plane(&self) -> GainMapPlane<'_> {
        GainMapPlane {
            luma: &self.luma,
            width: self.width,
            height: self.height,
            min_gain: self.min_gain,
            max_gain: self.max_gain,
        }
    }
}

/// Generate linear thumbnail and dynamic 32×32 photographic style light maps.
pub fn generate_linear_thumbnail_and_light_maps(
    source_heic: &[u8],
    rotate_cw_quarter_turns: u32,
    orientation: u16,
    baseline_exposure: f32,
) -> Result<LinearThumbnailOutput, String> {
    generate_linear_thumbnail_and_light_maps_with_gain_map(
        source_heic,
        rotate_cw_quarter_turns,
        orientation,
        baseline_exposure,
        None,
    )
}

/// Like [`generate_linear_thumbnail_and_light_maps`], but multiplies the
/// scene-linear base by the supplied ISO 21496 gain map before resampling, so
/// the Apple Log codes carry the file's HDR headroom.
pub fn generate_linear_thumbnail_and_light_maps_with_gain_map(
    source_heic: &[u8],
    rotate_cw_quarter_turns: u32,
    orientation: u16,
    baseline_exposure: f32,
    gain_map: Option<&GainMapPlane<'_>>,
) -> Result<LinearThumbnailOutput, String> {
    const LINEAR_THUMBNAIL_MAX_SIZE: u32 = 1024;

    // Converted OPPO files keep the donor's trailing extension region after
    // mdat; a claimed box size past EOF makes heif-oxide bail with
    // Truncated("top-level"). Decode from the valid ISOBMFF prefix only.
    let mut pos = 0usize;
    while pos + 8 <= source_heic.len() {
        let size = u32::from_be_bytes(
            source_heic[pos..pos + 4].try_into().unwrap(),
        ) as usize;
        let (size, hdr) = if size == 1 {
            if pos + 16 > source_heic.len() {
                break;
            }
            (
                usize::try_from(u64::from_be_bytes(
                    source_heic[pos + 8..pos + 16].try_into().unwrap(),
                ))
                .unwrap_or(usize::MAX),
                16,
            )
        } else {
            (size, 8)
        };
        if size < hdr || pos + size > source_heic.len() {
            break;
        }
        pos += size;
    }
    let good_end = pos;
    let decodable = if good_end == source_heic.len() || good_end == 0 {
        source_heic
    } else {
        &source_heic[..good_end]
    };

    let image = heif_oxide::decode_bytes(decodable)
        .map_err(|e| format!("linear thumb: decode primary: {e:?}"))?;
    let (rgb, w, h) = match &image.pixels {
        heif_oxide::Pixels::Rgb8(v) => (v.clone(), image.width, image.height),
        heif_oxide::Pixels::Rgba8(v) => (
            v.chunks_exact(4).flat_map(|p| p[..3].iter().copied()).collect(),
            image.width,
            image.height,
        ),
        heif_oxide::Pixels::Rgb16(v) => (
            v.chunks_exact(3).flat_map(|p| p.iter().map(|&s| (s >> 8) as u8)).collect(),
            image.width,
            image.height,
        ),
        heif_oxide::Pixels::Rgba16(v) => (
            v.chunks_exact(4).flat_map(|p| p[..3].iter().map(|&s| (s >> 8) as u8)).collect(),
            image.width,
            image.height,
        ),
    };
    if w == 0 || h == 0 {
        return Err("linear thumb: decoded primary has zero extent".into());
    }

    // Dynamic 32×32 photographic styles light maps derived from decoded primary pixels.
    let (light_c, light_d) = compute_storage_light_maps(&rgb, w, h, orientation);

    // Undo the display rotation: rotate CW by the primary's irot amount so
    // the stored (pre-irot) orientation matches the primary's storage.
    let (mut rgb, mut w, mut h) = (rgb, w, h);
    for _ in 0..(rotate_cw_quarter_turns % 4) {
        let mut out = vec![0u8; rgb.len()];
        for y in 0..h {
            for x in 0..w {
                let src = ((y * w + x) * 3) as usize;
                let dst = ((x * h + (h - 1 - y)) * 3) as usize;
                out[dst..dst + 3].copy_from_slice(&rgb[src..src + 3]);
            }
        }
        rgb = out;
        std::mem::swap(&mut w, &mut h);
    }

    // Linearize the display-referred sRGB samples, because Apple Log codes are
    // defined over linear light. Skipping this would make the Photos consumer
    // decode log over sRGB (double transfer -> washed-out style preview).
    let linearize = |gain_map: Option<&GainMapPlane<'_>>| -> Vec<f32> {
        let mut linear = Vec::with_capacity(rgb.len());
        for (pixel_index, chunk) in rgb.chunks_exact(3).enumerate() {
            let x = (pixel_index % w as usize) as u32;
            let y = (pixel_index / w as usize) as u32;
            let gain = match gain_map {
                Some(plane) => plane.gain_at(x, y, w, h),
                None => 1.0,
            };
            for &sample in chunk {
                linear.push(crate::apple_log::srgb8_to_linear(sample) as f32 * gain);
            }
        }
        linear
    };

    // Native geometry contract: long edge capped, both edges even, coded
    // aspect preserved (no 4:3 crop), never upscaled.
    let (out_w, out_h) = fitted_even_dimensions(w, h, LINEAR_THUMBNAIL_MAX_SIZE)?;
    let resized = area_resize_linear_rgb(&linearize(gain_map), w, h, out_w, out_h)?;
    // The Styles fits pair the scene-linear thumbnail with the displayed
    // primary at the same footprint. One full-resolution buffer at a time.
    let primary_resized = if gain_map.is_some() {
        area_resize_linear_rgb(&linearize(None), w, h, out_w, out_h)?
    } else {
        resized.clone()
    };
    // Fits run in display order (upstream `bb66981b`); undo the storage
    // rotation applied above on the small buffers.
    let turns = rotate_cw_quarter_turns % 4;
    let (fit_w, fit_h, scene_display) = rotate_ccw_rgb_f32(&resized, out_w, out_h, turns);
    let (_, _, primary_display) = rotate_ccw_rgb_f32(&primary_resized, out_w, out_h, turns);
    let fit_raster = crate::styles_fit::StyleFitRaster {
        width: fit_w as usize,
        height: fit_h as usize,
        primary_linear: primary_display,
        scene_linear: scene_display,
    };

    // Baseline exposure (Styles plist key 4) then Apple Log. Both encoders
    // consume the same 16-bit codes; only the quantization/encoder differs, so
    // the 8-bit interim and the Main10 path cannot drift apart.
    let codes16 = crate::apple_log::thumbnail_codes(&resized, baseline_exposure)?;
    let (stream, hvcc, bit_depth) = encode_linear_thumbnail_codes(&codes16, out_w, out_h)?;
    let idr = crate::hevc::drop_parameter_nals(&stream);
    Ok(LinearThumbnailOutput {
        stream: crate::hevc::hevc_byte_stream_to_length_prefixed(&idr),
        hvcc,
        light_c,
        light_d,
        width: out_w,
        height: out_h,
        bit_depth,
        fit_raster,
    })
}

/// Rotate an interleaved f32 RGB raster counter-clockwise by `turns` quarter
/// turns (the inverse of the storage CW rotation above).
fn rotate_ccw_rgb_f32(rgb: &[f32], w: u32, h: u32, turns: u32) -> (u32, u32, Vec<f32>) {
    let (mut data, mut w, mut h) = (rgb.to_vec(), w as usize, h as usize);
    for _ in 0..(turns % 4) {
        // Output is h x w; out(x', y') = src(w - 1 - y', x').
        let mut out = vec![0.0f32; data.len()];
        for yo in 0..w {
            for xo in 0..h {
                let src = ((xo * w) + (w - 1 - yo)) * 3;
                let dst = (yo * h + xo) * 3;
                out[dst..dst + 3].copy_from_slice(&data[src..src + 3]);
            }
        }
        data = out;
        std::mem::swap(&mut w, &mut h);
    }
    (w as u32, h as u32, data)
}

/// Encode Apple Log codes with the best encoder this build has.
///
/// The optional Main10 encoder is used when the 10-bit x265 archive was linked
/// at build time (`xdremux_main10`); otherwise the 8-bit Apple Log interim path
/// quantizes the same codes in the log domain, which is the behaviour that
/// shipped before Main10 landed.
fn encode_linear_thumbnail_codes(
    codes16: &[u16],
    width: u32,
    height: u32,
) -> Result<(Vec<u8>, Vec<u8>, u8), String> {
    // x265 refuses pictures smaller than one CTU (64x64 with the default
    // maxCUSize); tiny thumbnails fall back to the 8-bit path which has its own
    // small-picture handling.
    if crate::hevc::main10_available() && width >= 64 && height >= 64 {
        #[cfg(xdremux_main10)]
        {
            let stream = crate::hevc::encode_thumbnail_10bit(codes16, width, height)
                .map_err(|e| format!("linear thumb 10-bit encode: {e}"))?;
            let hvcc =
                crate::hevc::extract_hvcc_config_with_chroma_and_depth(&stream, 1, 10)
                    .ok_or("linear thumb hvcC extraction failed (10-bit)")?;
            return Ok((stream, hvcc, 10));
        }
    }
    let codes8: Vec<u8> = codes16
        .iter()
        .map(|&code| ((u32::from(code) + 128) / 257) as u8)
        .collect();
    let stream = crate::hevc::x265_encode_tiles(&[codes8.as_slice()], width, height, 3, true)
        .map_err(|e| format!("linear thumb encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("linear thumb encode produced no stream")?;
    let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, 1)
        .ok_or("linear thumb hvcC extraction failed")?;
    Ok((stream, hvcc, 8))
}

/// Long-edge cap for the stored linear thumbnail (native files use 1024).
const MAX_LINEAR_THUMBNAIL_EDGE: u32 = 1024;

/// Fit `(width, height)` into a square `maximum_edge` budget with both edges
/// even, preserving aspect and never upscaling. Mirrors the upstream
/// `fitted_even_dimensions` contract that native Styles thumbnails follow.
pub fn fitted_even_dimensions(
    width: u32,
    height: u32,
    maximum_edge: u32,
) -> Result<(u32, u32), String> {
    if width == 0 || height == 0 || maximum_edge < 2 {
        return Err(format!(
            "linear thumb geometry: width/height must be positive and max edge at least 2 \
             (got {width}x{height}, max {maximum_edge})"
        ));
    }
    let maximum = f64::from(maximum_edge);
    let scale = (maximum / f64::from(width))
        .min(maximum / f64::from(height))
        .min(1.0);
    let even = |value: u32| -> u32 {
        let scaled = (f64::from(value) * scale / 2.0).round() * 2.0;
        scaled.clamp(2.0, maximum) as u32
    };
    Ok((even(width), even(height)))
}

/// Area-covered mean resample in linear light (f32, interleaved RGB).
///
/// The destination pixel is the coverage-weighted mean of the source pixels it
/// covers, which is the resample the native pipeline applies after scene-linear
/// reconstruction. It is not nearest-neighbour and it must run before the log
/// encode, not on encoded codes.
pub fn area_resize_linear_rgb(
    linear: &[f32],
    width: u32,
    height: u32,
    target_width: u32,
    target_height: u32,
) -> Result<Vec<f32>, String> {
    let (width, height) = (width as usize, height as usize);
    let (target_width, target_height) = (target_width as usize, target_height as usize);
    if width == 0 || height == 0 || target_width == 0 || target_height == 0 {
        return Err("linear thumb resize: zero extent".into());
    }
    if linear.len() != width * height * 3 {
        return Err(format!(
            "linear thumb resize: raster has {} samples for {width}x{height}x3",
            linear.len()
        ));
    }
    if width == target_width && height == target_height {
        return Ok(linear.to_vec());
    }

    let mut out = vec![0.0f32; target_width * target_height * 3];
    for ty in 0..target_height {
        let y0 = ty as f64 * height as f64 / target_height as f64;
        let y1 = (ty + 1) as f64 * height as f64 / target_height as f64;
        for tx in 0..target_width {
            let x0 = tx as f64 * width as f64 / target_width as f64;
            let x1 = (tx + 1) as f64 * width as f64 / target_width as f64;
            let mut accumulator = [0.0f64; 3];
            let mut coverage = 0.0f64;
            for sy in (y0.floor() as usize)..(y1.ceil() as usize).min(height) {
                let y_coverage = ((sy + 1) as f64).min(y1) - (sy as f64).max(y0);
                if y_coverage <= 0.0 {
                    continue;
                }
                for sx in (x0.floor() as usize)..(x1.ceil() as usize).min(width) {
                    let x_coverage = ((sx + 1) as f64).min(x1) - (sx as f64).max(x0);
                    if x_coverage <= 0.0 {
                        continue;
                    }
                    let weight = x_coverage * y_coverage;
                    let offset = (sy * width + sx) * 3;
                    for (acc, sample) in accumulator.iter_mut().zip(&linear[offset..offset + 3]) {
                        *acc += f64::from(*sample) * weight;
                    }
                    coverage += weight;
                }
            }
            if coverage <= 0.0 {
                return Err("linear thumb resize: destination pixel has no coverage".into());
            }
            let destination = (ty * target_width + tx) * 3;
            for (slot, acc) in out[destination..destination + 3]
                .iter_mut()
                .zip(accumulator)
            {
                let value = acc / coverage;
                if !value.is_finite() {
                    return Err("linear thumb resize: non-finite sample".into());
                }
                *slot = value as f32;
            }
        }
    }
    Ok(out)
}

/// Area-average (box) downsample of an interleaved RGB8 raster.
pub fn box_resize(rgb: &[u8], w: u32, h: u32, tw: u32, th: u32) -> Vec<u8> {
    let (w, h, tw, th) = (w as usize, h as usize, tw as usize, th as usize);
    let mut out = vec![0u8; tw * th * 3];
    if w == 0 || h == 0 {
        return out;
    }
    for dy in 0..th {
        // Source rows covered by this destination row (fractional bounds).
        let sy0 = dy as f64 * h as f64 / th as f64;
        let sy1 = (dy + 1) as f64 * h as f64 / th as f64;
        for dx in 0..tw {
            let sx0 = dx as f64 * w as f64 / tw as f64;
            let sx1 = (dx + 1) as f64 * w as f64 / tw as f64;
            let mut acc = [0f64; 3];
            let mut count = 0f64;
            let y0 = sy0.floor() as usize;
            let y1 = (sy1.ceil() as usize).min(h);
            let x0 = sx0.floor() as usize;
            let x1 = (sx1.ceil() as usize).min(w);
            for y in y0..y1 {
                let fy = row_weight(y, sy0, sy1);
                for x in x0..x1 {
                    let fx = col_weight(x, sx0, sx1);
                    let weight = fy * fx;
                    if weight <= 0.0 {
                        continue;
                    }
                    let src = (y * w + x) * 3;
                    acc[0] += rgb[src] as f64 * weight;
                    acc[1] += rgb[src + 1] as f64 * weight;
                    acc[2] += rgb[src + 2] as f64 * weight;
                    count += weight;
                }
            }
            let dst = (dy * tw + dx) * 3;
            if count > 0.0 {
                out[dst] = (acc[0] / count).round().clamp(0.0, 255.0) as u8;
                out[dst + 1] = (acc[1] / count).round().clamp(0.0, 255.0) as u8;
                out[dst + 2] = (acc[2] / count).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

fn row_weight(y: usize, y0: f64, y1: f64) -> f64 {
    y1.min((y + 1) as f64) - y0.max(y as f64)
}

fn col_weight(x: usize, x0: f64, x1: f64) -> f64 {
    x1.min((x + 1) as f64) - x0.max(x as f64)
}

/// Convert f32 to f16 (IEEE 754 half-precision) using round-to-nearest-even.
pub fn f32_to_f16(val: f32) -> u16 {
    let bits = val.to_bits();
    let sign = ((bits >> 31) & 1) as u16;
    let exp = ((bits >> 23) & 0xff) as i32;
    let frac = bits & 0x7f_ffff;

    if exp == 0xff {
        let f16_frac = if frac != 0 { 0x200 } else { 0 };
        return (sign << 15) | 0x7c00 | f16_frac;
    }
    let new_exp = exp - 127 + 15;
    if new_exp >= 31 {
        return (sign << 15) | 0x7c00;
    }
    if new_exp <= 0 {
        if new_exp < -10 {
            return sign << 15;
        }
        let frac_full = frac | 0x80_0000;
        let shift = (14 - new_exp) as u32;
        let mut f16_frac = frac_full >> shift;
        let round_bits = frac_full & ((1 << shift) - 1);
        let half_way = 1 << (shift - 1);
        if (round_bits > half_way) || (round_bits == half_way && (f16_frac & 1) != 0) {
            f16_frac += 1;
        }
        return (sign << 15) | (f16_frac as u16);
    }
    let mut f16_frac = frac >> 13;
    let round_bits = frac & 0x1fff;
    if (round_bits > 0x1000) || (round_bits == 0x1000 && (f16_frac & 1) != 0) {
        f16_frac += 1;
    }
    let mant = ((new_exp as u16) << 10) + (f16_frac as u16);
    (sign << 15) | mant
}

/// Compute 32×32 toneLightMap (key "c") and linearLightMap (key "d") in display
/// (presentation) order from decoded primary sRGB pixels.
/// Each map is returned as 2048 bytes (32×32 f16 little-endian).
pub fn compute_presentation_light_maps(rgb: &[u8], width: u32, height: u32) -> (Vec<u8>, Vec<u8>) {
    const SIDE: usize = 32;
    const TONE_SCALE: f32 = 0.71372382;
    const TONE_OFFSET: f32 = 0.02554340;
    const LINEAR_SCALE: f32 = 0.93942103;
    const LINEAR_OFFSET: f32 = 0.06494295;
    const TONE_MIN: f32 = 0.040740966796875;
    const TONE_MAX: f32 = 0.76123046875;
    const LINEAR_MIN: f32 = 0.040740966796875;
    const LINEAR_MAX: f32 = 0.75830078125;

    let w = width as usize;
    let h = height as usize;
    let mut light_c = Vec::with_capacity(SIDE * SIDE * 2);
    let mut light_d = Vec::with_capacity(SIDE * SIDE * 2);

    for ty in 0..SIDE {
        let y0 = ty * h / SIDE;
        let y1 = ((ty + 1) * h / SIDE).max(y0 + 1).min(h);
        for tx in 0..SIDE {
            let x0 = tx * w / SIDE;
            let x1 = ((tx + 1) * w / SIDE).max(x0 + 1).min(w);
            let mut sum_luma = 0.0f64;
            let mut count = 0usize;
            for y in y0..y1 {
                let row_start = y * w * 3;
                for x in x0..x1 {
                    let idx = row_start + x * 3;
                    let r = rgb[idx] as f64 / 255.0;
                    let g = rgb[idx + 1] as f64 / 255.0;
                    let b = rgb[idx + 2] as f64 / 255.0;
                    sum_luma += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    count += 1;
                }
            }
            let avg = if count > 0 { (sum_luma / count as f64) as f32 } else { 0.0 };
            let t_val = (avg * TONE_SCALE + TONE_OFFSET).clamp(TONE_MIN, TONE_MAX);
            let l_val = (avg * LINEAR_SCALE + LINEAR_OFFSET).clamp(LINEAR_MIN, LINEAR_MAX);
            light_c.extend_from_slice(&f32_to_f16(t_val).to_le_bytes());
            light_d.extend_from_slice(&f32_to_f16(l_val).to_le_bytes());
        }
    }
    (light_c, light_d)
}

/// Convert presentation-ordered 32×32 f16 light map into storage coordinates
/// according to EXIF storage orientation (1..8).
pub fn storage_ordered_light_map(presentation: &[u8], orientation: u16) -> Vec<u8> {
    const SIDE: usize = 32;
    if presentation.len() != SIDE * SIDE * 2 {
        return presentation.to_vec();
    }
    let mut out = vec![0u8; SIDE * SIDE * 2];
    for storage_y in 0..SIDE {
        for storage_x in 0..SIDE {
            let (disp_x, disp_y) = match orientation {
                2 => (SIDE - 1 - storage_x, storage_y),
                3 => (SIDE - 1 - storage_x, SIDE - 1 - storage_y),
                4 => (storage_x, SIDE - 1 - storage_y),
                5 => (storage_y, storage_x),
                6 => (SIDE - 1 - storage_y, storage_x),
                7 => (SIDE - 1 - storage_y, SIDE - 1 - storage_x),
                8 => (storage_y, SIDE - 1 - storage_x),
                _ => (storage_x, storage_y),
            };
            let src_idx = (disp_y * SIDE + disp_x) * 2;
            let dst_idx = (storage_y * SIDE + storage_x) * 2;
            out[dst_idx] = presentation[src_idx];
            out[dst_idx + 1] = presentation[src_idx + 1];
        }
    }
    out
}

/// Compute 32×32 toneLightMap and linearLightMap in storage order.
pub fn compute_storage_light_maps(
    rgb: &[u8],
    width: u32,
    height: u32,
    orientation: u16,
) -> (Vec<u8>, Vec<u8>) {
    let (c_pres, d_pres) = compute_presentation_light_maps(rgb, width, height);
    (
        storage_ordered_light_map(&c_pres, orientation),
        storage_ordered_light_map(&d_pres, orientation),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gain_map_plane_maps_codes_and_samples_nearest() {
        let plane = GainMapPlane {
            luma: &[0u8, 255u8],
            width: 2,
            height: 1,
            min_gain: 1.0,
            max_gain: 4.0,
        };
        assert!((plane.gain_from_code(0) - 1.0).abs() < 1e-6);
        assert!((plane.gain_from_code(255) - 4.0).abs() < 1e-6);
        assert!((plane.gain_at(0, 0, 4, 1) - 1.0).abs() < 1e-6);
        assert!((plane.gain_at(2, 0, 4, 1) - 4.0).abs() < 1e-6);
        assert!((plane.gain_at(3, 0, 4, 1) - 4.0).abs() < 1e-6);

        let empty = GainMapPlane {
            luma: &[],
            width: 0,
            height: 0,
            min_gain: 1.0,
            max_gain: 4.0,
        };
        assert_eq!(empty.gain_at(3, 3, 10, 10), 1.0);
        let no_headroom = GainMapPlane {
            luma: &[255u8],
            width: 1,
            height: 1,
            min_gain: 1.0,
            max_gain: 1.0,
        };
        assert_eq!(no_headroom.gain_from_code(255), 1.0);
    }

    #[test]
    fn test_f32_to_f16_known_values() {
        assert_eq!(f32_to_f16(0.0), 0x0000);
        assert_eq!(f32_to_f16(1.0), 0x3c00);
        assert_eq!(f32_to_f16(0.5), 0x3800);
        assert_eq!(f32_to_f16(2.0), 0x4000);
        assert_eq!(f32_to_f16(-1.0), 0xbc00);
    }

    #[test]
    fn test_light_map_dimensions_and_clamping() {
        // 64x64 white image
        let white = vec![255u8; 64 * 64 * 3];
        let (c, d) = compute_presentation_light_maps(&white, 64, 64);
        assert_eq!(c.len(), 32 * 32 * 2);
        assert_eq!(d.len(), 32 * 32 * 2);

        // 64x64 black image
        let black = vec![0u8; 64 * 64 * 3];
        let (cb, db) = compute_presentation_light_maps(&black, 64, 64);
        assert_eq!(cb.len(), 32 * 32 * 2);
        assert_eq!(db.len(), 32 * 32 * 2);
    }

    #[test]
    fn test_storage_ordered_light_map_identity() {
        let dummy: Vec<u8> = (0..(32 * 32 * 2)).map(|i| (i & 0xff) as u8).collect();
        let reordered = storage_ordered_light_map(&dummy, 1);
        assert_eq!(dummy, reordered);
    }

    // ---------- native geometry contract (P0-1) ----------

    #[test]
    fn rotate_ccw_inverts_the_storage_cw_rotation() {
        // 3x2 raster, one distinct value per pixel (R channel).
        let src: Vec<f32> = (0..6).flat_map(|i| [i as f32, 0.0, 0.0]).collect();
        // One CCW turn: out is 2x3, out(x', y') = src(2 - y', x').
        let (w, h, out) = rotate_ccw_rgb_f32(&src, 3, 2, 1);
        assert_eq!((w, h), (2, 3));
        let r: Vec<f32> = out.chunks_exact(3).map(|p| p[0]).collect();
        assert_eq!(r, vec![2.0, 5.0, 1.0, 4.0, 0.0, 3.0]);
        let (w4, h4, full) = rotate_ccw_rgb_f32(&src, 3, 2, 4);
        assert_eq!((w4, h4, full), (3, 2, src.clone()));
        let (w0, h0, none) = rotate_ccw_rgb_f32(&src, 3, 2, 0);
        assert_eq!((w0, h0, none), (3, 2, src));
    }

    #[test]
    fn fitted_even_dimensions_follow_the_native_contract() {
        // 4:3 landscape keeps the native 1024x768 shape.
        assert_eq!(fitted_even_dimensions(4032, 3024, 1024).unwrap(), (1024, 768));
        // 16:9 keeps its aspect instead of being cropped to 4:3.
        assert_eq!(fitted_even_dimensions(4032, 2268, 1024).unwrap(), (1024, 576));
        // Portrait coded frame stays portrait (irot handles display rotation).
        assert_eq!(fitted_even_dimensions(3024, 4032, 1024).unwrap(), (768, 1024));
        // Small images are never upscaled.
        assert_eq!(fitted_even_dimensions(800, 600, 1024).unwrap(), (800, 600));
        // Odd edges are forced even and stay inside the budget.
        let (w, h) = fitted_even_dimensions(4001, 3001, 1024).unwrap();
        assert_eq!((w % 2, h % 2), (0, 0));
        assert!(w <= 1024 && h <= 1024);
        // Extreme aspect still yields an even raster inside the budget.
        let (w, h) = fitted_even_dimensions(10000, 100, 1024).unwrap();
        assert_eq!((w, h), (1024, 10));
    }

    #[test]
    fn fitted_even_dimensions_rejects_degenerate_input() {
        assert!(fitted_even_dimensions(0, 100, 1024).is_err());
        assert!(fitted_even_dimensions(100, 0, 1024).is_err());
        assert!(fitted_even_dimensions(100, 100, 1).is_err());
    }

    #[test]
    fn area_resize_linear_averages_coverage() {
        // 4x4 with column-graded values -> 2x2 averages per quadrant.
        let mut raster = vec![0.0f32; 4 * 4 * 3];
        for y in 0..4 {
            for x in 0..4 {
                let v = (x + 1) as f32;
                let offset = (y * 4 + x) * 3;
                raster[offset] = v;
                raster[offset + 1] = v;
                raster[offset + 2] = v;
            }
        }
        let out = area_resize_linear_rgb(&raster, 4, 4, 2, 2).unwrap();
        assert_eq!(out.len(), 2 * 2 * 3);
        // Left quadrant covers x=0,1 (mean 1.5); right covers x=2,3 (mean 3.5).
        assert!((out[0] - 1.5).abs() < 1e-6);
        assert!((out[3] - 3.5).abs() < 1e-6);
        // Rows are identical because the source is column-only graded.
        assert!((out[6] - 1.5).abs() < 1e-6);
        assert!((out[9] - 3.5).abs() < 1e-6);
    }

    #[test]
    fn area_resize_linear_identity_and_validation() {
        let raster = vec![0.25f32; 3 * 2 * 3];
        let same = area_resize_linear_rgb(&raster, 3, 2, 3, 2).unwrap();
        assert_eq!(same, raster);
        assert!(area_resize_linear_rgb(&raster, 3, 2, 0, 2).is_err());
        assert!(area_resize_linear_rgb(&[], 0, 0, 2, 2).is_err());
        assert!(area_resize_linear_rgb(&[0.0; 5], 3, 2, 2, 2).is_err());
    }
}
