//! One-call conversion pipeline and output planning shared by every
//! front-end (plan: docs/plans/apple-native.md §4.2).
//!
//! Until now each UI (Dart, Swift, ArkTS) re-implemented the same policy
//! glue around the C ABI: map its config enums to `ConvertConfig` bytes,
//! call convert, verify the output (plus the Styles / Portrait structure
//! checks when those were requested), and for Photographic Styles 3 run the
//! two injection passes. [`run_pipeline`] does all of that from one JSON
//! config, and [`plan_output`] answers the pre-conversion questions
//! (capture-mode folder, Huawei admission, Motion Photo, output file name)
//! so the three apps stop drifting.
//!
//! The JSON config uses the Dart / Swift `ConversionConfig` keys verbatim:
//! `outputMode` ("oppo" | "apple"), `oppoCompatibility`, `oppoCameraTail`,
//! `strictTmap`, `applePhotographicStyles`, `applePhotographicStyles3`,
//! `applePortrait`, `fileNameSuffix`, `categorizeOutputByMode`. Missing keys
//! take the shared defaults.

use std::ffi::CString;

use serde_json::{json, Value};

use crate::ConvertConfig;

/// Parsed front-end config.
#[derive(Debug, Clone, PartialEq)]
pub struct PipelineConfig {
    pub apple_output: bool,
    pub oppo_compat: u8,
    pub oppo_camera_tail: u8,
    pub strict_tmap: bool,
    pub styles: bool,
    pub styles3: bool,
    pub portrait: bool,
    pub file_name_suffix: String,
    pub categorize_output_by_mode: bool,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            apple_output: false,
            oppo_compat: 2,        // "on"
            oppo_camera_tail: 255, // "automatic"
            strict_tmap: false,
            styles: false,
            styles3: false,
            portrait: false,
            file_name_suffix: "_iso".to_string(),
            categorize_output_by_mode: false,
        }
    }
}

/// `oppoCompatibility` names → `ConvertConfig.oppo_compat` (same table as
/// Dart `OppoCompatMode.rustValue` / Swift `OppoCompatMode.rustValue`).
fn oppo_compat_byte(name: &str) -> Result<u8, String> {
    Ok(match name {
        "off" => 0,
        "auto" => 1,
        "on" => 2,
        "tail" => 3,
        "iso" => 4,
        "isoNoLocal" => 5,
        "isoGraph" => 6,
        other => return Err(format!("unknown oppoCompatibility: {other}")),
    })
}

/// `oppoCameraTail` names → `ConvertConfig.oppo_camera_tail` (255 = let the
/// core choose).
fn oppo_camera_tail_byte(name: &str) -> Result<u8, String> {
    Ok(match name {
        "automatic" => 255,
        "off" => 0,
        "watermark" => 1,
        "compact" => 2,
        "preserve" => 3,
        "preserveWithoutPortrait" => 4,
        "preserveWithoutPortraitOrPrivateHdr" => 5,
        "preserveWithoutPrivateUhdr" => 6,
        "preserveWithoutPrivateHdr" => 7,
        "preserveNoUhdr" => 8,
        "preserveNoHdr" => 9,
        other => return Err(format!("unknown oppoCameraTail: {other}")),
    })
}

pub fn parse_config(config_json: &str) -> Result<PipelineConfig, String> {
    let v: Value = if config_json.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(config_json).map_err(|e| format!("config is not JSON: {e}"))?
    };
    let mut cfg = PipelineConfig::default();
    let s = |key: &str| v.get(key).and_then(Value::as_str);
    let b = |key: &str, default: bool| v.get(key).and_then(Value::as_bool).unwrap_or(default);
    match s("outputMode") {
        None | Some("oppo") => cfg.apple_output = false,
        Some("apple") => cfg.apple_output = true,
        Some(other) => return Err(format!("unknown outputMode: {other}")),
    }
    if let Some(name) = s("oppoCompatibility") {
        cfg.oppo_compat = oppo_compat_byte(name)?;
    }
    if let Some(name) = s("oppoCameraTail") {
        cfg.oppo_camera_tail = oppo_camera_tail_byte(name)?;
    }
    cfg.strict_tmap = b("strictTmap", false);
    cfg.styles = b("applePhotographicStyles", false);
    cfg.styles3 = b("applePhotographicStyles3", false);
    cfg.portrait = b("applePortrait", false);
    if let Some(suffix) = s("fileNameSuffix") {
        cfg.file_name_suffix = suffix.to_string();
    }
    cfg.categorize_output_by_mode = b("categorizeOutputByMode", false);
    Ok(cfg)
}

