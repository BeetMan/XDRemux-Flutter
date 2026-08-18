//! R5: native Portrait graph writer. Attaches a disparity auxiliary map +
//! portrait effects mattes + Apple sidecars to a converted base, so Photos
//! shows the depth (aperture) slider.
//!
//! Data flow (all formulas ported from the Swift pipeline and verified
//! numerically against the golden candidates):
//!   rear.depth (zstd) -> rank plane -> disparity floats
//!     value = near - pow(rank/255, exponentiation) * span,
//!     span = 255 * scale, near = span, far = 0
//!   scale = calibration decision (passthrough embedded, or p50 fallback for
//!     the zero-quantization producer variant)
//!   quantization: linear remap to 0..=255 with apdi FloatMin/Max = the
//!     actual data range (what ImageIO records for f16->u8 storage)
//!   REND = static template + 7 dynamic records from the recovered XHLRB
//!     scaler formulas (+0x01c5 gain-map headroom)
//!
//! Mattes v1: the OPPO portrait plane upscaled 2x stands in for the
//! person/skin/teeth/glasses mattes, the OPPO hair plane for the hair matte
//! (the Swift pipeline fused Vision semantic mattes with these planes as
//! priors; portable semantic mattes are the R4 segmenter's later job).

use crate::isobmff::{self, BoxHeader, IlocEntry, IpmaEntry, IrefEntry, ParsedMeta};

use crate::portrait_consts::{PORTRAIT_MAKER_NOTE, REND_TEMPLATE};
use crate::portrait_depth as pd;
use crate::portrait_graft::{self, find_top, idat_payload, top_level_boxes};

const AUXC_DISPARITY: &[u8] = b"urn:mpeg:hevc:2015:auxid:2";
const AUXC_PORTRAIT_MATTE: &[u8] = b"urn:com:apple:photo:2018:aux:portraiteffectsmatte";
const AUXC_SKIN: &[u8] = b"urn:com:apple:photo:2019:aux:semanticskinmatte";
const AUXC_HAIR: &[u8] = b"urn:com:apple:photo:2019:aux:semantichairmatte";
const AUXC_TEETH: &[u8] = b"urn:com:apple:photo:2019:aux:semanticteethmatte";
const AUXC_GLASSES: &[u8] = b"urn:com:apple:photo:2020:aux:semanticglassesmatte";

// Device-specific calibration block (this OPPO unit; see portrait_consts.rs).
const INTRINSIC_REF_W: u32 = 4208;
const INTRINSIC_REF_H: u32 = 3156;
const INTRINSIC: [f64; 9] = [
    2860.37890625, 0.0, 0.0,
    0.0, 2860.37890625, 0.0,
    2098.31103515625, 1591.0140380859375, 1.0,
];
const INV_LENS_DISTORTION: [f64; 8] = [
    0.0, 0.54487484693527222, -0.05080728605389595, 0.0016805990599095821,
    7.3705832619452849e-06, -1.7933325580088422e-06, 3.9592695344481392e-08,
    -2.6891447402199731e-10,
];
const LENS_DISTORTION: [f64; 8] = [
    0.0, -0.55521947145462036, 0.053949449211359024, -0.0018901334842666984,
    -4.6210166146920528e-06, 1.9594019704527454e-06, -4.5183909946899803e-08,
    3.1430857916348032e-10,
];
const DISTORTION_CENTER_X: f64 = 2105.552734375;
const DISTORTION_CENTER_Y: f64 = 1589.492919921875;
const PIXEL_SIZE_MM: f64 = 0.002546086957;

/// Structured parse of the rear.depth payload (depth header + full planes).
struct DepthData {
    width: usize,
    height: usize,
    ranks: Vec<u8>,
    hair: Option<Vec<u8>>,
    portrait: Option<Vec<u8>>,
    embedded_scale: f64,
    exponentiation: u8,
    disparity_minimum: u16,
    disparity_maximum: u16,
    near_object_detected: bool,
    focal_length: f64,
    stereo_baseline: f64,
    config: Option<pd::ConfigSummary>,
    decision: pd::ScaleDecision,
    src_dims: (u32, u32),
}

fn parse_depth(source: &[u8]) -> Result<DepthData, String> {
    let compressed = crate::container::extract_tail_entry(source, "rear.depth")
        .ok_or("no rear.depth tail entry (not an OPPO portrait photo?)")?;
    let config_bytes =
        crate::container::extract_tail_entry(source, "rear.depth.config");
    let decoded = zstd::decode_all(compressed.as_slice())
        .map_err(|e| format!("rear.depth zstd: {e}"))?;
    if decoded.len() < pd::HEADER_SIZE {
        return Err("rear.depth shorter than 768-byte header".into());
    }
    let width = pd::read_u32le(&decoded, 0).ok_or("header truncated")? as usize;
    let height = pd::read_u32le(&decoded, 4).ok_or("header truncated")? as usize;
    if width == 0 || height == 0 || width > 16_384 || height > 16_384 {
        return Err("rear.depth dimensions invalid".into());
    }
    let plane_size = width * height;
    if decoded.len() < pd::HEADER_SIZE + plane_size {
        return Err("rank plane truncated".into());
    }
    let ranks = decoded[pd::HEADER_SIZE..pd::HEADER_SIZE + plane_size].to_vec();
    let hair_present = decoded[0x24] != 0;
    let portrait_present = decoded[0x25] != 0;
    let pet_present = decoded[0x26] != 0;
    let mut cursor = pd::HEADER_SIZE + plane_size;
    let mut take = |present: bool| -> Option<Vec<u8>> {
        if !present {
            return None;
        }
        let plane = decoded.get(cursor..cursor + plane_size).map(|p| p.to_vec());
        cursor += plane_size;
        plane
    };
    let hair = take(hair_present);
    let portrait = take(portrait_present);
    let _pet = take(pet_present);

    let raw_scale = pd::read_u32le(&decoded, 0x18).ok_or("header truncated")?;
    let embedded_scale = f32::from_bits(raw_scale) as f64;
    let focal_length = pd::read_f32le(&decoded, 0x1c).ok_or("header truncated")? as f64;
    let stereo_baseline = pd::read_f32le(&decoded, 0x20).ok_or("header truncated")? as f64;
    let near_object_detected = decoded[0x27] != 0;
    let disparity_minimum = pd::read_u16le(&decoded, 0x2e).ok_or("header truncated")?;
    let disparity_maximum = pd::read_u16le(&decoded, 0x30).ok_or("header truncated")?;
    let exponentiation = decoded[0x32];

    let config = pd::parse_config(config_bytes.as_deref());
    let src_dims = crate::container::extract_tail_entry(source, "src.image")
        .and_then(|b| pd::image_dimensions(&b))
        .or_else(|| {
            config
                .as_ref()
                .map(|c| (c.canvas_width.max(0) as u32, c.canvas_height.max(0) as u32))
        })
        .unwrap_or((0, 0));

    // Calibration decision (same rule as the diagnostic): passthrough when
    // producer quantization is valid, otherwise the p50 physical fallback.
    let quantization_valid =
        disparity_maximum > disparity_minimum && (1..=2).contains(&exponentiation);
    let rank_max = ranks.iter().copied().max().unwrap_or(0);
    let decision = if quantization_valid && embedded_scale.is_finite() && embedded_scale > 0.0 {
        pd::ScaleDecision::Passthrough(embedded_scale)
    } else if rank_max > 0 {
        let cfg = config.as_ref();
        let dist = cfg.and_then(|c| c.object_distance).filter(|&d| d > 0);
        match (cfg, dist) {
            (Some(cfg), Some(dist)) if focal_length > 0.0 && stereo_baseline > 0.0 => {
                match pd::focus_window_ranks(&decoded, width, height, cfg, src_dims) {
                    Some(sorted) => {
                        let p50 = pd::percentile(&sorted, 0.50);
                        let scale = pd::scale_for_rank(
                            p50,
                            rank_max as u32,
                            focal_length,
                            stereo_baseline,
                            dist as f64,
                        );
                        if scale.is_finite() && scale > 0.0 {
                            pd::ScaleDecision::CalibratedP50(scale)
                        } else {
                            pd::ScaleDecision::Unavailable("p50 formula non-finite".into())
                        }
                    }
                    None => pd::ScaleDecision::Unavailable("focus window out of range".into()),
                }
            }
            _ => pd::ScaleDecision::Unavailable(
                "missing objectDistance/focalLength/stereoBaseline".into(),
            ),
        }
    } else {
        pd::ScaleDecision::Unavailable("empty rank plane".into())
    };

    Ok(DepthData {
        width,
        height,
        ranks,
        hair,
        portrait,
        embedded_scale,
        exponentiation,
        disparity_minimum,
        disparity_maximum,
        near_object_detected,
        focal_length,
        stereo_baseline,
        config,
        decision,
        src_dims,
    })
}

