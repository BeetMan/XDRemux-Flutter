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

use xdremux_core::{
    xdremux_convert, xdremux_free_result, xdremux_verify_output, xdremux_verify_styles_output,
    ConvertConfig,
};

const SAMPLE_DIR_ENV: &str = "XDREMUX_SAMPLE_DIR";
const HUAWEI_SAMPLE_DIR_ENV: &str = "XDREMUX_HUAWEI_SAMPLE_DIR";
const HUAWEI_MOTION_SAMPLE_DIR_ENV: &str = "XDREMUX_HUAWEI_MOTION_SAMPLE_DIR";
const HUAWEI_PORTRAIT_SAMPLE_DIR_ENV: &str = "XDREMUX_HUAWEI_PORTRAIT_SAMPLE_DIR";
const HUAWEI_XMAGE_SAMPLE_DIR_ENV: &str = "XDREMUX_HUAWEI_XMAGE_SAMPLE_DIR";
const STYLES_SAMPLE_ENV: &str = "XDREMUX_STYLES_SAMPLE";

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
fn recognizes_huawei_samples_when_available() {
    let Ok(sample_dir) = env::var(HUAWEI_SAMPLE_DIR_ENV) else {
        eprintln!("{HUAWEI_SAMPLE_DIR_ENV} is unset; Huawei sample regression skipped");
        return;
    };
    let sample_dir = PathBuf::from(sample_dir);
    if !sample_dir.is_dir() {
        eprintln!(
            "{HUAWEI_SAMPLE_DIR_ENV} is not a directory; Huawei sample regression skipped: {}",
            sample_dir.display()
        );
        return;
    }

    let mut samples: Vec<PathBuf> = fs::read_dir(&sample_dir)
        .expect("could not read Huawei sample directory")
        .map(|entry| entry.expect("could not read Huawei sample entry").path())
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("heic"))
        })
        .collect();
    samples.sort();
    if samples.is_empty() {
        eprintln!(
            "no Huawei HEIC samples found in {}; regression skipped",
            sample_dir.display()
        );
        return;
    }

    let mut with_xtstyle = 0;
    let mut without_xtstyle = 0;
    for sample in &samples {
        let report = xdremux_core::huawei_heic::inspect_path(sample)
            .unwrap_or_else(|error| panic!("{}: {error}", sample.display()));
        assert!(
            report.is_huawei_hdr,
            "Huawei source was not recognized: {} ({})",
            sample.display(),
            report.status
        );
        assert!(
            report.has_tmap_graph,
            "missing tmap graph: {}",
            sample.display()
        );
        assert!(report.has_nclx, "missing nclx: {}", sample.display());
        assert!(report.has_exif, "missing Exif: {}", sample.display());
        assert_eq!(report.exif_make.as_deref(), Some("HUAWEI"));
        assert_eq!(report.exif_orientation.as_deref(), Some("normal"));
        assert!(report.has_gps, "missing GPS: {}", sample.display());
        assert!(report.focal_length_mm.is_some());
        if report.has_xtstyle {
            with_xtstyle += 1;
            assert_eq!(report.xtstyle_version, Some(5));
            assert_eq!(report.xtstyle_header_f32, Some(vec![0.5, 0.5, 0.5]));
            assert_eq!(
                report.xtstyle_observed_layout.as_deref(),
                Some("u16le[6][192][192]")
            );
            assert_eq!(report.xtstyle_grid_dimensions, Some((192, 192)));
            assert_eq!(report.xtstyle_plane_count, Some(6));
            assert!(report.xtstyle_nonzero_bytes.unwrap_or(0) > 0);
        } else {
            without_xtstyle += 1;
            assert!(report.xtstyle_version.is_none());
        }
    }

    // The Mate 70 corpus intentionally contains both standard-mode samples
    // with XMAGE metadata and high-pixel samples without it.
    assert!(with_xtstyle > 0, "Huawei corpus has no xtstyle sample");
    assert!(
        without_xtstyle > 0,
        "Huawei corpus has no high-pixel sample"
    );
}