impl PipelineConfig {
    /// The bytes every front-end used to compute itself: Apple output turns
    /// OPPO compat and tail off and is the only mode where Styles / Portrait
    /// apply (Styles 3 implies Styles).
    pub fn convert_config(&self) -> ConvertConfig {
        if self.apple_output {
            ConvertConfig {
                oppo_compat: 0,
                oppo_camera_tail: 0,
                strict_tmap: self.strict_tmap as u8,
                apple_photographic_styles: (self.styles || self.styles3) as u8,
                apple_portrait: self.portrait as u8,
            }
        } else {
            ConvertConfig {
                oppo_compat: self.oppo_compat,
                oppo_camera_tail: self.oppo_camera_tail,
                strict_tmap: self.strict_tmap as u8,
                apple_photographic_styles: 0,
                apple_portrait: 0,
            }
        }
    }

    pub fn wants_styles(&self) -> bool {
        self.apple_output && (self.styles || self.styles3)
    }
    pub fn wants_styles3(&self) -> bool {
        self.apple_output && self.styles3
    }
    pub fn wants_portrait(&self) -> bool {
        self.apple_output && self.portrait
    }
}

/// Grain seed for the Styles 3 texture item: Dart's `_grainSeedFor` (Java
/// string hash over UTF-16 units, 31-bit mask) so the same file name gives
/// the same grain on every platform.
pub fn grain_seed(name: &str) -> u64 {
    let mut h: u64 = 0;
    for unit in name.encode_utf16() {
        h = (h.wrapping_mul(31).wrapping_add(unit as u64)) & 0x7fff_ffff;
    }
    h
}

fn file_name(path: &str) -> &str {
    std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
}

fn file_stem(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string()
}

/// Convert → verify → (Styles 3 post-process → verify again). `handle` is a
/// progress handle from `xdremux_progress_begin` (0 for none); cancellation
/// through `xdremux_progress_cancel` surfaces as `cancelled: true`.
pub fn run_pipeline(input: &str, output: &str, config_json: &str, handle: u32) -> Value {
    let cfg = match parse_config(config_json) {
        Ok(c) => c,
        Err(e) => return json!({ "success": false, "stage": "config", "errorMessage": e }),
    };
    let (c_in, c_out) = match (CString::new(input), CString::new(output)) {
        (Ok(a), Ok(b)) => (a, b),
        _ => {
            return json!({ "success": false, "stage": "config", "errorMessage": "path contains NUL" })
        }
    };
    let bytes = cfg.convert_config();
    let result =
        crate::xdremux_convert_with_progress(c_in.as_ptr(), c_out.as_ptr(), &bytes, handle);
    let take = |p: *mut std::os::raw::c_char| -> Option<String> {
        if p.is_null() {
            None
        } else {
            Some(
                unsafe { std::ffi::CStr::from_ptr(p) }
                    .to_string_lossy()
                    .into_owned(),
            )
        }
    };
    let success = result.success;
    let mode = take(result.mode);
    let family = take(result.family);
    let edr_scale = result.edr_scale;
    let gain_map_max = result.gain_map_max;
    let error = take(result.error_message);
    crate::xdremux_free_result(result);

    if !success {
        let cancelled = error.as_deref() == Some(crate::progress::CANCELLED_MESSAGE);
        return json!({
            "success": false, "stage": "convert", "cancelled": cancelled,
            "errorMessage": error, "mode": mode, "family": family,
        });
    }

    let mut data = match std::fs::read(output) {
        Ok(d) => d,
        Err(e) => {
            return json!({ "success": false, "stage": "verify", "outputValid": false,
                           "errorMessage": format!("core reported success but the output is unreadable: {e}") })
        }
    };
    let mut verified: Vec<&str> = Vec::new();
    let verify = |data: &[u8], verified: &mut Vec<&str>| -> Result<(), String> {
        if !crate::verify_iso_gain_map(data) {
            return Err("output failed the ISO gain-map structure check".into());
        }
        verified.push("iso");
        if cfg.wants_styles() {
            if !crate::verify_photographic_styles(data) {
                return Err("output is missing Apple Photographic Styles data".into());
            }
            verified.push("styles");
        }
        if cfg.wants_portrait() {
            if !crate::verify_portrait_graph(data) {
                return Err("output is missing Apple Portrait data".into());
            }
            verified.push("portrait");
        }
        Ok(())
    };
    if let Err(e) = verify(&data, &mut verified) {
        return json!({ "success": false, "stage": "verify", "outputValid": false, "errorMessage": e,
                       "mode": mode, "family": family, "edrScale": edr_scale, "gainMapMax": gain_map_max });
    }

    let mut styles3_applied = false;
    if cfg.wants_styles3() {
        let seed = grain_seed(file_name(input));
        let step = (|| -> Result<Vec<u8>, String> {
            let textured = crate::texture_styles::inject_texture_styles(&data, seed)
                .map_err(|e| format!("PS3 texture_styles injection failed: {e}"))?;
            crate::semantic_mattes::inject_semantic_mattes(&textured)
                .map_err(|e| format!("PS3 semantic matte injection failed: {e}"))
        })();
        match step {
            Ok(patched) => {
                if let Err(e) = std::fs::write(output, &patched) {
                    return json!({ "success": false, "stage": "styles3", "errorMessage": format!("write: {e}") });
                }
                data = patched;
                styles3_applied = true;
                verified.clear();
                if let Err(e) = verify(&data, &mut verified) {
                    return json!({ "success": false, "stage": "styles3", "outputValid": false,
                                   "errorMessage": format!("after PS3 post-process: {e}") });
                }
            }
            Err(e) => return json!({ "success": false, "stage": "styles3", "errorMessage": e }),
        }
    }

    json!({
        "success": true, "stage": "done", "cancelled": false,
        "mode": mode, "family": family, "edrScale": edr_scale, "gainMapMax": gain_map_max,
        "outputValid": true, "verified": verified, "styles3Applied": styles3_applied,
        "grainSeed": if styles3_applied { Some(grain_seed(file_name(input))) } else { None },
    })
}

