//! ort smoke test: load YuNet and run it on a decoded image.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).expect("image");
    let model = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "xdremux/rust/models/face_detection_yunet_2023mar.onnx".into());
    let bytes = std::fs::read(&path)?;
    let (rgb, w, h, _oriented) = xdremux_core::sdr_source::decode_to_rgb(&bytes)?;
    println!("decoded {w}x{h}");

    use ort::inputs;
    use ort::session::builder::GraphOptimizationLevel;
    let mut session = ort::session::Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Level3)?
        .commit_from_file(&model)?;
    println!("model ok: {:?}", session.inputs().iter().map(|i| i.name().to_string()).collect::<Vec<_>>());
    println!("outputs: {:?}", session.outputs().iter().map(|o| o.name().to_string()).collect::<Vec<_>>());

    // YuNet wants planar float32 [1,3,H,W] scaled to 0..1? actually it takes
    // BGR planar float; keep the smoke test to shape plumbing only.
    // YuNet takes a fixed 640x640 planar float32 input; nearest-neighbour is
    // fine for a detection smoke test (boxes scale back by 640/w).
    let (pw, ph) = (640usize, 640usize);
    let sx = w as usize; let sy = h as usize;
    let mut planar = vec![0f32; 3 * pw * ph];
    for y in 0..ph {
        for x in 0..pw {
            let src_x = x * sx / pw;
            let src_y = y * sy / ph;
            let s = (src_y * sx + src_x) * 3;
            planar[y * pw + x] = rgb[s] as f32;
            planar[pw * ph + y * pw + x] = rgb[s + 1] as f32;
            planar[2 * pw * ph + y * pw + x] = rgb[s + 2] as f32;
        }
    }
    let input = ort::value::Tensor::from_array(([1usize, 3, ph, pw], planar))?;
    let outputs = session.run(inputs![input])?;
    for (name, value) in outputs.iter() {
        println!("  out {name}: {:?}", value.dtype());
    }
    // cls_32 是最高层的置信度，看有没有脸
    if let Some((_, v)) = outputs.iter().find(|(n, _)| *n == "cls_32") {
        if let Ok((shape, data)) = v.try_extract_tensor::<f32>() {
            let max = data.iter().cloned().fold(0f32, f32::max);
            println!("  cls_32 shape={:?} max_conf={:.4}", shape, max);
        }
    }
    println!("ort smoke OK");
    Ok(())
}
