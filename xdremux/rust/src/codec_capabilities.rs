//! Runtime facts, not an assertion that every HEIF/HDR variant is supported.
pub fn report() -> serde_json::Value {
    #[cfg(feature = "libheif-decoder")]
    let native = {
        use std::ffi::{c_char, CStr};
        extern "C" {
            fn xdremux_heif_runtime_version() -> *const c_char;
            fn xdremux_heif_decoder_name(out: *mut c_char, len: usize) -> i32;
        }
        let version = unsafe { CStr::from_ptr(xdremux_heif_runtime_version()) }
            .to_string_lossy()
            .into_owned();
        let mut name = [0 as c_char; 256];
        let available = unsafe { xdremux_heif_decoder_name(name.as_mut_ptr(), name.len()) } == 1;
        let decoder = if available {
            Some(
                unsafe { CStr::from_ptr(name.as_ptr()) }
                    .to_string_lossy()
                    .into_owned(),
            )
        } else {
            None
        };
        serde_json::json!({"compiled": true, "runtimeVersion": version, "hevcDecoderAvailable": available, "decoder": decoder})
    };
    #[cfg(not(feature = "libheif-decoder"))]
    let native = serde_json::json!({"compiled": false, "runtimeVersion": null, "hevcDecoderAvailable": false, "decoder": null});
    serde_json::json!({
        "schemaVersion": 1, "coreVersion": env!("CARGO_PKG_VERSION"),
        "rustHeif": "heif-oxide 0.1.0 / HEVC 4:2:0",
        "libheif": native, "primaryPreview": true,
        "previewMaxSide": 2048, "previewMaxInputMiB": 256, "previewMaxPixels": 67108864,
        "fallbackScope": "SDR unsupported-chroma only; not PQ/HLG tone mapping",
        "hdrJpegMetadata": ["Apple gain map v1/v2", "ISO 21496-1", "Adobe XMP"]
    })
}
#[cfg(test)]
mod tests {
    #[test]
    fn reflects_actual_build_feature() {
        let report = super::report();
        assert_eq!(
            report["libheif"]["compiled"],
            cfg!(feature = "libheif-decoder")
        );
        assert_eq!(report["schemaVersion"], 1);
        assert_eq!(report["primaryPreview"], true);
        assert!(report.get("paths").is_none());
    }
}
