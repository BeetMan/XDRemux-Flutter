//! Optional native fallback for the pure Rust decoder's specific chroma gap.
//! Not a catch-all retry for corrupt containers or a replacement HDR engine.
use heif_oxide::HeifError;

pub(crate) fn is_chroma_gap(error: &HeifError) -> bool {
    matches!(error, HeifError::Codec(message) if message.contains("only 4:2:0 (chroma_format_idc=1) supported"))
}

#[cfg(feature = "libheif-decoder")]
pub(crate) fn native_rgb(data: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    use std::ffi::{c_char, CStr};
    extern "C" {
        fn xdremux_heif_decode_rgb(
            input: *const u8,
            input_len: usize,
            output: *mut *mut u8,
            output_len: *mut usize,
            width: *mut u32,
            height: *mut u32,
            error: *mut c_char,
            error_len: usize,
        ) -> i32;
        fn xdremux_heif_free_rgb(pixels: *mut u8);
    }
    struct Buffer(*mut u8);
    impl Drop for Buffer {
        fn drop(&mut self) {
            unsafe {
                xdremux_heif_free_rgb(self.0);
            }
        }
    }
    let mut raw = std::ptr::null_mut();
    let (mut len, mut w, mut h) = (0usize, 0u32, 0u32);
    let mut error = [0 as c_char; 512];
    // SAFETY: input lives through the synchronous decode, output pointers are
    // initialized by the helper; Buffer always frees using the same allocator.
    let ok = unsafe {
        xdremux_heif_decode_rgb(
            data.as_ptr(),
            data.len(),
            &mut raw,
            &mut len,
            &mut w,
            &mut h,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    let buffer = Buffer(raw);
    if ok != 1 {
        return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
            .to_string_lossy()
            .into_owned());
    }
    let expected = (w as usize)
        .checked_mul(h as usize)
        .and_then(|n| n.checked_mul(3))
        .ok_or("native HEIF output size overflow")?;
    if raw.is_null()
        || w == 0
        || h == 0
        || u64::from(w) * u64::from(h) > 64 * 1024 * 1024
        || len != expected
    {
        return Err("invalid native HEIF output buffer".into());
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(len)
        .map_err(|_| "cannot allocate Rust HEIF pixels")?;
    // SAFETY: success returns an allocated, initialized buffer of exactly len.
    pixels.extend_from_slice(unsafe { std::slice::from_raw_parts(buffer.0, len) });
    drop(buffer);
    // libheif applies HEIF irot/imir/clap. EXIF is only a fallback when the
    // container declares no rotation/mirror; never rotate twice.
    let parsed = crate::isobmff::parse_source_meta(data)?;
    let transformed = parsed
        .ipma_entries
        .iter()
        .filter(|e| e.item_id == parsed.primary_id)
        .flat_map(|e| &e.associations)
        .any(|(index, _)| {
            parsed
                .props
                .iter()
                .any(|p| p.index == *index && (p.ptype == "irot" || p.ptype == "imir"))
        });
    if transformed {
        return Ok((pixels, w, h));
    }
    let top = crate::isobmff::parse_boxes(data, 0, data.len());
    let meta = top
        .iter()
        .find(|b| &b.btype == b"meta")
        .ok_or("missing HEIF meta")?;
    let children = crate::isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
    let idat = children.iter().find(|b| &b.btype == b"idat");
    let orientation =
        crate::exif::read_heif_exif_orientation(data, &parsed.items, &parsed.iloc_entries, idat)?;
    if orientation == crate::exif::ExifOrientation::Normal {
        return Ok((pixels, w, h));
    }
    crate::isobmff_write::orient_gainmap_pixels(&pixels, w, h, 3, w as usize * 3, orientation)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_the_chroma_gap_can_trigger_native_retry() {
        assert!(is_chroma_gap(&HeifError::Codec(
            "Unsupported(\"only 4:2:0 (chroma_format_idc=1) supported\")".into()
        )));
        assert!(!is_chroma_gap(&HeifError::Codec(
            "invalid HEVC bitstream".into()
        )));
        assert!(!is_chroma_gap(&HeifError::Invalid(
            "container error".into()
        )));
        assert!(!is_chroma_gap(&HeifError::Unsupported(
            "external references".into()
        )));
    }
    #[cfg(feature = "libheif-decoder")]
    #[test]
    fn native_decoder_rejects_invalid_input() {
        assert!(native_rgb(b"not HEIF").is_err());
        assert!(native_rgb(&[]).is_err());
    }
}
