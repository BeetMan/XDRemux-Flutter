//! R5 stage 3: OPPO rear.depth diagnostics + disparity-scale calibration.
//!
//! Rust port of `PortraitDepthDiagnostics.swift` (schema
//! `xdremux-portrait-depth-diagnostic-v1`) plus the calibration decision the
//! 2026-08-18 candidate acceptance settled: **pass through the
//! producer-embedded rankDisparityScale (upstream behaviour); fall back to
//! the p50 physical formula** (`focal * baseline / (disparity * distance)`,
//! median focus-window rank) when the embedded scale is missing/invalid.
//!
//! Acceptance note: all four calibration candidates (p20/p50/p80/uniform)
//! produced working Photos depth sliders — the scale only shifts the
//! f-number mapping, and Photos tolerates a wide plausible range.

use serde_json::{json, Map, Value};

pub(crate) const HEADER_SIZE: usize = 768;

/// Parse pixel dimensions from a JPEG (SOF0/1/2) or PNG (IHDR) payload.
pub(crate) fn image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    // PNG: 8-byte signature + IHDR
    if data.starts_with(b"\x89PNG\r\n\x1a\n") && data.len() > 24 {
        let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
        let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
        return Some((w, h));
    }
    // JPEG: scan markers for SOF0/1/2
    if data.starts_with(b"\xff\xd8") {
        let mut pos = 2usize;
        while pos + 4 <= data.len() {
            if data[pos] != 0xff {
                pos += 1;
                continue;
            }
            let marker = data[pos + 1];
            if marker == 0xc0 || marker == 0xc1 || marker == 0xc2 {
                if pos + 9 <= data.len() {
                    let h = u16::from_be_bytes([data[pos + 5], data[pos + 6]]) as u32;
                    let w = u16::from_be_bytes([data[pos + 7], data[pos + 8]]) as u32;
                    return Some((w, h));
                }
                return None;
            }
            if marker == 0xd8 || marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
                pos += 2;
                continue;
            }
            let len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
            if len < 2 {
                return None;
            }
            pos += 2 + len;
        }
    }
    None
}

