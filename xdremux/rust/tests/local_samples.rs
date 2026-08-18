//! Opt-in regression coverage for real, locally stored HEIC samples.
//!
//! Run with `XDREMUX_SAMPLE_DIR` set to a directory of source HEIC files:
//! `cargo test -p xdremux-core --test local_samples -- --ignored --nocapture`.
//! Outputs are written to a unique temporary directory and deleted on exit.

use std::env;
use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use xdremux_core::{xdremux_convert, xdremux_free_result, xdremux_verify_output, ConvertConfig};

const SAMPLE_DIR_ENV: &str = "XDREMUX_SAMPLE_DIR";

struct TempOutputDir {
    path: PathBuf,
}

impl TempOutputDir {
    fn new() -> Result<Self, String> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| format!("could not create temp-dir nonce: {e}"))?
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "xdremux-local-samples-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path).map_err(|e| format!("could not create {}: {e}", path.display()))?;
        Ok(Self { path })
    }
}

impl Drop for TempOutputDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn is_source_sample(path: &Path) -> bool {
    let is_heic = path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("heic"));
    if !is_heic {
        return false;
    }

    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    !["_py", "_final", "_oppo", "_out", "_normal", "_iso"]
        .iter()
        .any(|suffix| stem.ends_with(suffix))
}

fn c_path(path: &Path) -> CString {
    CString::new(
        path.to_str()
            .expect("local sample paths must be valid UTF-8 for the C FFI"),
    )
    .expect("local sample paths must not contain NUL bytes")
}

#[test]
fn source_sample_filter_skips_derived_variants() {
    for name in [
        "photo.heic",
        "PHOTO.HEIC",
        "portrait.heic",
        "portrait.jpg",
        "photo_py.heic",
        "photo_final.heic",
        "photo_oppo.heic",
        "photo_out.heic",
        "photo_normal.heic",
        "photo_iso.heic",
    ] {
        let expected = matches!(name, "photo.heic" | "PHOTO.HEIC" | "portrait.heic");
        assert_eq!(is_source_sample(Path::new(name)), expected, "{name}");
    }
}

#[test]
#[ignore = "requires private real HEIC samples; set XDREMUX_SAMPLE_DIR and pass --ignored"]
fn converts_local_samples_to_valid_iso_gain_maps() {
    let sample_dir = PathBuf::from(env::var(SAMPLE_DIR_ENV).unwrap_or_else(|_| {
        panic!("set {SAMPLE_DIR_ENV} to a directory containing source HEIC samples")
    }));
    assert!(
        sample_dir.is_dir(),
        "{SAMPLE_DIR_ENV} is not a directory: {}",
        sample_dir.display()
    );

    let mut samples: Vec<PathBuf> = fs::read_dir(&sample_dir)
        .unwrap_or_else(|e| panic!("could not read {}: {e}", sample_dir.display()))
        .map(|entry| entry.expect("could not read sample directory entry").path())
        .filter(|path| path.is_file() && is_source_sample(path))
        .collect();
    samples.sort();
    assert!(
        !samples.is_empty(),
        "no source HEIC files found in {}",
        sample_dir.display()
    );

    let output_dir = TempOutputDir::new().expect("could not create temporary output directory");
    let config = ConvertConfig {
        oppo_compat: 0,
        oppo_camera_tail: xdremux_core::container::OppoCameraTail::AUTOMATIC,
        strict_tmap: 0,
        apple_photographic_styles: 0,
    };

    for (index, input) in samples.iter().enumerate() {
        let stem = input
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("sample");
        let output = output_dir.path.join(format!("{index:03}-{stem}_iso.heic"));
        let input_c = c_path(input);
        let output_c = c_path(&output);

        let result = xdremux_convert(input_c.as_ptr(), output_c.as_ptr(), &config);
        let error = if result.error_message.is_null() {
            None
        } else {
            Some(
                unsafe { std::ffi::CStr::from_ptr(result.error_message) }
                    .to_string_lossy()
                    .into_owned(),
            )
        };
        let success = result.success;
        xdremux_free_result(result);

        assert!(
            success,
            "conversion failed for {}: {}",
            input.display(),
            error.unwrap_or_else(|| "unknown error".into())
        );
        assert!(
            output.is_file(),
            "conversion created no output for {}",
            input.display()
        );
        assert!(
            xdremux_verify_output(output_c.as_ptr()),
            "output does not contain a valid ISO gain map: {}",
            input.display()
        );
    }
}
