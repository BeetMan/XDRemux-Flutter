//! OPPO private tail data for the photo details view.
//!
//! Only fields whose layout has been checked are reported: against camera
//! originals, against the Gallery APK, or both. Anything else in the tail is
//! listed by name and size and left unread.
//! See docs/modules/photo-details.md.

use serde_json::{json, Map, Value};

use crate::container;
use crate::portrait_depth as pd;

/// What the OPPO tail of `data` says, or `None` for a file without one.
pub fn inspect(data: &[u8]) -> Option<Value> {
    let entries = container::tail_entries(data);
    if entries.is_empty() {
        return None;
    }
    let has = |name: &str| entries.iter().any(|(entry, _)| entry == name);
    let mut report = Map::new();
    report.insert(
        "entries".into(),
        entries
            .iter()
            .map(|(name, length)| json!({ "name": name, "length": length }))
            .collect(),
    );
    if let Some(device) = device_name(data) {
        report.insert("device".into(), json!(device));
    }
    report.insert("watermark".into(), watermark(data));
    if let Some(filter) = filter_info(data) {
        report.insert("filter".into(), filter);
    }
    let portrait = if has("rear.depth") {
        Some(rear_portrait(data))
    } else if has("front.depth") {
        Some(front_portrait(data))
    } else {
        None
    };
    if let Some(portrait) = portrait {
        report.insert("portrait".into(), portrait);
    }
    let source = container::extract_tail_entry(data, "src.image")
        .and_then(|image| pd::image_dimensions(&image));
    if let Some((width, height)) = source {
        report.insert("sourceImage".into(), json!({ "width": width, "height": height }));
    }
    Some(Value::Object(report))
}

/// Printable ASCII up to the first NUL of `bytes`, or `None` when that is
/// empty or holds anything else.
fn ascii_field(bytes: &[u8]) -> Option<String> {
    let text = bytes.split(|&byte| byte == 0).next()?;
    (!text.is_empty() && text.iter().all(|byte| (0x20..0x7f).contains(byte)))
        .then(|| String::from_utf8_lossy(text).into_owned())
}

/// A float as JSON, rounded to two decimals so 5.1 does not print as
/// 5.099999904632568. `None` for NaN and infinities.
fn rounded(value: f32) -> Option<f64> {
    value.is_finite().then(|| (value as f64 * 100.0).round() / 100.0)
}

/// `watermark.device`: a version float, one byte, then the NUL-terminated
/// name the camera prints in the watermark ("OPPO Find X8 Ultra").
fn device_name(data: &[u8]) -> Option<String> {
    let device = container::extract_tail_entry(data, "watermark.device")?;
    ascii_field(device.get(5..)?)
}

/// Pixel size of the primary image, the frame the watermark geometry is in.
fn primary_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.starts_with(b"\xff\xd8") {
        return pd::image_dimensions(data);
    }
    let meta = crate::isobmff::parse_source_meta(data).ok()?;
    crate::portrait::base_primary_dims(&meta).ok()
}

/// How the camera put its watermark in the picture. `png`: an overlay kept as
/// a PNG entry. `frame`: baked into the pixels, described by
/// `watermark.master.params`. `unknown`: watermark entries of neither kind.
/// `none`: no rendered watermark.
fn watermark(data: &[u8]) -> Value {
    let overlay = container::extract_tail_entry(data, "watermark")
        .filter(|png| png.starts_with(b"\x89PNG\r\n\x1a\n"));
    if let Some(png) = overlay {
        let mut report = Map::new();
        report.insert("kind".into(), json!("png"));
        if let Some((width, height)) = pd::image_dimensions(&png) {
            report.insert("width".into(), json!(width));
            report.insert("height".into(), json!(height));
        }
        return Value::Object(report);
    }
    let Some(params) = container::extract_tail_entry(data, "watermark.master.params") else {
        let kind = if container::has_rendered_watermark(data) { "unknown" } else { "none" };
        return json!({ "kind": kind });
    };
    let mut report = Map::new();
    report.insert("kind".into(), json!("frame"));
    // The style id is a NUL-padded string in bytes 4..68.
    if let Some(style) = params.get(4..68).and_then(ascii_field) {
        report.insert("style".into(), json!(style));
    }
    let picture = primary_dimensions(data).and_then(|(width, height)| {
        let rect = container::watermark_frame_picture_rect(data, width, height)?;
        Some((width, height, rect))
    });
    if let Some((width, height, (x, y, w, h))) = picture {
        report.insert("picture".into(), json!({ "x": x, "y": y, "width": w, "height": h }));
        report.insert(
            "margins".into(),
            json!({ "left": x, "top": y, "right": width - x - w, "bottom": height - y - h }),
        );
    }
    Value::Object(report)
}

