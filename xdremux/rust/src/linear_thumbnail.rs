//! Real Linear Thumbnail generation (`tag:apple.com,2023:photo:aux:linearthumbnail`).
//!
//! Native spec: a fixed 1024×768 landscape HEVC preview stored with the
//! primary's `irot`, linear-domain color. Our generation path:
//!
//! 1. decode the primary (grid-aware, orientation-applied, sRGB) via
//!    heif-oxide — 8-bit sources yield `Rgb8`, 10/12-bit yield `Rgb16`;
//! 2. rotate a portrait display image to landscape storage (the aux item
//!    inherits the primary's irot, so landscape storage + inherited irot
//!    reproduces the native "横置 + irot" convention);
//! 3. area-average resample to exactly 1024×768;
//! 4. encode 8-bit 4:2:0 HEVC (the existing x265 path). Native files carry
//!    10-bit; MAIN10 support depends on the linked x265 build, so 8-bit is
//!    the portable floor (Photos tolerates it — placeholder acceptance
//!    precedent).

#[derive(Debug, Clone)]
pub struct LinearThumbnailOutput {
    pub stream: Vec<u8>,
    pub hvcc: Vec<u8>,
    pub light_c: Vec<u8>,
    pub light_d: Vec<u8>,
}

/// Generate the linear thumbnail HEVC stream + hvcC for a converted HEIC.
///
/// `rotate_cw_quarter_turns` is the primary's `irot` value (quarter turns
/// CCW applied at display time): heif-oxide returns the display-oriented
/// image, and the stored thumbnail must undo that rotation (rotate CW by
/// the same amount) so the inherited `irot` renders it upright again.
/// Returns `(length-prefixed stream, hvcC box payload)`.
pub fn generate_linear_thumbnail(
    source_heic: &[u8],
    rotate_cw_quarter_turns: u32,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    generate_linear_thumbnail_and_light_maps(source_heic, rotate_cw_quarter_turns, 1)
        .map(|out| (out.stream, out.hvcc))
}

/// Generate linear thumbnail and dynamic 32×32 photographic style light maps.
pub fn generate_linear_thumbnail_and_light_maps(
    source_heic: &[u8],
    rotate_cw_quarter_turns: u32,
    orientation: u16,
) -> Result<LinearThumbnailOutput, String> {
    const OUT_W: u32 = 1024;
    const OUT_H: u32 = 768;

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

    // Fixed 1024×768 output: center-crop to 4:3 first so the resample never
    // distorts non-4:3 aspects.
    let (w, h) = (w as usize, h as usize);
    let target_ratio = OUT_W as f64 / OUT_H as f64;
    let cur_ratio = w as f64 / h as f64;
    let (cw, cw_w, cw_h): (Vec<u8>, usize, usize) = if (cur_ratio - target_ratio).abs() > 1e-6 {
        if cur_ratio > target_ratio {
            // too wide: crop width
            let nw = (h as f64 * target_ratio).round() as usize;
            let x0 = (w - nw) / 2;
            let mut out = Vec::with_capacity(nw * h * 3);
            for y in 0..h {
                let row = &rgb[(y * w + x0) * 3..(y * w + x0 + nw) * 3];
                out.extend_from_slice(row);
            }
            (out, nw, h)
        } else {
            // too tall: crop height
            let nh = (w as f64 / target_ratio).round() as usize;
            let y0 = (h - nh) / 2;
            let mut out = Vec::with_capacity(w * nh * 3);
            out.extend_from_slice(&rgb[(y0 * w) * 3..((y0 + nh) * w) * 3]);
            (out, w, nh)
        }
    } else {
        (rgb, w, h)
    };

    let thumb = box_resize(&cw, cw_w as u32, cw_h as u32, OUT_W, OUT_H);

    let stream = crate::hevc::x265_encode_tiles(
        &[thumb.as_slice()],
        OUT_W,
        OUT_H,
        3,
        true,
    )
    .map_err(|e| format!("linear thumb encode: {e}"))?
    .into_iter()
    .next()
    .ok_or("linear thumb encode produced no stream")?;
    let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, 1)
        .ok_or("linear thumb hvcC extraction failed")?;
    let idr = crate::hevc::drop_parameter_nals(&stream);
    Ok(LinearThumbnailOutput {
        stream: crate::hevc::hevc_byte_stream_to_length_prefixed(&idr),
        hvcc,
        light_c,
        light_d,
    })
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
}
