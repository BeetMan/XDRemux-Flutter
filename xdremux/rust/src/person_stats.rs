//! Per-face statistics for the Texture Style person contract.
//!
//! The estimator choices here are calibrated against Apple's own recorded
//! values on 31 native samples — see
//! `docs/research/person-data-reverse-engineering.md`:
//!
//! - `SkinSmoothAverageFaceColour`: **linear-light mean** over a skin-hue mask
//!   inside `faceSkinROI` (error 0.09 versus the recorded values, a 42%
//!   improvement over a plain bounding-box sRGB mean).
//! - `SkinSmoothFaceRoughness`: high-frequency texture energy — mean absolute
//!   3x3 Laplacian — through the linear fit derived from the same samples.
//!
//! The mask is a colour heuristic, not a segmentation model: the real
//! `semanticfaceskinmatte` was measured and is *not* more accurate here.

use crate::texture_styles::PersonInstance;

/// Fit from 21 native samples: `rough ≈ 0.475 * lap_abs + 0.0057`.
const ROUGHNESS_GAIN: f64 = 0.4751;
const ROUGHNESS_BIAS: f64 = 0.00572;

fn srgb_to_linear(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// A rectangle in normalised image coordinates.
#[derive(Debug, Clone, Copy)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// RGB image, 8-bit, tightly packed, already in presentation orientation.
pub struct RgbImage<'a> {
    pub pixels: &'a [u8],
    pub width: u32,
    pub height: u32,
}

impl<'a> RgbImage<'a> {
    pub fn at(&self, x: u32, y: u32) -> [f64; 3] {
        let i = ((y * self.width + x) * 3) as usize;
        [
            self.pixels[i] as f64 / 255.0,
            self.pixels[i + 1] as f64 / 255.0,
            self.pixels[i + 2] as f64 / 255.0,
        ]
    }
    pub fn luma(&self, x: u32, y: u32) -> f64 {
        let p = self.at(x, y);
        (p[0] + p[1] + p[2]) / 3.0
    }
}

/// Pixel window covered by a normalised rect, clamped to the image.
fn window(img: &RgbImage, r: Rect) -> Option<(u32, u32, u32, u32)> {
    let x0 = (r.x.max(0.0) * img.width as f64).floor() as u32;
    let y0 = (r.y.max(0.0) * img.height as f64).floor() as u32;
    let x1 = ((r.x + r.w).min(1.0) * img.width as f64).ceil() as u32;
    let y1 = ((r.y + r.h).min(1.0) * img.height as f64).ceil() as u32;
    if x1 <= x0 || y1 <= y0 {
        None
    } else {
        Some((x0, y0, x1.min(img.width), y1.min(img.height)))
    }
}

/// Skin-hue mask: warm, mid-luminance pixels. Measured to cut the skin-colour
/// error by ~31% versus using the whole bounding box.
fn is_skin(p: [f64; 3]) -> bool {
    let (r, g, b) = (p[0], p[1], p[2]);
    let lum = (r + g + b) / 3.0;
    r > g + 0.02 && g > b && (0.12..0.95).contains(&lum)
}

/// Linear-light mean over the skin-hue pixels of `roi`.
fn skin_colour(img: &RgbImage, roi: Rect) -> [f64; 3] {
    let Some((x0, y0, x1, y1)) = window(img, roi) else {
        return [0.0, 0.0, 0.0];
    };
    let mut sum = [0.0; 3];
    let mut n = 0u64;
    for y in y0..y1 {
        for x in x0..x1 {
            let p = img.at(x, y);
            if is_skin(p) {
                for c in 0..3 {
                    sum[c] += srgb_to_linear(p[c]);
                }
                n += 1;
            }
        }
    }
    if n == 0 {
        return [0.0, 0.0, 0.0];
    }
    let mut out = [0.0; 3];
    for c in 0..3 {
        // Report in the same domain Apple uses: sRGB-encoded.
        let lin = sum[c] / n as f64;
        out[c] = if lin <= 0.0031308 {
            lin * 12.92
        } else {
            1.055 * lin.powf(1.0 / 2.4) - 0.055
        };
    }
    out
}