/// Per-pixel disparity: near - pow(rank/255, exp) * span, quantized linearly
/// to 0..=255; returns (u8 plane, float_min, float_max).
fn build_disparity(
    ranks: &[u8],
    exponentiation: u8,
    scale: f64,
) -> (Vec<u8>, f64, f64) {
    let span = 255.0 * scale;
    let near = span;
    let exp = exponentiation.max(1) as f64; // zero-quant variant is patched to 1
    let floats: Vec<f32> = ranks
        .iter()
        .map(|&r| {
            let normalized = (r as f32 / 255.0).powf(exp as f32);
            (near as f32 - normalized * span as f32).max(0.0)
        })
        .collect();
    let mut min = f32::INFINITY;
    let mut max = f32::NEG_INFINITY;
    for &v in &floats {
        min = min.min(v);
        max = max.max(v);
    }
    let range = (max - min).max(1e-9);
    let quantized: Vec<u8> = floats
        .iter()
        .map(|&v| ((v - min) / range * 255.0).round().clamp(0.0, 255.0) as u8)
        .collect();
    (quantized, min as f64, max as f64)
}

/// Recovered XHLRB CPU scaler (iOS 26.5 ControlLogicForXHLRB): dynamic REND
/// record values from scene activation + gain-map headroom.
fn xhlrb_dynamic_values(
    activation: f64,
    headroom_stops: f64,
    profile_is_1x: bool,
) -> Vec<(u16, f64)> {
    let activation = activation.clamp(0.0, 1.0);
    let headroom = headroom_stops.max(0.0);
    let headroom_factor = headroom.min(4.0) / 4.0;
    let max_intensity = if profile_is_1x { 0.25 } else { 0.10 };
    let max_weight = if profile_is_1x { 20.0 } else { 23.0 };
    let max_obscene = if profile_is_1x { 0.60 } else { 0.70 };
    let secondary = activation * headroom_factor;
    vec![
        (0x0190, (50.0 * activation).round()),
        (0x0191, 0.25 * activation),
        (0x0192, 12.0 * activation),
        (0x0193, max_intensity * activation),
        (0x01c2, 8.0 * secondary),
        (0x01c3, max_weight * secondary),
        (0x01c4, max_obscene * secondary),
        (0x01c5, headroom),
    ]
}

/// Patch the dynamic records in the REND template. Record types: 1 = f32
/// bits, 2 = i32, 3/4 = u32 (per the Swift builder).
fn patch_rend(dynamic: &[(u16, f64)]) -> Result<Vec<u8>, String> {
    let mut data = REND_TEMPLATE.to_vec();
    if data.len() < 16 || &data[0..4] != b"REND" {
        return Err("REND template header invalid".into());
    }
    let declared = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;
    if declared != data.len() {
        return Err("REND template length mismatch".into());
    }
    for &(id, value) in dynamic {
        let mut cursor = 16usize;
        let mut found = false;
        while cursor + 8 <= declared {
            let rid = u16::from_le_bytes([data[cursor], data[cursor + 1]]);
            let rtype = u16::from_le_bytes([data[cursor + 2], data[cursor + 3]]);
            if rid == id {
                let raw: u32 = match rtype {
                    1 => (value as f32).to_bits(),
                    2 => (value.round() as i32) as u32,
                    3 | 4 => value.round().max(0.0) as u32,
                    _ => return Err(format!("REND record 0x{id:04x} bad type {rtype}")),
                };
                data[cursor + 4..cursor + 8].copy_from_slice(&raw.to_le_bytes());
                found = true;
                break;
            }
            cursor += 8;
        }
        if !found {
            return Err(format!("REND template missing record 0x{id:04x}"));
        }
    }
    Ok(data)
}

fn fmt_f64(v: f64) -> String {
    format!("{v:.6}")
}

fn disparity_xmp(
    float_min: f64,
    float_max: f64,
    rend_b64: &str,
    simulated_aperture: f64,
) -> Vec<u8> {
    let intrinsic: String = INTRINSIC
        .iter()
        .map(|v| format!("               <rdf:li>{v}</rdf:li>\n"))
        .collect();
    let inv_distortion: String = INV_LENS_DISTORTION
        .iter()
        .map(|v| format!("               <rdf:li>{v}</rdf:li>\n"))
        .collect();
    let distortion: String = LENS_DISTORTION
        .iter()
        .map(|v| format!("               <rdf:li>{v}</rdf:li>\n"))
        .collect();
    format!(
        r##"<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:apdi="http://ns.apple.com/pixeldatainfo/1.0/"
            xmlns:depthData="http://ns.apple.com/depthData/1.0/"
            xmlns:depthBlurEffect="http://ns.apple.com/depthBlurEffect/1.0/"
            xmlns:portraitLightingEffect="http://ns.apple.com/portraitLightingEffect/1.0/">
         <apdi:IntMaxValue>255</apdi:IntMaxValue>
         <apdi:StoredFormat>1278226488</apdi:StoredFormat>
         <apdi:NativeFormat>1751411059</apdi:NativeFormat>
         <apdi:IntMinValue>0</apdi:IntMinValue>
         <apdi:FloatMaxValue>{float_max}</apdi:FloatMaxValue>
         <apdi:FloatMinValue>{float_min}</apdi:FloatMinValue>
         <apdi:AuxiliaryImageType>disparity</apdi:AuxiliaryImageType>
         <depthData:IntrinsicMatrixReferenceWidth>{INTRINSIC_REF_W}</depthData:IntrinsicMatrixReferenceWidth>
         <depthData:DepthDataVersion>65541</depthData:DepthDataVersion>
         <depthData:Quality>high</depthData:Quality>
         <depthData:IntrinsicMatrix>
            <rdf:Seq>
{intrinsic}            </rdf:Seq>
         </depthData:IntrinsicMatrix>
         <depthData:IntrinsicMatrixReferenceHeight>{INTRINSIC_REF_H}</depthData:IntrinsicMatrixReferenceHeight>
         <depthData:InverseLensDistortionCoefficients>
            <rdf:Seq>
{inv_distortion}            </rdf:Seq>
         </depthData:InverseLensDistortionCoefficients>
         <depthData:LensDistortionCenterOffsetX>{DISTORTION_CENTER_X:.12}</depthData:LensDistortionCenterOffsetX>
         <depthData:Accuracy>relative</depthData:Accuracy>
         <depthData:PixelSize>{PIXEL_SIZE_MM:.12}</depthData:PixelSize>
         <depthData:Filtered>True</depthData:Filtered>
         <depthData:ExtrinsicMatrix>
            <rdf:Seq>
               <rdf:li>1</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>1</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>1</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
               <rdf:li>0</rdf:li>
            </rdf:Seq>
         </depthData:ExtrinsicMatrix>
         <depthData:LensDistortionCenterOffsetY>{DISTORTION_CENTER_Y:.12}</depthData:LensDistortionCenterOffsetY>
         <depthBlurEffect:RenderingParameters>{rend_b64}</depthBlurEffect:RenderingParameters>
         <depthBlurEffect:SimulatedAperture>{simulated_aperture:.6}</depthBlurEffect:SimulatedAperture>
         <portraitLightingEffect:EffectStrength>0.500000</portraitLightingEffect:EffectStrength>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>"##
    )
    .into_bytes()
}

