//! Photographic Style inspection and un-styled base photo extraction for OPPO/OnePlus photos.

use serde_json::json;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

use crate::container::{
    extract_tail_entry, find_extension_region, parse_manifest, tail_entry_slice,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotographicStyleInfo {
    pub has_style: bool,
    pub style_name_zh: String,
    pub style_name_en: String,
    pub lut_name: String,
    pub base_image_bytes: usize,
    pub intensity: i32,
    pub tone: i32,
    pub version: String,
}

impl PhotographicStyleInfo {
    pub fn to_json(&self) -> serde_json::Value {
        json!({
            "hasPhotographicStyle": self.has_style,
            "styleNameZh": self.style_name_zh,
            "styleNameEn": self.style_name_en,
            "lutName": self.lut_name,
            "baseImageBytes": self.base_image_bytes,
            "intensity": self.intensity,
            "tone": self.tone,
            "version": self.version,
        })
    }
}

/// Inspect raw photo bytes for OPPO Photographic Style metadata and embedded un-styled base image.
pub fn parse_photographic_style(data: &[u8]) -> Option<PhotographicStyleInfo> {
    let (_ext_start, ext) = find_extension_region(data).ok()?;
    let (entries, json_start, _) = parse_manifest(ext)?;

    // Must have src.image entry (unrendered base photo)
    let src_entry = entries.iter().find(|e| e.name == "src.image")?;
    let src_len = tail_entry_slice(ext, json_start, src_entry)?.len();
    if src_len == 0 {
        return None;
    }

    // Must have filter.info (style recipe) or master.mode.preset.info
    let filter_entry = entries
        .iter()
        .find(|e| e.name == "filter.info" || e.name == "filtEr.info");
    let master_entry = entries.iter().find(|e| e.name == "master.mode.preset.info");

    if filter_entry.is_none() && master_entry.is_none() {
        return None;
    }

    let mut intensity = 100;
    let mut tone = 0;
    let mut version = String::from("1.0");
    let mut lut_name = String::new();

    if let Some(entry) = filter_entry {
        let payload = tail_entry_slice(ext, json_start, entry)?;
        if payload.len() < 28 {
            return None;
        }
        {
            if payload.len() >= 4 {
                let v = f32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
                if !v.is_finite() {
                    return None;
                }
                version = format!("{:.1}", v);
            }
            if payload.len() >= 12 {
                intensity = i32::from_le_bytes([payload[4], payload[5], payload[6], payload[7]]);
                tone = i32::from_le_bytes([payload[8], payload[9], payload[10], payload[11]]);
            }
            if payload.len() > 28 {
                let null_pos = payload[28..]
                    .iter()
                    .position(|&b| b == 0)
                    .unwrap_or(payload.len() - 28);
                lut_name = String::from_utf8_lossy(&payload[28..28 + null_pos]).to_string();
            }
        }
    }

    let mut master_name = String::new();
    if let Some(entry) = master_entry {
        let payload = tail_entry_slice(ext, json_start, entry)?;
        if payload.len() < 16 {
            return None;
        }
        {
            // Extract UTF-8 preset string (usually at offset 200 or 12)
            if payload.len() > 200 {
                let slice = &payload[200..];
                let null_pos = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
                let text = String::from_utf8_lossy(&slice[..null_pos])
                    .trim()
                    .to_string();
                if !text.is_empty() && text != "无" {
                    master_name = text;
                }
            }
            if master_name.is_empty() && payload.len() > 12 {
                let slice = &payload[12..];
                let null_pos = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
                let text = String::from_utf8_lossy(&slice[..null_pos])
                    .trim()
                    .to_string();
                if !text.is_empty() && text != "无" {
                    master_name = text;
                }
            }
        }
    }

    let (name_zh, name_en) = map_style_name(&lut_name, &master_name);

    Some(PhotographicStyleInfo {
        has_style: true,
        style_name_zh: name_zh,
        style_name_en: name_en,
        lut_name,
        base_image_bytes: src_len,
        intensity,
        tone,
        version,
    })
}

/// Extract the un-styled base photo directly from the container tail and write to `output_path`.
pub fn extract_base_photo_to_file(data: &[u8], output_path: &Path) -> Result<usize, String> {
    let base_bytes = extract_tail_entry(data, "src.image")
        .ok_or_else(|| "src.image entry not found in tail manifest".to_string())?;
    // Raw export deliberately retains the embedded JPEG bytes (including its
    // own EXIF/orientation), not the styled outer image's capture metadata.
    // Never label an arbitrary tail payload as a JPEG or overwrite a source.
    validate_base_jpeg(&base_bytes)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output_path)
        .map_err(|e| {
            format!(
                "cannot create base photo {} (destination must not exist): {e}",
                output_path.display()
            )
        })?;
    if let Err(e) = file.write_all(&base_bytes).and_then(|_| file.flush()) {
        drop(file);
        let _ = std::fs::remove_file(output_path);
        return Err(format!("failed to write base photo: {e}"));
    }
    Ok(base_bytes.len())
}

fn validate_base_jpeg(data: &[u8]) -> Result<(), String> {
    if !data.starts_with(b"\xff\xd8") {
        return Err("Embedded base is not a supported JPEG; raw export requires JPEG".into());
    }
    let mut decoder = jpeg_decoder::Decoder::new(data);
    decoder.set_max_decoding_buffer_size(256 * 1024 * 1024);
    decoder
        .decode()
        .map_err(|e| format!("Invalid embedded base JPEG: {e}"))?;
    Ok(())
}