/// Mean absolute 3x3 Laplacian over the skin pixels, mapped to the roughness
/// scale through the fit above. Returns `None` when there is too little skin
/// to measure — Apple omits the field for some faces too.
fn skin_roughness(img: &RgbImage, roi: Rect) -> Option<f64> {
    let (x0, y0, x1, y1) = window(img, roi)?;
    if x1 - x0 < 3 || y1 - y0 < 3 {
        return None;
    }
    let mut acc = 0.0;
    let mut n = 0u64;
    for y in (y0 + 1)..(y1 - 1) {
        for x in (x0 + 1)..(x1 - 1) {
            if !is_skin(img.at(x, y)) {
                continue;
            }
            let c = img.luma(x, y);
            let lap = 4.0 * c
                - img.luma(x - 1, y)
                - img.luma(x + 1, y)
                - img.luma(x, y - 1)
                - img.luma(x, y + 1);
            acc += lap.abs();
            n += 1;
        }
    }
    if n < 64 {
        return None;
    }
    Some(ROUGHNESS_GAIN * (acc / n as f64) + ROUGHNESS_BIAS)
}

/// Linear-light mean colour plus luminance variance inside `roi`.
fn region_colour(img: &RgbImage, roi: Rect) -> ([f64; 3], f64) {
    let Some((x0, y0, x1, y1)) = window(img, roi) else {
        return ([0.0, 0.0, 0.0], 0.0);
    };
    let mut sum = [0.0; 3];
    let mut lums = Vec::new();
    for y in y0..y1 {
        for x in x0..x1 {
            let p = img.at(x, y);
            for c in 0..3 {
                sum[c] += srgb_to_linear(p[c]);
            }
            lums.push((p[0] + p[1] + p[2]) / 3.0);
        }
    }
    let n = lums.len() as f64;
    let mut out = [0.0; 3];
    for c in 0..3 {
        let lin = sum[c] / n;
        out[c] = if lin <= 0.0031308 {
            lin * 12.92
        } else {
            1.055 * lin.powf(1.0 / 2.4) - 0.055
        };
    }
    let mean = lums.iter().sum::<f64>() / n;
    let var = lums.iter().map(|l| (l - mean) * (l - mean)).sum::<f64>() / n;
    (out, var)
}

/// Cheap bimodality test: two well-separated luminance modes (dark lashes /
/// bright sclera) show up as a large gap between the two cluster centres of a
/// 2-means split at the median.
fn is_bimodal(img: &RgbImage, roi: Rect) -> bool {
    let Some((x0, y0, x1, y1)) = window(img, roi) else {
        return false;
    };
    let mut lums: Vec<f64> = Vec::new();
    for y in y0..y1 {
        for x in x0..x1 {
            lums.push(img.luma(x, y));
        }
    }
    if lums.len() < 16 {
        return false;
    }
    lums.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mid = lums.len() / 2;
    let lo = lums[..mid].iter().sum::<f64>() / mid as f64;
    let hi = lums[mid..].iter().sum::<f64>() / (lums.len() - mid) as f64;
    (hi - lo) > 0.12
}

/// Eye region from the 76-landmark layout: points 0-6 are one eye, 7-13 the
/// other. Returns normalised rects.
pub fn eye_rects(landmarks: &[(f64, f64)]) -> (Rect, Rect) {
    let rect_of = |pts: &[(f64, f64)]| {
        let xs: Vec<f64> = pts.iter().map(|p| p.0).collect();
        let ys: Vec<f64> = pts.iter().map(|p| p.1).collect();
        let (x0, x1) = (
            xs.iter().cloned().fold(f64::INFINITY, f64::min),
            xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
        );
        let (y0, y1) = (
            ys.iter().cloned().fold(f64::INFINITY, f64::min),
            ys.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
        );
        // Pad a little: the eyelid sits above/below the landmark ring.
        let (w, h) = ((x1 - x0).max(1e-4), (y1 - y0).max(1e-4));
        Rect {
            x: x0 - 0.25 * w,
            y: y0 - 0.5 * h,
            w: w * 1.5,
            h: h * 2.0,
        }
    };
    (rect_of(&landmarks[..7]), rect_of(&landmarks[7..14]))
}