fn portrait_matte_xmp() -> Vec<u8> {
    r##"<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:apdi="http://ns.apple.com/pixeldatainfo/1.0/"
            xmlns:portraitEffectsMatte="http://ns.apple.com/portraitEffectsMatte/1.0/">
         <apdi:AuxiliaryImageSubType>portraiteffectsmatte</apdi:AuxiliaryImageSubType>
         <apdi:NativeFormat>1278226488</apdi:NativeFormat>
         <apdi:AuxiliaryImageType>depth</apdi:AuxiliaryImageType>
         <apdi:StoredFormat>1278226488</apdi:StoredFormat>
         <portraitEffectsMatte:PortraitEffectsMatteVersion>65537</portraitEffectsMatte:PortraitEffectsMatteVersion>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>"##
        .as_bytes()
        .to_vec()
}



/// Content rectangle from the OPPO watermark tail entry
/// (`watermark.master.params`: a float array containing CORNER quads
/// (x0, y0, x1, y1) with x1 = primary width - right pad and y1 = primary
/// height - bottom pad; the photo itself is the untouched sensor frame
/// centered by a symmetric border). Returns (x0, y0, w, h) or None when
/// the photo has no watermark frame (content = full primary).
fn watermark_content_rect(
    input: &[u8],
    primary_w: u32,
    primary_h: u32,
) -> Option<(u32, u32, u32, u32)> {
    let tail = {
        // extract the manifest region without the full LHDR machinery
        let json_start = input.windows(2).rposition(|w| w == b"[{")?;
        let json_end = input[json_start..].iter().position(|&b| b == b']')? + json_start;
        let entries =
            crate::portrait_scaffold::parse_manifest_entries(input, json_start, json_end)?;
        let e = entries.into_iter().find(|e| e.name == "watermark.master.params")?;
        let start = (json_start as i64 - e.offset as i64) as usize;
        input.get(start..start + e.length as usize)?
    };
    let n = tail.len() / 4;
    let mut f = vec![0f32; n];
    for (k, chunk) in tail.chunks_exact(4).enumerate() {
        f[k] = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
    }
    for k in 0..n.saturating_sub(4) {
        let quad = [f[k], f[k + 1], f[k + 2], f[k + 3]];
        if !quad.iter().all(|v| {
            v.is_finite()
                && v.abs() <= 1_000_000.0
                && *v > 1.0
                && (v - v.round()).abs() < 0.01
        }) {
            continue;
        }
        let (x, y, w, h) = (
            quad[0].round() as i64,
            quad[1].round() as i64,
            quad[2].round() as i64,
            quad[3].round() as i64,
        );
        if (x + w - primary_w as i64).abs() <= 3
            && (y + h - primary_h as i64).abs() <= 3
            && w > primary_w as i64 / 2
            && h > primary_h as i64 / 2
        {
            // corner quad (x0, y0, x1, y1) -> (x0, y0, w, h)
            let (cw, ch) = (w - x, h - y);
            if cw > 0 && ch > 0 {
                return Some((x as u32, y as u32, cw as u32, ch as u32));
            }
        }
    }
    None
}

/// Bilinear-resample a gray plane to arbitrary target dims.
fn resample_plane(plane: &[u8], w: usize, h: usize, tw: usize, th: usize) -> Vec<u8> {
    if w == tw && h == th {
        return plane.to_vec();
    }
    let mut out = vec![0u8; tw * th];
    for y in 0..th {
        let sy = (y as f64 + 0.5) * h as f64 / th as f64 - 0.5;
        let sy = sy.clamp(0.0, (h - 1) as f64);
        let y0 = sy.floor() as usize;
        let y1 = (y0 + 1).min(h - 1);
        let fy = sy - y0 as f64;
        for x in 0..tw {
            let sx = (x as f64 + 0.5) * w as f64 / tw as f64 - 0.5;
            let sx = sx.clamp(0.0, (w - 1) as f64);
            let x0 = sx.floor() as usize;
            let x1 = (x0 + 1).min(w - 1);
            let fx = sx - x0 as f64;
            let p00 = plane[y0 * w + x0] as f64;
            let p01 = plane[y0 * w + x1] as f64;
            let p10 = plane[y1 * w + x0] as f64;
            let p11 = plane[y1 * w + x1] as f64;
            let v = p00 * (1.0 - fx) * (1.0 - fy)
                + p01 * fx * (1.0 - fy)
                + p10 * (1.0 - fx) * fy
                + p11 * fx * fy;
            out[y * tw + x] = v.round().clamp(0.0, 255.0) as u8;
        }
    }
    out
}

/// Rotate a WxH plane 90 degrees clockwise (orientation-6 display mapping).
fn rotate_cw90(plane: &[u8], w: usize, h: usize) -> (Vec<u8>, usize, usize) {
    let (nw, nh) = (h, w);
    let mut out = vec![0u8; nw * nh];
    for y in 0..nh {
        for x in 0..nw {
            // CW: new(x, y) = old(y, h - 1 - x)
            out[y * nw + x] = plane[(h - 1 - x) * w + y];
        }
    }
    (out, nw, nh)
}

/// The base primary's ispe dims (frame the aux maps must align with).
fn base_primary_dims(meta: &ParsedMeta) -> Result<(u32, u32), String> {
    let entry = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == meta.primary_id)
        .ok_or("primary has no ipma entry")?;
    for (idx, _) in &entry.associations {
        if let Some(p) = meta.props.iter().find(|p| p.index == *idx) {
            if p.ptype == "ispe" && p.raw.len() >= 20 {
                let w = u32::from_be_bytes([p.raw[12], p.raw[13], p.raw[14], p.raw[15]]);
                let h = u32::from_be_bytes([p.raw[16], p.raw[17], p.raw[18], p.raw[19]]);
                if w > 512 && h > 512 {
                    return Ok((w, h));
                }
            }
        }
    }
    Err("primary ispe not found".into())
}

