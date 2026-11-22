//! Print the OPPO private data the photo details view reports for each file.
//!
//! cargo run --release --example oppo_details_probe -- [--entries] <photo>...

fn main() {
    let mut show_entries = false;
    for path in std::env::args().skip(1) {
        if path == "--entries" {
            show_entries = true;
            continue;
        }
        let name = path.rsplit('/').next().unwrap_or(&path);
        match xdremux_core::photo_details::inspect_photo_details(&path) {
            Ok(details) => {
                let report = details.to_json();
                let Some(oppo) = report.get("oppo") else {
                    println!("{name}\tno OPPO tail");
                    continue;
                };
                let mut oppo = oppo.clone();
                let count = oppo["entries"].as_array().map_or(0, Vec::len);
                if !show_entries {
                    oppo.as_object_mut().map(|object| object.remove("entries"));
                }
                println!("{name}\t{count} entries\t{oppo}");
            }
            Err(error) => println!("{name}\terror: {error}"),
        }
    }
}
