//! R4: portable sky-matte segmentation via SegFormer-B0 (ADE20K, class 2 =
//! "sky") on ONNX Runtime (ort crate, load-dynamic against the system
//! libonnxruntime). Produces a half-res 8-bit gray matte bitmap that
//! `styles` encodes into the semantic sky matte items, replacing the zero
//! placeholder.
//!
//! Note: tract (pure Rust) was tried first but mishandles this model
//! (0.21/0.22: quantized graph fails analysis at the conv bias-add; the
//! f32 export segfaults at run). ONNX Runtime is the pragmatic research
//! runtime; final cross-platform packaging is an R6 question.

use std::path::Path;

/// ADE20K class index for "sky".
const SKY_CLASS: usize = 2;
/// SegFormer-B0 ADE input resolution.
const MODEL_SIZE: usize = 512;
/// ImageNet normalization (SegformerImageProcessor defaults).
const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const STD: [f32; 3] = [0.229, 0.224, 0.225];

/// Run sky segmentation on a decoded photo. Returns a row-major gray matte
/// at `(matte_w, matte_h)` with values 0..255 (sky probability scaled).
pub(crate) fn segment_sky(
    photo_path: &Path,
    model_path: &Path,
    matte_w: u32,
    matte_h: u32,
) -> Result<Vec<u8>, String> {
    let img = image::open(photo_path)
        .map_err(|e| format!("decode photo {}: {e}", photo_path.display()))?
        .to_rgb8();
    let resized = image::imageops::resize(
        &img,
        MODEL_SIZE as u32,
        MODEL_SIZE as u32,
        image::imageops::FilterType::Triangle,
    );

    // NCHW float input with ImageNet normalization.
    let mut input = vec![0f32; 3 * MODEL_SIZE * MODEL_SIZE];
    for y in 0..MODEL_SIZE {
        for x in 0..MODEL_SIZE {
            let px = resized.get_pixel(x as u32, y as u32);
            for c in 0..3 {
                let v = px[c] as f32 / 255.0;
                input[c * MODEL_SIZE * MODEL_SIZE + y * MODEL_SIZE + x] =
                    (v - MEAN[c]) / STD[c];
            }
        }
    }

    ort::init_from(
        std::env::var("ORT_DYLIB_PATH")
            .unwrap_or_else(|_| "/opt/homebrew/lib/libonnxruntime.dylib".to_string()),
    )
    .map_err(|e| format!("ort init: {e}"))?
    .commit();

    let mut session = ort::session::Session::builder()
        .map_err(|e| format!("session builder: {e}"))?
        .commit_from_file(model_path)
        .map_err(|e| format!("load model {}: {e}", model_path.display()))?;

    let input_tensor = ort::value::Tensor::from_array((
        [1usize, 3, MODEL_SIZE, MODEL_SIZE],
        input,
    ))
    .map_err(|e| format!("input tensor: {e}"))?;
    let outputs = session
        .run(ort::inputs![input_tensor])
        .map_err(|e| format!("inference: {e}"))?;
    let (shape, logits) = outputs[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("extract logits: {e}"))?;
    let dims: Vec<usize> = shape.iter().map(|&d| d as usize).collect();
    eprintln!("[seg] logits shape: {dims:?}");
    if dims.len() != 4 || dims[0] != 1 {
        return Err(format!("unexpected logits shape {dims:?}"));
    }
    let (num_classes, oh, ow) = (dims[1], dims[2], dims[3]);
    if SKY_CLASS >= num_classes {
        return Err(format!("model has {num_classes} classes, no sky"));
    }
    let mut sky = vec![0f32; oh * ow];
    for y in 0..oh {
        for x in 0..ow {
            let base = |c: usize| logits[c * oh * ow + y * ow + x];
            let mut maxv = f32::NEG_INFINITY;
            for c in 0..num_classes {
                maxv = maxv.max(base(c));
            }
            let mut sum = 0f32;
            for c in 0..num_classes {
                sum += (base(c) - maxv).exp();
            }
            sky[y * ow + x] = (base(SKY_CLASS) - maxv).exp() / sum;
        }
    }

    let prob_bytes: Vec<u8> = sky
        .iter()
        .map(|p| (p.clamp(0.0, 1.0) * 255.0).round() as u8)
        .collect();
    let prob_img = image::GrayImage::from_raw(ow as u32, oh as u32, prob_bytes)
        .ok_or("probability image construction failed")?;
    let matte = image::imageops::resize(
        &prob_img,
        matte_w,
        matte_h,
        image::imageops::FilterType::Triangle,
    );
    Ok(matte.into_raw())
}

/// CLI entry: `sky-matte <photo.png> <model.onnx> <out.raw> [matte_w matte_h]`.
/// Defaults to half the photo dims (even-rounded), matching the scaffold
/// matte convention.
pub(crate) fn cmd_sky_matte(args: &[String]) -> Result<(), String> {
    if args.len() < 3 {
        return Err(
            "sky-matte: expected <photo.png> <model.onnx> <out.raw> [w h]".into(),
        );
    }
    let photo = Path::new(&args[0]);
    let model = Path::new(&args[1]);
    let out = Path::new(&args[2]);
    let img = image::open(photo)
        .map_err(|e| format!("decode photo {}: {e}", photo.display()))?;
    let (pw, ph) = (img.width(), img.height());
    let (matte_w, matte_h) = if args.len() >= 5 {
        let w: u32 = args[3].parse().map_err(|_| "bad width")?;
        let h: u32 = args[4].parse().map_err(|_| "bad height")?;
        (w, h)
    } else {
        ((pw / 2) & !1, (ph / 2) & !1)
    };
    let matte = segment_sky(photo, model, matte_w, matte_h)?;
    std::fs::write(out, &matte).map_err(|e| format!("write {}: {e}", out.display()))?;
    let nonzero = matte.iter().filter(|&&v| v > 16).count();
    let mean: u64 = matte.iter().map(|&v| v as u64).sum::<u64>() / matte.len().max(1) as u64;
    println!(
        "sky-matte: {}x{} written ({}), sky(>16): {:.1}%, mean={}",
        matte_w,
        matte_h,
        out.display(),
        100.0 * nonzero as f64 / matte.len() as f64,
        mean
    );
    Ok(())
}
