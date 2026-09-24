/// Print the ProXDR metadata version/family decision for a file, plus which
/// extraction path produced it. Answers "does the x6/x7 split and the
/// float144-vs-manifest fallback match real devices?".
fn main() {
    for path in std::env::args().skip(1) {
        let name = path.rsplit('/').next().unwrap_or(&path).to_string();
        let Ok(bytes) = std::fs::read(&path) else {
            println!("{name}: unreadable");
            continue;
        };
        if bytes.starts_with(&[0xFF, 0xD8]) {
            match xdremux_core::uhdr_jpeg::parse(&bytes) {
                Ok(Some(info)) => println!(
                    "{name:28} UHDR-JPEG  meta[0]={:.3} floats={} gainmap={}B exif={}",
                    info.meta_floats.first().copied().unwrap_or(f32::NAN),
                    info.meta_floats.len(),
                    info.gainmap_jpeg.len(),
                    info.exif_tiff.as_ref().map(|t| t.len()).unwrap_or(0)
                ),
                Ok(None) => println!("{name:28} plain JPEG (no gain map)"),
                Err(e) => println!("{name:28} UHDR parse error: {e}"),
            }
            continue;
        }
        match xdremux_core::container::extract_lhdr_from_bytes(&bytes) {
            Ok(e) => {
                let v0 = e.meta_floats.first().copied().unwrap_or(f32::NAN);
                let family = if v0 >= 3.0 || e.mode == "uhdr" { "x7" } else { "x6" };
                println!(
                    "{name:28} {:<6} meta[0]={:.3} -> family={} floats={} mask={} gainmap={} manifest={}",
                    e.mode,
                    v0,
                    family,
                    e.meta_floats.len(),
                    e.mask_data.as_ref().map(|m| m.len()).unwrap_or(0),
                    e.gainmap_data.as_ref().map(|g| g.len()).unwrap_or(0),
                    e.manifest_entries.as_ref().map(|m| m.len()).unwrap_or(0)
                );
            }
            Err(e) => println!("{name:28} no LHDR: {e}"),
        }
    }
}