#[test]
fn recognizes_huawei_motion_samples_when_available() {
    let Ok(sample_dir) = env::var(HUAWEI_MOTION_SAMPLE_DIR_ENV) else {
        eprintln!(
            "{HUAWEI_MOTION_SAMPLE_DIR_ENV} is unset; Huawei Motion Photo regression skipped"
        );
        return;
    };
    let sample_dir = PathBuf::from(sample_dir);
    if !sample_dir.is_dir() {
        eprintln!(
            "{HUAWEI_MOTION_SAMPLE_DIR_ENV} is not a directory; Huawei Motion Photo regression skipped: {}",
            sample_dir.display()
        );
        return;
    }

    let mut samples: Vec<PathBuf> = fs::read_dir(&sample_dir)
        .expect("could not read Huawei Motion Photo sample directory")
        .map(|entry| {
            entry
                .expect("could not read Huawei Motion Photo sample entry")
                .path()
        })
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("heic"))
        })
        .collect();
    samples.sort();
    if samples.is_empty() {
        eprintln!(
            "no Huawei Motion Photo HEIC samples found in {}; regression skipped",
            sample_dir.display()
        );
        return;
    }

    let mut recognized = 0;
    for sample in &samples {
        let data = fs::read(sample).unwrap_or_else(|error| panic!("{}: {error}", sample.display()));
        match xdremux_core::motion_photo::parse_motion_photo(&data) {
            Ok(Some(asset)) => {
                assert_eq!(asset.source_kind, "huaweiOpenHarmonyMotionPhoto");
                assert_eq!(asset.still_range.end, asset.video_range.start);
                assert!(asset.presentation_timestamp_us.is_some());
                let video = &data[asset.video_range.start as usize..asset.video_range.end as usize];
                let clean_len = xdremux_core::motion_photo::standalone_bmff_length(video)
                    .expect("Huawei appended video BMFF");
                assert!(clean_len <= video.len());
                let metadata = asset.huawei_metadata.as_ref().expect("Huawei metadata");
                assert!(metadata.cover_time_ms.is_some());
                assert!(metadata.video_id.is_some());
                recognized += 1;
            }
            Ok(None) => {}
            Err(error) => panic!("{}: {error}", sample.display()),
        }
    }
    assert!(
        recognized > 0,
        "no Huawei Motion Photo sample was recognized"
    );
}

#[test]
fn recognizes_huawei_portrait_resources_when_available() {
    let Ok(sample_dir) = env::var(HUAWEI_PORTRAIT_SAMPLE_DIR_ENV) else {
        eprintln!("{HUAWEI_PORTRAIT_SAMPLE_DIR_ENV} is unset; Huawei Portrait regression skipped");
        return;
    };
    let sample_dir = PathBuf::from(sample_dir);
    if !sample_dir.is_dir() {
        eprintln!(
            "{HUAWEI_PORTRAIT_SAMPLE_DIR_ENV} is not a directory; Huawei Portrait regression skipped: {}",
            sample_dir.display()
        );
        return;
    }

    let mut samples: Vec<PathBuf> = fs::read_dir(&sample_dir)
        .expect("could not read Huawei Portrait sample directory")
        .map(|entry| {
            entry
                .expect("could not read Huawei Portrait sample entry")
                .path()
        })
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("heic"))
        })
        .collect();
    samples.sort();
    if samples.is_empty() {
        eprintln!(
            "no Huawei Portrait HEIC samples found in {}; regression skipped",
            sample_dir.display()
        );
        return;
    }

    let mut recognized = 0;
    let mut with_obp8 = 0;
    for sample in &samples {
        let report = xdremux_core::huawei_heic::inspect_path(sample)
            .unwrap_or_else(|error| panic!("{}: {error}", sample.display()));
        let Some(portrait) = report.portrait.as_ref() else {
            continue;
        };
        assert!(
            portrait.detected,
            "portrait report not detected: {}",
            sample.display()
        );
        assert_eq!(portrait.classification, "huawei-portrait");
        assert!(!portrait.safe_to_transform);
        assert_eq!(portrait.edof_tile_item_ids.len(), 12);
        assert!(portrait.edof_auxl_to_primary);
        assert!(portrait
            .edof_auxiliary_types
            .iter()
            .any(|value| value == "urn:com:huawei:photo:5:0:0:aux:unrefocusmap"));
        if portrait.rf_data_b_observed_magic.as_deref() == Some("obp8") {
            with_obp8 += 1;
        }
        assert_eq!(
            portrait.rf_data_b_observed_plane_dimensions,
            Some((1024, 768))
        );
        assert_eq!(portrait.rf_data_b_observed_sample_bytes, Some(1));
        assert_eq!(portrait.rf_data_b_observed_plane_bytes, Some(1024 * 768));
        assert_eq!(portrait.rf_data_b_observed_plane_complete, Some(true));
        recognized += 1;
    }
    assert!(recognized > 0, "no Huawei Portrait sample was recognized");
    assert!(
        with_obp8 > 0,
        "Huawei Portrait corpus has no observed obp8 sample"
    );
}

