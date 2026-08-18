//! XDRemux cross-platform conversion core.
//!
//! Exposes a small C FFI surface consumed by Flutter via `dart:ffi`.

pub mod categorize;
pub mod container;
pub mod edr;
pub mod exif;
pub mod gainmap;
pub mod hevc;
pub mod iso21496;
pub mod isobmff;
pub mod isobmff_write;
pub mod jpeg_decode;
pub mod progress;

// Apple Photographic Styles writer (R3c). This is intentionally kept as a
// separate native Rust path until the Photos conformance surface is stable.
mod styles_bplist;
mod styles_consts;
mod styles_graft;
mod styles_native;
mod styles_scaffold;

#[cfg(not(xdremux_ffmpeg_fallback))]
pub mod x265_ffi;

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use container::OppoCameraTail;
use exif::OppoCompat;
use isobmff_write::PreparedOutput;

/// Opaque result struct returned to Dart. Dart must call `xdremux_free_result`.
#[repr(C)]
pub struct ConversionResult {
    pub success: bool,
    pub mode: *mut c_char,
    pub family: *mut c_char,
    pub edr_scale: f64,
    pub gain_map_max: f64,
    pub error_message: *mut c_char,
}

/// Capture-mode result returned to Dart by `xdremux_classify`.
/// All string pointers are owned by Rust and must be released with
/// `xdremux_free_classification_result`.
#[repr(C)]
pub struct ClassificationResult {
    pub mode_key: *mut c_char,
    pub folder_name: *mut c_char,
    pub status: *mut c_char,
    pub raw_user_comment: *mut c_char,
    pub has_tag_flags: bool,
    pub tag_flags: u64,
    pub unknown_flags: u64,
    /// "lhdr" or "uhdr" (from the source container), or null if not a ProXDR file.
    pub hdr_kind: *mut c_char,
    /// "x6" or "x7" family, or null when unknown.
    pub family: *mut c_char,
}

/// Configuration for conversion.
///
/// Fields match the Swift `OppoCompatibility` enum:
/// - `oppo_compat`: 0=off, 1=auto, 2=on, 3=tail, 4=iso,
///   5=iso-no-local, 6=iso-graph
/// - `oppo_camera_tail`: 0=off through 9=preserve-no-hdr;
///   255 selects the compatibility-dependent default.
/// - `strict_tmap`: 0=ImageIO-compatible 62/142-byte payload, 1=strict
///   ISO 21496-1 65/145-byte payload.
/// - `apple_photographic_styles`: 1 generates the native Rust Styles graph.
#[repr(C)]
pub struct ConvertConfig {
    pub oppo_compat: u8,
    pub oppo_camera_tail: u8,
    pub strict_tmap: u8,
    pub apple_photographic_styles: u8,
}

// ---------------------------------------------------------------------------
// FFI: version
// ---------------------------------------------------------------------------

