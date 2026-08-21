use std::ffi::CString;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: styles_convert <input.heic> <output.heic>");
        std::process::exit(2);
    }
    let input = CString::new(args[1].as_str()).unwrap();
    let output = CString::new(args[2].as_str()).unwrap();
    let config = xdremux_core::ConvertConfig {
        oppo_compat: 0,
        oppo_camera_tail: 0,
        strict_tmap: 0,
        apple_photographic_styles: 1,
        apple_portrait: 0,
    };
    let result = xdremux_core::xdremux_convert(
        input.as_ptr(),
        output.as_ptr(),
        &config as *const _,
    );
    println!("success={}", result.success);
    if !result.error_message.is_null() {
        let msg = unsafe { std::ffi::CStr::from_ptr(result.error_message) };
        println!("error: {}", msg.to_string_lossy());
    }
    xdremux_core::xdremux_free_result(result);
}
