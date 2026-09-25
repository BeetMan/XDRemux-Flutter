//! Face detection + landmark synthesis for the Texture Style person contract.
//!
//! Pipeline: decode -> YuNet (bbox + 5 keypoints) -> canonical 76-point
//! template -> [crate::person_stats] -> `TextureStylePostProcessedPeopleData`.
//!
//! The 76-point template is derived from Apple's own samples
//! (see `docs/research/person-data-reverse-engineering.md`), so no external
//! landmark model is needed. YuNet is embedded in the binary (232 KB, Apache
//! 2.0) so there is nothing to ship alongside the app.

use crate::person_stats::{fill_stats, RgbImage};
use crate::texture_styles::PersonInstance;

/// YuNet face detection model (Apache-2.0, from opencv_zoo).
const YUNET: &[u8] = include_bytes!("../models/face_detection_yunet_2023mar.onnx");
/// Canonical 76-point face template, normalised to the face box.
const LANDMARKS_76: &str = include_str!("../models/face_landmarks_76.json");

const INPUT_SIZE: usize = 640;

/// Intersection over union of two normalised `[x, y, w, h]` boxes.
fn iou(a: [f64; 4], b: [f64; 4]) -> f64 {
    let (ax0, ay0, ax1, ay1) = (a[0], a[1], a[0] + a[2], a[1] + a[3]);
    let (bx0, by0, bx1, by1) = (b[0], b[1], b[0] + b[2], b[1] + b[3]);
    let (ix0, iy0) = (ax0.max(bx0), ay0.max(by0));
    let (ix1, iy1) = (ax1.min(bx1), ay1.min(by1));
    let inter = (ix1 - ix0).max(0.0) * (iy1 - iy0).max(0.0);
    let union = a[2] * a[3] + b[2] * b[3] - inter;
    if union <= 0.0 {
        0.0
    } else {
        inter / union
    }
}

/// One detected face before statistics are measured.
#[derive(Debug, Clone)]
pub struct DetectedFace {
    /// Normalised (x, y, w, h) in image coordinates.
    pub face_roi: [f64; 4],
    /// YuNet's 5 keypoints, normalised: left eye, right eye, nose,
    /// left mouth corner, right mouth corner.
    pub keypoints: [(f64, f64); 5],
    pub confidence: f64,
}

/// Simple JSON array reader for the template (avoids a serde dependency).
fn parse_template(json: &str) -> Vec<(f64, f64)> {
    // The file is {"mean": [[x,y], ...], "std": [...], "n": ...}; only the
    // mean shape is the template.
    let anchor = json.find("\"mean\"").unwrap_or(0);
    let start = json[anchor..].find('[').map(|i| anchor + i).unwrap_or(0);
    let depth_end = {
        let mut depth = 0i32;
        let mut end = start;
        for (i, ch) in json[start..].char_indices() {
            match ch {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if depth == 0 {
                        end = start + i + 1;
                        break;
                    }
                }
                _ => {}
            }
        }
        end
    };
    let body = &json[start..depth_end];
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut buf = String::new();
    let mut pair: Vec<f64> = Vec::new();
    for ch in body.chars() {
        match ch {
            '[' => {
                depth += 1;
                buf.clear();
                pair.clear();
            }
            ']' => {
                depth -= 1;
                // Only sub-arrays are points; the outer array closes at depth 0.
                if depth == 1 {
                    for part in buf.split(',') {
                        let t = part.trim();
                        if let Ok(v) = t.parse::<f64>() {
                            pair.push(v);
                        }
                    }
                    if pair.len() >= 2 {
                        out.push((pair[0], pair[1]));
                    }
                }
                buf.clear();
                pair.clear();
            }
            ',' if depth == 2 => {
                for part in buf.split(',') {
                    let t = part.trim();
                    if let Ok(v) = t.parse::<f64>() {
                        pair.push(v);
                    }
                }
                buf.clear();
            }
            _ => buf.push(ch),
        }
    }
    out
}

