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
    if stem.starts_with("output_") || stem.starts_with("test_") {
        return false;
    }
    !["_py", "_final", "_oppo", "_out", "_normal", "_iso", "_apple_portrait"]
        .iter()
        .any(|suffix| stem.ends_with(suffix))
}

fn collect_heic_sources(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(current) = stack.pop() {
        if let Ok(entries) = fs::read_dir(&current) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    stack.push(p);
                } else if is_source_sample(&p) {
                    out.push(p);
                }
            }
        }
    }
    out.sort();
    out
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

                let still = &data[asset.still_range.start as usize..asset.still_range.end as usize];
                let (still_out, mov, content_id) = xdremux_core::live_photo::make_live_photo(
                    still,
                    &video[..clean_len],
                    asset.presentation_timestamp_us,
                    asset.vendor_metadata.as_ref(),
                ).expect("make_live_photo succeeds for Huawei motion photo");
                assert!(!content_id.is_empty());
                assert!(xdremux_core::live_photo::existing_pair_is_valid(&still_out, &mov));

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

    let samples = collect_heic_sources(&sample_dir);
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
        assert!(
            portrait.safe_to_transform,
            "Huawei portrait should route to the Apple portrait remux: {}",
            sample.display()
        );
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
fn remuxes_huawei_portrait_samples_when_available() {
    let Ok(sample_dir) = env::var(HUAWEI_PORTRAIT_SAMPLE_DIR_ENV) else {
        eprintln!("{HUAWEI_PORTRAIT_SAMPLE_DIR_ENV} is unset; Huawei Portrait remux skipped");
        return;
    };
    let sample_dir = PathBuf::from(sample_dir);
    if !sample_dir.is_dir() {
        eprintln!(
            "{HUAWEI_PORTRAIT_SAMPLE_DIR_ENV} is not a directory; Huawei Portrait remux skipped: {}",
            sample_dir.display()
        );
        return;
    }

    let samples = collect_heic_sources(&sample_dir);
    if samples.is_empty() {
        eprintln!("no samples found in {}; remux test skipped", sample_dir.display());
        return;
    }

    let mut tested = 0;
    for sample in &samples {
        let report = match xdremux_core::huawei_heic::inspect_path(sample) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if report.portrait.is_none() {
            continue;
        }
        let source_bytes = fs::read(sample).expect("read source");
        let remuxed = match xdremux_core::run_huawei_portrait(&source_bytes) {
            Ok(bytes) => bytes,
            Err(e) => panic!("{}: Huawei portrait remux failed: {e}", sample.display()),
        };
        if std::env::var("XDREMUX_WRITE_OUTPUTS").is_ok() {
            let stem = sample.file_stem().unwrap().to_str().unwrap();
            let out_name = format!("output_{stem}_apple_portrait.heic");
            let out_path = PathBuf::from(r"C:\tmp\huawei").join(out_name);
            let _ = fs::write(out_path, &remuxed);

            // Also generate base primary variant (for real-device comparison)
            std::env::set_var("XDREMUX_PORTRAIT_USE_BASE", "1");
            if let Ok(base_remuxed) = xdremux_core::run_huawei_portrait(&source_bytes) {
                let out_base_name = format!("output_{stem}_apple_portrait_base.heic");
                let out_base_path = PathBuf::from(r"C:\tmp\huawei").join(out_base_name);
                let _ = fs::write(out_base_path, &base_remuxed);
            }
            std::env::remove_var("XDREMUX_PORTRAIT_USE_BASE");
        }

        assert!(!remuxed.is_empty());
        let meta = xdremux_core::isobmff::parse_source_meta(&remuxed).expect("parse output meta");
        let edof_item = meta
            .items
            .iter()
            .find(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"edof"));
        if let Some(edof) = edof_item {
            assert_eq!(meta.primary_id, edof.item_id, "primary should be switched to edof");
        }
        let auxl = meta.refs.iter().find(|r| r.rtype == "auxl").expect("auxl reference present");
        assert!(auxl.to.contains(&meta.primary_id));
        for item in &meta.items {
            if item.itype == "mime" {
                if let Some(entry) = meta.iloc_entries.iter().find(|e| e.item_id == item.item_id) {
                    if let Some(&(off, len)) = entry.extents.first() {
                        let payload = &remuxed[off as usize..(off + len) as usize];
                        if payload.windows(12).any(|w| w == b"<stArea:unit") {
                            assert!(
                                !payload.windows(15).any(|w| w == b"<stArea:x>1536<"),
                                "focus coordinate was not normalized: {}",
                                sample.display()
                            );
                        }
                    }
                }
            }
        }

        // Verify portraiteffectsmatte item exists and contains non-trivial encoded matte
        let matte_prop_idx = meta.props.iter().position(|p| {
            p.raw.windows(20).any(|w| w == b"portraiteffectsmatte")
        }).map(|idx| meta.props[idx].index);
        assert!(matte_prop_idx.is_some(), "portraiteffectsmatte auxC property must exist");
        let matte_prop_idx = matte_prop_idx.unwrap();
        let matte_item = meta.items.iter().find(|i| {
            meta.ipma_entries.iter().any(|e| {
                e.item_id == i.item_id
                    && e.associations.iter().any(|(idx, _)| *idx == matte_prop_idx)
            })
        });
        assert!(matte_item.is_some(), "portraiteffectsmatte item must exist in portrait output");
        let matte_id = matte_item.unwrap().item_id;
        let entry = meta.iloc_entries.iter().find(|e| e.item_id == matte_id).expect("iloc for matte");
        let (_off, len) = entry.extents[0];
        assert!(len > 3000, "portraiteffectsmatte stream must contain non-empty person mask: len={len}");

        tested += 1;
    }
    assert!(tested > 0, "no Huawei Portrait sample was tested");
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