/// Returns an owned version string. Caller must free with `xdremux_free_string`.
#[no_mangle]
pub extern "C" fn xdremux_version() -> *mut c_char {
    match CString::new("0.3.0") {
        Ok(s) => s.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Frees a string previously returned by `xdremux_version`.
#[no_mangle]
pub extern "C" fn xdremux_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Read the current conversion progress tuple.
///
/// `buf` must point to 3 × u32 (12 bytes).  Returns (stage, current, total).
///
/// Stage: 0=idle, 1=extract, 2=decode, 3=encode tiles, 4=assemble.
/// Dart should poll this on a timer during conversion.
#[no_mangle]
pub extern "C" fn xdremux_read_progress(buf: *mut u32) {
    if buf.is_null() {
        return;
    }
    let (stage, current, total) = progress::read_progress();
    unsafe {
        *buf = stage;
        *buf.add(1) = current;
        *buf.add(2) = total;
    }
}

/// Read the progress tuple for a specific conversion handle.
///
/// `handle` must be the value from [xdremux_progress_begin] (or 0 for the
/// legacy most-recent view). `buf` must point to 3 × u32.
#[no_mangle]
pub extern "C" fn xdremux_read_progress_for(handle: u32, buf: *mut u32) {
    if buf.is_null() {
        return;
    }
    let (stage, current, total) = if handle == 0 {
        progress::read_progress()
    } else {
        progress::read_progress_for(handle).unwrap_or((0, 0, 0))
    };
    unsafe {
        *buf = stage;
        *buf.add(1) = current;
        *buf.add(2) = total;
    }
}

// ---------------------------------------------------------------------------
// FFI: capture-mode classification
// ---------------------------------------------------------------------------

fn ffi_string(value: Option<&str>) -> *mut c_char {
    value
        .and_then(|text| CString::new(text).ok())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

fn classification_result(
    classification: categorize::Classification,
    hdr_kind: Option<&str>,
    family: Option<&str>,
) -> ClassificationResult {
    let mode = classification.mode;
    ClassificationResult {
        mode_key: ffi_string(mode.map(|value| value.key())),
        folder_name: ffi_string(mode.map(|value| value.folder_name())),
        status: ffi_string(Some(classification.status.as_str())),
        raw_user_comment: ffi_string(classification.raw_user_comment.as_deref()),
        has_tag_flags: classification.tag_flags.is_some(),
        tag_flags: classification.tag_flags.unwrap_or(0),
        unknown_flags: classification.unknown_flags,
        hdr_kind: ffi_string(hdr_kind),
        family: ffi_string(family),
    }
}

/// Classify one image into an OPPO/OnePlus capture mode.
///
/// The result always contains a status. `mode_key` and `folder_name` are null
/// for unreadable, missing, malformed, or unknown-only UserComment metadata.
/// `hdr_kind` ("lhdr"/"uhdr") and `family` ("x6"/"x7") come from the source
/// container when it is a ProXDR HEIC.
#[no_mangle]
pub extern "C" fn xdremux_classify(input_path: *const c_char) -> ClassificationResult {
    let (path, data) = if input_path.is_null() {
        (String::new(), None)
    } else {
        unsafe { CStr::from_ptr(input_path) }
            .to_str()
            .map(|p| (p.to_string(), std::fs::read(p).ok()))
            .unwrap_or((String::new(), None))
    };
    let classification = if path.is_empty() {
        categorize::classify_path("")
    } else {
        categorize::classify_path(&path)
    };

    // Parse the container for LHDR/UHDR kind and x6/x7 family when readable.
    let (hdr_kind, family) = match data.as_deref() {
        Some(bytes) => match container::extract_lhdr_from_bytes(bytes) {
            Ok(extracted) => {
                let kind = Some(extracted.mode.clone());
                let fam = if extracted.mode == "uhdr" {
                    Some("x7".to_string())
                } else if extracted.meta_floats.first().map(|v| *v >= 3.0).unwrap_or(false) {
                    Some("x7".to_string())
                } else {
                    Some("x6".to_string())
                };
                (kind, fam)
            }
            Err(_) => (None, None),
        },
        None => (None, None),
    };
    classification_result(classification, hdr_kind.as_deref(), family.as_deref())
}

/// Free a `ClassificationResult` previously returned by `xdremux_classify`.
#[no_mangle]
pub extern "C" fn xdremux_free_classification_result(result: ClassificationResult) {
    for value in [
        result.mode_key,
        result.folder_name,
        result.status,
        result.raw_user_comment,
        result.hdr_kind,
        result.family,
    ] {
        if !value.is_null() {
            unsafe {
                drop(CString::from_raw(value));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: inspect
// ---------------------------------------------------------------------------

/// Inspect a ProXDR HEIC file and return parsed metadata.
#[no_mangle]
pub extern "C" fn xdremux_inspect(input_path: *const c_char) -> ConversionResult {
    let path = match unsafe { CStr::from_ptr(input_path) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            return ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new("input path is not valid UTF-8")
                    .unwrap()
                    .into_raw(),
            };
        }
    };

    if path.is_empty() {
        return ConversionResult {
            success: false,
            mode: ptr::null_mut(),
            family: ptr::null_mut(),
            edr_scale: 0.0,
            gain_map_max: 0.0,
            error_message: CString::new("empty input path").unwrap().into_raw(),
        };
    }

    match container::extract_lhdr(path) {
        Ok(extracted) => {
            let (edr_scale, gain_map_max) = if extracted.mode == "uhdr" {
                let scale = if extracted.meta_floats.len() >= 19 {
                    extracted.meta_floats[18]
                } else {
                    1.0
                };
                let ratio_max = if extracted.meta_floats.len() >= 7 {
                    extracted.meta_floats[4]
                        .max(extracted.meta_floats[5])
                        .max(extracted.meta_floats[6])
                } else {
                    1.0
                };
                let gm_max = if ratio_max > 0.0 {
                    ratio_max.log2()
                } else {
                    0.0
                };
                (scale as f64, gm_max as f64)
            } else {
                let edr = edr::edr_scale_calculator(&extracted.meta_floats);
                let gm_max = if edr > 1.0 { (edr as f64).log2() } else { 0.0 };
                (edr as f64, gm_max)
            };

            let family = if extracted.meta_floats[0] >= 3.0 || extracted.mode == "uhdr" {
                "x7"
            } else {
                "x6"
            };

            ConversionResult {
                success: true,
                mode: CString::new(extracted.mode.as_str()).unwrap().into_raw(),
                family: CString::new(family).unwrap().into_raw(),
                edr_scale,
                gain_map_max,
                error_message: ptr::null_mut(),
            }
        }
        Err(e) => ConversionResult {
            success: false,
            mode: ptr::null_mut(),
            family: ptr::null_mut(),
            edr_scale: 0.0,
            gain_map_max: 0.0,
            error_message: CString::new(e).unwrap().into_raw(),
        },
    }
}

// ---------------------------------------------------------------------------
// FFI: convert
// ---------------------------------------------------------------------------

/// Convert a single ProXDR HEIC file to ISO 21496-1 HDR HEIC.
///
/// `config` can be null (treated as clean ISO with its legacy tail policy).
/// Returns a [ConversionResult] that the caller must free.
/// Allocate a progress handle and bind it to the calling thread. The UI calls
/// this on the main isolate, passes the handle to the worker, then polls with
/// [xdremux_read_progress_for]. Release with [xdremux_progress_end].
#[no_mangle]
pub extern "C" fn xdremux_progress_begin() -> u32 {
    progress::begin_progress()
}

/// Release a progress handle allocated by [xdremux_progress_begin].
#[no_mangle]
pub extern "C" fn xdremux_progress_end(handle: u32) {
    progress::end_progress_with(handle);
}

#[no_mangle]
pub extern "C" fn xdremux_convert(
    input_path: *const c_char,
    output_path: *const c_char,
    config: *const ConvertConfig,
) -> ConversionResult {
    // Legacy path: own a progress slot for this thread so the plain
    // `xdremux_read_progress` view tracks this conversion.
    progress::begin_progress();
    let result = xdremux_convert_impl(input_path, output_path, config);
    progress::end_progress();
    result
}

/// Convert with a caller-supplied progress handle (from
/// [xdremux_progress_begin]). The handle is adopted for this thread's
/// duration; the caller keeps ownership and releases it after polling.
#[no_mangle]
pub extern "C" fn xdremux_convert_with_progress(
    input_path: *const c_char,
    output_path: *const c_char,
    config: *const ConvertConfig,
    handle: u32,
) -> ConversionResult {
    progress::begin_progress_with(handle);
    let result = xdremux_convert_impl(input_path, output_path, config);
    // Detach from this thread only; the caller releases the handle itself so
    // it can read the final stage after we return.
    progress::end_progress();
    result
}

fn xdremux_convert_impl(
    input_path: *const c_char,
    output_path: *const c_char,
    config: *const ConvertConfig,
) -> ConversionResult {
    let (oppo_compat, oppo_camera_tail, strict_tmap, apple_photographic_styles) = if config.is_null() {
        let oppo_compat = OppoCompat::Off;
        (
            oppo_compat,
            OppoCameraTail::default_for_compat(oppo_compat),
            false,
            false,
        )
    } else {
        let oppo_compat = OppoCompat::from_u8(unsafe { (*config).oppo_compat });
        let tail_value = unsafe { (*config).oppo_camera_tail };
        (
            oppo_compat,
            OppoCameraTail::resolve(tail_value, oppo_compat),
            unsafe { (*config).strict_tmap != 0 },
            unsafe { (*config).apple_photographic_styles != 0 },
        )
    };

    let input = match unsafe { CStr::from_ptr(input_path) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            return ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new("input path is not valid UTF-8")
                    .unwrap()
                    .into_raw(),
            };
        }
    };
    let output = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            return ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new("output path is not valid UTF-8")
                    .unwrap()
                    .into_raw(),
            };
        }
    };

    // Create the output parent directory before writing, matching Swift's
    // `ensureDirectory(parentURL)`. Without this, clearing the output folder
    // while the app keeps its path breaks every later conversion with
    // "write error: No such file or directory".
    if let Some(parent) = std::path::Path::new(output).parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return ConversionResult {
                    success: false,
                    mode: ptr::null_mut(),
                    family: ptr::null_mut(),
                    edr_scale: 0.0,
                    gain_map_max: 0.0,
                    error_message: CString::new(format!("cannot create output directory: {e}"))
                        .unwrap()
                        .into_raw(),
                };
            }
        }
    }

    // 1. Read source HEIC bytes before parsing. This permits a clear rejection
    // for already-lossy ISO inputs instead of attempting an invalid promotion.
    let source = match std::fs::read(input) {
        Ok(d) => d,
        Err(e) => {
            return ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new(format!("cannot read input: {e}"))
                    .unwrap()
                    .into_raw(),
            };
        }
    };

    if let Err(error) = reject_lossy_gainmap_promotion(&source, oppo_compat) {
        return ConversionResult {
            success: false,
            mode: ptr::null_mut(),
            family: ptr::null_mut(),
            edr_scale: 0.0,
            gain_map_max: 0.0,
            error_message: CString::new(error).unwrap().into_raw(),
        };
    }

    // 2. Extract source metadata from the already-read bytes.
    let extracted = match container::extract_lhdr_from_bytes(&source) {
        Ok(e) => e,
        Err(e) => {
            return ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new(e).unwrap().into_raw(),
            };
        }
    };

    let family = if extracted.meta_floats[0] >= 3.0 || extracted.mode == "uhdr" {
        "x7"
    } else {
        "x6"
    };

    // 3. Route to UHDR or LHDR path. Styles is a post-processor over the
    // normal Rust ISO output, so render the base into a private sibling file
    // first and publish the styled graph only after it succeeds.
    let standard_output = if apple_photographic_styles {
        format!("{output}.styles-base-{}.heic", std::process::id())
    } else {
        output.to_string()
    };
    let result = if extracted.mode == "uhdr" {
        convert_uhdr(
            &extracted,
            &source,
            &standard_output,
            oppo_compat,
            oppo_camera_tail,
            strict_tmap,
        )
    } else {
        convert_lhdr(
            &extracted,
            &source,
            &standard_output,
            oppo_compat,
            oppo_camera_tail,
            strict_tmap,
        )
    };

    match result {
        Ok((edr, gm_max)) => {
            if apple_photographic_styles {
                if let Err(error) = finalize_native_styles(&standard_output, output) {
                    let _ = std::fs::remove_file(&standard_output);
                    return ConversionResult {
                        success: false,
                        mode: ptr::null_mut(),
                        family: ptr::null_mut(),
                        edr_scale: 0.0,
                        gain_map_max: 0.0,
                        error_message: CString::new(error).unwrap().into_raw(),
                    };
                }
            }
            ConversionResult {
                success: true,
                mode: CString::new(extracted.mode.as_str()).unwrap().into_raw(),
                family: CString::new(family).unwrap().into_raw(),
                edr_scale: edr as f64,
                gain_map_max: gm_max as f64,
                error_message: ptr::null_mut(),
            }
        }
        Err(e) => {
            if apple_photographic_styles {
                let _ = std::fs::remove_file(&standard_output);
            }
            ConversionResult {
                success: false,
                mode: ptr::null_mut(),
                family: ptr::null_mut(),
                edr_scale: 0.0,
                gain_map_max: 0.0,
                error_message: CString::new(e).unwrap().into_raw(),
            }
        }
    }
}