/// Place the canonical 76-point template on a detected face.
///
/// The template is normalised to the face box (centre + max side), so placing
/// it needs only the box. Measured accuracy is 0.103 of the face box size,
/// which is enough for skin smoothing but coarse for the eye regions.
pub fn place_landmarks(face_roi: [f64; 4]) -> Vec<(f64, f64, f64)> {
    let template = parse_template(LANDMARKS_76);
    let (cx, cy) = (face_roi[0] + face_roi[2] / 2.0, face_roi[1] + face_roi[3] / 2.0);
    let scale = face_roi[2].max(face_roi[3]);
    template
        .into_iter()
        .map(|(x, y)| (cx + x * scale, cy + y * scale, 0.02))
        .collect()
}

/// Detect faces with YuNet. `image` must already be in presentation
/// orientation (the same convention as the pixels we write out).
pub fn detect_faces(image: &RgbImage) -> Result<Vec<DetectedFace>, String> {
    use ort::inputs;
    use ort::session::builder::GraphOptimizationLevel;

    // Nearest-neighbour downscale to YuNet's fixed 640x640 input.
    let (pw, ph) = (INPUT_SIZE, INPUT_SIZE);
    let (sw, sh) = (image.width as usize, image.height as usize);
    let mut planar = vec![0f32; 3 * pw * ph];
    for y in 0..ph {
        for x in 0..pw {
            let (sx, sy) = (x * sw / pw, y * sh / ph);
            let p = image.at(sx as u32, sy as u32);
            // YuNet is an OpenCV model: BGR channel order, 0..255 floats.
            planar[y * pw + x] = (p[2] * 255.0) as f32;
            planar[pw * ph + y * pw + x] = (p[1] * 255.0) as f32;
            planar[2 * pw * ph + y * pw + x] = (p[0] * 255.0) as f32;
        }
    }

    let mut session = ort::session::Session::builder()
        .map_err(|e| format!("ort session: {e:?}"))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| format!("ort opt: {e:?}"))?
        .commit_from_memory(YUNET)
        .map_err(|e| format!("ort commit: {e:?}"))?;
    let input = ort::value::Tensor::from_array(([1usize, 3, ph, pw], planar))
        .map_err(|e| format!("ort tensor: {e:?}"))?;
    let outputs = session
        .run(inputs![input])
        .map_err(|e| format!("ort run: {e:?}"))?;

    // Three detection strides (8/16/32); take the best candidate per anchor
    // set and keep everything above threshold.
    let mut faces: Vec<DetectedFace> = Vec::new();
    for stride in [8usize, 16, 32] {
        let cells = (INPUT_SIZE / stride) * (INPUT_SIZE / stride);
        let pick = |name: String| outputs.iter().find(|(n, _)| *n == name).map(|(_, v)| v);
        let (Some(cls_v), Some(bbox_v), Some(kps_v)) = (
            pick(format!("cls_{}", stride)),
            pick(format!("bbox_{}", stride)),
            pick(format!("kps_{}", stride)),
        ) else {
            continue;
        };
        let (Ok((_, cls)), Ok((_, bbox)), Ok((_, kps))) = (
            cls_v.try_extract_tensor::<f32>(),
            bbox_v.try_extract_tensor::<f32>(),
            kps_v.try_extract_tensor::<f32>(),
        ) else {
            continue;
        };
        for i in 0..cells {
            let conf = *cls.get(i).unwrap_or(&0.0);
            if conf < 0.85 {
                continue;
            }
            let b = i * 4;
            if b + 4 > bbox.len() {
                continue;
            }
            // YuNet predicts anchor-relative deltas, not absolute boxes:
            //   centre = anchor_centre + delta * stride
            //   size   = exp(delta) * stride
            // with the anchor for cell (row, col) at ((col+0.5)*stride,
            // (row+0.5)*stride) and base size = stride.
            let cells_per_row = INPUT_SIZE / stride;
            let (col, row) = (i % cells_per_row, i / cells_per_row);
            let ax = (col as f64 + 0.5) * stride as f64;
            let ay = (row as f64 + 0.5) * stride as f64;
            let s = stride as f64;
            let (dx, dy, dw, dh) = (
                bbox[b] as f64,
                bbox[b + 1] as f64,
                bbox[b + 2] as f64,
                bbox[b + 3] as f64,
            );
            let (cx, cy) = (ax + dx * s, ay + dy * s);
            let (w, h) = (dw.exp() * s, dh.exp() * s);
            let (x, y) = (cx - w / 2.0, cy - h / 2.0);
            // Raw keypoint deltas for this anchor (5 pairs).
            let mut kp5 = [(0.0f64, 0.0f64); 5];
            for (k, slot) in kp5.iter_mut().enumerate() {
                let o = i * 10 + k * 2;
                if o + 1 < kps.len() {
                    *slot = (kps[o] as f64, kps[o + 1] as f64);
                }
            }
            // Keypoints are anchor-relative the same way.
            let mut kp_norm = [(0.0, 0.0); 5];
            for (k, (kdx, kdy)) in kp5.iter().enumerate() {
                kp_norm[k] = (
                    (ax + kdx * s) / INPUT_SIZE as f64,
                    (ay + kdy * s) / INPUT_SIZE as f64,
                );
            }
            faces.push(DetectedFace {
                face_roi: [
                    x / INPUT_SIZE as f64,
                    y / INPUT_SIZE as f64,
                    w / INPUT_SIZE as f64,
                    h / INPUT_SIZE as f64,
                ],
                keypoints: kp_norm,
                confidence: conf as f64,
            });
        }
    }
    // NMS: the three strides report the same face several times, so keep the
    // strongest and drop anything that overlaps it.
    faces.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
    let mut kept: Vec<DetectedFace> = Vec::new();
    for f in faces {
        // Ignore slivers: a real face is at least a couple of percent wide.
        if f.face_roi[2] < 0.02 {
            continue;
        }
        let overlaps = kept.iter().any(|k| iou(k.face_roi, f.face_roi) > 0.3);
        if !overlaps {
            kept.push(f);
        }
    }
    Ok(kept)
}