/// Encode a mono plane as an in-container HEVC item payload + hvcC.
fn encode_mono(pixels: &[u8], w: u32, h: u32) -> Result<(Vec<u8>, Vec<u8>), String> {
    let refs: Vec<&[u8]> = vec![pixels];
    let stream = crate::hevc::x265_encode_tiles(&refs, w, h, 1, false)
        .map_err(|e| format!("mono encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("mono encode produced no stream")?;
    let hvcc = crate::hevc::extract_hvcc_config_with_chroma(&stream, 0)
        .ok_or("mono hvcC extraction failed")?;
    let idr = crate::hevc::drop_parameter_nals(&stream);
    Ok((
        crate::hevc::hevc_byte_stream_to_length_prefixed(&idr),
        hvcc,
    ))
}

/// Upscale a gray plane 2x with bilinear interpolation.
fn upscale2x(plane: &[u8], w: usize, h: usize) -> (Vec<u8>, u32, u32) {
    let (dw, dh) = (w * 2, h * 2);
    let mut out = vec![0u8; dw * dh];
    for y in 0..dh {
        let sy = (y as f64 / 2.0).min((h - 1) as f64);
        let y0 = sy.floor() as usize;
        let y1 = (y0 + 1).min(h - 1);
        let fy = sy - y0 as f64;
        for x in 0..dw {
            let sx = (x as f64 / 2.0).min((w - 1) as f64);
            let x0 = sx.floor() as usize;
            let x1 = (x0 + 1).min(w - 1);
            let fx = sx - x0 as f64;
            let p00 = plane[y0 * w + x0] as f64;
            let p01 = plane[y0 * w + x1] as f64;
            let p10 = plane[y1 * w + x0] as f64;
            let p11 = plane[y1 * w + x1] as f64;
            let v = p00 * (1.0 - fx) * (1.0 - fy)
                + p01 * fx * (1.0 - fy)
                + p10 * (1.0 - fx) * fy
                + p11 * fx * fy;
            out[y * dw + x] = v.round().clamp(0.0, 255.0) as u8;
        }
    }
    (out, dw as u32, dh as u32)
}

pub fn run_portrait(input: &[u8], base: &[u8]) -> Result<Vec<u8>, String> {
    let depth = parse_depth(input)?;
    let scale = depth
        .decision
        .scale()
        .ok_or_else(|| format!("no usable disparity scale: {:?}", depth.decision))?;
    eprintln!(
        "portrait: depth {}x{}, scale={:.7} ({:?})",
        depth.width, depth.height, scale, depth.decision
    );

    // ---- disparity pixels + apdi range ------------------------------------
    let (disparity_u8, float_min, float_max) =
        build_disparity(&depth.ranks, depth.exponentiation, scale);

    // ---- REND dynamic records ---------------------------------------------
    // Focus: median rank of the config focus window (matches the p50
    // calibration choice).
    let span = 255.0 * scale;
    let focus_rank = depth
        .config
        .as_ref()
        .and_then(|cfg| {
            let mut plane = vec![0u8; pd::HEADER_SIZE];
            plane.extend_from_slice(&depth.ranks);
            pd::focus_window_ranks(&plane, depth.width, depth.height, cfg, depth.src_dims)
        })
        .map(|sorted| pd::percentile(&sorted, 0.50))
        .unwrap_or(128.0);
    let exp = depth.exponentiation.max(1) as f64;
    let normalized_focus = (focus_rank / 255.0).clamp(0.0, 1.0).powf(exp);
    let focus_disparity = span * (1.0 - normalized_focus);
    let focus_normalized = if span > 0.0 {
        (focus_disparity / span).clamp(0.0, 1.0)
    } else {
        0.0
    };
    // Gain-map headroom from the LHDR/UHDR metadata floats (index 17 holds
    // the alternate headroom as a linear ratio; REND wants stops).
    let headroom = crate::container::extract_lhdr_from_bytes(input)
        .ok()
        .and_then(|l| l.meta_floats.get(17).copied())
        .map(|v| (v.max(1.0) as f64).log2().max(0.0))
        .unwrap_or(0.0);
    let headroom_normalized = (headroom / 4.0).min(1.0);
    let lux_normalized = 0.5; // Swift default when aecLuxIndex is absent
    let near_boost = if depth.near_object_detected { 1.15 } else { 1.0 };
    let fitted_primary_gain = ((0.02
        + 0.17 * focus_normalized
        + 0.04 * headroom_normalized
        + 0.02 * lux_normalized)
        * near_boost)
        .clamp(0.005, 0.25);
    let activation = fitted_primary_gain / 0.25;
    let dynamic = xhlrb_dynamic_values(activation, headroom, true);
    let rend = patch_rend(&dynamic)?;
    let rend_b64 = base64_encode(&rend);

    let aperture = depth
        .config
        .as_ref()
        .and_then(|c| c.current_f_number)
        .unwrap_or(9.0) as f64;
    let disparity_xmp = disparity_xmp(
        f64::from(float_min).into(),
        float_max,
        &rend_b64,
        aperture,
    );

    // ---- mattes -------------------------------------------------------------
    let person_plane = depth
        .portrait
        .as_ref()
        .ok_or("rear.depth has no portrait (person) plane")?;
    let (person_up, mu_w, mu_h) = upscale2x(person_plane, depth.width, depth.height);
    let hair_up = depth
        .hair
        .as_ref()
        .map(|h| upscale2x(h, depth.width, depth.height).0);

    // Frame alignment: the OPPO primary is baked portrait while the depth
    // planes live in the landscape sensor frame (the golden pipeline swapped
    // the base to the landscape src.image + orientation 6; we keep the OPPO
    // primary and rotate the aux data - orientation-6 semantics). Residual
    // aspect stretch (sensor 4:3 vs the hi-res primary crop) is a documented
    // v1 approximation.
    let m0 = isobmff::parse_source_meta(base).map_err(|e| format!("meta parse: {e}"))?;
    let (pw_frame, ph_frame) = base_primary_dims(&m0)?;
    let rotate = ph_frame > pw_frame && depth.width > depth.height;
    eprintln!(
        "portrait: primary frame {pw_frame}x{ph_frame}, depth {}x{}, rotate90={rotate}",
        depth.width, depth.height
    );
    let content_rect = watermark_content_rect(input, pw_frame, ph_frame);
    eprintln!(
        "portrait: watermark content rect: {content_rect:?}"
    );
    let mut focus_x_norm: Option<f64> = None;
    let mut focus_y_norm: Option<f64> = None;
    if rotate {
        let cfg2 = depth.config.as_ref();
        let nx = cfg2.map(|c| c.focus_x as f64).unwrap_or(0.5)
            / depth.src_dims.0.max(1) as f64;
        let ny = cfg2.map(|c| c.focus_y as f64).unwrap_or(0.5)
            / depth.src_dims.1.max(1) as f64;
        // landscape (nx, ny) -> portrait content (1 - ny, nx), then into
        // the padded primary frame.
        match content_rect {
            Some((cx, cy, cw2, ch2)) => {
                // normalized sensor point -> rotated point, then into the
                // cover-cropped content window (center crop), then offset by
                // the frame padding.
                let (rx, ry) = (1.0 - ny, nx); // rotated normalized
                let s_aspect = (depth.height as f64 / depth.width as f64)
                    / (cw2 as f64 / ch2 as f64); // rotated-frame / content aspect
                let content_x;
                let content_y;
                if s_aspect > 1.0 {
                    // content is narrower: horizontal center crop
                    let used = 1.0 / s_aspect;
                    content_x = (rx - 0.5) * used + 0.5;
                    content_y = ry;
                } else {
                    let used = s_aspect;
                    content_x = rx;
                    content_y = (ry - 0.5) * used + 0.5;
                }
                focus_x_norm =
                    Some((cx as f64 + content_x.clamp(0.0, 1.0) * cw2 as f64) / pw_frame as f64);
                focus_y_norm =
                    Some((cy as f64 + content_y.clamp(0.0, 1.0) * ch2 as f64) / ph_frame as f64);
            }
            None => {
                focus_x_norm = Some(1.0 - ny);
                focus_y_norm = Some(nx);
            }
        }
    }

    // Aux geometry: Photos linearly stretches aux maps to the primary size,
    // so the aux canvas uses the primary aspect. Watermark photos carry a
    // padded frame (content rect from the watermark tail entry): content is
    // resampled into the content rect and the frame border gets the far
    // plane (disparity 0 = fully blurred, mattes 0).
    let canvas_dims = |scale: f64| -> (usize, usize) {
        let w = ((pw_frame as f64 * scale).round() as usize).max(64) & !1;
        let h = ((ph_frame as f64 * scale).round() as usize).max(64) & !1;
        (w, h)
    };
    // Compose: rotate -> resample into the content-rect proportions ->
    // place onto the canvas (pad-aware). Without a watermark frame the
    // content rect covers the whole canvas (plain resample).
    // Cover mapping: the content rect (e.g. a full-screen-ratio crop inside
    // the watermark frame) relates to the sensor frame by uniform scale +
    // center crop, NOT a stretch. Resample the center-cropped sensor window
    // to the content rect, then pad the canvas with the far plane.
    let cover_crop = |rw: usize, rh: usize, tw: usize, th: usize| -> (usize, usize, usize, usize) {
        let scale = (tw as f64 / rw as f64).max(th as f64 / rh as f64);
        let sw = ((tw as f64 / scale).round() as usize).clamp(1, rw);
        let sh = ((th as f64 / scale).round() as usize).clamp(1, rh);
        let sx = (rw - sw) / 2;
        let sy = (rh - sh) / 2;
        (sx, sy, sw, sh)
    };
    let place = |rotated: &[u8], rw: usize, rh: usize, target_scale: f64| -> (Vec<u8>, u32, u32) {
        let (cw, chh) = canvas_dims(target_scale);
        let (cx, cy, ccw, cch) = match content_rect {
            Some((x, y, w, h)) => (
                ((x as f64 * target_scale).round() as usize).min(cw),
                ((y as f64 * target_scale).round() as usize).min(chh),
                ((w as f64 * target_scale).round() as usize).max(64),
                ((h as f64 * target_scale).round() as usize).max(64),
            ),
            None => (0, 0, cw, chh),
        };
        let ccw = ccw.min(cw.saturating_sub(cx));
        let cch = cch.min(chh.saturating_sub(cy));
        // center-crop the source to the content aspect, then resample
        let (sx, sy, sw, sh) = cover_crop(rw, rh, ccw, cch);
        let mut cropped = vec![0u8; sw * sh];
        for y in 0..sh {
            let src = (sy + y) * rw + sx;
            cropped[y * sw..(y + 1) * sw].copy_from_slice(&rotated[src..src + sw]);
        }
        let content = resample_plane(&cropped, sw, sh, ccw, cch);
        let mut canvas = vec![0u8; cw * chh];
        for y in 0..cch {
            let dst = (cy + y) * cw + cx;
            canvas[dst..dst + ccw].copy_from_slice(&content[y * ccw..(y + 1) * ccw]);
        }
        (canvas, cw as u32, chh as u32)
    };
    let (disp_final, disp_fw, disp_fh) = if rotate {
        let (r, w2, h2) = rotate_cw90(&disparity_u8, depth.width, depth.height);
        place(&r, w2, h2, 0.5) // disparity at half the primary frame
    } else {
        (disparity_u8.clone(), depth.width as u32, depth.height as u32)
    };
    let (matte_final, matte_fw, matte_fh) = if rotate {
        let (r, w2, h2) = rotate_cw90(&person_up, mu_w as usize, mu_h as usize);
        place(&r, w2, h2, 0.5)
    } else {
        (person_up.clone(), mu_w, mu_h)
    };
    let hair_final = match (&hair_up, rotate) {
        (Some(h), true) => {
            let (r, w2, h2) = rotate_cw90(h, mu_w as usize, mu_h as usize);
            let (m, _, _) = place(&r, w2, h2, 0.5);
            Some(m)
        }
        (Some(h), false) => Some(h.clone()),
        (None, _) => None,
    };
    let (disparity_stream, disparity_hvcc) = encode_mono(&disp_final, disp_fw, disp_fh)?;
    let (person_stream, person_hvcc) = encode_mono(&matte_final, matte_fw, matte_fh)?;
    let (hair_stream, hair_hvcc) = match &hair_final {
        Some(h) => encode_mono(h, matte_fw, matte_fh)?,
        None => (person_stream.clone(), person_hvcc.clone()),
    };

    // ---- graph assembly -----------------------------------------------------
    attach_portrait_graph(
        base,
        disparity_stream,
        disparity_hvcc,
        disparity_xmp,
        disp_fw,
        disp_fh,
        person_stream,
        person_hvcc,
        hair_stream,
        hair_hvcc,
        matte_fw,
        matte_fh,
        &depth,
        focus_x_norm,
        focus_y_norm,
        (pw_frame, ph_frame),
    )
}

fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn attach_portrait_graph(
    base: &[u8],
    disparity_stream: Vec<u8>,
    disparity_hvcc: Vec<u8>,
    disparity_xmp: Vec<u8>,
    disp_w: u32,
    disp_h: u32,
    person_stream: Vec<u8>,
    person_hvcc: Vec<u8>,
    hair_stream: Vec<u8>,
    hair_hvcc: Vec<u8>,
    matte_w: u32,
    matte_h: u32,
    depth: &DepthData,
    focus_x_norm: Option<f64>,
    focus_y_norm: Option<f64>,
    primary_frame: (u32, u32),
) -> Result<Vec<u8>, String> {
    let top = top_level_boxes(base)?;
    let meta_hdr = find_top(&top, b"meta").ok_or("no meta box")?;
    let mdat_hdr = find_top(&top, b"mdat").ok_or("no mdat box")?;
    let meta = isobmff::parse_source_meta(base).map_err(|e| format!("meta parse: {e}"))?;

    let primary = meta.primary_id;
    // tmap = the ISO gain-map grid (non-primary grid item).
    let tmap = meta
        .items
        .iter()
        .find(|i| i.itype == "grid" && i.item_id != primary)
        .map(|i| i.item_id)
        .ok_or("no gain-map grid item")?;

    let mut next_id = meta
        .items
        .iter()
        .map(|i| i.item_id)
        .max()
        .unwrap_or(0)
        .max(crate::portrait_scaffold::max_group_id_pub(base, &meta_hdr).unwrap_or(0))
        + 1;
    let mut alloc = move || {
        let id = next_id;
        next_id += 1;
        id
    };
    let disparity_id = alloc();
    let disparity_xmp_id = alloc();
    let portrait_matte_id = alloc();
    let portrait_matte_xmp_id = alloc();
    let skin_id = alloc();
    let skin_xmp_id = alloc();
    let hair_id = alloc();
    let hair_xmp_id = alloc();
    let teeth_id = alloc();
    let teeth_xmp_id = alloc();
    let glasses_id = alloc();
    let glasses_xmp_id = alloc();

    // ---- properties ---------------------------------------------------------
    let mut new_props: Vec<Vec<u8>> = Vec::new();
    let mut add_prop = |raw: Vec<u8>| -> u32 {
        new_props.push(raw);
        (meta.props.len() + new_props.len()) as u32
    };
    let pixi_mono_idx = meta
        .props
        .iter()
        .find(|p| p.raw == isobmff::PIXI_MONO8_BOX)
        .map(|p| p.index)
        .unwrap_or_else(|| add_prop(isobmff::PIXI_MONO8_BOX.to_vec()));
    let irot_idx = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == primary)
        .and_then(|e| {
            e.associations.iter().find(|(idx, _)| {
                meta.props
                    .iter()
                    .find(|p| p.index == *idx)
                    .map(|p| p.ptype == "irot")
                    .unwrap_or(false)
            })
        })
        .map(|(idx, _)| *idx);
    let ispe_disp_idx = add_prop(isobmff::make_ispe_box(disp_w, disp_h));
    let ispe_matte_idx = add_prop(isobmff::make_ispe_box(matte_w, matte_h));
    let auxc_disp_idx = add_prop(make_auxc(AUXC_DISPARITY));
    let auxc_portrait_idx = add_prop(make_auxc(AUXC_PORTRAIT_MATTE));
    let auxc_skin_idx = add_prop(make_auxc(AUXC_SKIN));
    let auxc_hair_idx = add_prop(make_auxc(AUXC_HAIR));
    let auxc_teeth_idx = add_prop(make_auxc(AUXC_TEETH));
    let auxc_glasses_idx = add_prop(make_auxc(AUXC_GLASSES));
    let hvcc_disp_idx = add_prop(isobmff::make_box(b"hvcC", &disparity_hvcc));
    let hvcc_person_idx = add_prop(isobmff::make_box(b"hvcC", &person_hvcc));
    let hvcc_hair_idx = add_prop(isobmff::make_box(b"hvcC", &hair_hvcc));

    // ---- infes ---------------------------------------------------------------
    // iinf must carry ALL entries. Order matters to ImageIO's XMP merge:
    // the golden (ImageIO-written) places the main XMP mime item immediately
    // after the Exif item, so insert ours there instead of appending at the
    // end.
    // iinf carries ALL entries (originals first, then the new ones). The
    // Focus XMP is NOT a separate mime item: the base converter already
    // emits an hdrgm-xmp mime item with cdsc->primary, and ImageIO merges
    // only that one as the primary XMP. We rewrite its payload in place.
    let mut new_infes: Vec<Vec<u8>> = meta
        .items
        .iter()
        .map(|i| i.raw_infe.clone())
        .collect();
    for id in [disparity_id, portrait_matte_id, skin_id, hair_id, teeth_id, glasses_id] {
        new_infes.push(isobmff::make_infe_box(id, "hvc1", 1)); // hidden
    }
    for id in [
        disparity_xmp_id,
        portrait_matte_xmp_id,
        skin_xmp_id,
        hair_xmp_id,
        teeth_xmp_id,
        glasses_xmp_id,
    ] {
        new_infes.push(make_xmp_infe(id));
    }

    // ---- ipma (new entries only; build_output chains them onto the source) ---
    let mut extra_ipma: Vec<IpmaEntry> = Vec::new();
    let mut image_assocs = |ispe_idx: u32, auxc_idx: u32, hvcc_idx: u32| {
        let mut a = vec![
            (ispe_idx, false),
            (pixi_mono_idx, false),
            (auxc_idx, true),
            (hvcc_idx, true),
        ];
        if let Some(ir) = irot_idx {
            a.push((ir, true));
        }
        a
    };
    extra_ipma.push(IpmaEntry {
        item_id: disparity_id,
        associations: image_assocs(ispe_disp_idx, auxc_disp_idx, hvcc_disp_idx),
    });
    extra_ipma.push(IpmaEntry {
        item_id: portrait_matte_id,
        associations: image_assocs(ispe_matte_idx, auxc_portrait_idx, hvcc_person_idx),
    });
    extra_ipma.push(IpmaEntry {
        item_id: skin_id,
        associations: image_assocs(ispe_matte_idx, auxc_skin_idx, hvcc_person_idx),
    });
    extra_ipma.push(IpmaEntry {
        item_id: hair_id,
        associations: image_assocs(ispe_matte_idx, auxc_hair_idx, hvcc_hair_idx),
    });
    extra_ipma.push(IpmaEntry {
        item_id: teeth_id,
        associations: image_assocs(ispe_matte_idx, auxc_teeth_idx, hvcc_person_idx),
    });
    extra_ipma.push(IpmaEntry {
        item_id: glasses_id,
        associations: image_assocs(ispe_matte_idx, auxc_glasses_idx, hvcc_person_idx),
    });

    // ---- refs ------------------------------------------------------------------
    let mut new_refs: Vec<IrefEntry> = meta.refs.clone();
    for image_id in [disparity_id, portrait_matte_id, skin_id, hair_id, teeth_id, glasses_id] {
        new_refs.push(IrefEntry {
            rtype: "auxl".into(),
            from: image_id,
            to: vec![primary, tmap],
        });
    }
    new_refs.push(IrefEntry {
        rtype: "cdsc".into(),
        from: disparity_xmp_id,
        to: vec![disparity_id],
    });
    for (xmp_id, image_id) in [
        (portrait_matte_xmp_id, portrait_matte_id),
        (skin_xmp_id, skin_id),
        (hair_xmp_id, hair_id),
        (teeth_xmp_id, teeth_id),
        (glasses_xmp_id, glasses_id),
    ] {
        new_refs.push(IrefEntry {
            rtype: "cdsc".into(),
            from: xmp_id,
            to: vec![image_id],
        });
    }

    // ---- payloads ----------------------------------------------------------------
    let std_idat = idat_payload(base, &meta_hdr).unwrap_or_default();
    let new_idat = std_idat; // XMP payloads go to mdat (golden layout), idat stays untouched
    let semantic_xmp = crate::portrait_scaffold::matte_xmp_pub();
    let datetime = extract_exif_datetime(base, &meta).unwrap_or_else(|| "1970:01:01 00:00:00".into());
    let cfg = depth.config.as_ref();
    // Merge the Focus region into the base converter's hdrgm-xmp mime item
    // (the only mime XMP ImageIO merges for the primary).
    let hdrgm_item = find_primary_xmp_item(&meta, primary)?;
    let hdrgm_payload = read_item_payload(base, &meta, hdrgm_item)
        .ok_or("hdrgm-xmp item payload unreadable")?;

    // Portrait marker metadata: CustomRendered = 9 + the Apple portrait
    // MakerNote (Photos' portrait detection reads these; the golden pipeline
    // sets both via ImageIO properties on the blank carrier).
    let exif_item = meta
        .items
        .iter()
        .find(|i| i.itype == "Exif")
        .ok_or("no Exif item in base")?
        .item_id;
    let exif_payload = read_item_payload(base, &meta, exif_item)
        .ok_or("Exif payload unreadable")?;
    let patched_exif = patch_exif_portrait_markers(&exif_payload, &PORTRAIT_MAKER_NOTE.to_vec())?;
    let (fx, fy, ap_w, ap_h) = match (focus_x_norm, focus_y_norm) {
        (Some(nx), Some(ny)) => (nx, ny, primary_frame.0, primary_frame.1),
        _ => (
            cfg.map(|c| c.focus_x as f64).unwrap_or(depth.src_dims.0 as f64 / 2.0),
            cfg.map(|c| c.focus_y as f64).unwrap_or(depth.src_dims.1 as f64 / 2.0),
            depth.src_dims.0,
            depth.src_dims.1,
        ),
    };
    let merged_main_xmp = merge_focus_into_xmp(
        &hdrgm_payload,
        fx,
        fy,
        ap_w,
        ap_h,
        &datetime,
    )?;

    let std_mdat_payload = base[mdat_hdr.data_start..mdat_hdr.data_end].to_vec();
    let mut appended_mdat = Vec::new();
    let mut mdat_items: Vec<(u32, u64, u64)> = Vec::new();
    let mut push_mdat = |id: u32, payload: &[u8], buf: &mut Vec<u8>| {
        let off = buf.len() as u64;
        buf.extend_from_slice(payload);
        mdat_items.push((id, off, payload.len() as u64));
    };
    // Golden-exact: XMP mime payloads live in MDAT referenced cm=0 absolute.
    // (ImageIO's reader merges mime XMP only in this layout: idat-relative
    // cm=1 is ignored, and cm=0 pointing back into meta is ignored too.)
    push_mdat(disparity_xmp_id, &disparity_xmp, &mut appended_mdat);
    // The rewritten hdrgm-xmp payload goes to mdat too; its iloc extent is
    // repointed below (cm=0 absolute, like the golden layout).
    let hdrgm_rel = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&merged_main_xmp);
    let hdrgm_len = merged_main_xmp.len() as u64;
    let exif_rel = appended_mdat.len() as u64;
    appended_mdat.extend_from_slice(&patched_exif);
    let exif_len = patched_exif.len() as u64;
    push_mdat(portrait_matte_xmp_id, &portrait_matte_xmp(), &mut appended_mdat);
    for xmp_id in [skin_xmp_id, hair_xmp_id, teeth_xmp_id, glasses_xmp_id] {
        push_mdat(xmp_id, &semantic_xmp, &mut appended_mdat);
    }
    push_mdat(disparity_id, &disparity_stream, &mut appended_mdat);
    push_mdat(portrait_matte_id, &person_stream, &mut appended_mdat);
    push_mdat(skin_id, &person_stream, &mut appended_mdat);
    push_mdat(hair_id, &hair_stream, &mut appended_mdat);
    push_mdat(teeth_id, &person_stream, &mut appended_mdat);
    push_mdat(glasses_id, &person_stream, &mut appended_mdat);

    // ---- two-pass assembly (same pattern as scaffold) -----------------------
    let new_ipco: Vec<u8> = meta
        .props
        .iter()
        .flat_map(|p| p.raw.clone())
        .chain(new_props.iter().flatten().copied())
        .collect();

    let build = |iloc_entries: &[IlocEntry]| -> Vec<u8> {
        portrait_graft::build_output_pub(
            None,
            None,
            base,
            &top,
            &meta_hdr,
            &mdat_hdr,
            &meta,
            &new_infes,
            iloc_entries,
            &new_ipco,
            &extra_ipma,
            &new_refs,
            &new_idat,
            &std_mdat_payload,
            &appended_mdat,
        )
    };

    let mut placeholder_iloc = meta.iloc_entries.clone();
    for (id, _, _) in mdat_items.iter() {
        placeholder_iloc.push(IlocEntry {
            item_id: *id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, 0)],
        });
    }
    let preliminary = build(&placeholder_iloc);
    let prelim_top = top_level_boxes(&preliminary)?;
    let prelim_meta_hdr = find_top(&prelim_top, b"meta").ok_or("prelim: no meta")?;
    let prelim_meta_size = prelim_meta_hdr.size;
    let mut prefix = 0usize;
    for hdr in &top {
        if hdr.box_start == mdat_hdr.box_start {
            break;
        }
        prefix += if hdr.box_start == meta_hdr.box_start {
            prelim_meta_size
        } else {
            hdr.size
        };
    }
    let new_mdat_data_start = prefix + 8;
    let file_delta = new_mdat_data_start as i64 - mdat_hdr.data_start as i64;

    let mut final_iloc: Vec<IlocEntry> = meta
        .iloc_entries
        .iter()
        .map(|entry| {
            if entry.item_id == exif_item {
                // Repoint Exif to the portrait-marked rewrite (mdat-appended).
                return IlocEntry {
                    item_id: entry.item_id,
                    construction_method: 0,
                    data_reference_index: 0,
                    extents: vec![(
                        (new_mdat_data_start + std_mdat_payload.len()) as u64 + exif_rel,
                        exif_len,
                    )],
                };
            }
            if entry.item_id == hdrgm_item {
                // Repoint to the merged payload appended to mdat.
                return IlocEntry {
                    item_id: entry.item_id,
                    construction_method: 0,
                    data_reference_index: 0,
                    extents: vec![(
                        (new_mdat_data_start + std_mdat_payload.len()) as u64 + hdrgm_rel,
                        hdrgm_len,
                    )],
                };
            }
            let extents = entry
                .extents
                .iter()
                .map(|&(offset, length)| {
                    let off = offset as i64;
                    let shift = entry.construction_method == 0
                        && off >= mdat_hdr.data_start as i64
                        && off < mdat_hdr.data_end as i64;
                    let new_off = if shift { off + file_delta } else { off };
                    (new_off as u64, length)
                })
                .collect();
            IlocEntry {
                extents,
                ..entry.clone()
            }
        })
        .collect();
    // New mdat items: absolute file offsets after the original mdat payload.
    for (id, rel, len) in &mdat_items {
        final_iloc.push(IlocEntry {
            item_id: *id,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(
                (new_mdat_data_start + std_mdat_payload.len()) as u64 + rel,
                *len,
            )],
        });
    }
    Ok(build(&final_iloc))
}