fn finalize_native_styles(base_path: &str, output_path: &str) -> Result<(), String> {
    let base = std::fs::read(base_path)
        .map_err(|e| format!("read Rust Styles base output: {e}"))?;
    let styled = styles_native::styles_native(&base)
        .map_err(|e| format!("Rust Photographic Styles: {e}"))?;
    std::fs::write(output_path, styled)
        .map_err(|e| format!("write Rust Photographic Styles output: {e}"))?;
    std::fs::remove_file(base_path)
        .map_err(|e| format!("remove Styles base output: {e}"))?;
    Ok(())
}

fn reject_lossy_gainmap_promotion(source: &[u8], oppo_compat: OppoCompat) -> Result<(), String> {
    if should_reject_lossy_gainmap_promotion(
        isobmff::has_lossy_iso_gainmap_420(source),
        oppo_compat,
    ) {
        return Err(
            "cannot promote an existing 4:2:0 gain map to high-spec 4:4:4 because chroma information has already been discarded".into(),
        );
    }
    Ok(())
}

const fn should_reject_lossy_gainmap_promotion(
    has_lossy_gainmap: bool,
    oppo_compat: OppoCompat,
) -> bool {
    has_lossy_gainmap && !oppo_compat.wants_oppo_compat()
}

fn convert_lhdr(
    extracted: &container::ExtractedLhdr,
    source: &[u8],
    output: &str,
    oppo_compat: OppoCompat,
    oppo_camera_tail: OppoCameraTail,
    strict_tmap: bool,
) -> Result<(f32, f32), String> {
    progress::set_progress(1, 0, 0); // extract

    let edr = edr::edr_scale_calculator(&extracted.meta_floats);

    let mask_data = extracted
        .mask_data
        .as_ref()
        .ok_or_else(|| "no mask JPEG in extracted LHDR data".to_string())?;

    progress::set_progress(2, 0, 0); // decode JPEG
    let (mask_pixels, mask_w, mask_h) = jpeg_decode::decode_jpeg_to_gray(mask_data)
        .map_err(|e| format!("mask JPEG decode failed: {e}"))?;

    progress::set_progress(4, 1, 1); // assemble
    isobmff_write::write_lhdr_iso_output(
        source,
        &mask_pixels,
        mask_w,
        mask_h,
        &extracted.meta_floats,
        edr,
        oppo_compat,
        oppo_camera_tail,
        strict_tmap,
        output,
    )?;

    progress::set_progress(0, 0, 0); // done
    let gm_max = if edr > 1.0 { edr.log2() } else { 0.0 };
    Ok((edr, gm_max))
}

fn convert_uhdr(
    extracted: &container::ExtractedLhdr,
    source: &[u8],
    output: &str,
    oppo_compat: OppoCompat,
    oppo_camera_tail: OppoCameraTail,
    strict_tmap: bool,
) -> Result<(f32, f32), String> {
    progress::set_progress(1, 0, 0); // extract

    let gainmap_jpeg = extracted
        .gainmap_data
        .as_ref()
        .ok_or_else(|| "no gainmap JPEG in extracted UHDR data".to_string())?;

    progress::set_progress(2, 0, 0); // decode JPEG

    progress::set_progress(4, 1, 1); // assemble
    isobmff_write::write_uhdr_iso_output(
        source,
        gainmap_jpeg,
        &extracted.meta_floats,
        oppo_compat,
        oppo_camera_tail,
        strict_tmap,
        output,
    )?;

    progress::set_progress(0, 0, 0); // done
    let scale = if extracted.meta_floats.len() >= 19 {
        extracted.meta_floats[18]
    } else {
        1.0
    };
    let ratio_max = if extracted.meta_floats.len() >= 7 {
        extracted.meta_floats[4]
            .max(extracted.meta_floats[5])
            .max(extracted.meta_floats[6])
    } else {
        1.0
    };
    let gm_max = if ratio_max > 0.0 {
        ratio_max.log2()
    } else {
        0.0
    };
    Ok((scale, gm_max))
}

// ---------------------------------------------------------------------------
// FFI: hardware-encoding split (prepare → Dart encodes tiles → assemble)
// ---------------------------------------------------------------------------

/// Result of `xdremux_prepare_tiles`. All pointers are owned by Rust and must
/// be released with `xdremux_free_prepared`.
#[repr(C)]
pub struct PreparedTilesResult {
    pub success: bool,
    pub opaque: *mut std::os::raw::c_void,
    pub tile_data: *mut u8,
    pub tile_data_len: usize,
    pub tile_w: u32,
    pub tile_h: u32,
    pub tile_count: u32,
    pub error_message: *mut c_char,
}

