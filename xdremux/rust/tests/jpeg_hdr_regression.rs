//! Private original-file smoke test; never check the photograph into Git.
//! Set XDREMUX_HDR_JPEG_SAMPLE and optionally XDREMUX_HDR_JPEG_OUTPUT_DIR,
//! then run this test with --ignored --nocapture. Outputs are kept for review.
use std::ffi::{CStr, CString};
use sha2::{Digest, Sha256};
use xdremux_core::{photo_details, uhdr_jpeg, iso_validate,
    xdremux_convert, xdremux_free_result, xdremux_verify_output, ConvertConfig};

#[test]
#[ignore = "requires the issue #11 original JPEG via XDREMUX_HDR_JPEG_SAMPLE"]
fn issue11_redmi_jpeg_keeps_hdr_in_both_output_modes() {
    let input = std::env::var("XDREMUX_HDR_JPEG_SAMPLE").expect("set XDREMUX_HDR_JPEG_SAMPLE");
    let before = std::fs::read(&input).unwrap();
    assert_eq!(format!("{:x}", Sha256::digest(&before)),
        "3f1e942f63799a3045efac8a7afd542c0258634fd63285d6d9cce43cbbcb0747");
    let info = uhdr_jpeg::parse(&before).unwrap().unwrap();
    assert_eq!(info.gainmap_jpeg.len(), 1_215_977);
    assert!((info.meta_floats[4].log2() - 1.12392).abs() < 1e-5);
    assert!((info.meta_floats[17] - 2.1793833).abs() < 1e-5);
    let details = photo_details::inspect_photo_details_from_bytes(&before);
    assert_eq!(details.hdr_kind.as_deref(), Some("uhdr"));
    assert!(details.hdr_parse_error.is_none());
    assert_eq!((details.width, details.height), (Some(3072), Some(4096)));
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::var_os("XDREMUX_HDR_JPEG_OUTPUT_DIR")
        .map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let output_dir = root.join(format!("issue11-{nonce}"));
    std::fs::create_dir_all(&output_dir).unwrap();
    let input_c = CString::new(input).unwrap();
    for (mode, compat) in [("apple", 0), ("oppo", 1)] {
        let output = output_dir.join(format!("redmi-{mode}.heic"));
        let output_c = CString::new(output.to_str().unwrap()).unwrap();
        let config = ConvertConfig { oppo_compat: compat, oppo_camera_tail: 0,
            strict_tmap: 0, apple_photographic_styles: 0, apple_portrait: 0 };
        let result = xdremux_convert(input_c.as_ptr(), output_c.as_ptr(), &config);
        let error = if result.error_message.is_null() { String::new() }
            else { unsafe { CStr::from_ptr(result.error_message).to_string_lossy().into_owned() } };
        let (success, edr, max) = (result.success, result.edr_scale, result.gain_map_max);
        xdremux_free_result(result);
        assert!(success, "{mode}: {error}");
        assert!((edr - 2.1793833).abs() < 1e-5);
        assert!((max - 1.12392).abs() < 1e-5);
        assert!(xdremux_verify_output(output_c.as_ptr()), "{mode} output verification");
        let bytes = std::fs::read(&output).unwrap();
        let structure = iso_validate::validate_gain_map_structure(&bytes).unwrap();
        assert_eq!((structure.width, structure.height), (1536, 2048));
        assert_eq!(Sha256::digest(&before), Sha256::digest(std::fs::read(input_c.to_str().unwrap()).unwrap()));
        println!("{mode}: HDR output={} bytes={} sha256={:x}", output.display(), bytes.len(), Sha256::digest(&bytes));
    }
}

#[test]
#[ignore = "requires MIX Flip 2 original via XDREMUX_ICC_JPEG_SAMPLE"]
fn mix_flip2_icc_and_watermark_geometry_survive_both_outputs() {
    let input = std::env::var("XDREMUX_ICC_JPEG_SAMPLE").expect("set XDREMUX_ICC_JPEG_SAMPLE");
    let before = std::fs::read(&input).unwrap();
    assert_eq!(format!("{:x}", Sha256::digest(&before)),
        "b5d0dcf287df4d2d9085b246a017cdfcd3a04e81081a4c6371ad31c3291f8caa");
    let mut decoder = jpeg_decoder::Decoder::new(std::io::Cursor::new(&before));
    decoder.decode().unwrap();
    let icc = decoder.icc_profile().unwrap();
    assert_eq!(icc.len(), 632);
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::var_os("XDREMUX_HDR_JPEG_OUTPUT_DIR")
        .map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let dir = root.join(format!("mix-icc-{nonce}"));
    std::fs::create_dir_all(&dir).unwrap();
    let input_c = CString::new(input).unwrap();
    for (mode, compat) in [("apple", 0), ("oppo", 1)] {
        let output = dir.join(format!("mix-{mode}.heic"));
        let output_c = CString::new(output.to_str().unwrap()).unwrap();
        let result = xdremux_convert(input_c.as_ptr(), output_c.as_ptr(), &ConvertConfig {
            oppo_compat: compat, oppo_camera_tail: 0, strict_tmap: 0,
            apple_photographic_styles: 0, apple_portrait: 0,
        });
        let error = if result.error_message.is_null() { String::new() }
            else { unsafe { CStr::from_ptr(result.error_message).to_string_lossy().into_owned() } };
        let success = result.success;
        xdremux_free_result(result);
        assert!(success, "{mode}: {error}");
        assert!(xdremux_verify_output(output_c.as_ptr()));
        let bytes = std::fs::read(&output).unwrap();
        let structure = iso_validate::validate_gain_map_structure(&bytes).unwrap();
        assert_eq!((structure.width, structure.height), (1536, 2286));
        let meta = xdremux_core::isobmff::parse_source_meta(&bytes).unwrap();
        let primary_tiles = &meta.refs.iter().find(|r| r.rtype == "dimg" && r.from == meta.primary_id).unwrap().to;
        for item in meta.items.iter().filter(|i| i.item_id == meta.primary_id || primary_tiles.contains(&i.item_id)) {
            let assocs = &meta.ipma_entries.iter().find(|a| a.item_id == item.item_id).unwrap().associations;
            assert!(assocs.iter().any(|(index, _)| meta.props.iter().any(|p|
                p.index == *index && p.ptype == "colr" && &p.raw[8..12] == b"prof" && p.raw[12..] == icc)));
        }
        let primary_assocs = &meta.ipma_entries.iter().find(|a| a.item_id == meta.primary_id).unwrap().associations;
        assert!(primary_assocs.iter().any(|(index, _)| meta.props.iter().any(|p|
            p.index == *index && p.ptype == "ispe" &&
            xdremux_core::isobmff::ispe_dimensions(&p.raw).unwrap() == (3072, 4572))));
        assert_eq!(Sha256::digest(&before), Sha256::digest(std::fs::read(input_c.to_str().unwrap()).unwrap()));
        println!("{mode}: ICC-preserving output={} bytes={} sha256={:x}", output.display(), bytes.len(), Sha256::digest(&bytes));
    }
}
