//! XDRemux cross-platform conversion core.
//!
//! Exposes a small C FFI surface consumed by Flutter via `dart:ffi`.

pub mod container;
pub mod edr;
pub mod exif;
pub mod gainmap;
pub mod iso21496;
pub mod isobmff;
pub mod isobmff_write;
pub mod jpeg_decode;
pub mod hevc;
pub mod progress;

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use exif::OppoCompat;

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

/// Configuration for conversion.
///
/// Fields match the Swift `OppoCompatibility` enum:
/// - `oppo_compat`: 0=off, 1=auto, 2=on, 3=tail (alias for on)
#[repr(C)]
pub struct ConvertConfig {
    pub oppo_compat: u8,
}

// ---------------------------------------------------------------------------
// FFI: version
// ---------------------------------------------------------------------------

/// Returns an owned version string. Caller must free with `xdremux_free_string`.
#[no_mangle]
pub extern "C" fn xdremux_version() -> *mut c_char {
    match CString::new("0.1.0") {
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
                    extracted.meta_floats[4].max(extracted.meta_floats[5]).max(extracted.meta_floats[6])
                } else {
                    1.0
                };
                let gm_max = if ratio_max > 0.0 { ratio_max.log2() } else { 0.0 };
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
/// `config` can be null (treated as `oppo_compat=0` / off).
/// Returns a [ConversionResult] that the caller must free.
#[no_mangle]
pub extern "C" fn xdremux_convert(
    input_path: *const c_char,
    output_path: *const c_char,
    config: *const ConvertConfig,
) -> ConversionResult {
    let oppo_compat = if config.is_null() {
        OppoCompat::Off
    } else {
        OppoCompat::from_u8(unsafe { (*config).oppo_compat })
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

    // 1. Extract from source
    let extracted = match container::extract_lhdr(input) {
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

    // 2. Read source HEIC bytes (needed by both paths)
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

    let family = if extracted.meta_floats[0] >= 3.0 || extracted.mode == "uhdr" {
        "x7"
    } else {
        "x6"
    };

    // 3. Route to UHDR or LHDR path
    let result = if extracted.mode == "uhdr" {
        convert_uhdr(&extracted, &source, output, oppo_compat)
    } else {
        convert_lhdr(&extracted, &source, output, oppo_compat)
    };

    match result {
        Ok((edr, gm_max)) => ConversionResult {
            success: true,
            mode: CString::new(extracted.mode.as_str()).unwrap().into_raw(),
            family: CString::new(family).unwrap().into_raw(),
            edr_scale: edr as f64,
            gain_map_max: gm_max as f64,
            error_message: ptr::null_mut(),
        },
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

fn convert_lhdr(
    extracted: &container::ExtractedLhdr,
    source: &[u8],
    output: &str,
    oppo_compat: OppoCompat,
) -> Result<(f32, f32), String> {
    progress::set_progress(1, 0, 0); // extract

    let edr = edr::edr_scale_calculator(&extracted.meta_floats);

    let mask_data = extracted.mask_data.as_ref()
        .ok_or_else(|| "no mask JPEG in extracted LHDR data".to_string())?;

    progress::set_progress(2, 0, 0); // decode JPEG
    let (mask_pixels, mask_w, mask_h) = jpeg_decode::decode_jpeg_to_gray(mask_data)
        .map_err(|e| format!("mask JPEG decode failed: {e}"))?;

    progress::set_progress(4, 1, 1); // assemble
    isobmff_write::write_lhdr_iso_output(
        source, &mask_pixels, mask_w, mask_h,
        &extracted.meta_floats, edr, oppo_compat, output,
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
) -> Result<(f32, f32), String> {
    progress::set_progress(1, 0, 0); // extract

    let gainmap_jpeg = extracted.gainmap_data.as_ref()
        .ok_or_else(|| "no gainmap JPEG in extracted UHDR data".to_string())?;

    progress::set_progress(2, 0, 0); // decode JPEG

    progress::set_progress(4, 1, 1); // assemble
    isobmff_write::write_uhdr_iso_output(
        source, gainmap_jpeg, &extracted.meta_floats, oppo_compat, output,
    )?;

    progress::set_progress(0, 0, 0); // done
    let scale = if extracted.meta_floats.len() >= 19 {
        extracted.meta_floats[18]
    } else {
        1.0
    };
    let ratio_max = if extracted.meta_floats.len() >= 7 {
        extracted.meta_floats[4].max(extracted.meta_floats[5]).max(extracted.meta_floats[6])
    } else {
        1.0
    };
    let gm_max = if ratio_max > 0.0 { ratio_max.log2() } else { 0.0 };
    Ok((scale, gm_max))
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
    refs.iter().any(|r| r.rtype == "dimg" && r.from == tmap_id && !r.to.is_empty())
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

    /// Diagnostic: dump source and output ISOBMFF structures for comparison.
    #[test]
    fn dump_diagnostics() {
        let input_path = "C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155054.heic";
        let output_path = "C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155054_out.heic";

        let src = std::fs::read(input_path).unwrap();
        let out = std::fs::read(output_path).unwrap();

        fn dump(name: &str, data: &[u8]) {
            fn btype_str(b: &[u8;4]) -> String {
                String::from_utf8_lossy(b).to_string()
            }

            let top = isobmff::parse_boxes(data, 0, data.len());
            eprintln!("\n===== {name} =====");
            eprintln!("Top: {:?}", top.iter().map(|b| btype_str(&b.btype)).collect::<Vec<_>>());

            let meta = top.iter().find(|b| &b.btype == b"meta").unwrap();
            let kids = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
            eprintln!("Meta kids: {:?}", kids.iter().map(|b| btype_str(&b.btype)).collect::<Vec<_>>());

            if let Some(pitm) = kids.iter().find(|b| &b.btype == b"pitm") {
                eprintln!("pitm primary: {}", isobmff::parse_pitm(data, pitm));
            }
            if let Some(iinf) = kids.iter().find(|b| &b.btype == b"iinf") {
                let items = isobmff::parse_iinf(data, iinf).unwrap();
                let max_id = items.iter().map(|i| i.item_id).max().unwrap_or(0);
                eprintln!("iinf v{}: {} items, max_id={}", data[iinf.data_start], items.len(), max_id);
                for it in &items {
                    eprintln!("  id={} type={} flags={}", it.item_id, it.itype, it.flags);
                }
            }
            if let Some(iloc) = kids.iter().find(|b| &b.btype == b"iloc") {
                let entries = isobmff::parse_iloc(data, iloc).unwrap();
                eprintln!("iloc v{}: {} entries", data[iloc.data_start], entries.len());
                let mut entry_strs: Vec<String> = entries.iter().map(|e| {
                    let ext_strs: Vec<String> = e.extents.iter().map(|(o,l)| format!("({}+{})", o, l)).collect();
                    format!("id={} cm={} dr={} ext=[{}]", e.item_id, e.construction_method, e.data_reference_index, ext_strs.join(","))
                }).collect();
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
                        eprintln!("       nclx: prim={} tf={} matrix={}", p.raw[12], p.raw[13], p.raw[14]);
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
                        let a: Vec<String> = e.associations.iter().map(|(i,ess)| format!("{}{}", i, if *ess{"!"}else{""})).collect();
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
    fn compare_py_rust_payloads() {
        let py_path = "C:/Users/Beet/Desktop/duibi/IMG20260707155054_py.heic";
        let rust_path = "C:/Users/Beet/Desktop/duibi/IMG20260707155054_out.heic";

        let py_data = std::fs::read(py_path).unwrap();
        let rust_data = std::fs::read(rust_path).unwrap();

        fn hex(data: &[u8]) -> String {
            data.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join("")
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
                items.iter().find(|i| i.itype == itype).map(|i| i.item_id).unwrap_or(0)
            };
            let find_extent = |item_id: u32| -> (usize, usize) {
                entries.iter()
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

            eprintln!("  idat={}B tmap@{} len={} xmp@{} len={} grid@{} len={}",
                idat.len(), tmap_off, tmap_len, xmp_off, xmp_len, _grid_off, _grid_len);

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
            (0..data.len()).step_by(4).take(data.len()/4).map(|i| {
                i32::from_be_bytes([data[i], data[i+1], data[i+2], data[i+3]])
            }).collect()
        };
        eprintln!("PY  tmap i32: {:?}", tmap_i32(&py_tmap));
        eprintln!("RUST tmap i32: {:?}", tmap_i32(&rust_tmap));

        eprintln!("\n--- XMP ---");
        eprintln!("PY  XMP ({}B): {}", py_xmp.len(), String::from_utf8_lossy(&py_xmp));
        eprintln!("RUST XMP ({}B): {}", rust_xmp.len(), String::from_utf8_lossy(&rust_xmp));
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
                        eprintln!("{label} colr nclx [{}]: prim={} tf={} matrix={} full_range={}",
                            p.index, p.raw[12], p.raw[13], p.raw[14], p.raw[15] & 0x80 != 0);
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
            let item_map: std::collections::HashMap<u32, &str> = items.iter()
                .map(|it| (it.item_id, it.itype.as_str()))
                .collect();

            let pitm = kids.iter().find(|b| &b.btype == b"pitm").unwrap();
            let primary = isobmff::parse_pitm(data, pitm);

            let iprp = kids.iter().find(|b| &b.btype == b"iprp").unwrap();
            let iprp_kids = isobmff::parse_boxes(data, iprp.data_start, iprp.data_end);
            let ipma = iprp_kids.iter().find(|b| &b.btype == b"ipma").unwrap();
            let (flags, entries) = isobmff::parse_ipma(data, ipma);

            let key_types = ["grid", "tmap", "hvc1", "Exif", "mime"];
            let mut key_ids: Vec<u32> = items.iter()
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
                    let a: Vec<String> = e.associations.iter().map(|(i,ess)| format!("{i}{}", if *ess{"!"}else{""})).collect();
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
            let mut key_ids: Vec<u32> = items.iter()
                .filter(|it| key_types.contains(&it.itype.as_str()))
                .map(|it| it.item_id)
                .collect();
            // Add a few gain tile IDs (the first few hvc1 items for gain map)
            let gain_tiles: Vec<u32> = items.iter()
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
                    let it = items.iter().find(|i| i.item_id == e.item_id).map(|i| i.itype.as_str()).unwrap_or("?");
                    let ext_strs: Vec<String> = e.extents.iter().map(|(o,l)| format!("{o}+{l}")).collect();
                    eprintln!("  id={} ({it}) cm={} ext=[{}]", e.item_id, e.construction_method, ext_strs.join(","));
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
                if it.flags != 0 || it.itype == "grid" || it.itype == "tmap" || it.itype == "Exif" || it.itype == "mime" {
                    eprintln!("  id={} type={} flags=0x{:06x}", it.item_id, it.itype, it.flags);
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

    #[test]
    fn convert_photo1_55054() {
        use std::ffi::CString;
        let input = CString::new("C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155054.heic").unwrap();
        let output = CString::new("C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155054_out.heic").unwrap();
        let cfg = ConvertConfig { oppo_compat: 0 };
        let res = xdremux_convert(input.as_ptr(), output.as_ptr(), &cfg);
        let msg = unsafe { if res.error_message.is_null() { "(null)".to_string() } else { CStr::from_ptr(res.error_message).to_str().unwrap_or("?").to_string() } };
        let ok = res.success;
        let m = unsafe { if res.mode.is_null() { "?".to_string() } else { CStr::from_ptr(res.mode).to_str().unwrap_or("?").to_string() } };
        let f = unsafe { if res.family.is_null() { "?".to_string() } else { CStr::from_ptr(res.family).to_str().unwrap_or("?").to_string() } };
        eprintln!("convert: success={ok} mode={m} family={f} edr={} gm={} msg={msg}", res.edr_scale, res.gain_map_max);
        xdremux_free_result(res);
        if !ok {
            eprintln!("SKIP verify — conversion failed");
            return;
        }
        let vo = xdremux_verify_output(output.as_ptr());
        eprintln!("verify_output: {vo}");
        assert!(vo, "verify_output returned false");
    }

    #[test]
    fn convert_photo1_oppo() {
        use std::ffi::CString;
        let input = CString::new("C:/Users/Beet/Desktop/duibi/IMG20260707155054.heic").unwrap();
        let output = CString::new("C:/Users/Beet/Desktop/duibi/IMG20260707155054_rust_oppo.heic").unwrap();
        let cfg = ConvertConfig { oppo_compat: 1 };
        let res = xdremux_convert(input.as_ptr(), output.as_ptr(), &cfg);
        let msg = unsafe { if res.error_message.is_null() { "(null)".to_string() } else { CStr::from_ptr(res.error_message).to_str().unwrap_or("?").to_string() } };
        let ok = res.success;
        let m = unsafe { if res.mode.is_null() { "?".to_string() } else { CStr::from_ptr(res.mode).to_str().unwrap_or("?").to_string() } };
        let f = unsafe { if res.family.is_null() { "?".to_string() } else { CStr::from_ptr(res.family).to_str().unwrap_or("?").to_string() } };
        eprintln!("OPPO convert: success={ok} mode={m} family={f} edr={} gm={} msg={msg}", res.edr_scale, res.gain_map_max);
        xdremux_free_result(res);
        assert!(ok, "OPPO conversion failed: {msg}");
    }

    #[test]
    fn convert_121521_all() {
        use std::ffi::CString;
        let input = CString::new("C:/Users/Beet/Desktop/IMG20260711121521.heic").unwrap();

        // 1. Normal mode
        let out1 = CString::new("C:/Users/Beet/Desktop/IMG20260711121521_normal.heic").unwrap();
        let cfg1 = ConvertConfig { oppo_compat: 0 };
        let r1 = xdremux_convert(input.as_ptr(), out1.as_ptr(), &cfg1);
        let ok1 = r1.success; let m1 = unsafe { if r1.mode.is_null() { "?".to_string() } else { CStr::from_ptr(r1.mode).to_str().unwrap_or("?").to_string() } };
        eprintln!("normal: success={ok1} mode={m1} edr={}", r1.edr_scale);
        xdremux_free_result(r1);
        assert!(ok1, "normal conversion failed");

        // 2. OPPO mode
        let out2 = CString::new("C:/Users/Beet/Desktop/IMG20260711121521_oppo.heic").unwrap();
        let cfg2 = ConvertConfig { oppo_compat: 1 };
        let r2 = xdremux_convert(input.as_ptr(), out2.as_ptr(), &cfg2);
        let ok2 = r2.success; let m2 = unsafe { if r2.mode.is_null() { "?".to_string() } else { CStr::from_ptr(r2.mode).to_str().unwrap_or("?").to_string() } };
        eprintln!("oppo:   success={ok2} mode={m2} edr={}", r2.edr_scale);
        xdremux_free_result(r2);
        assert!(ok2, "oppo conversion failed");

        eprintln!("All 3 variants written to Desktop.");
    }

    #[test]
    fn convert_photo2_55044() {
        use std::ffi::CString;
        let input = CString::new("C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155044.heic").unwrap();
        let output = CString::new("C:/Users/Beet/Downloads/Telegram Desktop/IMG20260707155044_out.heic").unwrap();
        let cfg = ConvertConfig { oppo_compat: 0 };
        let res = xdremux_convert(input.as_ptr(), output.as_ptr(), &cfg);
        let msg = unsafe { if res.error_message.is_null() { "(null)".to_string() } else { CStr::from_ptr(res.error_message).to_str().unwrap_or("?").to_string() } };
        let ok = res.success;
        eprintln!("convert: success={ok} msg={msg}");
        xdremux_free_result(res);
        if !ok {
            eprintln!("SKIP verify — conversion failed");
            return;
        }
        let vo = xdremux_verify_output(output.as_ptr());
        eprintln!("verify_output: {vo}");
        assert!(vo, "verify_output returned false");
    }
}