/// `xdremux_convert_impl` internals reuse `progress::begin_progress` per-call.
/// These split helpers accept an explicit `handle` from the caller so the UI
/// can poll real per-tile progress across the Dart-side MediaCodec loop.
#[no_mangle]
pub extern "C" fn xdremux_prepare_tiles(
    input_path: *const c_char,
    config: *const ConvertConfig,
    handle: u32,
) -> PreparedTilesResult {
    let fail = PreparedTilesResult {
        success: false,
        opaque: ptr::null_mut(),
        tile_data: ptr::null_mut(),
        tile_data_len: 0,
        tile_w: 0,
        tile_h: 0,
        tile_count: 0,
        error_message: ptr::null_mut(),
    };
    let (oppo_compat, tail_policy, strict_tmap) = if config.is_null() {
        let c = OppoCompat::Off;
        (c, OppoCameraTail::default_for_compat(c), false)
    } else {
        let c = OppoCompat::from_u8(unsafe { (*config).oppo_compat });
        (
            c,
            OppoCameraTail::resolve(unsafe { (*config).oppo_camera_tail }, c),
            unsafe { (*config).strict_tmap != 0 },
        )
    };
    let input = match unsafe { CStr::from_ptr(input_path) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            return PreparedTilesResult { error_message: CString::new("input path is not valid UTF-8").unwrap().into_raw(), ..fail };
        }
    };

    if handle != 0 {
        progress::begin_progress_with(handle);
    }

    progress::set_progress(1, 0, 0); // extract

    let result = (|| -> Result<(PreparedOutput, Vec<u8>), String> {
        let source = std::fs::read(input).map_err(|e| format!("cannot read input: {e}"))?;
        let extracted = container::extract_lhdr_from_bytes(&source)
            .map_err(|e| e.to_string())?;
        if extracted.mode == "uhdr" {
            let gm = extracted.gainmap_data.as_ref().ok_or("no gainmap JPEG in UHDR data")?;
            progress::set_progress(2, 0, 0); // decode JPEG
            isobmff_write::prepare_uhdr_tiles(
                &source,
                gm,
                &extracted.meta_floats,
                oppo_compat,
                tail_policy,
                strict_tmap,
            )
        } else {
            let mask = extracted
                .mask_data
                .as_ref()
                .ok_or("no mask JPEG in extracted LHDR data")?;
            progress::set_progress(2, 0, 0); // decode JPEG
            let (mp, mw, mh) = jpeg_decode::decode_jpeg_to_gray(mask)
                .map_err(|e| format!("mask JPEG decode failed: {e}"))?;
            let edr = edr::edr_scale_calculator(&extracted.meta_floats);
            isobmff_write::prepare_lhdr_tiles(
                &source,
                &mp,
                mw,
                mh,
                &extracted.meta_floats,
                edr,
                oppo_compat,
                tail_policy,
                strict_tmap,
            )
        }
    })();

    if handle != 0 {
        progress::end_progress();
    }

    match result {
        Ok((prepared, yuv)) => {
            let tile_count = (prepared.rows * prepared.cols) as u32;
            let mut yuv_box = yuv.into_boxed_slice();
            let tile_data = yuv_box.as_mut_ptr();
            let tile_data_len = yuv_box.len();
            std::mem::forget(yuv_box);
            let opaque = Box::into_raw(Box::new(prepared)) as *mut std::os::raw::c_void;
            PreparedTilesResult {
                success: true,
                opaque,
                tile_data,
                tile_data_len,
                tile_w: 512,
                tile_h: 512,
                tile_count,
                error_message: ptr::null_mut(),
            }
        }
        Err(e) => PreparedTilesResult {
            error_message: CString::new(e).unwrap().into_raw(),
            ..fail
        },
    }
}

/// Free a `PreparedTilesResult` returned by `xdremux_prepare_tiles`.
#[no_mangle]
pub extern "C" fn xdremux_free_prepared(result: PreparedTilesResult) {
    if !result.tile_data.is_null() && result.tile_data_len > 0 {
        unsafe {
            let slice = std::slice::from_raw_parts_mut(result.tile_data, result.tile_data_len);
            drop(Box::from_raw(slice));
        }
    }
    if !result.opaque.is_null() {
        unsafe {
            drop(Box::from_raw(result.opaque as *mut PreparedOutput));
        }
    }
    if !result.error_message.is_null() {
        unsafe {
            drop(CString::from_raw(result.error_message));
        }
    }
}

/// Assemble the final HEIC from externally-encoded tile byte-streams.
///
/// `tile_streams` points to `tile_count` elements; each is a null-terminated
/// list of pointers to byte-stream HEVC NAL data with per-stream lengths in
/// `tile_lengths`. Returns a `ConversionResult` like `xdremux_convert`.
#[no_mangle]
pub extern "C" fn xdremux_assemble_tiles(
    opaque: *mut std::os::raw::c_void,
    tile_streams: *const *const c_char,
    tile_lengths: *const usize,
    tile_count: usize,
    output_path: *const c_char,
    handle: u32,
) -> ConversionResult {
    let fail = ConversionResult {
        success: false,
        mode: ptr::null_mut(),
        family: ptr::null_mut(),
        edr_scale: 0.0,
        gain_map_max: 0.0,
        error_message: ptr::null_mut(),
    };
    if opaque.is_null() || tile_streams.is_null() || tile_lengths.is_null() {
        return ConversionResult { error_message: CString::new("invalid prepared tiles handle").unwrap().into_raw(), ..fail };
    }
    let output = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            return ConversionResult { error_message: CString::new("output path is not valid UTF-8").unwrap().into_raw(), ..fail };
        }
    };

    // Collect the tile streams into owned Vec<u8> for the assembler.
    let mut streams: Vec<Vec<u8>> = Vec::with_capacity(tile_count);
    for i in 0..tile_count {
        let ptr = unsafe { *tile_streams.add(i) };
        let len = unsafe { *tile_lengths.add(i) };
        if ptr.is_null() {
            return ConversionResult { error_message: CString::new(format!("tile {i} stream is null")).unwrap().into_raw(), ..fail };
        }
        let slice = unsafe { std::slice::from_raw_parts(ptr as *const u8, len) };
        streams.push(slice.to_vec());
    }

    if handle != 0 {
        progress::begin_progress_with(handle);
    }

    let result = (|| -> Result<(f32, f32), String> {
        let prepared = unsafe { &*(opaque as *const PreparedOutput) };
        let refs: Vec<&[u8]> = streams.iter().map(|s| s.as_slice()).collect();
        isobmff_write::assemble_prepared_tiles(prepared, &refs, output)
    })();

    if handle != 0 {
        progress::end_progress();
    }

    match result {
        Ok((edr, gm_max)) => {
            let prepared = unsafe { &*(opaque as *const PreparedOutput) };
            ConversionResult {
                success: true,
                mode: CString::new(prepared.mode_key.as_str()).unwrap().into_raw(),
                family: CString::new(prepared.family.as_str()).unwrap().into_raw(),
                edr_scale: edr as f64,
                gain_map_max: gm_max as f64,
                error_message: ptr::null_mut(),
            }
        }
        Err(e) => ConversionResult {
            error_message: CString::new(e).unwrap().into_raw(),
            ..fail
        },
    }
}

/// Report per-tile encode progress into a handle from the Dart encoding loop.
#[no_mangle]
pub extern "C" fn xdremux_progress_report(handle: u32, current: u32, total: u32) {
    progress::set_progress_for(handle, 3, current, total);
}

// ---------------------------------------------------------------------------
// FFI: verify
// ---------------------------------------------------------------------------

/// Verifies an output file contains ISO gain-map auxiliary data.
///
/// Checks for:
/// 1. `auxC` property box with `urn:iso:std:iso:ts:21496:-1` in ipco
/// 2. `tmap` item type in iinf
/// 3. `auxl` reference in iref
///
/// All three must be present for the output to be considered valid ISO HDR.
#[no_mangle]
pub extern "C" fn xdremux_verify_output(path: *const c_char) -> bool {
    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    let data = match std::fs::read(path_str) {
        Ok(d) => d,
        Err(_) => return false,
    };

    verify_iso_gain_map(&data)
}

fn verify_iso_gain_map(data: &[u8]) -> bool {
    let top = isobmff::parse_boxes(data, 0, data.len());

    // Find meta box
    let meta = match top.iter().find(|b| &b.btype == b"meta") {
        Some(m) => m,
        None => return false,
    };

    let meta_kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);

    // 1. Check auxC in ipco
    let has_auxc = check_auxc_in_ipco(data, &meta_kids);

    // 2. Check tmap item in iinf
    let has_tmap = check_tmap_in_iinf(data, &meta_kids);

    // 3. Check tmap→primary dimg reference in iref (ISO gain map signal)
    let has_tmap_ref = check_tmap_dimg_in_iref(data, &meta_kids);

    has_auxc && has_tmap && has_tmap_ref
}