/// `filter.info`, the display-time filter recipe. Field order and the version
/// each field appears in come from the Gallery 17.24.12 parser; the three
/// luma floats of version 5.1 are left out because their offset is unsettled.
/// See docs/research/oppo-gallery-17.24.12-20261114.md §1.
fn filter_info(data: &[u8]) -> Option<Value> {
    let info = container::extract_tail_entry(data, "filter.info")?;
    let version = pd::read_f32le(&info, 0).filter(|v| v.is_finite() && (1.0..100.0).contains(v))?;
    if info.len() < 128 {
        return None;
    }
    let mut report = Map::new();
    report.insert("version".into(), json!(rounded(version)));
    report.insert("intensity".into(), json!(pd::read_i32le(&info, 4)));
    report.insert("sourceOrientation".into(), json!(pd::read_i32le(&info, 8)));
    report.insert("mirrored".into(), json!(pd::read_i32le(&info, 12) == Some(1)));
    report.insert("softLight".into(), json!(pd::read_i32le(&info, 16).is_some_and(|v| v != 0)));
    report.insert("enabled".into(), json!(pd::read_i32le(&info, 24).is_some_and(|v| v != 0)));
    if let Some(lut) = ascii_field(&info[28..128]) {
        report.insert("lut".into(), json!(lut));
    }
    let float = |offset: usize| pd::read_f32le(&info, offset).and_then(rounded);
    if version >= 2.0 {
        if let Some(value) = float(128) {
            report.insert("colorTemperature".into(), json!(value));
        }
    }
    if version >= 4.0 {
        if let Some(value) = float(132) {
            report.insert("luxIndex".into(), json!(value));
        }
        if let Some(value) = float(136) {
            report.insert("saturation".into(), json!(value));
        }
    }
    if version >= 5.0 {
        if let Some(value) = pd::read_i32le(&info, 140) {
            report.insert("palette".into(), json!(value != 0));
        }
        if let Some(value) = pd::read_i32le(&info, 152) {
            report.insert("tone".into(), json!(value));
        }
        if let Some(mode) = info.get(156..206).and_then(ascii_field) {
            report.insert("captureMode".into(), json!(mode));
        }
    }
    Some(Value::Object(report))
}

/// Rear-camera portrait data: the simulated aperture from `rear.depth.config`.
fn rear_portrait(data: &[u8]) -> Value {
    let config = container::extract_tail_entry(data, "rear.depth.config");
    let aperture = pd::parse_config(config.as_deref())
        .and_then(|config| config.current_f_number)
        .and_then(rounded);
    let mut report = Map::new();
    report.insert("camera".into(), json!("rear"));
    if let Some(aperture) = aperture {
        report.insert("fNumber".into(), json!(aperture));
    }
    Value::Object(report)
}