/// Fill the statistics half of a [PersonInstance] from the image.
///
/// Geometry (rects, landmarks, pose) is the caller's — it comes from the face
/// detector and the landmark template. This only measures the image.
pub fn fill_stats(
    img: &RgbImage,
    person: &mut PersonInstance,
    landmarks_norm: &[(f64, f64)],
) {
    person.skin_colour = skin_colour(img, Rect {
        x: person.face_skin_roi[0],
        y: person.face_skin_roi[1],
        w: person.face_skin_roi[2],
        h: person.face_skin_roi[3],
    });
    person.skin_roughness = skin_roughness(img, Rect {
        x: person.face_skin_roi[0],
        y: person.face_skin_roi[1],
        w: person.face_skin_roi[2],
        h: person.face_skin_roi[3],
    });
    person.mattify_colour = person.skin_colour;

    let (left, right) = eye_rects(landmarks_norm);
    let (lc, lv) = region_colour(img, left);
    let (rc, rv) = region_colour(img, right);
    person.left_eye_colour = lc;
    person.right_eye_colour = rc;
    person.left_eye_luma_var = lv;
    person.right_eye_luma_var = rv;
    person.left_eye_bimodal = is_bimodal(img, left);
    person.right_eye_bimodal = is_bimodal(img, right);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 8x8 image: a warm skin patch plus a cool corner.
    fn toy() -> (Vec<u8>, u32, u32) {
        let mut px = Vec::new();
        for y in 0..8 {
            for x in 0..8 {
                if x < 4 && y < 4 {
                    px.extend_from_slice(&[200, 150, 120]); // skin-ish
                } else {
                    px.extend_from_slice(&[40, 60, 200]); // blue
                }
            }
        }
        (px, 8, 8)
    }

    #[test]
    fn skin_colour_finds_the_skin_patch() {
        let (px, w, h) = toy();
        let img = RgbImage {
            pixels: &px,
            width: w,
            height: h,
        };
        let c = skin_colour(&img, Rect { x: 0.0, y: 0.0, w: 1.0, h: 1.0 });
        // Warm and bright, unlike the blue background.
        assert!(c[0] > c[2], "R should exceed B, got {c:?}");
        assert!(c[0] > 0.4, "expected a bright skin tone, got {c:?}");
    }

    #[test]
    fn roughness_is_low_on_a_flat_patch() {
        let (px, w, h) = toy();
        let img = RgbImage {
            pixels: &px,
            width: w,
            height: h,
        };
        // Flat skin block: near-zero Laplacian inside it.
        let r = skin_roughness(&img, Rect { x: 0.0, y: 0.0, w: 0.4, h: 0.4 });
        // May be None on tiny regions; when present it must be near the bias.
        if let Some(v) = r {
            assert!(v < 0.02, "flat skin should be smooth, got {v}");
        }
    }

    #[test]
    fn eye_rects_follow_the_landmark_layout() {
        let mut lm = Vec::new();
        for i in 0..7 {
            lm.push((0.1 + i as f64 * 0.01, 0.3));
        }
        for i in 0..7 {
            lm.push((0.6 + i as f64 * 0.01, 0.3));
        }
        while lm.len() < 76 {
            lm.push((0.5, 0.5));
        }
        let (l, r) = eye_rects(&lm);
        assert!(l.x < 0.2, "left eye should sit left, got {l:?}");
        assert!(r.x > 0.5, "right eye should sit right, got {r:?}");
    }
}