fn check_auxc_in_ipco(data: &[u8], meta_kids: &[isobmff::BoxHeader]) -> bool {
    let iprp = match meta_kids.iter().find(|b| &b.btype == b"iprp") {
        Some(b) => b,
        None => return false,
    };
    let iprp_kids = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end);
    let ipco = match iprp_kids.iter().find(|b| &b.btype == b"ipco") {
        Some(b) => b,
        None => return false,
    };

    // Scan for auxC box containing the ISO 21496-1 URN
    let ipco_boxes = isobmff::parse_boxes(data, ipco.data_start, ipco.data_end);
    for b in &ipco_boxes {
        if &b.btype == b"auxC" {
            let payload = &data[b.data_start..b.data_end];
            // auxC payload: 4-byte aux_type (0), then null-terminated URN
            // Check for the URN substring
            const URN: &[u8] = b"urn:iso:std:iso:ts:21496:-1";
            if payload.windows(URN.len()).any(|w| w == URN) {
                return true;
            }
        }
    }
    false
}

fn check_tmap_in_iinf(data: &[u8], meta_kids: &[isobmff::BoxHeader]) -> bool {
    let iinf = match meta_kids.iter().find(|b| &b.btype == b"iinf") {
        Some(b) => b,
        None => return false,
    };
    // Scan iinf payload for "tmap" type string in infe entries
    let iinf_data = &data[iinf.data_start..iinf.data_end];
    // infe entries contain the type string after item_ID and protection_index
    // Simple scan: look for "tmap" as a 4-byte string in the iinf payload
    iinf_data.windows(4).any(|w| w == b"tmap")
}

fn check_tmap_dimg_in_iref(data: &[u8], meta_kids: &[isobmff::BoxHeader]) -> bool {
    // Find tmap item ID from iinf
    let tmap_id = {
        let iinf = match meta_kids.iter().find(|b| &b.btype == b"iinf") {
            Some(b) => b,
            None => return false,
        };
        let items = match isobmff::parse_iinf(data, iinf) {
            Ok(items) => items,
            Err(_) => return false,
        };
        match items.iter().find(|it| it.itype == "tmap") {
            Some(it) => it.item_id,
            None => return false,
        }
    };

    let iref = match meta_kids.iter().find(|b| &b.btype == b"iref") {
        Some(b) => b,
        None => return false,
    };
    let (_, refs) = isobmff::parse_iref(data, iref);
    // Check that tmap has a dimg reference to at least one other item
    refs.iter()
        .any(|r| r.rtype == "dimg" && r.from == tmap_id && !r.to.is_empty())
}

// ---------------------------------------------------------------------------
// FFI: thumbnail extraction
// ---------------------------------------------------------------------------

/// Result of thumbnail extraction. Dart must call `xdremux_free_thumbnail`.
#[repr(C)]
pub struct ThumbnailResult {
    pub data: *mut u8,
    pub len: usize,
    pub success: bool,
}

/// Extract an embedded JPEG thumbnail from a HEIC file.
///
/// Strategy:
/// 1. Parse ISOBMFF → find `Exif` item → read EXIF blob from mdat
/// 2. Parse TIFF/EXIF → find JPEGInterchangeFormat (tag 0x0201) in IFD1
/// 3. Return the thumbnail JPEG bytes
///
/// Falls back to scanning the file for the first embedded JPEG if EXIF
/// thumbnail is not found.
#[no_mangle]
pub extern "C" fn xdremux_extract_thumbnail(path: *const c_char) -> ThumbnailResult {
    let fail = ThumbnailResult {
        data: ptr::null_mut(),
        len: 0,
        success: false,
    };

    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return fail,
    };

    let data = match std::fs::read(path_str) {
        Ok(d) => d,
        Err(_) => return fail,
    };

    // Try EXIF thumbnail first
    if let Some(jpeg) = extract_exif_thumbnail(&data) {
        return return_thumbnail(jpeg);
    }

    // Fallback: scan for any embedded JPEG (e.g. gain map preview)
    if let Some(jpeg) = find_first_jpeg(&data) {
        return return_thumbnail(jpeg);
    }

    fail
}

fn return_thumbnail(jpeg: Vec<u8>) -> ThumbnailResult {
    let len = jpeg.len();
    let mut boxed = jpeg.into_boxed_slice();
    let data = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    ThumbnailResult {
        data,
        len,
        success: true,
    }
}

/// Free a `ThumbnailResult` previously returned by `xdremux_extract_thumbnail`.
#[no_mangle]
pub extern "C" fn xdremux_free_thumbnail(result: ThumbnailResult) {
    if !result.data.is_null() && result.len > 0 {
        unsafe {
            let slice = std::slice::from_raw_parts_mut(result.data, result.len);
            drop(Box::from_raw(slice));
        }
    }
}

/// Extract JPEG thumbnail from EXIF data embedded in a HEIC container.
fn extract_exif_thumbnail(data: &[u8]) -> Option<Vec<u8>> {
    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta = top.iter().find(|b| &b.btype == b"meta")?;
    let meta_kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);

    let iinf = meta_kids.iter().find(|b| &b.btype == b"iinf")?;
    let iloc = meta_kids.iter().find(|b| &b.btype == b"iloc")?;

    let items = isobmff::parse_iinf(data, iinf).ok()?;
    let iloc_entries = isobmff::parse_iloc(data, iloc).ok()?;

    // Find the Exif item
    let exif_item = items.iter().find(|it| it.itype == "Exif")?;
    let exif_id = exif_item.item_id;

    // Get its data location from iloc
    let iloc_entry = iloc_entries.iter().find(|e| e.item_id == exif_id)?;
    let (offset, length) = iloc_entry.extents.first()?;
    let start = *offset as usize;
    let end = start + *length as usize;
    if end > data.len() {
        return None;
    }

    let exif_blob = &data[start..end];

    // HEIC Exif item: first 4 bytes = offset to TIFF header (usually 0 or 6)
    if exif_blob.len() < 8 {
        return None;
    }
    let tiff_offset =
        u32::from_be_bytes([exif_blob[0], exif_blob[1], exif_blob[2], exif_blob[3]]) as usize;
    if tiff_offset + 8 > exif_blob.len() {
        return None;
    }
    let tiff = &exif_blob[tiff_offset..];

    // Parse TIFF header
    let little_endian = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };

    let read_u16 = |buf: &[u8], pos: usize| -> u16 {
        if pos + 2 > buf.len() {
            return 0;
        }
        if little_endian {
            u16::from_le_bytes([buf[pos], buf[pos + 1]])
        } else {
            u16::from_be_bytes([buf[pos], buf[pos + 1]])
        }
    };
    let read_u32 = |buf: &[u8], pos: usize| -> u32 {
        if pos + 4 > buf.len() {
            return 0;
        }
        if little_endian {
            u32::from_le_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]])
        } else {
            u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]])
        }
    };

    // Verify TIFF magic (42)
    if read_u16(tiff, 2) != 42 {
        return None;
    }

    // Walk IFD chain: IFD0 → next IFD (IFD1 = thumbnail)
    let ifd0_offset = read_u32(tiff, 4) as usize;
    if ifd0_offset == 0 || ifd0_offset + 2 > tiff.len() {
        return None;
    }

    // Find next IFD pointer at end of IFD0
    let entry_count = read_u16(tiff, ifd0_offset) as usize;
    let next_ifd_pos = ifd0_offset + 2 + entry_count * 12;
    if next_ifd_pos + 4 > tiff.len() {
        return None;
    }
    let ifd1_offset = read_u32(tiff, next_ifd_pos) as usize;
    if ifd1_offset == 0 || ifd1_offset + 2 > tiff.len() {
        return None;
    }

    // Parse IFD1 for JPEGInterchangeFormat (0x0201) and JPEGInterchangeFormatLength (0x0202)
    let ifd1_count = read_u16(tiff, ifd1_offset) as usize;
    let mut thumb_offset: Option<u32> = None;
    let mut thumb_length: Option<u32> = None;

    for i in 0..ifd1_count {
        let entry_pos = ifd1_offset + 2 + i * 12;
        if entry_pos + 12 > tiff.len() {
            break;
        }
        let tag = read_u16(tiff, entry_pos);
        let value = read_u32(tiff, entry_pos + 8);
        match tag {
            0x0201 => thumb_offset = Some(value),
            0x0202 => thumb_length = Some(value),
            _ => {}
        }
    }

    let (t_off, t_len) = match (thumb_offset, thumb_length) {
        (Some(o), Some(l)) if o > 0 && l > 0 => (o as usize, l as usize),
        _ => return None,
    };

    if t_off + t_len > tiff.len() {
        return None;
    }

    let jpeg = &tiff[t_off..t_off + t_len];
    // Verify JPEG SOI marker
    if jpeg.len() >= 2 && jpeg[0] == 0xFF && jpeg[1] == 0xD8 {
        Some(jpeg.to_vec())
    } else {
        None
    }
}