/// Front-camera portrait data from `front.depth.config`: depth plane size,
/// face count, mirror flag and simulated aperture.
/// See docs/modules/portrait-pipeline.md §3.2 for the field table.
fn front_portrait(data: &[u8]) -> Value {
    let mut report = Map::new();
    report.insert("camera".into(), json!("front"));
    let Some(config) = container::extract_tail_entry(data, "front.depth.config") else {
        return Value::Object(report);
    };
    let version = pd::read_f32le(&config, 0).filter(|v| v.is_finite() && (1.0..3.0).contains(v));
    let Some(version) = version else {
        return Value::Object(report);
    };
    let size = |offset: usize| pd::read_u32le(&config, offset).filter(|v| (1..=8_192).contains(v));
    if let (Some(width), Some(height)) = (size(4), size(8)) {
        report.insert("depthWidth".into(), json!(width));
        report.insert("depthHeight".into(), json!(height));
    }
    // The face arrays hold ten entries each.
    if let Some(faces) = pd::read_u32le(&config, 84).filter(|count| *count <= 10) {
        report.insert("faceCount".into(), json!(faces));
    }
    if let Some(mirrored) = crate::portrait::front_config_mirror(&config) {
        report.insert("mirrored".into(), json!(mirrored));
    }
    if version >= 1.1 {
        let aperture = pd::read_f32le(&config, config.len().saturating_sub(4))
            .filter(|v| (1.0..=22.0).contains(v))
            .and_then(rounded);
        if let Some(aperture) = aperture {
            report.insert("fNumber".into(), json!(aperture));
        }
    }
    Value::Object(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::container::test_support::tail_file;

    fn device(name: &str) -> Vec<u8> {
        let mut entry = vec![0u8; 80];
        entry[..4].copy_from_slice(&1.2f32.to_le_bytes());
        entry[4] = 0xff;
        entry[5..5 + name.len()].copy_from_slice(name.as_bytes());
        entry
    }

    /// `filter.info` with the values of a camera original: intensity 90,
    /// orientation 270, mirrored, LUT `fuji_cc.bin`.
    fn filter(version: f32, len: usize) -> Vec<u8> {
        let mut info = vec![0u8; len];
        info[..4].copy_from_slice(&version.to_le_bytes());
        for (offset, value) in [(4, 90i32), (8, 270), (12, 1), (24, 1)] {
            info[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        info[28..39].copy_from_slice(b"fuji_cc.bin");
        if len >= 132 {
            info[128..132].copy_from_slice(&5123.4f32.to_le_bytes());
        }
        if len >= 140 {
            info[132..136].copy_from_slice(&212.5f32.to_le_bytes());
            info[136..140].copy_from_slice(&1.0f32.to_le_bytes());
        }
        if len >= 206 {
            info[152..156].copy_from_slice(&3i32.to_le_bytes());
            info[156..164].copy_from_slice(b"portrait");
        }
        info
    }

    #[test]
    fn file_without_a_tail_reports_nothing() {
        assert_eq!(inspect(&[0u8; 64]), None);
        assert_eq!(inspect(b"\xff\xd8\xff\xd9"), None);
    }

    #[test]
    fn lists_entries_and_reads_the_device_name() {
        let file = tail_file(&[
            ("private.emptyspace", &[0u8; 4]),
            ("watermark.device", &device("OPPO Find X10")),
        ]);
        let report = inspect(&file).expect("report");
        assert_eq!(
            report["entries"],
            json!([
                { "name": "private.emptyspace", "length": 4 },
                { "name": "watermark.device", "length": 80 },
            ])
        );
        assert_eq!(report["device"], "OPPO Find X10");
        // The device name alone is not a watermark.
        assert_eq!(report["watermark"], json!({ "kind": "none" }));
        assert!(report.get("filter").is_none());
        assert!(report.get("portrait").is_none());
    }

    #[test]
    fn watermark_kind_follows_the_entries() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&3688u32.to_be_bytes());
        png.extend_from_slice(&218u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0]);
        let overlay = inspect(&tail_file(&[("watermark", &png)])).expect("report");
        assert_eq!(overlay["watermark"], json!({ "kind": "png", "width": 3688, "height": 218 }));

        let mut params = vec![0u8; 6492];
        params[..4].copy_from_slice(&1f32.to_le_bytes());
        params[4..30].copy_from_slice(b"hassel_style_master_mode_1");
        // No readable primary in this file, so the style is all there is.
        let frame = inspect(&tail_file(&[("watermark.master.params", &params)])).expect("report");
        assert_eq!(
            frame["watermark"],
            json!({ "kind": "frame", "style": "hassel_style_master_mode_1" })
        );

        let unknown = inspect(&tail_file(&[("watermark.params", &[0u8; 63])])).expect("report");
        assert_eq!(unknown["watermark"], json!({ "kind": "unknown" }));
    }

    #[test]
    fn filter_fields_appear_with_their_version() {
        let v4 = inspect(&tail_file(&[("filter.info", &filter(4.0, 140))])).expect("report");
        assert_eq!(
            v4["filter"],
            json!({
                "version": 4.0,
                "intensity": 90,
                "sourceOrientation": 270,
                "mirrored": true,
                "softLight": false,
                "enabled": true,
                "lut": "fuji_cc.bin",
                "colorTemperature": 5123.4,
                "luxIndex": 212.5,
                "saturation": 1.0,
            })
        );
        let v5 = inspect(&tail_file(&[("filter.info", &filter(5.1, 228))])).expect("report");
        assert_eq!(v5["filter"]["version"], 5.1);
        assert_eq!(v5["filter"]["palette"], false);
        assert_eq!(v5["filter"]["tone"], 3);
        assert_eq!(v5["filter"]["captureMode"], "portrait");
        // Version 1 stops before the colour temperature.
        let v1 = inspect(&tail_file(&[("filter.info", &filter(1.0, 128))])).expect("report");
        assert!(v1["filter"].get("colorTemperature").is_none());
        // Not a version, or too short for the fixed fields: not reported.
        for bad in [filter(0.0, 140), filter(4.0, 100)] {
            assert!(inspect(&tail_file(&[("filter.info", &bad)])).expect("report").get("filter").is_none());
        }
    }

    #[test]
    fn front_portrait_reads_the_config_fields() {
        // The 544-byte config of both front originals: depth 820x616, one
        // face, mirrorEnable 1, cameraRoll 270, f-number 4.5.
        let mut config = vec![0u8; 544];
        config[..4].copy_from_slice(&1.2f32.to_le_bytes());
        for (offset, value) in [(4, 820u32), (8, 616), (84, 1), (532, 1), (536, 270)] {
            config[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        config[540..544].copy_from_slice(&4.5f32.to_le_bytes());
        let file = tail_file(&[("front.depth", &[0u8; 8]), ("front.depth.config", &config)]);
        assert_eq!(
            inspect(&file).expect("report")["portrait"],
            json!({
                "camera": "front",
                "depthWidth": 820,
                "depthHeight": 616,
                "faceCount": 1,
                "mirrored": true,
                "fNumber": 4.5,
            })
        );
        // Without a config the camera is still known.
        let bare = tail_file(&[("front.depth", &[0u8; 8])]);
        assert_eq!(inspect(&bare).expect("report")["portrait"], json!({ "camera": "front" }));
    }

    #[test]
    fn rear_portrait_reads_the_simulated_aperture() {
        let mut config = vec![0u8; 512];
        config[..4].copy_from_slice(&3f32.to_le_bytes());
        config[292..296].copy_from_slice(&1.4f32.to_le_bytes());
        let file = tail_file(&[("rear.depth", &[0u8; 8]), ("rear.depth.config", &config)]);
        assert_eq!(
            inspect(&file).expect("report")["portrait"],
            json!({ "camera": "rear", "fNumber": 1.4 })
        );
    }
}