/// Map a normalised point from the *presented* (oriented) space back to the
/// *stored* pixel space, which is where Apple records its face geometry.
///
/// The decode gives us pixels already rotated for display, so a measurement
/// taken there has to be carried back before it is written to the bplist.
/// `orientation` is the EXIF value (1..8).
pub fn unorient_point(x: f64, y: f64, orientation: u32) -> (f64, f64) {
    match orientation {
        2 => (1.0 - x, y),
        3 => (1.0 - x, 1.0 - y),
        4 => (x, 1.0 - y),
        5 => (y, x),
        6 => (y, 1.0 - x),
        7 => (1.0 - y, 1.0 - x),
        8 => (1.0 - y, x),
        _ => (x, y),
    }
}

/// Same for a normalised `[x, y, w, h]` box: transform the corners and take
/// the bounding box, since 90-degree turns swap width and height.
pub fn unorient_rect(r: [f64; 4], orientation: u32) -> [f64; 4] {
    if orientation <= 1 {
        return r;
    }
    let corners = [
        (r[0], r[1]),
        (r[0] + r[2], r[1]),
        (r[0], r[1] + r[3]),
        (r[0] + r[2], r[1] + r[3]),
    ];
    let t: Vec<(f64, f64)> = corners
        .iter()
        .map(|(x, y)| unorient_point(*x, *y, orientation))
        .collect();
    let xs: Vec<f64> = t.iter().map(|p| p.0).collect();
    let ys: Vec<f64> = t.iter().map(|p| p.1).collect();
    let (x0, x1) = (
        xs.iter().cloned().fold(f64::INFINITY, f64::min),
        xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    );
    let (y0, y1) = (
        ys.iter().cloned().fold(f64::INFINITY, f64::min),
        ys.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    );
    [x0, y0, x1 - x0, y1 - y0]
}

/// Full person pipeline: detect, place landmarks, measure the image, and
/// return the instances ready to publish in the texture bplist.
pub fn build_person_instances(image: &RgbImage) -> Result<Vec<PersonInstance>, String> {
    build_person_instances_oriented(image, 1)
}

