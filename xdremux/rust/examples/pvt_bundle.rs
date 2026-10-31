//! Live Photo `.pvt` bundle CLI.
//!
//! cargo run --example pvt_bundle -- <still.heic> <paired.mov> <out.pvt>
//! cargo run --example pvt_bundle -- --check <bundle.pvt>
//! cargo run --example pvt_bundle -- --from-source <motion.jpg> <converted.heic> <out.pvt>
//!
//! `--from-source` follows the Flutter `composeLivePhoto(bundle: true)` path:
//! `xdremux_make_live_photo` into a staging dir, then
//! `xdremux_make_live_photo_bundle`, then `xdremux_live_photo_bundle_valid`.
use std::ffi::{CStr, CString};
use std::path::Path;

fn ffi_json(raw: *mut std::os::raw::c_char) -> serde_json::Value {
    assert!(!raw.is_null(), "FFI returned no report");
    let text = unsafe { CStr::from_ptr(raw) }
        .to_string_lossy()
        .into_owned();
    xdremux_core::xdremux_free_string(raw);
    serde_json::from_str(&text).expect("FFI report is JSON")
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [flag, bundle] if flag == "--check" => {
            let bundle = Path::new(bundle);
            match xdremux_core::live_photo_bundle::read_bundle(bundle) {
                Ok(paths) => println!(
                    "still: {}\nmovie: {}",
                    paths.still.display(),
                    paths.movie.display()
                ),
                Err(e) => println!("structure: {e}"),
            }
            println!(
                "valid: {}",
                xdremux_core::live_photo_bundle::bundle_is_valid(bundle)
            );
        }
        [flag, source, still, bundle] if flag == "--from-source" => {
            let staging = std::env::temp_dir().join(format!("pvt_bundle_{}", std::process::id()));
            std::fs::create_dir_all(&staging).unwrap();
            let c = |s: &str| CString::new(s).unwrap();
            let pair = ffi_json(xdremux_core::xdremux_make_live_photo(
                c(source).as_ptr(),
                c(still).as_ptr(),
                c(staging.to_str().unwrap()).as_ptr(),
            ));
            println!("pair: {pair}");
            let report = ffi_json(xdremux_core::xdremux_make_live_photo_bundle(
                c(pair["stillPath"].as_str().expect("pair still")).as_ptr(),
                c(pair["videoPath"].as_str().expect("pair video")).as_ptr(),
                c(bundle).as_ptr(),
            ));
            println!("bundle: {report}");
            println!(
                "valid: {}",
                xdremux_core::xdremux_live_photo_bundle_valid(c(bundle).as_ptr())
            );
            let _ = std::fs::remove_dir_all(&staging);
        }
        [still, movie, bundle] => {
            match xdremux_core::live_photo_bundle::write_bundle(
                Path::new(still),
                Path::new(movie),
                Path::new(bundle),
            ) {
                Ok(paths) => println!(
                    "bundle: {}\nvalid: {}",
                    paths.bundle.display(),
                    xdremux_core::live_photo_bundle::bundle_is_valid(&paths.bundle)
                ),
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        _ => {
            eprintln!("usage: pvt_bundle <still> <mov> <out.pvt> | --check <bundle.pvt> | --from-source <motion> <converted> <out.pvt>");
            std::process::exit(2);
        }
    }
}