/// Find the base converter's primary-XMP mime item (the hdrgm-xmp mime with
/// cdsc -> [primary, tmap]); ImageIO merges only this one as the primary's
/// XMP metadata.
fn find_primary_xmp_item(meta: &ParsedMeta, primary: u32) -> Result<u32, String> {
    for r in &meta.refs {
        if r.rtype == "cdsc" && r.to.contains(&primary) {
            let is_mime = meta
                .items
                .iter()
                .find(|i| i.item_id == r.from)
                .map(|i| i.itype.contains("mime"))
                .unwrap_or(false);
            if is_mime {
                return Ok(r.from);
            }
        }
    }
    Err("no primary mime XMP item (hdrgm-xmp) in base".into())
}

/// Read an item payload handling both cm=0 (absolute) and cm=1 (idat).
fn read_item_payload(data: &[u8], meta: &ParsedMeta, item_id: u32) -> Option<Vec<u8>> {
    let entry = meta
        .iloc_entries
        .iter()
        .find(|e| e.item_id == item_id)?;
    let &(off, len) = entry.extents.first()?;
    let abs = if entry.construction_method == 1 {
        // idat-relative: locate idat via a fresh top-level scan
        let top = top_level_boxes(data).ok()?;
        let meta_hdr = find_top(&top, b"meta")?;
        let idat = find_meta_child(data, &meta_hdr, b"idat")?;
        idat.data_start as u64 + off
    } else {
        off
    };
    data.get(abs as usize..(abs + len) as usize).map(|p| p.to_vec())
}

