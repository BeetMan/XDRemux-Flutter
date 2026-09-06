use std::fs;

/// Mimic the app flow: split the still from a Motion Photo, then convert the
/// still through the UHDR JPEG main path.
fn main() {
    let mut args = std::env::args().skip(1);
    while let Some(path) = args.next() {
        let data = fs::read(&path).unwrap();
        let name = std::path::Path::new(&path)
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .to_string();
        let asset = match xdremux_core::motion_photo::parse_motion_photo(&data) {
            Ok(Some(a)) => a,
            other => {
                println!("{name}: not a motion photo ({other:?})");
                continue;
            }
        };
        let still = &data[asset.still_range.start as usize..asset.still_range.end as usize];
        let still_path = format!("{name}_still.jpg");
        let out_path = format!("{name}_iso.heic");
        fs::write(&still_path, still).unwrap();

        let input = std::ffi::CString::new(still_path.as_str()).unwrap();
        let output = std::ffi::CString::new(out_path.as_str()).unwrap();
        let cfg = xdremux_core::ConvertConfig {
            oppo_compat: 2,
            oppo_camera_tail: 3,
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
        let out_size = fs::metadata(&out_path).map(|m| m.len()).unwrap_or(0);
        println!(
            "{name}: still={}KB success={} out={}KB err='{}'",
            still.len() / 1024,
            r.success,
            out_size / 1024,
            msg
        );
    }
}
