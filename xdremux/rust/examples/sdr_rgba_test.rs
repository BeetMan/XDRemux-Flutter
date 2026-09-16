use std::ffi::CString;

/// Exercises the FFI the Flutter side calls: pixels already decoded by the
/// platform codec -> standard container -> styles scaffold -> PS3 contract.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = &args[1];
    let output = &args[2];
    let (rgb, w, h) =
        xdremux_core::jpeg_decode::decode_jpeg_to_rgb(&std::fs::read(input).unwrap()).unwrap();
    let mut rgba = Vec::with_capacity(rgb.len() / 3 * 4);
    for px in rgb.chunks_exact(3) {
        rgba.extend_from_slice(&[px[0], px[1], px[2], 255]);
    }
    let cin = CString::new(input.as_str()).unwrap();
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
    println!("success={} {}x{} err='{}'", r.success, w, h, msg);
}
