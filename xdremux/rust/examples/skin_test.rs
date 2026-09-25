//! End-to-end skin pipeline: convert with Photographic Styles, then attach a
//! filled-in Texture Style person block so Photos has something real to run
//! skin smoothing with.
//!
//! usage: skin_test <input image> <output heic>

use std::ffi::CString;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = &args[1];
    let output = &args[2];

    // 1. Decode for measurement (pixels must match what the conversion stores,
    // i.e. presentation orientation).
    let bytes = std::fs::read(input).unwrap();
    let (rgb, w, h, _oriented) = xdremux_core::sdr_source::decode_to_rgb(&bytes).unwrap();
    let img = xdremux_core::person_stats::RgbImage {
        pixels: &rgb,
        width: w,
        height: h,
    };

    // 2. Detect + measure.
    let people = match xdremux_core::face_detect::build_person_instances(&img) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("person pipeline failed: {e}");
            Vec::new()
        }
    };
    println!("faces: {}", people.len());
    for (i, p) in people.iter().enumerate() {
        println!(
            "  [{i}] face={:?} skin={:?} rough={:?} eyes={:?}/{:?} bimodal={}/{}",
            p.face_roi,
            p.skin_colour.map(|v| (v * 1000.0).round() / 1000.0),
            p.skin_roughness,
            p.left_eye_colour.map(|v| (v * 1000.0).round() / 1000.0),
            p.right_eye_colour.map(|v| (v * 1000.0).round() / 1000.0),
            p.left_eye_bimodal,
            p.right_eye_bimodal
        );
    }

    // 3. Convert with Photographic Styles (full scaffold).
    let cin = CString::new(input.as_str()).unwrap();
    let cout = CString::new(output.as_str()).unwrap();
    let cfg = xdremux_core::ConvertConfig {
        oppo_compat: 2,
        oppo_camera_tail: 3,
        strict_tmap: 0,
        apple_photographic_styles: 1,
        apple_portrait: 0,
    };
    let r = xdremux_core::xdremux_convert(cin.as_ptr(), cout.as_ptr(), &cfg);
    let msg = unsafe {
        if r.error_message.is_null() {
            String::new()
        } else {
            std::ffi::CStr::from_ptr(r.error_message)
                .to_string_lossy()
                .into_owned()
        }
    };
    if !r.success {
        eprintln!("convert failed: {msg}");
        std::process::exit(1);
    }
    println!("converted ok");

    // 4. Swap in the person block.
    let container = std::fs::read(output).unwrap();
    match xdremux_core::texture_styles::inject_texture_styles_with_people(
        &container,
        203,
        &people,
    ) {
        Ok(with_people) => {
            std::fs::write(output, &with_people).unwrap();
            println!("people data attached -> {output}");
        }
        Err(e) => eprintln!("people inject failed: {e}"),
    }
}
