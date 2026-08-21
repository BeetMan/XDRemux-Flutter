use std::ffi::CString;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: wb_probe <donor.heic> <returned.heic> <output.heic> [mode:oppo|apple] [restore:0|1]");
        std::process::exit(2);
    }
    let donor = CString::new(args[1].as_str()).unwrap();
    let returned = CString::new(args[2].as_str()).unwrap();
    let output = CString::new(args[3].as_str()).unwrap();
    let mode: u8 = if args.get(4).map(|s| s.as_str()) == Some("apple") { 0 } else { 1 };
    let restore: u8 = if args.get(5).map(|s| s.as_str()) == Some("0") { 0 } else { 1 };
    let report = xdremux_core::xdremux_writeback_returned_photo(
        donor.as_ptr(),
        returned.as_ptr(),
        output.as_ptr(),
        mode,
        restore,
    );
    if report.is_null() {
        eprintln!("null report");
        std::process::exit(1);
    }
    let msg = unsafe { std::ffi::CStr::from_ptr(report) };
    println!("{}", msg.to_string_lossy());
    xdremux_core::xdremux_free_string(report);
}
