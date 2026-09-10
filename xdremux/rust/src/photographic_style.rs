//! Photographic Style inspection and un-styled base photo extraction for OPPO/OnePlus photos.

use std::fs;
use std::path::Path;
use serde_json::json;

use crate::container::{extract_tail_entry, find_extension_region, parse_manifest};

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
    let src_len = src_entry.length as usize;
    if src_len == 0 {
        return None;
    }

    // Must have filter.info (style recipe) or master.mode.preset.info
    let filter_entry = entries
        .iter()
        .find(|e| e.name == "filter.info" || e.name == "filtEr.info");
    let master_entry = entries
        .iter()
        .find(|e| e.name == "master.mode.preset.info");

    if filter_entry.is_none() && master_entry.is_none() {
        return None;
    }

    let mut intensity = 100;
    let mut tone = 0;
    let mut version = String::from("1.0");
    let mut lut_name = String::new();

    if let Some(entry) = filter_entry {
        let start = (json_start as i64 - entry.offset as i64) as usize;
        let end = start.checked_add(entry.length as usize).unwrap_or(start);
        if end <= ext.len() && entry.length >= 28 {
            let payload = &ext[start..end];
            if payload.len() >= 4 {
                let v = f32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
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
        let start = (json_start as i64 - entry.offset as i64) as usize;
        let end = start.checked_add(entry.length as usize).unwrap_or(start);
        if end <= ext.len() && entry.length >= 16 {
            let payload = &ext[start..end];
            // Extract UTF-8 preset string (usually at offset 200 or 12)
            if payload.len() > 200 {
                let slice = &payload[200..];
                let null_pos = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
                let text = String::from_utf8_lossy(&slice[..null_pos]).trim().to_string();
                if !text.is_empty() && text != "无" {
                    master_name = text;
                }
            }
            if master_name.is_empty() && payload.len() > 12 {
                let slice = &payload[12..];
                let null_pos = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
                let text = String::from_utf8_lossy(&slice[..null_pos]).trim().to_string();
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
    fs::write(output_path, &base_bytes)
        .map_err(|e| format!("failed to write base photo to {}: {e}", output_path.display()))?;
    Ok(base_bytes.len())
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

        let (zh, en) = map_style_name("portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin", "");
        assert_eq!(zh, "胶片");
        assert_eq!(en, "Portra Film");
    }

    #[test]
    fn inspects_real_style_sample_if_present() {
        let path = r"C:\Users\Beet\Desktop\Find X10\IMG20260910130102.jpg";
        if let Ok(data) = fs::read(path) {
            let info = parse_photographic_style(&data).expect("should parse style");
            assert!(info.has_style);
            assert_eq!(info.style_name_zh, "清透");
            assert_eq!(info.style_name_en, "Fresh");
            assert_eq!(info.lut_name, "qing_tou.bin");
            assert_eq!(info.intensity, 100);
            assert_eq!(info.tone, 90);
            assert!(info.base_image_bytes > 8_000_000);
        }
    }

    #[test]
    fn extracts_real_style_base_photo_if_present() {
        let path = r"C:\Users\Beet\Desktop\Find X10\IMG20260910130102.jpg";
        if let Ok(data) = fs::read(path) {
            let temp_out = std::env::temp_dir().join("test_extracted_base.jpg");
            let sz = extract_base_photo_to_file(&data, &temp_out).expect("should extract base");
            assert!(sz > 8_000_000);
            assert!(temp_out.exists());
            let _ = fs::remove_file(temp_out);
        }
    }
}
