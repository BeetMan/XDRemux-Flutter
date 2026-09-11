//! Fast on-demand inspection of photo EXIF and HDR metadata.
//!
//! Extracts camera shooting parameters (Make, Model, F-Number, Shutter, ISO,
//! Focal Length, Exposure Bias, DateTime, Dimensions) and HDR GainMap attributes
//! for both JPEG and HEIF/AVIF containers.

use std::fs;
use std::ops::Deref;
use std::path::Path;

use crate::container;
use crate::edr;
use crate::isobmff_write;

#[derive(Debug, Clone, Default)]
pub struct PhotoDetails {
    pub success: bool,
    pub error_message: Option<String>,

    // EXIF Shooting & Camera Parameters
    pub make: Option<String>,
    pub model: Option<String>,
    pub date_time: Option<String>,
    pub exposure_time: Option<String>,
    pub f_number: Option<String>,
    pub iso: Option<String>,
    pub focal_length: Option<String>,
    pub focal_length_35mm: Option<String>,
    pub exposure_bias: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,

    // HDR GainMap Properties
    pub hdr_kind: Option<String>,
    pub edr_scale: Option<f64>,
    pub gain_map_max: Option<f64>,
}

impl PhotoDetails {
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        map.insert("success".into(), serde_json::Value::Bool(self.success));
        if let Some(err) = &self.error_message {
            map.insert("errorMessage".into(), serde_json::Value::String(err.clone()));
        }
        if let Some(v) = &self.make {
            map.insert("make".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.model {
            map.insert("model".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.date_time {
            map.insert("dateTime".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.exposure_time {
            map.insert("exposureTime".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.f_number {
            map.insert("fNumber".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.iso {
            map.insert("iso".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.focal_length {
            map.insert("focalLength".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.focal_length_35mm {
            map.insert("focalLength35mm".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = &self.exposure_bias {
            map.insert("exposureBias".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = self.width {
            map.insert("width".into(), serde_json::Value::Number(v.into()));
        }
        if let Some(v) = self.height {
            map.insert("height".into(), serde_json::Value::Number(v.into()));
        }
        if let Some(v) = &self.hdr_kind {
            map.insert("hdrKind".into(), serde_json::Value::String(v.clone()));
        }
        if let Some(v) = self.edr_scale {
            if let Some(n) = serde_json::Number::from_f64(v) {
                map.insert("edrScale".into(), serde_json::Value::Number(n));
            }
        }
        if let Some(v) = self.gain_map_max {
            if let Some(n) = serde_json::Number::from_f64(v) {
                map.insert("gainMapMax".into(), serde_json::Value::Number(n));
            }
        }
        serde_json::Value::Object(map)
    }
}

#[derive(Clone, Copy)]
struct Bo(bool); // true = big-endian ("MM"), false = little-endian ("II")

impl Bo {
    #[inline]
    fn u16(self, b: &[u8]) -> u16 {
        if self.0 {
            u16::from_be_bytes([b[0], b[1]])
        } else {
            u16::from_le_bytes([b[0], b[1]])
        }
    }

    #[inline]
    fn u32(self, b: &[u8]) -> u32 {
        if self.0 {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        }
    }

    #[inline]
    fn i32(self, b: &[u8]) -> i32 {
        if self.0 {
            i32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            i32::from_le_bytes([b[0], b[1], b[2], b[3]])
        }
    }
}

fn tiff_header(tiff: &[u8]) -> Option<(Bo, u32)> {
    if tiff.len() < 8 {
        return None;
    }
    let bo = match &tiff[0..2] {
        b"MM" => Bo(true),
        b"II" => Bo(false),
        _ => return None,
    };
    if bo.u16(&tiff[2..4]) != 42 {
        return None;
    }
    Some((bo, bo.u32(&tiff[4..8])))
}

#[inline]
fn type_size(typ: u16) -> usize {
    match typ {
        1 | 2 | 6 | 7 => 1,
        3 | 8 => 2,
        4 | 9 | 11 => 4,
        5 | 10 | 12 => 8,
        _ => 1,
    }
}

struct IfdEntry {
    tag: u16,
    typ: u16,
    count: u32,
    val_bytes: [u8; 4],
    val_offset: u32,
}

enum EntryData<'a> {
    Inline([u8; 4], usize),
    Borrowed(&'a [u8]),
}

impl<'a> Deref for EntryData<'a> {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        match self {
            EntryData::Inline(b, len) => &b[..*len],
            EntryData::Borrowed(s) => s,
        }
    }
}

fn read_ifd(tiff: &[u8], bo: Bo, ifd_off: u32) -> Option<Vec<IfdEntry>> {
    let base = ifd_off as usize;
    if base + 2 > tiff.len() {
        return None;
    }
    let count = bo.u16(&tiff[base..base + 2]) as usize;
    let entries_start = base + 2;
    if entries_start + count * 12 > tiff.len() {
        return None;
    }
    let mut entries = Vec::with_capacity(count);
    for i in 0..count {
        let e = entries_start + i * 12;
        let tag = bo.u16(&tiff[e..e + 2]);
        let typ = bo.u16(&tiff[e + 2..e + 4]);
        let cnt = bo.u32(&tiff[e + 4..e + 8]);
        let mut val_bytes = [0u8; 4];
        val_bytes.copy_from_slice(&tiff[e + 8..e + 12]);
        let val_offset = bo.u32(&val_bytes);
        entries.push(IfdEntry {
            tag,
            typ,
            count: cnt,
            val_bytes,
            val_offset,
        });
    }
    Some(entries)
}

fn entry_bytes<'a>(tiff: &'a [u8], _bo: Bo, entry: &IfdEntry) -> Option<EntryData<'a>> {
    let total = (entry.count as usize).checked_mul(type_size(entry.typ))?;
    if total <= 4 {
        Some(EntryData::Inline(entry.val_bytes, total))
    } else {
        let off = entry.val_offset as usize;
        if off.checked_add(total)? <= tiff.len() {
            Some(EntryData::Borrowed(&tiff[off..off + total]))
        } else {
            None
        }
    }
}

fn read_ascii(tiff: &[u8], bo: Bo, entry: &IfdEntry) -> Option<String> {
    let bytes = entry_bytes(tiff, bo, entry)?;
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let s = String::from_utf8_lossy(&bytes[..end]).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn read_u32(tiff: &[u8], bo: Bo, entry: &IfdEntry) -> Option<u32> {
    let bytes = entry_bytes(tiff, bo, entry)?;
    match entry.typ {
        3 if bytes.len() >= 2 => Some(bo.u16(&bytes[0..2]) as u32),
        4 if bytes.len() >= 4 => Some(bo.u32(&bytes[0..4])),
        _ => None,
    }
}

fn read_urational(tiff: &[u8], bo: Bo, entry: &IfdEntry) -> Option<(u32, u32)> {
    if entry.typ != 5 {
        return None;
    }
    let bytes = entry_bytes(tiff, bo, entry)?;
    if bytes.len() < 8 {
        return None;
    }
    Some((bo.u32(&bytes[0..4]), bo.u32(&bytes[4..8])))
}

fn read_srational(tiff: &[u8], bo: Bo, entry: &IfdEntry) -> Option<(i32, i32)> {
    if entry.typ != 10 {
        return None;
    }
    let bytes = entry_bytes(tiff, bo, entry)?;
    if bytes.len() < 8 {
        return None;
    }
    Some((bo.i32(&bytes[0..4]), bo.i32(&bytes[4..8])))
}

fn format_exposure_time(num: u32, den: u32) -> Option<String> {
    if num == 0 || den == 0 {
        return None;
    }
    if num >= den {
        if num % den == 0 {
            Some(format!("{}s", num / den))
        } else {
            Some(format!("{:.1}s", num as f64 / den as f64))
        }
    } else {
        let frac = (den as f64 / num as f64).round() as u64;
        Some(format!("1/{}s", frac))
    }
}

fn format_f_number(num: u32, den: u32) -> Option<String> {
    if num == 0 || den == 0 {
        return None;
    }
    let val = num as f64 / den as f64;
    if (val * 10.0).round() == val * 10.0 {
        Some(format!("f/{:.1}", val))
    } else {
        Some(format!("f/{:.2}", val))
    }
}

fn format_focal_length(num: u32, den: u32) -> Option<String> {
    if num == 0 || den == 0 {
        return None;
    }
    let val = num as f64 / den as f64;
    Some(format!("{:.1}mm", val))
}

fn format_exposure_bias(num: i32, den: i32) -> Option<String> {
    if den == 0 {
        return None;
    }
    let val = num as f64 / den as f64;
    if val.abs() < 0.01 {
        Some("0.0 EV".to_string())
    } else if val > 0.0 {
        Some(format!("+{:.1} EV", val))
    } else {
        Some(format!("{:.1} EV", val))
    }
}

fn format_date_time(raw: String) -> String {
    // Standard Exif date is "YYYY:MM:DD HH:MM:SS" -> convert date colons to hyphens
    if raw.len() >= 10 && raw.as_bytes()[4] == b':' && raw.as_bytes()[7] == b':' {
        let mut chars: Vec<char> = raw.chars().collect();
        chars[4] = '-';
        chars[7] = '-';
        chars.into_iter().collect()
    } else {
        raw
    }
}

/// Parse EXIF IFD0 and ExifSubIFD tags from raw TIFF data.
fn parse_tiff_exif(tiff: &[u8], details: &mut PhotoDetails) {
    let (bo, ifd0_off) = match tiff_header(tiff) {
        Some(h) => h,
        None => return,
    };
    let ifd0 = match read_ifd(tiff, bo, ifd0_off) {
        Some(entries) => entries,
        None => return,
    };

    let mut exif_ifd_off = None;
    let mut fallback_datetime = None;

    for e in &ifd0 {
        match e.tag {
            0x010F => details.make = read_ascii(tiff, bo, e),
            0x0110 => details.model = read_ascii(tiff, bo, e),
            0x0132 => fallback_datetime = read_ascii(tiff, bo, e),
            0x0100 if details.width.is_none() => details.width = read_u32(tiff, bo, e),
            0x0101 if details.height.is_none() => details.height = read_u32(tiff, bo, e),
            0x8769 => exif_ifd_off = Some(e.val_offset),
            _ => {}
        }
    }

    if let Some(sub_off) = exif_ifd_off {
        if let Some(sub_entries) = read_ifd(tiff, bo, sub_off) {
            for e in &sub_entries {
                match e.tag {
                    0x829A => {
                        if let Some((n, d)) = read_urational(tiff, bo, e) {
                            details.exposure_time = format_exposure_time(n, d);
                        }
                    }
                    0x829D => {
                        if let Some((n, d)) = read_urational(tiff, bo, e) {
                            details.f_number = format_f_number(n, d);
                        }
                    }
                    0x8827 => {
                        if let Some(iso_val) = read_u32(tiff, bo, e) {
                            details.iso = Some(format!("ISO {iso_val}"));
                        }
                    }
                    0x9003 => {
                        if let Some(dt) = read_ascii(tiff, bo, e) {
                            details.date_time = Some(format_date_time(dt));
                        }
                    }
                    0x9204 => {
                        if let Some((n, d)) = read_srational(tiff, bo, e) {
                            details.exposure_bias = format_exposure_bias(n, d);
                        }
                    }
                    0x920A => {
                        if let Some((n, d)) = read_urational(tiff, bo, e) {
                            details.focal_length = format_focal_length(n, d);
                        }
                    }
                    0xA405 => {
                        if let Some(fl35) = read_u32(tiff, bo, e) {
                            details.focal_length_35mm = Some(format!("{fl35}mm"));
                        }
                    }
                    0xA002 if details.width.is_none() => details.width = read_u32(tiff, bo, e),
                    0xA003 if details.height.is_none() => details.height = read_u32(tiff, bo, e),
                    _ => {}
                }
            }
        }
    }

    if details.date_time.is_none() {
        if let Some(dt) = fallback_datetime {
            details.date_time = Some(format_date_time(dt));
        }
    }
}

fn find_tiff_slice(bytes: &[u8]) -> Option<&[u8]> {
    if let Some(pos) = bytes.windows(6).position(|w| w == b"Exif\0\0") {
        let tiff = &bytes[pos + 6..];
        if tiff.starts_with(b"II*\0") || tiff.starts_with(b"MM\0*") {
            return Some(tiff);
        }
    }
    if let Some(pos) = bytes.windows(4).position(|w| w == b"II*\0" || w == b"MM\0*") {
        return Some(&bytes[pos..]);
    }
    None
}

/// Inspects photo details from in-memory photo buffer.
pub fn inspect_photo_details_from_bytes(data: &[u8]) -> PhotoDetails {
    let mut details = PhotoDetails {
        success: true,
        ..Default::default()
    };

    // 1. JPEG path
    if data.starts_with(b"\xff\xd8\xff") {
        let mut pos = 2;
        let mut tiff_slice: Option<&[u8]> = None;
        while pos + 4 <= data.len() {
            if data[pos] != 0xFF {
                pos += 1;
                continue;
            }
            let marker = data[pos + 1];
            if marker == 0xD9 || marker == 0xDA {
                break;
            }
            if marker == 0x00 || marker == 0xFF || (0xD0..=0xD7).contains(&marker) {
                pos += 2;
                continue;
            }
            let seg_len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
            if seg_len < 2 || pos + 2 + seg_len > data.len() {
                break;
            }
            let payload = &data[pos + 4..pos + 2 + seg_len];
            if marker == 0xE1 && tiff_slice.is_none() {
                if let Some(tiff) = find_tiff_slice(payload) {
                    tiff_slice = Some(tiff);
                }
            } else if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) && payload.len() >= 5 {
                if details.height.is_none() {
                    details.height = Some(u16::from_be_bytes([payload[1], payload[2]]) as u32);
                }
                if details.width.is_none() {
                    details.width = Some(u16::from_be_bytes([payload[3], payload[4]]) as u32);
                }
            }
            pos += 2 + seg_len;
        }

        if let Some(tiff) = tiff_slice {
            parse_tiff_exif(tiff, &mut details);
        }
    }
    // 2. HEIF / ISO BMFF path
    else if data.len() >= 12 && &data[4..8] == b"ftyp" {
        if let Ok(Some(exif_bytes)) = isobmff_write::read_exif_payload(data) {
            if let Some(tiff) = find_tiff_slice(&exif_bytes) {
                parse_tiff_exif(tiff, &mut details);
            }
        }
        if details.width.is_none() || details.height.is_none() {
            if let Ok(meta) = crate::isobmff::parse_source_meta(data) {
                for prop in &meta.props {
                    if prop.ptype == "ispe" {
                        if let Ok((w, h)) = crate::isobmff::ispe_dimensions(&prop.raw) {
                            if details.width.is_none() {
                                details.width = Some(w);
                                details.height = Some(h);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. HDR GainMap inspection (UHDR or LHDR)
    if let Ok(extracted) = crate::extract_lhdr_or_uhdr_from_bytes(data) {
        details.hdr_kind = Some(extracted.mode.clone());
        let (edr_scale, gain_map_max) = if extracted.mode == "uhdr" {
            let scale = if extracted.meta_floats.len() >= 19 {
                extracted.meta_floats[18]
            } else {
                1.0
            };
            let ratio_max = if extracted.meta_floats.len() >= 7 {
                extracted.meta_floats[4]
                    .max(extracted.meta_floats[5])
                    .max(extracted.meta_floats[6])
            } else {
                1.0
            };
            let gm_max = if ratio_max > 0.0 {
                ratio_max.log2()
            } else {
                0.0
            };
            (scale as f64, gm_max as f64)
        } else {
            let edr = edr::edr_scale_calculator(&extracted.meta_floats);
            let gm_max = if edr > 1.0 { (edr as f64).log2() } else { 0.0 };
            (edr as f64, gm_max)
        };
        details.edr_scale = Some((edr_scale * 10.0).round() / 10.0);
        details.gain_map_max = Some((gain_map_max * 10.0).round() / 10.0);
    }

    details
}

/// Inspects photo details from a file path.
pub fn inspect_photo_details<P: AsRef<Path>>(path: P) -> Result<PhotoDetails, String> {
    let data = fs::read(path).map_err(|e| format!("cannot read photo file: {e}"))?;
    Ok(inspect_photo_details_from_bytes(&data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inspects_real_jpeg_sample_if_present() {
        let path = r"C:\Users\Beet\Desktop\Find X10\IMG20260910130102.jpg";
        if let Ok(details) = inspect_photo_details(path) {
            println!("JPEG details: {:?}", details);
            assert!(details.success);
            assert!(details.model.is_some());
            assert!(details.f_number.is_some());
            assert!(details.exposure_time.is_some());
            assert!(details.focal_length.is_some());
            assert!(details.iso.is_some());
            assert!(details.width.is_some());
            assert!(details.height.is_some());
        }
    }

    #[test]
    fn inspects_real_heic_sample_if_present() {
        let path = r"C:\Users\Beet\Desktop\Find X10\IMG20260910130226.heic";
        if let Ok(data) = fs::read(path) {
            let res = isobmff_write::read_exif_payload(&data);
            println!("HEIC read_exif_payload res: {:?}", res.as_ref().map(|p| p.as_ref().map(|v| &v[..v.len().min(32)])));
            let details = inspect_photo_details(path).unwrap();
            println!("HEIC details: {:?}", details);
        }
    }
}
