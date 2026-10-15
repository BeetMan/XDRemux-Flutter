use std::ffi::{CStr, CString};

#[test]
fn portrait_ffi_refuses_in_place_output_before_reading_or_writing() {
    let path = CString::new("same-source.heic").unwrap();
    let result = xdremux_core::xdremux_remux_huawei_portrait(path.as_ptr(), path.as_ptr());
    let report: serde_json::Value = serde_json::from_str(unsafe {
        CStr::from_ptr(result).to_str().unwrap()
    }).unwrap();
    xdremux_core::xdremux_free_string(result);
    assert_eq!(report["success"], false);
    assert!(report["error"].as_str().unwrap().contains("must not overwrite"));
}
