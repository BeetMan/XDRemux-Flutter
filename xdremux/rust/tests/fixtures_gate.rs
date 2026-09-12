//! Strict real-fixture gate for the Motion Photo parser.
//!
//! Ported from upstream `Tests/validation/verify_python_motion_photo_fixtures.py`
//! (v1.4): 14 real-world Motion Photo inputs covering OPPO/ColorOS Live Photo,
//! Android Motion Photo V1, and Android HEIF Motion Photo V1.
//!
//! The fixtures are committed byte-for-byte in the upstream clone
//! (`../../XDRemux-upstream/fixtures`, 166 MB) with a SHA256SUMS identity
//! manifest. We do not duplicate them into this repository; the gate runs
//! against the local clone and is skipped with a notice when it is absent.
//! Override the location with `XDEREMUX_FIXTURES`.
//!
//! Run: cargo test -p xdremux-core --test fixtures_gate

use sha2::{Digest, Sha256};
use std::path::PathBuf;

use xdremux_core::motion_photo::{parse_motion_photo, primary_video_range, MotionPhotoAsset};
use xdremux_core::uhdr_jpeg;

struct FixtureSpec {
    filename: &'static str,
    sha256: &'static str,
    source_kind: &'static str,
    still_end: u64,
    video_start: u64,
    video_end: u64,
    presentation_timestamp_us: i64,
    expects_gain_map: bool,
    /// Only set for the dual-stream ColorOS 16 samples.
    primary_video_end: Option<u64>,
}

const FIXTURES: &[FixtureSpec] = &[
    FixtureSpec {
        filename: "IMG20250502131605.jpg",
        sha256: "83a4f9f3c978f541e1255bff3bd89cffe0da182aef5558c1d9d081c41f4cdb01",
        source_kind: "oppoLivePhoto",
        still_end: 5_212_915,
        video_start: 5_212_915,
        video_end: 15_165_684,
        presentation_timestamp_us: 1_469_600,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "IMG20250502131608.jpg",
        sha256: "3f5cc79c1cf26f18acf22522964e7b8e009bf35b36c4c509d7618b1fd7cd6707",
        source_kind: "oppoLivePhoto",
        still_end: 4_610_334,
        video_start: 4_610_334,
        video_end: 13_359_471,
        presentation_timestamp_us: 1_433_190,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "IMG20250819170327.jpg",
        sha256: "20afbcfb3f6fbcd7ea7b2ca306b8208dbfd10eaeb7a9fb91cf86a5a9b21c3920",
        source_kind: "oppoLivePhoto",
        still_end: 19_365_654,
        video_start: 19_365_654,
        video_end: 30_680_658,
        presentation_timestamp_us: 1_666_600,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "IMG20260710191114_ColorOS_16.jpg",
        sha256: "5b555b0fffcec9ffb64a082a0532822431b59fc0490b677cc557e9810b764e70",
        source_kind: "oppoLivePhoto",
        still_end: 6_809_684,
        video_start: 6_809_684,
        video_end: 24_929_781,
        presentation_timestamp_us: 1_533_287,
        expects_gain_map: true,
        primary_video_end: Some(23_211_122),
    },
    FixtureSpec {
        filename: "IMG20260801190843_ColorOS_16.jpg",
        sha256: "15c19972c3328da9c4bfb8ad9134f92764c6c51827853f8118d5d2d986e967ff",
        source_kind: "oppoLivePhoto",
        still_end: 13_591_436,
        video_start: 13_591_436,
        video_end: 29_199_130,
        presentation_timestamp_us: 1_298_732,
        expects_gain_map: true,
        primary_video_end: Some(27_234_826),
    },
    FixtureSpec {
        filename: "MVIMG_20260419_151324_2_3..jpg",
        sha256: "18f5d5b9243dec290626b446f6812d7bf41399bdc66d7feb794e562a9ffca4dc",
        source_kind: "androidMotionPhotoV1",
        still_end: 9_541_876,
        video_start: 9_541_876,
        video_end: 10_550_148,
        presentation_timestamp_us: 430_574,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "20260312_135625..jpg",
        sha256: "d95c3bfe772d681c3b7b4c33ab39f6a9da46517b3e88209fe263843dfa49cfa4",
        source_kind: "androidMotionPhotoV1",
        still_end: 2_689_001,
        video_start: 2_689_001,
        video_end: 6_842_570,
        presentation_timestamp_us: 1_573_888,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "20260312_135627..jpg",
        sha256: "c9e97669689fcc975f3d511cc15274b047c6b340d12c434fd04ceaa249bfee9b",
        source_kind: "androidMotionPhotoV1",
        still_end: 2_690_459,
        video_start: 2_690_459,
        video_end: 3_752_096,
        presentation_timestamp_us: 1_585_246,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "20260312_135609..heic",
        sha256: "06eb244bc69ae464bd7b0a60b769f4fc3429dc543451481f5331586a7536b8d0",
        source_kind: "androidHeifMotionPhotoV1",
        still_end: 1_232_154,
        video_start: 1_232_162,
        video_end: 5_181_667,
        presentation_timestamp_us: 1_540_401,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "20260312_135610..heic",
        sha256: "d33f502276f0d8e8a0f49c9f5674ed1728812f7432f355a5a3325007fc780f1f",
        source_kind: "androidHeifMotionPhotoV1",
        still_end: 1_217_171,
        video_start: 1_217_179,
        video_end: 5_586_957,
        presentation_timestamp_us: 2_518_658,
        expects_gain_map: true,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "IMG_20260620_160335..jpg",
        sha256: "f71104787d3ce236e5543a71cfc50f8208fd9acbaeef057178350dfbacecd277",
        source_kind: "androidMotionPhotoV1",
        still_end: 3_307_962,
        video_start: 3_307_962,
        video_end: 6_031_584,
        presentation_timestamp_us: 1_333_944,
        expects_gain_map: false,
        primary_video_end: None,
    },
    FixtureSpec {
        filename: "IMG_20260620_160410..jpg",
        sha256: "7a00f4a63b51abfde5d1a93bc08053b3f4f28222b2234212da030ab8ed12d321",
        source_kind: "androidMotionPhotoV1",
        still_end: 3_036_474,
        video_start: 3_036_474,
        video_end: 9_638_904,
        presentation_timestamp_us: 838_055,
        expects_gain_map: false,
        primary_video_end: None,
    },
];

