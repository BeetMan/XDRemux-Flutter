fn main() {
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path).unwrap();
        match xdremux_core::linear_thumbnail::generate_linear_thumbnail(&data, 0, 4.0) {
            Ok((stream, hvcc, width, height)) => println!(
                "{path}: OK {width}x{height} stream={}B hvcc={}B",
                stream.len(),
                hvcc.len()
            ),
            Err(e) => println!("{path}: ERR {e}"),
        }
    }
}