/// Inject the MWG Focus region (+ dates/creator) into an existing XMP packet
/// before </rdf:RDF>, mirroring the golden's main-XMP content.
fn merge_focus_into_xmp(
    xmp: &[u8],
    focus_x: f64,
    focus_y: f64,
    src_w: u32,
    src_h: u32,
    datetime: &str,
) -> Result<Vec<u8>, String> {
    let text = String::from_utf8(xmp.to_vec()).map_err(|_| "hdrgm XMP not UTF-8")?;
    let nx = focus_x / src_w.max(1) as f64;
    let ny = focus_y / src_h.max(1) as f64;
    let mut chars: Vec<char> = datetime.chars().collect();
    for i in [4usize, 7] {
        if chars.get(i) == Some(&':') {
            chars[i] = '-';
        }
    }
    let date: String = chars.into_iter().collect();
    let block = format!(
        r##"      <rdf:Description rdf:about=""
            xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
            xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
            xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#">
         <mwg-rs:Regions rdf:parseType="Resource">
            <mwg-rs:RegionList>
               <rdf:Seq>
                  <rdf:li rdf:parseType="Resource">
                     <mwg-rs:Area rdf:parseType="Resource">
                        <stArea:y>{ny}</stArea:y>
                        <stArea:w>0.12</stArea:w>
                        <stArea:x>{nx}</stArea:x>
                        <stArea:h>0.12</stArea:h>
                        <stArea:unit>normalized</stArea:unit>
                     </mwg-rs:Area>
                     <mwg-rs:Type>Focus</mwg-rs:Type>
                     <mwg-rs:Extensions rdf:parseType="Resource"/>
                  </rdf:li>
               </rdf:Seq>
            </mwg-rs:RegionList>
            <mwg-rs:AppliedToDimensions rdf:parseType="Resource">
               <stDim:h>{src_h}</stDim:h>
               <stDim:w>{src_w}</stDim:w>
               <stDim:unit>pixel</stDim:unit>
            </mwg-rs:AppliedToDimensions>
         </mwg-rs:Regions>
         <xmp:CreatorTool xmlns:xmp="http://ns.adobe.com/xap/1.0/">XDRemux</xmp:CreatorTool>
         <photoshop:DateCreated xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">{date}</photoshop:DateCreated>
      </rdf:Description>
"##
    );
    let Some(pos) = text.rfind("</rdf:RDF>") else {
        return Err("hdrgm XMP has no </rdf:RDF>".into());
    };
    let mut out = text[..pos].to_string();
    out.push_str(&block);
    out.push_str(&text[pos..]);
    Ok(out.into_bytes())
}


