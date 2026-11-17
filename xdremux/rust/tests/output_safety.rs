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

fn make_live_photo(source: &std::path::Path, still: &std::path::Path, out: &std::path::Path) -> serde_json::Value {
    let c = |p: &std::path::Path| CString::new(p.to_str().unwrap()).unwrap();
    let result = xdremux_core::xdremux_make_live_photo(c(source).as_ptr(), c(still).as_ptr(), c(out).as_ptr());
    let report = serde_json::from_str(unsafe { CStr::from_ptr(result).to_str().unwrap() }).unwrap();
    xdremux_core::xdremux_free_string(result);
    report
}

#[test]
fn live_photo_ffi_refuses_outputs_over_its_inputs_before_reading_or_writing() {
    let dir = std::env::temp_dir().join(format!("xdremux_live_inputs_{}", std::process::id()));
    let out = dir.join("out");
    std::fs::create_dir_all(&out).unwrap();
    // The outputs are <out>/<source stem>.heic and .mov.
    let source = dir.join("IMG_1.jpg");
    let still = out.join("IMG_1.heic");
    std::fs::write(&source, b"source").unwrap();
    std::fs::write(&still, b"converted still").unwrap();
    let report = make_live_photo(&source, &still, &out);
    assert_eq!(report["success"], false);
    assert!(report["errorMessage"].as_str().unwrap().contains("must not overwrite the converted still"), "{report}");
    assert_eq!(std::fs::read(&still).unwrap(), b"converted still");
    assert_eq!(std::fs::read_dir(&out).unwrap().count(), 1);

    let source_in_out = out.join("IMG_2.heic");
    std::fs::write(&source_in_out, b"source").unwrap();
    let report = make_live_photo(&source_in_out, &still, &out);
    assert!(report["errorMessage"].as_str().unwrap().contains("must not overwrite the source"), "{report}");
    assert_eq!(std::fs::read(&source_in_out).unwrap(), b"source");
    std::fs::remove_dir_all(&dir).unwrap();
}
