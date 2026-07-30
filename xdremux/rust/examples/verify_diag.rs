fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = std::ffi::CString::new(args[1].as_str()).unwrap();
    let ok = xdremux_core::xdremux_verify_output(path.as_ptr());
    println!("verify_output = {ok}");
}
