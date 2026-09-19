fn main() {
    let input = std::env::args().nth(1).expect("usage: ts3_inject_test <in> <out>");
    let output = std::env::args().nth(2).expect("usage: ts3_inject_test <in> <out>");
    let data = std::fs::read(&input).expect("read");
    match xdremux_core::texture_styles::inject_texture_styles(&data, 104) {
        Ok(out) => {
            std::fs::write(&output, &out).unwrap();
            println!("OK: {} -> {} bytes", data.len(), out.len());
        }
        Err(e) => {
            eprintln!("ERR: {e}");
            std::process::exit(1);
        }
    }
}