#[test]
fn inspect_apple_and_huawei_depth() {
    let apple_sample = PathBuf::from(r"C:\tmp\huawei\step2-samples\IMG_3716.HEIC");
    if apple_sample.is_file() {
        println!("\n=== Inspecting Apple Reference Sample: {} ===", apple_sample.display());
        let bytes = fs::read(&apple_sample).expect("read apple sample");
        let meta = xdremux_core::isobmff::parse_source_meta(&bytes).expect("parse meta");
        println!("Items count: {}", meta.items.len());
        for item in &meta.items {
            let name = String::from_utf8_lossy(&item.raw_infe);
            println!("  Item ID {}: type='{}', infe='{}'", item.item_id, item.itype, name);
        }
        for p in &meta.props {
            if p.ptype == "auxC" {
                let text = String::from_utf8_lossy(&p.raw);
                println!("    Prop index {} is auxC: '{}'", p.index, text);
            }
        }

        for r in &meta.refs {
            println!("  Ref type='{}' from={} to={:?}", r.rtype, r.from, r.to);
        }
    }

    let samples = [
        ("near keyboard", r"C:\tmp\huawei\phone-20260908-0012\IMG_20260908_001257.heic"),
        ("mid charger", r"C:\tmp\huawei\phone-20260908-0012\IMG_20260908_001259.heic"),
        ("far monitor", r"C:\tmp\huawei\phone-20260908-0012\IMG_20260908_001301.heic"),
        ("outdoor person/table", r"C:\tmp\huawei\portrait-motion-20260907\IMG_20260907_021118.heic"),
    ];
    for (label, path_str) in samples {
        let p = PathBuf::from(path_str);
        if !p.is_file() { continue; }
        let bytes = fs::read(&p).expect("read");
        let meta = xdremux_core::isobmff::parse_source_meta(&bytes).expect("meta");
        let rf_item = meta.items.iter().find(|i| i.itype == "mime" && i.raw_infe.windows(7).any(|w| w == b"RfDataB")).unwrap();
        let entry = meta.iloc_entries.iter().find(|e| e.item_id == rf_item.item_id).unwrap();
        let (off, len) = entry.extents[0];
        let payload = &bytes[off as usize..(off + len) as usize];
        let header = &payload[..64];
        let u16_at = |o: usize| -> u16 { u16::from_le_bytes([header[o], header[o + 1]]) };
        let mode_flags = u16_at(2);
        let dim_major = u16_at(24) as f64;
        let dim_minor = u16_at(26) as f64;
        let pos_major = u16_at(28) as f64;
        let pos_minor = u16_at(30) as f64;
        let raw_plane = &payload[64..64 + 1024 * 768];

        // Is portrait?
        let is_portrait = mode_flags != 0x2200;
        let (disp, ow, oh, fx, fy) = if is_portrait {
            // cw90
            let mut rotated = vec![0u8; 768 * 1024];
            for y in 0..768 {
                for x in 0..1024 {
                    let rx = 768 - 1 - y;
                    let ry = x;
                    rotated[ry * 768 + rx] = raw_plane[y * 1024 + x];
                }
            }
            (rotated, 768, 1024, pos_minor / dim_minor, pos_major / dim_major)
        } else {
            let r: Vec<u8> = raw_plane.iter().rev().copied().collect();
            (r, 1024, 768, (dim_major - pos_major) / dim_major, (dim_minor - pos_minor) / dim_minor)
        };

        let fx_px = (fx * ow as f64).clamp(0.0, (ow - 1) as f64) as usize;
        let fy_px = (fy * oh as f64).clamp(0.0, (oh - 1) as f64) as usize;
        let center_val = disp[fy_px * ow + fx_px];

        // 5x5 median around focus
        let mut win = Vec::new();
        for dy in -2i32..=2i32 {
            let y = (fy_px as i32 + dy).clamp(0, oh as i32 - 1) as usize;
            for dx in -2i32..=2i32 {
                let x = (fx_px as i32 + dx).clamp(0, ow as i32 - 1) as usize;
                win.push(disp[y * ow + x]);
            }
        }
        win.sort_unstable();
        let med_val = win[12];

        // Overall plane min, max, p5, p50, p95
        let mut sorted = disp.clone();
        sorted.sort_unstable();
        let p5 = sorted[sorted.len() * 5 / 100];
        let p50 = sorted[sorted.len() * 50 / 100];
        let p95 = sorted[sorted.len() * 95 / 100];
        let mut holes = 0usize;
        let mut spikes = 0usize;
        for y in 1..oh - 1 {
            for x in 1..ow - 1 {
                let c = disp[y * ow + x] as i32;
                let neighbors = [
                    disp[(y - 1) * ow + x] as i32,
                    disp[(y + 1) * ow + x] as i32,
                    disp[y * ow + (x - 1)] as i32,
                    disp[y * ow + (x + 1)] as i32,
                ];
                let min_nb = *neighbors.iter().min().unwrap();
                let max_nb = *neighbors.iter().max().unwrap();
                if c + 40 < min_nb { holes += 1; }
                if c - 40 > max_nb { spikes += 1; }
            }
        }
        println!("  Noise stats: holes (dropouts) = {}, spikes = {} (total pixels = {})", holes, spikes, ow * oh);
    }

    let p = PathBuf::from(r"C:\tmp\huawei\portrait-motion-20260907\IMG_20260907_021118.heic");
    if p.is_file() {
        let bytes = fs::read(&p).expect("read");
        let meta = xdremux_core::isobmff::parse_source_meta(&bytes).expect("meta");
        let base_grid = meta.items.iter().find(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"base")).unwrap();
        let edof_grid = meta.items.iter().find(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"edof")).unwrap();
        
        let base_tiles = meta.refs.iter().find(|r| r.rtype == "dimg" && r.from == base_grid.item_id).unwrap();
        let edof_tiles = meta.refs.iter().find(|r| r.rtype == "dimg" && r.from == edof_grid.item_id).unwrap();

        let get_item_len = |id: u32| -> u64 {
            meta.iloc_entries.iter().find(|e| e.item_id == id).and_then(|e| e.extents.first()).map(|&(_, l)| l).unwrap_or(0)
        };

        let base_tile_lens: Vec<u64> = base_tiles.to.iter().map(|&id| get_item_len(id)).collect();
        let edof_tile_lens: Vec<u64> = edof_tiles.to.iter().map(|&id| get_item_len(id)).collect();

        let base_total: u64 = base_tile_lens.iter().sum();
        let edof_total: u64 = edof_tile_lens.iter().sum();

        println!("\n=== Checking all samples for base and edof ===");
        for entry in fs::read_dir(r"C:\tmp\huawei").unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() {
                for sub in fs::read_dir(&path).unwrap() {
                    let sub = sub.unwrap();
                    let sp = sub.path();
                    if sp.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("heic")) {
                        if let Ok(b) = fs::read(&sp) {
                            if let Ok(m) = xdremux_core::isobmff::parse_source_meta(&b) {
                                let has_rf = m.items.iter().any(|i| i.itype == "mime" && i.raw_infe.windows(7).any(|w| w == b"RfDataB"));
                                if has_rf {
                                    let has_base = m.items.iter().any(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"base"));
                                    let has_edof = m.items.iter().any(|i| i.itype == "grid" && i.raw_infe.windows(4).any(|w| w == b"edof"));
                                    println!("  Sample {}: primary={}, has_base={}, has_edof={}", sp.file_name().unwrap().to_str().unwrap(), m.primary_id, has_base, has_edof);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}