fn fixtures_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("XDEREMUX_FIXTURES") {
        let p = PathBuf::from(dir);
        return p.is_dir().then_some(p);
    }
    // Default: the upstream clone next to this repository
    // (<repo>/xdremux/rust -> <playground>/XDRemux-upstream/fixtures).
    let candidates = [
        PathBuf::from("../../../XDRemux-upstream/fixtures"),
        PathBuf::from("../../XDRemux-upstream/fixtures"),
    ];
    candidates.into_iter().find(|p| p.is_dir())
}

/// Guard for fixture-gated tests: real photo fixtures live in the upstream
/// clone (166 MB, not committed here), so CI machines skip these tests with
/// a notice instead of failing. Machines with the clone still run the full
/// strict verification.
fn require_fixtures() -> Option<PathBuf> {
    match fixtures_dir() {
        Some(dir) => Some(dir),
        None => {
            eprintln!(
                "skipping: fixtures directory not found \
                 (default ../../../XDRemux-upstream/fixtures, override with XDEREMUX_FIXTURES)"
            );
            None
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    let digest = h.finalize();
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn load_fixture(spec: &FixtureSpec) -> (Vec<u8>, MotionPhotoAsset) {
    let dir = fixtures_dir().expect("fixtures directory must exist");
    let path = dir.join(spec.filename);
    let data = std::fs::read(&path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    assert_eq!(
        sha256_hex(&data),
        spec.sha256,
        "{}: bytes diverge from the upstream identity manifest",
        spec.filename
    );
    let asset = parse_motion_photo(&data)
        .unwrap_or_else(|e| panic!("{}: parse error: {e}", spec.filename))
        .unwrap_or_else(|| panic!("{}: not recognized as a motion photo", spec.filename));
    (data, asset)
}

fn assert_geometry(spec: &FixtureSpec, asset: &MotionPhotoAsset) {
    assert_eq!(
        asset.source_kind, spec.source_kind,
        "{}: source kind mismatch",
        spec.filename
    );
    assert_eq!(
        asset.still_range.end, spec.still_end,
        "{}: still end mismatch",
        spec.filename
    );
    assert_eq!(
        asset.video_range.start, spec.video_start,
        "{}: video start mismatch",
        spec.filename
    );
    assert_eq!(
        asset.video_range.end, spec.video_end,
        "{}: video end mismatch",
        spec.filename
    );
    assert_eq!(
        asset.presentation_timestamp_us,
        Some(spec.presentation_timestamp_us),
        "{}: presentation timestamp mismatch",
        spec.filename
    );
}

#[test]
fn fixtures_directory_present() {
    match fixtures_dir() {
        Some(dir) => println!("fixture gate running against {}", dir.display()),
        None => {
            eprintln!(
                "skipping fixture gate: fixtures directory not found \
                 (default ../../../XDRemux-upstream/fixtures, override with XDEREMUX_FIXTURES)"
            );
        }
    }
}

#[test]
fn reencoded_fixture_variants_are_byte_identical() {
    // Upstream ships R002_/R003_ re-encode variants whose bytes are identical
    // to the base HEIF fixtures (same SHA256 in the manifest). Guard against
    // upstream changing that assumption silently.
    let Some(dir) = require_fixtures() else { return };
    for (variant, base) in [
        ("R002_20260312_135609..heic", "20260312_135609..heic"),
        ("R003_20260312_135610..heic", "20260312_135610..heic"),
    ] {
        let v = std::fs::read(dir.join(variant)).unwrap();
        let b = std::fs::read(dir.join(base)).unwrap();
        assert_eq!(sha256_hex(&v), sha256_hex(&b), "{variant} != {base}");
    }
}

#[test]
fn oppo_live_photo_fixtures() {
    if require_fixtures().is_none() {
        return;
    }
    for spec in FIXTURES.iter().filter(|s| s.source_kind == "oppoLivePhoto") {
        let (data, asset) = load_fixture(spec);
        assert_geometry(spec, &asset);
        // Dual-stream ColorOS 16: the primary video range ends before the
        // second stream (the motion video proper stops early).
        if let Some(primary_end) = spec.primary_video_end {
            let primary = primary_video_range(&data, &asset);
            assert_eq!(
                primary.end, primary_end,
                "{}: primary video end mismatch",
                spec.filename
            );
        }
    }
}

#[test]
fn android_motion_photo_v1_fixtures() {
    if require_fixtures().is_none() {
        return;
    }
    for spec in FIXTURES
        .iter()
        .filter(|s| s.source_kind == "androidMotionPhotoV1")
    {
        let (_data, asset) = load_fixture(spec);
        assert_geometry(spec, &asset);
    }
}

#[test]
fn android_heif_motion_photo_fixtures() {
    if require_fixtures().is_none() {
        return;
    }
    for spec in FIXTURES
        .iter()
        .filter(|s| s.source_kind == "androidHeifMotionPhotoV1")
    {
        let (_data, asset) = load_fixture(spec);
        assert_geometry(spec, &asset);
    }
}

#[test]
fn jpeg_gain_map_presence_matches_spec() {
    let Some(dir) = require_fixtures() else { return };
    for spec in FIXTURES.iter().filter(|s| s.filename.ends_with(".jpg")) {
        let data = std::fs::read(dir.join(spec.filename)).unwrap();
        // uhdr_jpeg::parse returns Ok(None) when there is no MPF gain-map
        // second image — which is exactly the expects_gain_map=false signal.
        let has_gain_map = match uhdr_jpeg::parse(&data) {
            Ok(Some(info)) => !info.gainmap_jpeg.is_empty(),
            Ok(None) => false,
            Err(e) => panic!("{}: uhdr parse error: {e}", spec.filename),
        };
        assert_eq!(
            has_gain_map, spec.expects_gain_map,
            "{}: gain map presence mismatch",
            spec.filename
        );
    }
}
