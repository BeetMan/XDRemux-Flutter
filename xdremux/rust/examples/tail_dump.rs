use std::env;

fn main() {
    let path = env::args().nth(1).expect("usage: tail_dump <file.heic> [entry ...]");
    let data = std::fs::read(&path).expect("read failed");
    let names = xdremux_core::container::tail_entry_names(&data);
    println!("entries: {:?}", names);
    let wanted: Vec<String> = env::args().skip(2).collect();
    for name in &wanted {
        match xdremux_core::container::extract_tail_entry(&data, name) {
            Some(bytes) => {
                println!("--- {} ({} bytes)", name, bytes.len());
                let preview = &bytes[..bytes.len().min(600)];
                match std::str::from_utf8(preview) {
                    Ok(s) => println!("{}", s),
                    Err(_) => println!("hex: {}", preview[..preview.len().min(128)].iter().map(|b| format!("{b:02x}")).collect::<String>()),
                }
            }
            None => println!("--- {} MISSING", name),
        }
    }
}