/// Scan raw bytes for the first complete JPEG blob.
fn find_first_jpeg(data: &[u8]) -> Option<Vec<u8>> {
    let soi = b"\xff\xd8\xff";
    let mut pos = 0;
    while pos + 3 < data.len() {
        if let Some(hit) = data[pos..].windows(3).position(|w| w == soi) {
            let start = pos + hit;
            // Find EOI
            if let Some(eoi) = data[start + 3..].windows(2).position(|w| w == b"\xff\xd9") {
                let end = start + 3 + eoi + 2;
                let blob = &data[start..end];
                // Only accept reasonably-sized thumbnails (>1KB, <2MB)
                if blob.len() > 1024 && blob.len() < 2 * 1024 * 1024 {
                    return Some(blob.to_vec());
                }
            }
            pos = start + 3;
        } else {
            break;
        }
    }
    None
}

// ---------------------------------------------------------------------------
// FFI: free
// ---------------------------------------------------------------------------

/// Frees a `ConversionResult` previously returned by this library.
#[no_mangle]
pub extern "C" fn xdremux_free_result(result: ConversionResult) {
    if !result.mode.is_null() {
        unsafe {
            drop(CString::from_raw(result.mode));
        }
    }
    if !result.family.is_null() {
        unsafe {
            drop(CString::from_raw(result.family));
        }
    }
    if !result.error_message.is_null() {
        unsafe {
            drop(CString::from_raw(result.error_message));
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lossy_gainmap_promotion_is_rejected_only_for_clean_iso_output() {
        assert!(should_reject_lossy_gainmap_promotion(true, OppoCompat::Off));
        assert!(!should_reject_lossy_gainmap_promotion(
            false,
            OppoCompat::Off
        ));
        assert!(!should_reject_lossy_gainmap_promotion(
            true,
            OppoCompat::Auto
        ));
        assert!(!should_reject_lossy_gainmap_promotion(true, OppoCompat::On));
        assert!(!should_reject_lossy_gainmap_promotion(
            true,
            OppoCompat::Iso
        ));
    }

    #[test]
    fn version_returns_non_null() {
        let v = xdremux_version();
        assert!(!v.is_null());
        xdremux_free_string(v);
    }

    #[test]
    fn inspect_rejects_empty() {
        let empty = CString::new("").unwrap();
        let res = xdremux_inspect(empty.as_ptr());
        assert!(!res.success);
        xdremux_free_result(res);
    }

    #[test]
    fn inspect_rejects_nonexistent_file() {
        let path = CString::new("nonexistent_file_12345.heic").unwrap();
        let res = xdremux_inspect(path.as_ptr());
        assert!(!res.success);
        xdremux_free_result(res);
    }

    #[test]
    fn classify_nonexistent_returns_unreadable_status() {
        let path = CString::new("nonexistent_classify_test.heic").unwrap();
        let result = xdremux_classify(path.as_ptr());
        assert_eq!(
            unsafe { CStr::from_ptr(result.status) }.to_str().unwrap(),
            "unreadable-image"
        );
        assert!(result.mode_key.is_null());
        xdremux_free_classification_result(result);
    }

    #[test]
    fn classify_ffi_returns_mode_key_and_folder_name() {
        let path =
            std::env::temp_dir().join(format!("xdremux_classify_ffi_{}.heic", std::process::id()));
        std::fs::write(&path, b"metadata Oplus_16").unwrap();
        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let result = xdremux_classify(path_c.as_ptr());
        assert_eq!(
            unsafe { CStr::from_ptr(result.mode_key) }.to_str().unwrap(),
            "portrait"
        );
        assert_eq!(
            unsafe { CStr::from_ptr(result.folder_name) }
                .to_str()
                .unwrap(),
            "人像"
        );
        assert!(result.has_tag_flags);
        assert_eq!(result.tag_flags, 16);
        xdremux_free_classification_result(result);
        std::fs::remove_file(path).unwrap();
    }

    /// Diagnostic: dump source and output ISOBMFF structures for comparison.
    #[test]
    #[ignore = "local diagnostic; set XDREMUX_DIAGNOSTIC_SOURCE and XDREMUX_DIAGNOSTIC_OUTPUT"]
    fn dump_diagnostics() {
        let input_path = std::env::var("XDREMUX_DIAGNOSTIC_SOURCE")
            .expect("set XDREMUX_DIAGNOSTIC_SOURCE to a source HEIC path");
        let output_path = std::env::var("XDREMUX_DIAGNOSTIC_OUTPUT")
            .expect("set XDREMUX_DIAGNOSTIC_OUTPUT to a converted HEIC path");

        let src = std::fs::read(&input_path).unwrap();
        let out = std::fs::read(&output_path).unwrap();

        fn dump(name: &str, data: &[u8]) {
            fn btype_str(b: &[u8; 4]) -> String {
                String::from_utf8_lossy(b).to_string()
            }

            let top = isobmff::parse_boxes(data, 0, data.len());
            eprintln!("\n===== {name} =====");
            eprintln!(
                "Top: {:?}",
                top.iter().map(|b| btype_str(&b.btype)).collect::<Vec<_>>()
            );

            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            eprintln!(
                "Meta kids: {:?}",
                kids.iter().map(|b| btype_str(&b.btype)).collect::<Vec<_>>()
            );

            if let Some(pitm) = kids.iter().find(|b| &b.btype == b"pitm") {
                eprintln!("pitm primary: {}", isobmff::parse_pitm(data, pitm));
            }
            if let Some(iinf) = kids.iter().find(|b| &b.btype == b"iinf") {
                let items = isobmff::parse_iinf(data, iinf).unwrap();
                let max_id = items.iter().map(|i| i.item_id).max().unwrap_or(0);
                eprintln!(
                    "iinf v{}: {} items, max_id={}",
                    data[iinf.data_start],
                    items.len(),
                    max_id
                );
                for it in &items {
                    eprintln!("  id={} type={} flags={}", it.item_id, it.itype, it.flags);
                }
            }
            if let Some(iloc) = kids.iter().find(|b| &b.btype == b"iloc") {
                let entries = isobmff::parse_iloc(data, iloc).unwrap();
                eprintln!("iloc v{}: {} entries", data[iloc.data_start], entries.len());
                let mut entry_strs: Vec<String> = entries
                    .iter()
                    .map(|e| {
                        let ext_strs: Vec<String> = e
                            .extents
                            .iter()
                            .map(|(o, l)| format!("({}+{})", o, l))
                            .collect();
                        format!(
                            "id={} cm={} dr={} ext=[{}]",
                            e.item_id,
                            e.construction_method,
                            e.data_reference_index,
                            ext_strs.join(",")
                        )
                    })
                    .collect();
                entry_strs.sort_by_key(|s| s.split_whitespace().next().unwrap_or("").to_string());
                for s in &entry_strs {
                    eprintln!("  {}", s);
                }
            }
            if let Some(iref) = kids.iter().find(|b| &b.btype == b"iref") {
                let (ver, refs) = isobmff::parse_iref(data, iref);
                eprintln!("iref v{}: {} refs", ver, refs.len());
                for r in &refs {
                    let to_s: Vec<String> = r.to.iter().map(|x| x.to_string()).collect();
                    eprintln!("  {} {} -> [{}]", r.rtype, r.from, to_s.join(","));
                }
            }
            if let Some(iprp) = kids.iter().find(|b| &b.btype == b"iprp") {
                let props = isobmff::parse_iprp_properties(data, iprp).unwrap();
                eprintln!("ipco: {} props", props.len());
                for p in &props {
                    let btype = std::str::from_utf8(&p.raw[4..8]).unwrap_or("?");
                    eprintln!("  [{}] {} ({}B)", p.index, p.ptype, p.raw.len());
                    if btype == "colr" && p.raw.len() >= 16 {
                        eprintln!(
                            "       nclx: prim={} tf={} matrix={}",
                            p.raw[12], p.raw[13], p.raw[14]
                        );
                    }
                    if btype == "pixi" && p.raw.len() >= 15 {
                        eprintln!("       bits: {:?}", &p.raw[12..15]);
                    }
                    if btype == "ispe" && p.raw.len() >= 16 {
                        let w = isobmff::read_u32be(&p.raw, 12);
                        let h = isobmff::read_u32be(&p.raw, 16);
                        eprintln!("       size: {}x{}", w, h);
                    }
                }
                let iprp_kids = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end);
                if let Some(ipma) = iprp_kids.iter().find(|b| &b.btype == b"ipma") {
                    let (flags, entries) = isobmff::parse_ipma(data, ipma);
                    eprintln!("ipma: flags={} large={}", flags, (flags & 1) != 0);
                    for e in &entries {
                        let a: Vec<String> = e
                            .associations
                            .iter()
                            .map(|(i, ess)| format!("{}{}", i, if *ess { "!" } else { "" }))
                            .collect();
                        eprintln!("  id={}: [{}]", e.item_id, a.join(","));
                    }
                }
            }
            // Find mdat
            for b in &top {
                if &b.btype == b"mdat" {
                    eprintln!("mdat: @{} size={}", b.box_start, b.size);
                }
            }
        }

        dump("SOURCE", &src);
        dump("OUTPUT", &out);
    }

    /// Side-by-side comparison of tmap, XMP, and colr between PY and RUST outputs.
    #[test]
    #[ignore = "local diagnostic; set XDREMUX_DIAGNOSTIC_PY_OUTPUT and XDREMUX_DIAGNOSTIC_RUST_OUTPUT"]
    fn compare_py_rust_payloads() {
        let py_path = std::env::var("XDREMUX_DIAGNOSTIC_PY_OUTPUT")
            .expect("set XDREMUX_DIAGNOSTIC_PY_OUTPUT to a Python-converted HEIC path");
        let rust_path = std::env::var("XDREMUX_DIAGNOSTIC_RUST_OUTPUT")
            .expect("set XDREMUX_DIAGNOSTIC_RUST_OUTPUT to a Rust-converted HEIC path");

        let py_data = std::fs::read(&py_path).unwrap();
        let rust_data = std::fs::read(&rust_path).unwrap();

        fn hex(data: &[u8]) -> String {
            data.iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join("")
        }

        // Use iloc + iinf to find exact tmap/xmp offsets in idat
        fn find_payloads(data: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);

            let idat_box = kids.iter().find(|b| &b.btype == b"idat").unwrap();
            let idat = data[idat_box.data_start..idat_box.data_end].to_vec();

            let iinf = kids.iter().find(|b| &b.btype == b"iinf").unwrap();
            let iloc = kids.iter().find(|b| &b.btype == b"iloc").unwrap();

            let items = isobmff::parse_iinf(data, iinf).unwrap();
            let entries = isobmff::parse_iloc(data, iloc).unwrap();

            let find_item = |itype: &str| -> u32 {
                items
                    .iter()
                    .find(|i| i.itype == itype)
                    .map(|i| i.item_id)
                    .unwrap_or(0)
            };
            let find_extent = |item_id: u32| -> (usize, usize) {
                entries
                    .iter()
                    .find(|e| e.item_id == item_id)
                    .and_then(|e| e.extents.first())
                    .map(|&(off, len)| (off as usize, len as usize))
                    .unwrap_or((0, 0))
            };

            let tmap_id = find_item("tmap");
            let xmp_id = find_item("mime");
            let grid_id = find_item("grid");

            let (tmap_off, tmap_len) = find_extent(tmap_id);
            let (xmp_off, xmp_len) = find_extent(xmp_id);
            let (_grid_off, _grid_len) = find_extent(grid_id);

            let tmap = idat[tmap_off..tmap_off + tmap_len].to_vec();
            let xmp = idat[xmp_off..xmp_off + xmp_len].to_vec();

            eprintln!(
                "  idat={}B tmap@{} len={} xmp@{} len={} grid@{} len={}",
                idat.len(),
                tmap_off,
                tmap_len,
                xmp_off,
                xmp_len,
                _grid_off,
                _grid_len
            );

            (idat, tmap, xmp)
        }

        eprintln!("\n===== IDAT COMPARISON =====");
        eprintln!("PY:");
        let (_py_idat, py_tmap, py_xmp) = find_payloads(&py_data);
        eprintln!("RUST:");
        let (_rust_idat, rust_tmap, rust_xmp) = find_payloads(&rust_data);

        eprintln!("\n--- tmap ---");
        eprintln!("PY  : {}B {}", py_tmap.len(), hex(&py_tmap));
        eprintln!("RUST: {}B {}", rust_tmap.len(), hex(&rust_tmap));
        eprintln!("Match: {}", py_tmap == rust_tmap);

        let tmap_i32 = |data: &[u8]| -> Vec<i32> {
            (0..data.len())
                .step_by(4)
                .take(data.len() / 4)
                .map(|i| i32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]))
                .collect()
        };
        eprintln!("PY  tmap i32: {:?}", tmap_i32(&py_tmap));
        eprintln!("RUST tmap i32: {:?}", tmap_i32(&rust_tmap));

        eprintln!("\n--- XMP ---");
        eprintln!(
            "PY  XMP ({}B): {}",
            py_xmp.len(),
            String::from_utf8_lossy(&py_xmp)
        );
        eprintln!(
            "RUST XMP ({}B): {}",
            rust_xmp.len(),
            String::from_utf8_lossy(&rust_xmp)
        );
        eprintln!("XMP Match: {}", py_xmp == rust_xmp);

        // Compare colr nclx boxes
        let find_colr_nclx = |data: &[u8], label: &str| {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            let iprp = kids.iter().find(|b| &b.btype == b"iprp").unwrap();
            let props = isobmff::parse_iprp_properties(data, iprp).unwrap();
            for p in &props {
                if p.ptype == "colr" && p.raw.len() >= 16 {
                    let ct = std::str::from_utf8(&p.raw[8..12]).unwrap_or("?");
                    if ct == "nclx" {
                        eprintln!(
                            "{label} colr nclx [{}]: prim={} tf={} matrix={} full_range={}",
                            p.index,
                            p.raw[12],
                            p.raw[13],
                            p.raw[14],
                            p.raw[15] & 0x80 != 0
                        );
                        eprintln!("{label}   raw: {}", hex(&p.raw));
                    }
                }
            }
        };

        eprintln!("\n--- COLR NCLX ---");
        find_colr_nclx(&py_data, "PY");
        find_colr_nclx(&rust_data, "RUST");

        // Compare hvcC for gain map tiles
        let find_hvcc = |data: &[u8], label: &str| {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            let iprp = kids.iter().find(|b| &b.btype == b"iprp").unwrap();
            let props = isobmff::parse_iprp_properties(data, iprp).unwrap();
            for p in &props {
                if p.ptype == "hvcC" {
                    eprintln!("{label} hvcC [{}]: {}B", p.index, p.raw.len());
                    eprintln!("{label}   raw: {}", hex(&p.raw));
                }
            }
        };

        eprintln!("\n--- hvcC ---");
        find_hvcc(&py_data, "PY");
        find_hvcc(&rust_data, "RUST");

        // Compare ipma for key items
        let find_ipma = |data: &[u8], label: &str| {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);

            let iinf = kids.iter().find(|b| &b.btype == b"iinf").unwrap();
            let items = isobmff::parse_iinf(data, iinf).unwrap();
            let item_map: std::collections::HashMap<u32, &str> = items
                .iter()
                .map(|it| (it.item_id, it.itype.as_str()))
                .collect();

            let pitm = kids.iter().find(|b| &b.btype == b"pitm").unwrap();
            let primary = isobmff::parse_pitm(data, pitm);

            let iprp = kids.iter().find(|b| &b.btype == b"iprp").unwrap();
            let iprp_kids = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end);
            let ipma = iprp_kids.iter().find(|b| &b.btype == b"ipma").unwrap();
            let (flags, entries) = isobmff::parse_ipma(data, ipma);

            let key_types = ["grid", "tmap", "hvc1", "Exif", "mime"];
            let mut key_ids: Vec<u32> = items
                .iter()
                .filter(|it| key_types.contains(&it.itype.as_str()))
                .map(|it| it.item_id)
                .collect();
            key_ids.push(primary);
            key_ids.sort();
            key_ids.dedup();

            eprintln!("{label} ipma (flags={flags}):");
            for e in &entries {
                if key_ids.contains(&e.item_id) {
                    let it = item_map.get(&e.item_id).map(|s| *s).unwrap_or("?");
                    let a: Vec<String> = e
                        .associations
                        .iter()
                        .map(|(i, ess)| format!("{i}{}", if *ess { "!" } else { "" }))
                        .collect();
                    eprintln!("  id={} ({it}): [{a}]", e.item_id, a = a.join(","));
                }
            }
        };

        eprintln!("\n--- IPMA ---");
        find_ipma(&py_data, "PY");
        find_ipma(&rust_data, "RUST");

        // Compare iloc offsets for key items
        let find_iloc = |data: &[u8], label: &str| {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            let iloc = kids.iter().find(|b| &b.btype == b"iloc").unwrap();
            let iinf = kids.iter().find(|b| &b.btype == b"iinf").unwrap();
            let items = isobmff::parse_iinf(data, iinf).unwrap();
            let entries = isobmff::parse_iloc(data, iloc).unwrap();

            let key_types = ["grid", "tmap", "hvc1", "mime"];
            let mut key_ids: Vec<u32> = items
                .iter()
                .filter(|it| key_types.contains(&it.itype.as_str()))
                .map(|it| it.item_id)
                .collect();
            // Add a few gain tile IDs (the first few hvc1 items for gain map)
            let gain_tiles: Vec<u32> = items
                .iter()
                .filter(|it| it.itype == "hvc1" && it.item_id >= 10050)
                .map(|it| it.item_id)
                .take(3)
                .collect();
            key_ids.extend(gain_tiles);
            key_ids.sort();
            key_ids.dedup();

            eprintln!("{label} iloc key entries:");
            for e in &entries {
                if key_ids.contains(&e.item_id) {
                    let it = items
                        .iter()
                        .find(|i| i.item_id == e.item_id)
                        .map(|i| i.itype.as_str())
                        .unwrap_or("?");
                    let ext_strs: Vec<String> =
                        e.extents.iter().map(|(o, l)| format!("{o}+{l}")).collect();
                    eprintln!(
                        "  id={} ({it}) cm={} ext=[{}]",
                        e.item_id,
                        e.construction_method,
                        ext_strs.join(",")
                    );
                }
            }
        };

        eprintln!("\n--- ILOC ---");
        find_iloc(&py_data, "PY");
        find_iloc(&rust_data, "RUST");

        // Compare iinf hidden flags
        let find_iinf = |data: &[u8], label: &str| {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            let iinf = kids.iter().find(|b| &b.btype == b"iinf").unwrap();
            let items = isobmff::parse_iinf(data, iinf).unwrap();
            eprintln!("{label} iinf ({} items):", items.len());
            for it in &items {
                if it.flags != 0
                    || it.itype == "grid"
                    || it.itype == "tmap"
                    || it.itype == "Exif"
                    || it.itype == "mime"
                {
                    eprintln!(
                        "  id={} type={} flags=0x{:06x}",
                        it.item_id, it.itype, it.flags
                    );
                }
            }
        };

        eprintln!("\n--- IINF FLAGS ---");
        find_iinf(&py_data, "PY");
        find_iinf(&rust_data, "RUST");
    }

    #[test]
    fn verify_output_returns_false_for_nonexistent() {
        let path = CString::new("nonexistent_verify_test.heic").unwrap();
        assert!(!xdremux_verify_output(path.as_ptr()));
    }

    #[test]
    fn verify_output_empty_data() {
        // Empty bytes should not pass verification
        assert!(!verify_iso_gain_map(&[]));
    }

    #[test]
    fn verify_output_junk_data() {
        // Junk data should not crash and should return false
        assert!(!verify_iso_gain_map(&[0u8; 1024]));
    }

    // Real-photo conversions live in `tests/local_samples.rs`. They are
    // opt-in, discover their input through XDREMUX_SAMPLE_DIR, and only write
    // under the operating system temporary directory.
}