/// Same, carrying the source EXIF orientation so the published geometry lands
/// in the stored pixel space Apple uses.
pub fn build_person_instances_oriented(
    image: &RgbImage,
    orientation: u32,
) -> Result<Vec<PersonInstance>, String> {
    let faces = detect_faces(image)?;
    let mut out = Vec::with_capacity(faces.len());
    for (i, f) in faces.iter().enumerate() {
        let lm = place_landmarks(f.face_roi);
        // Face orientation from the five keypoints: the eye-line tilt gives
        // roll, the nose's sideways offset gives yaw, and its height below the
        // eye midpoint gives pitch.
        let (re, le, nose) = (f.keypoints[0], f.keypoints[1], f.keypoints[2]);
        let (eye_mx, eye_my) = ((re.0 + le.0) / 2.0, (re.1 + le.1) / 2.0);
        let roll = (le.1 - re.1).atan2(le.0 - re.0);
        let eye_span = ((le.0 - re.0).hypot(le.1 - re.1)).max(1e-6);
        let yaw = ((nose.0 - eye_mx) / eye_span).clamp(-1.5, 1.5) * 2.0;
        let pitch = ((nose.1 - eye_my) / eye_span - 0.45).clamp(-1.5, 1.5) * 2.0;
        // Skin region: a widened face box (Apple's faceSkinROI is larger than
        // the face box — it reaches the hairline and jaw).
        let pad = 0.55;
        let (w, h) = (f.face_roi[2], f.face_roi[3]);
        let skin = [
            f.face_roi[0] - pad * w,
            f.face_roi[1] - pad * h,
            w * (1.0 + 2.0 * pad),
            h * (1.0 + 2.0 * pad),
        ];
        let lm_xy: Vec<(f64, f64)> = lm.iter().map(|(x, y, _)| (*x, *y)).collect();
        let mut p = PersonInstance {
            face_id: i as i64,
            face_roi: f.face_roi,
            face_skin_roi: skin,
            // Apple records the whole person instance here (roughly 0.52 x
            // 0.64 for a face of 0.07 x 0.10), not the face box.
            instance_roi: {
                let (fx, fy, fw, fh) = (f.face_roi[0], f.face_roi[1], f.face_roi[2], f.face_roi[3]);
                let x = (fx - fw).max(0.0);
                let y = (fy - 3.0 * fh).max(0.0);
                [x, y, (3.5 * fw).min(1.0 - x), (7.0 * fh).min(1.0 - y)]
            },
            // Apple records a fixed horizontal inset here for this detection
            // scheme (1 - 2/44 wide), not the full unit square.
            scaling_roi: [0.02272727272727276, 0.0, 0.9545454545454546, 1.0],
            yaw,
            pitch,
            roll,
            landmarks: lm,
            skin_colour: [0.0; 3],
            skin_roughness: None,
            skin_skip: false,
            mattify_colour: [0.0; 3],
            mattify_highlights_ratio: 0.0,
            left_eye_colour: [0.0; 3],
            right_eye_colour: [0.0; 3],
            left_eye_luma_var: 0.0,
            right_eye_luma_var: 0.0,
            left_eye_bimodal: false,
            right_eye_bimodal: false,
        };
        fill_stats(image, &mut p, &lm_xy);
        p.mattify_colour = p.skin_colour;
        // Geometry is measured in the oriented (presented) space the decoder
        // gave us; Apple records it in the stored pixel space, so carry it
        // back before publishing. Statistics are unaffected — they sample
        // pixels, not coordinates.
        if orientation > 1 {
            p.face_roi = unorient_rect(p.face_roi, orientation);
            p.face_skin_roi = unorient_rect(p.face_skin_roi, orientation);
            p.instance_roi = unorient_rect(p.instance_roi, orientation);
            for slot in p.landmarks.iter_mut() {
                let (nx, ny) = unorient_point(slot.0, slot.1, orientation);
                slot.0 = nx;
                slot.1 = ny;
            }
        }
        out.push(p);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_parses_to_76_points() {
        let t = parse_template(LANDMARKS_76);
        assert_eq!(t.len(), 76, "template must carry exactly 76 points");
    }

    #[test]
    fn placing_landmarks_scales_with_the_face_box() {
        let a = place_landmarks([0.1, 0.1, 0.2, 0.2]);
        let b = place_landmarks([0.4, 0.4, 0.1, 0.1]);
        assert_eq!(a.len(), 76);
        assert_eq!(b.len(), 76);
        // Smaller box -> points closer to the centre of that box.
        let spread = |pts: &[(f64, f64, f64)]| {
            let xs: Vec<f64> = pts.iter().map(|p| p.0).collect();
            xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
                - xs.iter().cloned().fold(f64::INFINITY, f64::min)
        };
        assert!(spread(&b) < spread(&a));
    }
}