fn map_style_name(lut: &str, master: &str) -> (String, String) {
    if !master.is_empty() && master != "无" {
        let en = match master {
            "清透" => "Fresh",
            "通透" => "Transparent",
            "柔和" => "Soft",
            _ => master,
        };
        return (master.to_string(), en.to_string());
    }
    let lower = lut.to_lowercase();
    if lower.contains("qing_tou") {
        ("清透".into(), "Fresh".into())
    } else if lower.contains("hu_po") {
        ("琥珀".into(), "Amber".into())
    } else if lower.contains("portra") {
        ("胶片".into(), "Portra Film".into())
    } else if lower.contains("rou_he") {
        ("柔和".into(), "Soft".into())
    } else if lower.contains("fu_gu") {
        ("复古".into(), "Retro".into())
    } else if lower.contains("hei_bai") {
        ("黑白".into(), "B&W".into())
    } else if lower.contains("dian_ying") {
        ("电影".into(), "Cinema".into())
    } else if !lut.is_empty() {
        let stem = lut.strip_suffix(".bin").unwrap_or(lut);
        (stem.to_string(), stem.to_string())
    } else {
        ("摄影风格".into(), "Style".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_common_styles_correctly() {
        let (zh, en) = map_style_name("qing_tou.bin", "");
        assert_eq!(zh, "清透");
        assert_eq!(en, "Fresh");

        let (zh, en) = map_style_name("hu_po.bin", "");
        assert_eq!(zh, "琥珀");
        assert_eq!(en, "Amber");

        let (zh, en) = map_style_name(
            "portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin",
            "",
        );
        assert_eq!(zh, "胶片");
        assert_eq!(en, "Portra Film");
    }

    #[test]
    fn deterministic_recipe_and_checked_ranges() {
        let mut filter = vec![0u8; 28];
        filter[0..4].copy_from_slice(&1f32.to_le_bytes());
        filter[4..8].copy_from_slice(&100i32.to_le_bytes());
        filter[8..12].copy_from_slice(&90i32.to_le_bytes());
        filter.extend_from_slice(b"qing_tou.bin\0");
        let fixture =
            crate::container::test_tail(&[("src.image", b"base"), ("filter.info", &filter)]);
        let info = parse_photographic_style(&fixture).unwrap();
        assert_eq!(info.style_name_en, "Fresh");
        assert_eq!(info.tone, 90);
        for offset in [0, 1, u64::MAX] {
            let malformed = format!("base[{{\"name\":\"src.image\",\"offset\":{offset},\"length\":4}},{{\"name\":\"filter.info\",\"offset\":4,\"length\":40}}]");
            assert!(parse_photographic_style(malformed.as_bytes()).is_none());
        }
    }

    #[test]
    fn raw_export_rejects_invalid_payload_and_collision() {
        let path =
            std::env::temp_dir().join(format!("xdremux-base-test-{}.jpg", std::process::id()));
        let fixture = crate::container::test_tail(&[("src.image", b"not JPEG")]);
        assert!(extract_base_photo_to_file(&fixture, &path).is_err());
        assert!(!path.exists());
        // Existing destinations must survive even if the source is malformed.
        std::fs::write(&path, b"original").unwrap();
        assert!(extract_base_photo_to_file(&fixture, &path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"original");
        std::fs::remove_file(path).unwrap();
        assert!(validate_base_jpeg(b"\xff\xd8broken").is_err());
    }
    #[test]
    fn raw_export_preserves_jpeg_bytes_and_refuses_existing_destination() {
        // Fixed 2x2 RGB JPEG with EXIF orientation=6 and capture datetime.
        let hex = concat!(
            "ffd8ffe000104a46494600010100000100010000ffe100424578696600004d4d002a00000008000201120003000000010006",
            "000001320002000000140000002600000000323032363a30393a31302031333a30313a303200ffdb00430008060607060508",
            "0707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30313434341f27393d",
            "38323c2e333432ffdb0043010909090c0b0c180d0d1832211c21323232323232323232323232323232323232323232323232",
            "3232323232323232323232323232323232323232323232323232ffc00011080002000203012200021101031101ffc4001f00",
            "00010501010101010100000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01",
            "020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a34",
            "35363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495",
            "969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9",
            "eaf1f2f3f4f5f6f7f8f9faffc4001f0100030101010101010101010000000000000102030405060708090a0bffc400b51100",
            "020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f0156272",
            "d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475",
            "767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9ca",
            "d2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9faffda000c03010002110311003f00f11a28a2b6323fffd9",
        );
        let jpeg: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        let fixture = crate::container::test_tail(&[("src.image", &jpeg)]);
        let dir = std::env::temp_dir().join(format!("xdremux-valid-base-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("base.jpg");
        assert_eq!(
            extract_base_photo_to_file(&fixture, &path).unwrap(),
            jpeg.len()
        );
        assert_eq!(std::fs::read(&path).unwrap(), jpeg);
        assert!(extract_base_photo_to_file(&fixture, &path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), jpeg);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_json_and_ranges_never_panic_or_extract_manifest() {
        for manifest in [
            r#"[{"name":}]"#,
            r#"[{"name":"src.image","offset":-1,"length":1}]"#,
            r#"[{"name":"src.image","offset":18446744073709551615,"length":1}]"#,
            r#"[{"name":"src.image","offset":1,"length":18446744073709551615}]"#,
            r#"[{"name":"src.image","offset":0,"length":1}]"#,
            r#"[{"name":"src.image","offset":1,"length":1},{"name":"src.image","offset":1,"length":1}]"#,
        ] {
            let input = format!("x{manifest}");
            assert!(extract_tail_entry(input.as_bytes(), "src.image").is_none());
            assert!(parse_photographic_style(input.as_bytes()).is_none());
        }
    }
}