/// Pre-conversion plan for one input: classification, Huawei admission,
/// Motion Photo flag, and the output file name. Read-only.
pub fn plan_output(input: &str, config_json: &str) -> Value {
    let cfg = match parse_config(config_json) {
        Ok(c) => c,
        Err(e) => return json!({ "success": false, "errorMessage": e }),
    };
    let data = match std::fs::read(input) {
        Ok(d) => d,
        Err(e) => {
            return json!({ "success": false, "errorMessage": format!("cannot read input: {e}") })
        }
    };
    let classification = crate::categorize::classify_bytes(&data);
    let (hdr_kind, family, convertible, convert_error) =
        match crate::extract_lhdr_or_uhdr_from_bytes(&data) {
            Ok(extracted) => {
                let fam = if extracted.mode == "uhdr"
                    || extracted
                        .meta_floats
                        .first()
                        .map(|v| *v >= 3.0)
                        .unwrap_or(false)
                {
                    "x7"
                } else {
                    "x6"
                };
                (
                    Some(extracted.mode.clone()),
                    Some(fam.to_string()),
                    true,
                    None,
                )
            }
            Err(e) => (None, None, false, Some(e)),
        };
    let is_heic = {
        let lower = input.to_ascii_lowercase();
        lower.ends_with(".heic") || lower.ends_with(".heif")
    };
    let huawei = if is_heic {
        let report = crate::huawei_heic::inspect_bytes(&data);
        let portrait_ready = report
            .portrait
            .as_ref()
            .is_some_and(|p| p.safe_to_transform);
        if report.is_huawei_hdr || portrait_ready {
            Some(
                json!({ "isHdr": report.is_huawei_hdr, "hasXtstyle": report.has_xtstyle, "portraitReady": portrait_ready }),
            )
        } else {
            None
        }
    } else {
        None
    };
    let huawei_hdr = huawei
        .as_ref()
        .and_then(|h| h["isHdr"].as_bool())
        .unwrap_or(false);
    let portrait_ready = huawei
        .as_ref()
        .and_then(|h| h["portraitReady"].as_bool())
        .unwrap_or(false);
    let motion = crate::motion_photo::parse_motion_photo(&data)
        .ok()
        .flatten()
        .is_some();
    // Same rule as Dart `HuaweiPhotoPolicy.admission` / Swift `HuaweiPhotoPolicy`.
    let admitted = !huawei_hdr || portrait_ready || cfg.styles || cfg.styles3 || motion;
    let policy_reason = if admitted {
        None
    } else {
        Some("华为 HDR 原生兼容 Apple 照片，无需转换")
    };

    let capture_folder = classification.mode.map(|m| m.folder_name());
    let output_mode_folder = if cfg.apple_output {
        "Apple 标准"
    } else {
        "OPPO 兼容"
    };
    let stem = file_stem(input);
    json!({
        "success": true,
        "inputName": file_name(input),
        "convertible": convertible,
        "convertError": convert_error,
        "classification": {
            "modeKey": classification.mode.map(|m| m.key()),
            "folderName": capture_folder,
            "status": classification.status.as_str(),
            "hdrKind": hdr_kind,
            "family": family,
        },
        "huawei": huawei,
        "isMotionPhoto": motion,
        "policy": { "admitted": admitted, "reason": policy_reason },
        "output": {
            "fileName": format!("{stem}{}.heic", cfg.file_name_suffix),
            // Dart groups by capture mode, Swift by output mode; both folders
            // are offered so each front-end keeps its layout.
            "captureModeFolder": if cfg.categorize_output_by_mode { capture_folder } else { None },
            "outputModeFolder": if cfg.categorize_output_by_mode { Some(output_mode_folder) } else { None },
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults_and_apple_gating() {
        let d = parse_config("").unwrap();
        assert_eq!(d, PipelineConfig::default());
        let b = d.convert_config();
        assert_eq!(
            (
                b.oppo_compat,
                b.oppo_camera_tail,
                b.apple_photographic_styles,
                b.apple_portrait
            ),
            (2, 255, 0, 0)
        );

        let a = parse_config(r#"{"outputMode":"apple","applePhotographicStyles3":true,"applePortrait":true,"oppoCompatibility":"tail"}"#).unwrap();
        let b = a.convert_config();
        assert_eq!(
            (
                b.oppo_compat,
                b.oppo_camera_tail,
                b.apple_photographic_styles,
                b.apple_portrait
            ),
            (0, 0, 1, 1)
        );
        assert!(a.wants_styles() && a.wants_styles3() && a.wants_portrait());

        let o = parse_config(r#"{"outputMode":"oppo","applePhotographicStyles":true,"oppoCompatibility":"isoGraph","oppoCameraTail":"preserveNoHdr","strictTmap":true}"#).unwrap();
        let b = o.convert_config();
        assert_eq!(
            (
                b.oppo_compat,
                b.oppo_camera_tail,
                b.strict_tmap,
                b.apple_photographic_styles
            ),
            (6, 9, 1, 0)
        );
        assert!(!o.wants_styles());

        assert!(parse_config(r#"{"outputMode":"both"}"#).is_err());
        assert!(parse_config(r#"{"oppoCompatibility":"maybe"}"#).is_err());
        assert!(parse_config("not json").is_err());
    }

    #[test]
    fn grain_seed_matches_dart() {
        assert_eq!(grain_seed("IMG0001.heic"), 1_130_307_681);
        assert_eq!(grain_seed(""), 0);
    }

    #[test]
    fn plan_and_pipeline_reject_missing_input() {
        let plan = plan_output("/nonexistent/x.heic", "{}");
        assert_eq!(plan["success"], false);
        let report = run_pipeline(
            "/nonexistent/x.heic",
            "/tmp/xdremux-pipeline-none.heic",
            "{}",
            0,
        );
        assert_eq!(report["success"], false);
        assert_eq!(report["stage"], "convert");
        assert_eq!(report["cancelled"], false);
    }

    #[test]
    fn plan_on_garbage_is_not_convertible() {
        let dir = std::env::temp_dir().join(format!("xdremux-plan-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("garbage.heic");
        std::fs::write(&path, vec![0u8; 4096]).unwrap();
        let plan = plan_output(
            path.to_str().unwrap(),
            r#"{"fileNameSuffix":"_hdr","categorizeOutputByMode":true,"outputMode":"apple"}"#,
        );
        assert_eq!(plan["success"], true);
        assert_eq!(plan["convertible"], false);
        assert_eq!(plan["policy"]["admitted"], true);
        assert_eq!(plan["output"]["fileName"], "garbage_hdr.heic");
        assert_eq!(plan["output"]["outputModeFolder"], "Apple 标准");
        assert!(plan["output"]["captureModeFolder"].is_null());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Opt-in: `XDREMUX_SAMPLE_DIR` with ProXDR HEICs → plan, then the full
    /// Apple + Styles 3 pipeline verifies its own output.
    #[test]
    fn local_samples_pipeline() {
        let Ok(dir) = std::env::var("XDREMUX_SAMPLE_DIR") else {
            return;
        };
        let Some(sample) = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .find(|p| {
                p.extension()
                    .and_then(|e| e.to_str())
                    .map(|e| e.eq_ignore_ascii_case("heic"))
                    .unwrap_or(false)
            })
        else {
            return;
        };
        let input = sample.to_str().unwrap();
        let plan = plan_output(input, "{}");
        assert_eq!(plan["success"], true, "{plan}");
        assert_eq!(plan["convertible"], true, "{plan}");
        assert!(plan["huawei"].is_null());
        assert_eq!(plan["policy"]["admitted"], true);

        let out_dir = std::env::temp_dir().join(format!("xdremux-pipeline-{}", std::process::id()));
        std::fs::create_dir_all(&out_dir).unwrap();
        let output = out_dir.join("styles3_iso.heic");
        let report = run_pipeline(
            input,
            output.to_str().unwrap(),
            r#"{"outputMode":"apple","applePhotographicStyles":true,"applePhotographicStyles3":true}"#,
            0,
        );
        assert_eq!(report["success"], true, "{report}");
        assert_eq!(report["styles3Applied"], true);
        assert_eq!(report["verified"], json!(["iso", "styles"]));
        let bytes = std::fs::read(&output).unwrap();
        assert!(crate::verify_photographic_styles(&bytes));
        let _ = std::fs::remove_dir_all(&out_dir);
    }
}
