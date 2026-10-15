//! Check production conversion + hardware prepare, writing only to a NEW directory.
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, CString},
    path::PathBuf,
};

fn message(pointer: *const std::ffi::c_char) -> String {
    if pointer.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn main() -> Result<(), String> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let force_styles = args.iter().any(|a| a == "--styles");
    args.retain(|a| a != "--styles");
    if args.len() < 2 {
        return Err("usage: codec_regression <NEW-output-dir> <input>...".into());
    }
    let output = PathBuf::from(&args[0]);
    std::fs::create_dir(&output).map_err(|e| format!("output must be a new directory: {e}"))?;
    let output = output.canonicalize().map_err(|e| e.to_string())?;
    let mut config = xdremux_core::ConvertConfig {
        oppo_compat: 0,
        oppo_camera_tail: 0,
        strict_tmap: 1,
        apple_photographic_styles: 1,
        apple_portrait: 0,
    };
    let mut cases = Vec::new();
    for (index, input) in args.iter().skip(1).enumerate() {
        let source = std::fs::read(input).map_err(|e| e.to_string())?;
        // HEIC SDR fallback requires styles; real HDR JPEGs can be converted
        // independently. --styles also checks the separate Apple Styles gate.
        let real_hdr = xdremux_core::uhdr_jpeg::parse(&source)
            .ok()
            .flatten()
            .is_some_and(|info| {
                info.gainmap_jpeg != xdremux_core::uhdr_jpeg::IDENTITY_GAINMAP_JPEG
            });
        config.apple_photographic_styles = u8::from(force_styles || !real_hdr);
        let target = output.join(format!("case-{index:02}.heic"));
        let input_c = CString::new(input.as_str()).map_err(|e| e.to_string())?;
        let target_c = CString::new(target.to_str().ok_or("non-UTF8 output path")?)
            .map_err(|e| e.to_string())?;
        let mut case = json!({"input": input, "output": target, "sha256Before":hash(&source)});
        case["stylesRequested"] = json!(config.apple_photographic_styles != 0);
        let result = xdremux_core::xdremux_convert(input_c.as_ptr(), target_c.as_ptr(), &config);
        case["conversion"] = json!({"success":result.success, "error":message(result.error_message),
            "edrScale":result.edr_scale,"gainMapMax":result.gain_map_max});
        xdremux_core::xdremux_free_result(result);
        if target.exists() {
            let bytes = std::fs::read(&target).map_err(|e| e.to_string())?;
            case["outputBytes"] = json!(bytes.len());
            case["outputSha256"] = json!(hash(&bytes));
            match xdremux_core::iso_validate::validate_gain_map_structure(&bytes) {
                Ok(graph) => {
                    case["graphValid"] = json!(true);
                    let meta = xdremux_core::isobmff::parse_source_meta(&bytes)?;
                    let item = meta
                        .iloc_entries
                        .iter()
                        .find(|e| e.item_id == graph.tmap_item_id)
                        .ok_or("missing tmap extent")?;
                    let top = xdremux_core::isobmff::parse_boxes(&bytes, 0, bytes.len());
                    let mb = top
                        .iter()
                        .find(|b| &b.btype == b"meta")
                        .ok_or("missing meta box")?;
                    let children =
                        xdremux_core::isobmff::parse_boxes(&bytes, mb.data_start + 4, mb.data_end);
                    let base = match item.construction_method {
                        0 => 0,
                        1 => {
                            children
                                .iter()
                                .find(|b| &b.btype == b"idat")
                                .ok_or("missing idat")?
                                .data_start
                        }
                        _ => return Err("unsupported tmap construction".into()),
                    };
                    let mut payload = Vec::new();
                    for &(offset, length) in &item.extents {
                        let start = base
                            .checked_add(usize::try_from(offset).map_err(|_| "offset overflow")?)
                            .ok_or("offset overflow")?;
                        let end = start
                            .checked_add(usize::try_from(length).map_err(|_| "length overflow")?)
                            .ok_or("length overflow")?;
                        payload
                            .extend_from_slice(bytes.get(start..end).ok_or("invalid tmap extent")?);
                    }
                    case["tmapBytes"] = json!(payload.len());
                    case["tmapUseBaseColorSpace"] =
                        json!(payload.get(5).is_some_and(|flags| flags & 0x40 != 0));
                }
                Err(error) => {
                    case["graphValid"] = json!(false);
                    case["graphError"] = json!(error);
                }
            }
        }
        if source.starts_with(&[0xff, 0xd8]) {
            let prepared = xdremux_core::xdremux_prepare_tiles(input_c.as_ptr(), &config, 0);
            let mut value = json!({"success":prepared.success,"error":message(prepared.error_message),"tileCount":prepared.tile_count});
            if prepared.success && !prepared.opaque.is_null() {
                let context = unsafe {
                    &*prepared
                        .opaque
                        .cast::<xdremux_core::isobmff_write::PreparedOutput>()
                };
                value["useBaseColorSpace"] = json!(context.gainmap_use_base_color_space);
            }
            case["hardwarePrepare"] = value;
            xdremux_core::xdremux_free_prepared(prepared);
        }
        let after = std::fs::read(input).map_err(|e| e.to_string())?;
        case["sha256After"] = json!(hash(&after));
        case["sourceUnchanged"] = json!(source == after);
        println!("{case}");
        cases.push(case);
    }
    let report = json!({"nativeFeature":cfg!(feature="libheif-decoder"), "cases":cases});
    std::fs::write(
        output.join("report.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .map_err(|e| e.to_string())?;
    if cases.iter().any(|c| {
        c["conversion"]["success"] != true
            || c["graphValid"] != true
            || c["sourceUnchanged"] != true
            || (c.get("hardwarePrepare").is_some() && c["hardwarePrepare"]["success"] != true)
    }) {
        return Err("codec regression failed; inspect report.json".into());
    }
    Ok(())
}
