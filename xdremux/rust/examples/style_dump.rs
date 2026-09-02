// Dump the styleMetadata plist structure of a HEIC for diffing.
use std::process::Command;

fn main() {
    for path in std::env::args().skip(1) {
        let out = Command::new("python3")
            .arg("/tmp/extract_style_generic.py")
            .arg(&path)
            .output();
        match out {
            Ok(o) => print!("{}", String::from_utf8_lossy(&o.stdout)),
            Err(e) => println!("err: {e}"),
        }
    }
}
