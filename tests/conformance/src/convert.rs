//! Convert a source HEIC file using xdremux-core's FFI function.
//!
//! Thin wrapper around `xdremux_convert` for use by the conformance CLI.

use std::path::Path;

use xdremux_core::ConvertConfig;

/// Run the conversion and write output to `output_path`.
/// Mirrors the `xdremux_convert` FFI call in lib.rs.
pub fn run(input: &Path, output: &Path, oppo_compat: u8) -> Result<(), String> {
    let input_str = input.to_str().ok_or("input path is not valid UTF-8")?;
    let output_str = output.to_str().ok_or("output path is not valid UTF-8")?;

    let config = ConvertConfig { oppo_compat };

    // Use the same FFI binding that Flutter would use.
    // The xdremux_convert function is a public extern "C" with #[no_mangle],
    // but since we link directly we can call the internal path.
    let result = xdremux_core::container::extract_lhdr(input_str)
        .map_err(|e| format!("extract failed: {e}"))?;

    let source = std::fs::read(input_str)
        .map_err(|e| format!("cannot read input: {e}"))?;

    let family = if result.meta_floats.first().copied().unwrap_or(0.0) >= 3.0 || result.mode == "uhdr" {
        "x7"
    } else {
        "x6"
    };

    let oppo_compat_enum = xdremux_core::exif::OppoCompat::from_u8(oppo_compat);

    if result.mode == "uhdr" {
        convert_uhdr(&result, &source, output_str, oppo_compat_enum)
    } else {
        convert_lhdr(&result, &source, output_str, oppo_compat_enum)
    }
    .map_err(|e| format!("conversion failed: {e}"))?;

    Ok(())
}

use xdremux_core::container::ExtractedLhdr;
use xdremux_core::exif::OppoCompat;

fn convert_lhdr(
    extracted: &ExtractedLhdr,
    source: &[u8],
    output: &str,
    oppo_compat: OppoCompat,
) -> Result<(), String> {
    use xdremux_core::edr;
    use xdremux_core::isobmff_write;
    use xdremux_core::jpeg_decode;

    let edr_scale = edr::edr_scale_calculator(&extracted.meta_floats);
    let mask_data = extracted.mask_data.as_ref()
        .ok_or_else(|| "no mask JPEG in extracted LHDR data".to_string())?;
    let (mask_pixels, mask_w, mask_h) = jpeg_decode::decode_jpeg_to_gray(mask_data)
        .map_err(|e| format!("mask JPEG decode failed: {e}"))?;
    isobmff_write::write_lhdr_iso_output(
        source, &mask_pixels, mask_w, mask_h,
        &extracted.meta_floats, edr_scale, oppo_compat, output,
    )?;
    Ok(())
}

fn convert_uhdr(
    extracted: &ExtractedLhdr,
    source: &[u8],
    output: &str,
    oppo_compat: OppoCompat,
) -> Result<(), String> {
    use xdremux_core::isobmff_write;

    let gainmap_jpeg = extracted.gainmap_data.as_ref()
        .ok_or_else(|| "no gainmap JPEG in extracted UHDR data".to_string())?;
    isobmff_write::write_uhdr_iso_output(
        source, gainmap_jpeg, &extracted.meta_floats, oppo_compat, output,
    )?;
    Ok(())
}
