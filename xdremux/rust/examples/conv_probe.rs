use std::ffi::CString;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = CString::new(args[1].as_str()).unwrap();
    let output = CString::new(args[2].as_str()).unwrap();
    let cfg = xdremux_core::ConvertConfig {
        oppo_compat: 2,        // on
        oppo_camera_tail: 3,   // preserve
        strict_tmap: 0,
        apple_photographic_styles: 0,
        apple_portrait: 0,
    };
    let r = xdremux_core::xdremux_convert(input.as_ptr(), output.as_ptr(), &cfg);
    let msg = unsafe {
        if r.error_message.is_null() {
            String::new()
        } else {
            std::ffi::CStr::from_ptr(r.error_message).to_string_lossy().into_owned()
        }
    };
    println!("success={} mode_err='{}'", r.success, msg);
}