/// Set CustomRendered (0xA404) = 9 (portrait-rendered marker, golden layout:
/// type 5 / count 1) and inject the Apple portrait MakerNote into the Exif
/// item payload (Exif items carry a 4-byte big-endian TIFF offset prefix).
fn patch_exif_portrait_markers(exif: &[u8], maker_note: &[u8]) -> Result<Vec<u8>, String> {
    // CustomRendered first (in-place value patch inside the TIFF body).
    let prefix_len = 4 + u32::from_be_bytes([exif[0], exif[1], exif[2], exif[3]]) as usize;
    let mut tiff = exif[prefix_len..].to_vec();
    let le = tiff.starts_with(b"II");
    let rd16 = |b: &[u8]| {
        if le {
            u16::from_le_bytes([b[0], b[1]])
        } else {
            u16::from_be_bytes([b[0], b[1]])
        }
    };
    let rd32 = |b: &[u8]| {
        if le {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        }
    };
    let wr16 = |b: &mut [u8], v: u16| {
        if le {
            b.copy_from_slice(&v.to_le_bytes());
        } else {
            b.copy_from_slice(&v.to_be_bytes());
        }
    };
    let wr32 = |b: &mut [u8], v: u32| {
        if le {
            b.copy_from_slice(&v.to_le_bytes());
        } else {
            b.copy_from_slice(&v.to_be_bytes());
        }
    };
    let ifd0_off = rd32(&tiff[4..8]) as usize;
    let ifd0_count = rd16(&tiff[ifd0_off..ifd0_off + 2]);
    let mut exif_ifd_off = 0usize;
    for k in 0..ifd0_count as usize {
        let e = ifd0_off + 2 + k * 12;
        if rd16(&tiff[e..e + 2]) == 0x8769 {
            exif_ifd_off = rd32(&tiff[e + 8..e + 12]) as usize;
        }
    }
    if exif_ifd_off == 0 {
        return Err("Exif item has no ExifIFD pointer".into());
    }
    let exif_count = rd16(&tiff[exif_ifd_off..exif_ifd_off + 2]);
    for k in 0..exif_count as usize {
        let e = exif_ifd_off + 2 + k * 12;
        if rd16(&tiff[e..e + 2]) == 0xA404 {
            // golden layout: type 5 (LONG), count 1, value 9 (portrait render)
            wr16(&mut tiff[e + 2..e + 4], 5);
            wr32(&mut tiff[e + 4..e + 8], 1);
            wr32(&mut tiff[e + 8..e + 12], 9);
            break;
        }
    }
    // Reassemble with the original prefix, then run the scaffold MakerNote
    // injector (handles both the replace-in-place and insert+fixup paths).
    let mut with_prefix = exif[..prefix_len].to_vec();
    with_prefix.extend_from_slice(&tiff);
    crate::portrait_scaffold::inject_maker_note(&with_prefix, maker_note)
}