pub(crate) fn read_u32le(d: &[u8], off: usize) -> Option<u32> {
    d.get(off..off + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}
pub(crate) fn read_u16le(d: &[u8], off: usize) -> Option<u16> {
    d.get(off..off + 2).map(|b| u16::from_le_bytes([b[0], b[1]]))
}
pub(crate) fn read_i32le(d: &[u8], off: usize) -> Option<i32> {
    d.get(off..off + 4)
        .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}
pub(crate) fn read_f32le(d: &[u8], off: usize) -> Option<f32> {
    read_u32le(d, off).map(f32::from_bits)
}

struct PlaneStats {
    minimum: u8,
    maximum: u8,
    zero_count: usize,
    mean: f64,
}

fn plane_stats(data: &[u8], offset: usize, count: usize) -> Option<PlaneStats> {
    let plane = data.get(offset..offset + count)?;
    let mut minimum = u8::MAX;
    let mut maximum = 0u8;
    let mut zero_count = 0usize;
    let mut sum = 0u64;
    for &v in plane {
        minimum = minimum.min(v);
        maximum = maximum.max(v);
        if v == 0 {
            zero_count += 1;
        }
        sum += v as u64;
    }
    Some(PlaneStats {
        minimum,
        maximum,
        zero_count,
        mean: sum as f64 / count.max(1) as f64,
    })
}

impl PlaneStats {
    fn json(&self, count: usize) -> Value {
        json!({
            "min": self.minimum,
            "max": self.maximum,
            "zeroCount": self.zero_count,
            "nonZeroCount": count - self.zero_count,
            "mean": self.mean,
        })
    }
}

pub(crate) struct ConfigSummary {
    pub(crate) version: f32,
    pub(crate) canvas_width: i32,
    pub(crate) canvas_height: i32,
    pub(crate) focus_x: i32,
    pub(crate) focus_y: i32,
    pub(crate) current_f_number: Option<f32>,
    pub(crate) object_distance: Option<i32>,
    pub(crate) focus_roi_type: Option<i32>,
}

pub(crate) fn parse_config(data: Option<&[u8]>) -> Option<ConfigSummary> {
    let data = data?;
    let version = read_f32le(data, 0)?;
    if !version.is_finite() || !(1.0..=4.0).contains(&version) {
        return None;
    }
    let canvas_width = read_i32le(data, 4)?;
    let canvas_height = read_i32le(data, 8)?;
    let focus_x = read_i32le(data, 12)?;
    let focus_y = read_i32le(data, 16)?;
    let current_f_number = read_f32le(data, 292)
        .filter(|v| v.is_finite() && (1.0..=64.0).contains(v));
    let object_distance = read_i32le(data, 296).filter(|&v| v > 0);
    let focus_roi_type = read_i32le(data, 404);
    Some(ConfigSummary {
        version,
        canvas_width,
        canvas_height,
        focus_x,
        focus_y,
        current_f_number,
        object_distance,
        focus_roi_type,
    })
}

impl ConfigSummary {
    fn json(&self) -> Value {
        json!({
            "version": self.version,
            "canvasWidth": self.canvas_width,
            "canvasHeight": self.canvas_height,
            "focusX": self.focus_x,
            "focusY": self.focus_y,
            "currentFNumber": self.current_f_number,
            "objectDistance": self.object_distance,
            "focusROIType": self.focus_roi_type,
        })
    }
}

/// The calibration decision (R5 stage 3 closure).
#[derive(Debug, Clone)]
pub(crate) enum ScaleDecision {
    /// Producer quantization is present: pass the embedded scale through
    /// (upstream behaviour).
    Passthrough(f64),
    /// Zero-quantization variant: embedded scale unusable; use the p50
    /// physical formula derived from the focus window.
    CalibratedP50(f64),
    /// Cannot calibrate (missing config / distance / focus data).
    Unavailable(String),
}

impl ScaleDecision {
    /// The chosen scale value, when available.
    pub(crate) fn scale(&self) -> Option<f64> {
        match self {
            Self::Passthrough(v) | Self::CalibratedP50(v) => Some(*v),
            Self::Unavailable(_) => None,
        }
    }

    fn json(&self) -> Value {
        match self {
            Self::Passthrough(s) => json!({
                "mode": "passthrough",
                "scale": s,
                "rationale": "producer quantization present; matches upstream behaviour",
            }),
            Self::CalibratedP50(s) => json!({
                "mode": "calibrated-p50",
                "scale": s,
                "rationale": "zero-quantization depth; focal*baseline/(disparity*distance) at the median focus-window rank",
            }),
            Self::Unavailable(reason) => json!({
                "mode": "unavailable",
                "reason": reason,
            }),
        }
    }
}

/// Physical scale formula shared by the diagnostic candidates and the p50
/// fallback: map a focus-window rank through the rank normalization into an
/// internal disparity, then `focal * baseline / (disparity * distance)`.
pub(crate) fn scale_for_rank(
    rank: f64,
    rank_maximum: u32,
    focal_length: f64,
    stereo_baseline: f64,
    object_distance: f64,
) -> f64 {
    let normalized = (rank / 255.0).clamp(0.0, 1.0);
    let internal_disparity = 65_535.0 - normalized * rank_maximum as f64;
    focal_length * stereo_baseline / (internal_disparity * object_distance)
}

/// Focus-window rank percentiles (p20/p50/p80) of the rank plane around the
/// config focus point, mapped into the source-image coordinate space.
pub(crate) fn focus_window_ranks(
    data: &[u8],
    width: usize,
    height: usize,
    config: &ConfigSummary,
    source_dims: (u32, u32),
) -> Option<Vec<u8>> {
    let (sw, sh) = source_dims;
    if sw == 0 || sh == 0 {
        return None;
    }
    if config.focus_x < 0
        || config.focus_y < 0
        || config.focus_x >= sw as i32
        || config.focus_y >= sh as i32
    {
        return None;
    }
    let nx = (config.focus_x as f64 / sw as f64).clamp(0.0, 1.0);
    let ny = (config.focus_y as f64 / sh as f64).clamp(0.0, 1.0);
    let center_x = ((nx * width as f64).floor() as usize).min(width - 1);
    let center_y = ((ny * height as f64).floor() as usize).min(height - 1);
    let radius_x = (width / 20).max(4);
    let radius_y = (height / 20).max(4);
    let min_x = center_x.saturating_sub(radius_x);
    let max_x = (center_x + radius_x).min(width - 1);
    let min_y = center_y.saturating_sub(radius_y);
    let max_y = (center_y + radius_y).min(height - 1);
    let mut ranks = Vec::with_capacity((max_x - min_x + 1) * (max_y - min_y + 1));
    for y in min_y..=max_y {
        for x in min_x..=max_x {
            ranks.push(*data.get(HEADER_SIZE + y * width + x)?);
        }
    }
    if ranks.is_empty() {
        return None;
    }
    ranks.sort_unstable();
    Some(ranks)
}

pub(crate) fn percentile(sorted: &[u8], fraction: f64) -> f64 {
    let idx = ((sorted.len() - 1) as f64 * fraction).round() as usize;
    sorted[idx.min(sorted.len() - 1)] as f64
}

/// Full diagnostic + calibration report for one OPPO HEIC.
pub(crate) fn portrait_depth_report(data: &[u8]) -> Result<Value, String> {
    let names = xdremux_core::container::tail_entry_names(data);
    let mut report = Map::new();
    report.insert("schema".into(), json!("xdremux-portrait-depth-diagnostic-v1"));
    report.insert("available".into(), json!(false));
    report.insert("safeToTransform".into(), json!(false));
    report.insert("classification".into(), json!("missing-rear-depth"));
    report.insert("resources".into(), json!(names));

    let Some(compressed) = xdremux_core::container::extract_tail_entry(data, "rear.depth")
    else {
        return Ok(Value::Object(report));
    };
    let config_data = xdremux_core::container::extract_tail_entry(data, "rear.depth.config");

    let decoded = zstd::decode_all(compressed.as_slice())
        .map_err(|e| format!("rear.depth zstd decompress: {e}"))?;
    report.insert("decodedBytes".into(), json!(decoded.len()));
    report.insert(
        "resourceLengths".into(),
        json!({
            "rear.depth": compressed.len(),
            "rear.depth.config": config_data.as_ref().map(|c| c.len()),
        }),
    );

    // ---- header -----------------------------------------------------------
    if decoded.len() < HEADER_SIZE {
        return Err("decoded rear.depth shorter than 768-byte header".into());
    }
    let width = read_u32le(&decoded, 0).ok_or("header truncated")? as usize;
    let height = read_u32le(&decoded, 4).ok_or("header truncated")? as usize;
    if width == 0 || height == 0 || width > 16_384 || height > 16_384 {
        return Err("decoded rear.depth dimensions invalid".into());
    }
    let plane_size = width * height;
    if decoded.len() < HEADER_SIZE + plane_size {
        return Err("decoded rear.depth rank plane truncated".into());
    }

    let raw_scale = read_u32le(&decoded, 0x18).ok_or("header truncated")?;
    let embedded_scale = f32::from_bits(raw_scale) as f64;
    let focal_length = read_f32le(&decoded, 0x1c).ok_or("header truncated")? as f64;
    let stereo_baseline = read_f32le(&decoded, 0x20).ok_or("header truncated")? as f64;
    let disparity_minimum = read_u16le(&decoded, 0x2e).ok_or("header truncated")?;
    let disparity_maximum = read_u16le(&decoded, 0x30).ok_or("header truncated")?;
    let exponentiation = decoded[0x32];
    let hair_present = decoded[0x24] != 0;
    let portrait_present = decoded[0x25] != 0;
    let pet_present = decoded[0x26] != 0;

    let rank_stats = plane_stats(&decoded, HEADER_SIZE, plane_size)
        .ok_or("rank plane truncated")?;

    // ---- planes ------------------------------------------------------------
    let mut planes = Map::new();
    planes.insert("rank".into(), rank_stats.json(plane_size));
    let mut cursor = HEADER_SIZE + plane_size;
    for (present, name) in [
        (hair_present, "hair"),
        (portrait_present, "portrait"),
        (pet_present, "pet"),
    ] {
        if present {
            if let Some(stats) = plane_stats(&decoded, cursor, plane_size) {
                planes.insert(name.into(), stats.json(plane_size));
            }
            cursor += plane_size;
        }
    }

    // ---- classification + calibration decision -----------------------------
    let quantization_valid =
        disparity_maximum > disparity_minimum && (1..=2).contains(&exponentiation);
    let zero_quantization =
        disparity_minimum == 0 && disparity_maximum == 0 && exponentiation == 0;
    let classification = if zero_quantization && rank_stats.maximum > 0 {
        "rear-v4-zero-quantization"
    } else if quantization_valid {
        "rear-v4-validated-quantization"
    } else {
        "rear-depth-invalid-quantization"
    };

    let config = parse_config(config_data.as_deref());
    // The focus point lives in full-res source-image coordinates; the config
    // canvas is a small preview space, so read the real dims from src.image
    // (falling back to the canvas when src.image is absent).
    let src_dims = xdremux_core::container::extract_tail_entry(data, "src.image")
        .and_then(|b| image_dimensions(&b));
    let source_dims = src_dims
        .or_else(|| {
            config
                .as_ref()
                .map(|c| (c.canvas_width.max(0) as u32, c.canvas_height.max(0) as u32))
        })
        .unwrap_or((0, 0));

    let decision: ScaleDecision = if quantization_valid
        && embedded_scale.is_finite()
        && embedded_scale > 0.0
    {
        ScaleDecision::Passthrough(embedded_scale)
    } else if let (Some(cfg), true) = (&config, rank_stats.maximum > 0) {
        match cfg.object_distance {
            Some(dist) if dist > 0 && focal_length > 0.0 && stereo_baseline > 0.0 => {
                match focus_window_ranks(&decoded, width, height, cfg, source_dims) {
                    Some(ranks) => {
                        let p50 = percentile(&ranks, 0.50);
                        let scale = scale_for_rank(
                            p50,
                            rank_stats.maximum as u32,
                            focal_length,
                            stereo_baseline,
                            dist as f64,
                        );
                        if scale.is_finite() && scale > 0.0 {
                            ScaleDecision::CalibratedP50(scale)
                        } else {
                            ScaleDecision::Unavailable("p50 formula produced non-finite scale".into())
                        }
                    }
                    None => ScaleDecision::Unavailable("focus window out of range".into()),
                }
            }
            _ => ScaleDecision::Unavailable(
                "missing objectDistance/focalLength/stereoBaseline".into(),
            ),
        }
    } else {
        ScaleDecision::Unavailable("no config or empty rank plane".into())
    };

    // Diagnostic candidates (kept for parity with the Swift report).
    let mut calibration = Map::new();
    calibration.insert("classification".into(), json!(classification));
    calibration.insert("producerQuantizationValid".into(), json!(quantization_valid));
    calibration.insert("safeToTransform".into(), json!(quantization_valid));
    calibration.insert(
        "rankScaleInterpretations".into(),
        json!({"float32": embedded_scale, "uint32": raw_scale}),
    );
    calibration.insert("decision".into(), decision.json());
    if let (Some(cfg), Some(dist)) = (&config, config.as_ref().and_then(|c| c.object_distance)) {
        if rank_stats.maximum > 0 && focal_length > 0.0 && stereo_baseline > 0.0 {
            if let Some(ranks) = focus_window_ranks(&decoded, width, height, cfg, source_dims) {
                let mk = |f: f64| {
                    scale_for_rank(
                        percentile(&ranks, f),
                        rank_stats.maximum as u32,
                        focal_length,
                        stereo_baseline,
                        dist as f64,
                    )
                };
                calibration.insert(
                    "configDistanceScaleCandidates".into(),
                    json!({
                        "scaleForP20": mk(0.20),
                        "scaleForP50": mk(0.50),
                        "scaleForP80": mk(0.80),
                        "fullSpanForP50": mk(0.50) * 255.0,
                    }),
                );
            }
        }
    }

    report.insert("available".into(), json!(true));
    report.insert("sourceImage".into(), src_dims
        .map(|(w, h)| json!({"width": w, "height": h}))
        .unwrap_or(Value::Null));
    report.insert("safeToTransform".into(), json!(quantization_valid));
    report.insert("classification".into(), json!(classification));
    report.insert(
        "header".into(),
        json!({
            "width": width,
            "height": height,
            "rawScaleUInt32": raw_scale,
            "rawScaleFloat32": embedded_scale,
            "focalLengthPixels": focal_length,
            "stereoBaseline": stereo_baseline,
            "hairPlanePresent": hair_present,
            "portraitPlanePresent": portrait_present,
            "petPlanePresent": pet_present,
            "disparityMinimum": disparity_minimum,
            "disparityMaximum": disparity_maximum,
            "disparityExponentiation": exponentiation,
        }),
    );
    report.insert("planes".into(), Value::Object(planes));
    report.insert("config".into(), config.as_ref().map(|c| c.json()).unwrap_or(Value::Null));
    report.insert("calibration".into(), Value::Object(calibration));
    Ok(Value::Object(report))
}

/// CLI entry: `portrait-depth <input.heic> [output.json]`.
pub(crate) fn cmd_portrait_depth(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("portrait-depth: expected <input.heic> [output.json]".into());
    }
    let data = std::fs::read(&args[0]).map_err(|e| format!("read {}: {e}", args[0]))?;
    let report = portrait_depth_report(&data)?;
    let text = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
    if let Some(out) = args.get(1) {
        std::fs::write(out, &text).map_err(|e| format!("write {out}: {e}"))?;
        println!("portrait-depth: report written to {out}");
    } else {
        println!("{text}");
    }
    Ok(())
}
