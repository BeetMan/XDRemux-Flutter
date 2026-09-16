use std::ffi::CString;

/// Mirrors the app: the platform codec decodes the ORIGINAL file to pixels
/// (already rotated into presentation orientation) while the FFI reads the
/// original file for its Exif. Here Rust decodes a JPEG stand-in and applies
/// the same rotation the platform codec would.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = &args[1];
    let output = &args[2];
    let exif_src = args.get(3).unwrap_or(input);

    let (rgb, w, h) =
        xdremux_core::jpeg_decode::decode_jpeg_to_rgb(&std::fs::read(input).unwrap()).unwrap();

    // Stand in for the platform codec's EXIF-orientation handling.
    let orientation = std::fs::read(exif_src)
        .ok()
        .and_then(|b| xdremux_core::styles_attach::extract_exif_tiff(&b))
        .and_then(|t| xdremux_core::exif::parse_exif_orientation(&t).ok())
        .unwrap_or(xdremux_core::exif::ExifOrientation::Normal);
    let (rgb, w, h) = xdremux_core::isobmff_write::orient_gainmap_pixels(
        &rgb,
        w,
        h,
        3,
        w as usize * 3,
        orientation,
    )
    .unwrap();

    eprintln!("DBG orientation={:?} after-rotate={}x{}", orientation, w, h);
    let mut rgba = Vec::with_capacity(rgb.len() / 3 * 4);
    for px in rgb.chunks_exact(3) {
        rgba.extend_from_slice(&[px[0], px[1], px[2], 255]);
    }
    let cin = CString::new(exif_src.as_str()).unwrap();
    let cout = CString::new(output.as_str()).unwrap();
    let cfg = xdremux_core::ConvertConfig {
        oppo_compat: 2,
        oppo_camera_tail: 3,
        strict_tmap: 0,
        apple_photographic_styles: 1,
        apple_portrait: 0,
    };
    let r = xdremux_core::xdremux_convert_sdr_rgba(
        cin.as_ptr(),
        rgba.as_ptr(),
        w,
        h,
        cout.as_ptr(),
        &cfg,
    );
    let msg = unsafe {
        if r.error_message.is_null() {
            String::new()
        } else {
            std::ffi::CStr::from_ptr(r.error_message)
                .to_string_lossy()
                .into_owned()
        }
    };
    println!(
        "success={} {}x{} orient={:?} err='{}'",
        r.success, w, h, orientation, msg
    );
}