fn make_auxc(urn: &[u8]) -> Vec<u8> {
    // auxC FullBox: version/flags (4) + urn + NUL
    let mut payload = vec![0u8; 4];
    payload.extend_from_slice(urn);
    payload.push(0);
    isobmff::make_box(b"auxC", &payload)
}

fn make_xmp_infe(item_id: u32) -> Vec<u8> {
    // Golden-exact mime XMP infe (empty item name).
    let mut payload = vec![2u8, 0, 0, 1]; // version 2, flags = hidden
    payload.extend_from_slice(&(item_id as u16).to_be_bytes());
    payload.extend_from_slice(&[0, 0]); // protection index
    payload.extend_from_slice(b"mime");
    payload.push(0); // empty item name
    payload.extend_from_slice(b"application/rdf+xml\0");
    isobmff::make_box(b"infe", &payload)
}

fn find_meta_child(data: &[u8], meta_hdr: &BoxHeader, target: &[u8; 4]) -> Option<BoxHeader> {
    isobmff::parse_boxes(
        data,
        meta_hdr.data_start + 4,
        meta_hdr.box_start + meta_hdr.size,
    )
    .into_iter()
    .find(|b| &b.btype == target)
}

fn extract_exif_datetime(base: &[u8], meta: &ParsedMeta) -> Option<String> {
    let exif_item = meta.items.iter().find(|i| i.itype == "Exif")?;
    let entry = meta
        .iloc_entries
        .iter()
        .find(|e| e.item_id == exif_item.item_id)?;
    if entry.construction_method != 0 {
        return None;
    }
    let (off, len) = entry.extents.first()?;
    let start = *off as usize;
    let payload = base.get(start..start + *len as usize)?;
    // TIFF tag 0x9003 (DateTimeOriginal), ASCII "YYYY:MM:DD HH:MM:SS"
    let mut windows = payload.windows(4);
    let mut pos = 0;
    while let Some(p) = windows.position(|w| w[0] == b'2' && w[1] == b'0' && w[2].is_ascii_digit() && w[3].is_ascii_digit()) {
        let at = pos + p;
        if let Some(slice) = payload.get(at..at + 19) {
            if slice[4] == b':' && slice[7] == b':' && slice[10] == b' ' {
                return String::from_utf8(slice.to_vec()).ok();
            }
        }
        pos = at + 1;
        windows = payload[pos..].windows(4);
    }
    None
}

/// CLI entry: `portrait <source.heic> <base.heic> <output.heic>`.
/// `base` is the standard converted output for the same photo (the portrait
/// graph attaches onto it).
pub(crate) fn cmd_portrait(args: &[String]) -> Result<(), String> {
    if args.len() != 3 {
        return Err("portrait: expected <source.heic> <base.heic> <output.heic>".into());
    }
    let input = std::fs::read(&args[0]).map_err(|e| format!("read {}: {e}", args[0]))?;
    let base = std::fs::read(&args[1]).map_err(|e| format!("read {}: {e}", args[1]))?;
    let out = run_portrait(&input, &base)?;
    std::fs::write(&args[2], &out).map_err(|e| format!("write {}: {e}", args[2]))?;
    println!("portrait: {} -> {} bytes", args[2], out.len());
    Ok(())
}