#[test]
fn distinguishes_huawei_xmage_payload_versions_when_available() {
    let Ok(sample_dir) = env::var(HUAWEI_XMAGE_SAMPLE_DIR_ENV) else {
        eprintln!("{HUAWEI_XMAGE_SAMPLE_DIR_ENV} is unset; XMAGE version regression skipped");
        return;
    };
    let sample_dir = PathBuf::from(sample_dir);
    if !sample_dir.is_dir() {
        eprintln!(
            "{HUAWEI_XMAGE_SAMPLE_DIR_ENV} is not a directory; XMAGE version regression skipped: {}",
            sample_dir.display()
        );
        return;
    }

    let mut samples: Vec<PathBuf> = fs::read_dir(&sample_dir)
        .expect("could not read Huawei XMAGE sample directory")
        .map(|entry| {
            entry
                .expect("could not read Huawei XMAGE sample entry")
                .path()
        })
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("heic"))
        })
        .collect();
    samples.sort();
    if samples.is_empty() {
        eprintln!(
            "no Huawei XMAGE HEIC samples found in {}; regression skipped",
            sample_dir.display()
        );
        return;
    }

    let mut versions = Vec::new();
    for sample in &samples {
        let report = xdremux_core::huawei_heic::inspect_path(sample)
            .unwrap_or_else(|error| panic!("{}: {error}", sample.display()));
        assert!(report.is_huawei_hdr, "not Huawei HDR: {}", sample.display());
        assert!(report.has_xtstyle, "missing xtstyle: {}", sample.display());
        versions.push(report.xtstyle_version);
    }
    assert!(
        versions.iter().any(|version| *version == Some(5)),
        "XMAGE corpus has no payload version 5: {versions:?}"
    );
    assert!(
        versions.iter().any(|version| *version == Some(6)),
        "XMAGE corpus has no payload version 6: {versions:?}"
    );
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
        apple_portrait: 0,
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

#[test]
#[ignore = "requires one private real HEIC sample; set XDREMUX_STYLES_SAMPLE and pass --ignored"]
fn converts_real_sample_to_photos_editable_styles() {
    let input = PathBuf::from(
        env::var(STYLES_SAMPLE_ENV)
            .unwrap_or_else(|_| panic!("set {STYLES_SAMPLE_ENV} to a source HEIC file")),
    );
    assert!(input.is_file(), "sample is not a file: {}", input.display());
    let output_dir = TempOutputDir::new().expect("could not create temporary output directory");
    let output = output_dir.path.join("styles-output.heic");
    let input_c = c_path(&input);
    let output_c = c_path(&output);
    let config = ConvertConfig {
        oppo_compat: 0,
        oppo_camera_tail: 0,
        strict_tmap: 0,
        apple_photographic_styles: 1,
        apple_portrait: 0,
    };

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
        "Styles conversion failed for {}: {}",
        input.display(),
        error.unwrap_or_else(|| "unknown error".into())
    );
    assert!(output.is_file(), "Styles conversion created no output");
    assert!(
        xdremux_verify_output(output_c.as_ptr()),
        "Styles output does not contain a valid ISO gain map"
    );
    assert!(
        xdremux_verify_styles_output(output_c.as_ptr()),
        "Styles output is missing a valid 51,840-byte styleData payload"
    );
}
