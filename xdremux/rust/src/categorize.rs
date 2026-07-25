//! Capture-mode classification from OPPO/OnePlus EXIF UserComment metadata.
//!
//! The format is shared with the upstream `categorize` command: most phones
//! store `Oplus_<flags>` in TIFF tag 0x9286, while some files expose the same
//! value only as a raw string or as JSON `{ "oplustag": <flags> }`.

use std::collections::HashSet;
use std::path::Path;

/// A user-visible camera capture mode, selected from the first matching bit
/// in upstream priority order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
    Master,
    RicohGr,
    Professional,
    Portrait,
    Night,
    Panorama,
    TimeLapse,
    UltraHighResolution,
    IdPhoto,
    Sticker,
    EnhancedText,
    GroupPhoto,
    DoubleExposure,
    Beauty,
    Normal,
}

impl CaptureMode {
    pub const fn key(self) -> &'static str {
        match self {
            Self::Master => "master",
            Self::RicohGr => "ricoh-gr",
            Self::Professional => "professional",
            Self::Portrait => "portrait",
            Self::Night => "night",
            Self::Panorama => "panorama",
            Self::TimeLapse => "time-lapse",
            Self::UltraHighResolution => "ultra-high-resolution",
            Self::IdPhoto => "id-photo",
            Self::Sticker => "sticker",
            Self::EnhancedText => "enhanced-text",
            Self::GroupPhoto => "group-photo",
            Self::DoubleExposure => "double-exposure",
            Self::Beauty => "beauty",
            Self::Normal => "normal",
        }
    }

    pub const fn folder_name(self) -> &'static str {
        match self {
            Self::Master => "大师模式",
            Self::RicohGr => "RICOH GR",
            Self::Professional => "专业模式",
            Self::Portrait => "人像",
            Self::Night => "夜景",
            Self::Panorama => "全景",
            Self::TimeLapse => "延时摄影",
            Self::UltraHighResolution => "超清",
            Self::IdPhoto => "证件照",
            Self::Sticker => "贴纸",
            Self::EnhancedText => "超级文本",
            Self::GroupPhoto => "合影",
            Self::DoubleExposure => "双重曝光",
            Self::Beauty => "美颜",
            Self::Normal => "普通拍照",
        }
    }

    pub const fn bit(self) -> u64 {
        match self {
            Self::Master => 0x1_0000_0000,
            Self::RicohGr => 0x8000_0000,
            Self::Professional => 0x100,
            Self::Portrait => 0x10,
            Self::Night => 0x800,
            Self::Panorama => 0x4,
            Self::TimeLapse => 0x8,
            Self::UltraHighResolution => 0x2000,
            Self::IdPhoto => 0x4000,
            Self::Sticker => 0x200,
            Self::EnhancedText => 0x1000,
            Self::GroupPhoto => 0x40_0000,
            Self::DoubleExposure => 0x8000,
            Self::Beauty => 0x2,
            Self::Normal => 0,
        }
    }
}

const MODE_PRIORITY: [CaptureMode; 14] = [
    CaptureMode::Master,
    CaptureMode::RicohGr,
    CaptureMode::Professional,
    CaptureMode::Portrait,
    CaptureMode::Night,
    CaptureMode::Panorama,
    CaptureMode::TimeLapse,
    CaptureMode::UltraHighResolution,
    CaptureMode::IdPhoto,
    CaptureMode::Sticker,
    CaptureMode::EnhancedText,
    CaptureMode::GroupPhoto,
    CaptureMode::DoubleExposure,
    CaptureMode::Beauty,
];

/// Every flag currently understood by the upstream classifier, including
/// flags that do not map to a user-visible mode yet.
pub const KNOWN_FLAGS_MASK: u64 = ((1u64 << 33) - 1) | (1u64 << 62);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassificationStatus {
    Categorized,
    MissingUserComment,
    MalformedUserComment,
    UnknownFlags,
    UnreadableImage,
}

impl ClassificationStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Categorized => "categorized",
            Self::MissingUserComment => "missing-user-comment",
            Self::MalformedUserComment => "malformed-user-comment",
            Self::UnknownFlags => "unknown-flags",
            Self::UnreadableImage => "unreadable-image",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classification {
    pub raw_user_comment: Option<String>,
    pub tag_flags: Option<u64>,
    pub unknown_flags: u64,
    pub mode: Option<CaptureMode>,
    pub status: ClassificationStatus,
}

impl Classification {
    fn unreadable() -> Self {
        Self {
            raw_user_comment: None,
            tag_flags: None,
            unknown_flags: 0,
            mode: None,
            status: ClassificationStatus::UnreadableImage,
        }
    }
}

/// Classify a file from EXIF UserComment, with raw-byte fallbacks for files
/// whose HEIF/JPEG wrapper cannot be decoded on the current platform.
pub fn classify_path(path: impl AsRef<Path>) -> Classification {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(_) => return Classification::unreadable(),
    };
    classify_bytes(&data)
}

/// Classify an image byte buffer. Exposed for tests and FFI callers that have
/// already loaded the file.
pub fn classify_bytes(data: &[u8]) -> Classification {
    classify_user_comment(extract_user_comment(data).as_deref())
}

/// Apply upstream mode-priority and unknown-flag semantics to UserComment.
pub fn classify_user_comment(raw: Option<&str>) -> Classification {
    let Some(raw) = raw else {
        return Classification {
            raw_user_comment: None,
            tag_flags: None,
            unknown_flags: 0,
            mode: None,
            status: ClassificationStatus::MissingUserComment,
        };
    };
    let normalized = raw.trim_matches('\0').trim();
    if normalized.is_empty() {
        return Classification {
            raw_user_comment: None,
            tag_flags: None,
            unknown_flags: 0,
            mode: None,
            status: ClassificationStatus::MissingUserComment,
        };
    }

    let Some(flags) = parse_tag_flags(normalized) else {
        return Classification {
            raw_user_comment: Some(normalized.into()),
            tag_flags: None,
            unknown_flags: 0,
            mode: None,
            status: ClassificationStatus::MalformedUserComment,
        };
    };
    let unknown_flags = flags & !KNOWN_FLAGS_MASK;
    let mode = MODE_PRIORITY
        .into_iter()
        .find(|candidate| flags & candidate.bit() != 0);
    if mode.is_none() && unknown_flags != 0 {
        return Classification {
            raw_user_comment: Some(normalized.into()),
            tag_flags: Some(flags),
            unknown_flags,
            mode: None,
            status: ClassificationStatus::UnknownFlags,
        };
    }

    Classification {
        raw_user_comment: Some(normalized.into()),
        tag_flags: Some(flags),
        unknown_flags,
        mode: Some(mode.unwrap_or(CaptureMode::Normal)),
        status: ClassificationStatus::Categorized,
    }
}

/// Locate and decode TIFF tag 0x9286, then fall back to known raw markers.
pub fn extract_user_comment(data: &[u8]) -> Option<String> {
    for tiff in tiff_candidates(data) {
        if let Some(comment) = extract_tiff_user_comment(tiff) {
            return Some(comment);
        }
    }
    if let Some(raw) = find_prefixed_tag(data) {
        return Some(raw);
    }
    parse_json_oplustag_bytes(data).map(|flags| format!(r#"{{"oplustag":"{flags}"}}"#))
}

fn parse_tag_flags(raw: &str) -> Option<u64> {
    parse_json_oplustag_bytes(raw.as_bytes()).or_else(|| parse_prefixed_tag(raw.as_bytes()))
}

fn parse_prefixed_tag(data: &[u8]) -> Option<u64> {
    for index in 0..data.len() {
        for prefix in [b"oplus_".as_slice(), b"oppo_".as_slice()] {
            if starts_with_ascii_case_insensitive(&data[index..], prefix) {
                let digits = &data[index + prefix.len()..];
                return parse_decimal_prefix(digits);
            }
        }
    }
    None
}

fn find_prefixed_tag(data: &[u8]) -> Option<String> {
    for index in 0..data.len() {
        for prefix in [b"Oplus_".as_slice(), b"Oppo_".as_slice()] {
            if starts_with_ascii_case_insensitive(&data[index..], prefix) {
                let digits = &data[index + prefix.len()..];
                let digit_len = digits
                    .iter()
                    .take_while(|byte| byte.is_ascii_digit())
                    .count();
                if digit_len > 0 {
                    let mut raw = Vec::with_capacity(prefix.len() + digit_len);
                    raw.extend_from_slice(prefix);
                    raw.extend_from_slice(&digits[..digit_len]);
                    return String::from_utf8(raw).ok();
                }
            }
        }
    }
    None
}

fn parse_json_oplustag_bytes(data: &[u8]) -> Option<u64> {
    let key_pos = find_ascii_case_insensitive(data, b"oplustag")?;
    let rest = &data[key_pos + b"oplustag".len()..];
    let colon = rest.iter().position(|byte| *byte == b':')?;
    let mut value = &rest[colon + 1..];
    while matches!(value.first(), Some(byte) if byte.is_ascii_whitespace()) {
        value = &value[1..];
    }
    if value.first() == Some(&b'"') {
        value = &value[1..];
    }
    parse_decimal_prefix(value)
}

fn parse_decimal_prefix(data: &[u8]) -> Option<u64> {
    let mut value = 0u64;
    let mut saw_digit = false;
    for byte in data
        .iter()
        .copied()
        .take_while(|byte| byte.is_ascii_digit())
    {
        saw_digit = true;
        value = value.checked_mul(10)?.checked_add(u64::from(byte - b'0'))?;
    }
    saw_digit.then_some(value)
}

fn starts_with_ascii_case_insensitive(data: &[u8], prefix: &[u8]) -> bool {
    data.len() >= prefix.len()
        && data[..prefix.len()]
            .iter()
            .zip(prefix)
            .all(|(left, right)| left.eq_ignore_ascii_case(right))
}

fn find_ascii_case_insensitive(data: &[u8], needle: &[u8]) -> Option<usize> {
    data.windows(needle.len())
        .position(|window| starts_with_ascii_case_insensitive(window, needle))
}

fn tiff_candidates(data: &[u8]) -> Vec<&[u8]> {
    let mut candidates = Vec::new();
    if data.starts_with(b"II") || data.starts_with(b"MM") {
        candidates.push(data);
    }
    let mut start = 0;
    while let Some(position) = find_subslice(&data[start..], b"Exif\0\0") {
        let tiff_start = start + position + 6;
        candidates.push(&data[tiff_start..]);
        start = tiff_start;
    }
    for index in 0..data.len().saturating_sub(3) {
        if &data[index..index + 4] == b"II\x2a\0" || &data[index..index + 4] == b"MM\0\x2a" {
            candidates.push(&data[index..]);
        }
    }
    candidates
}

fn find_subslice(data: &[u8], needle: &[u8]) -> Option<usize> {
    data.windows(needle.len())
        .position(|window| window == needle)
}

fn extract_tiff_user_comment(tiff: &[u8]) -> Option<String> {
    if tiff.len() < 8 {
        return None;
    }
    let little_endian = match &tiff[..2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    if read_u16(tiff, 2, little_endian)? != 42 {
        return None;
    }

    let mut pending = vec![read_u32(tiff, 4, little_endian)? as usize];
    let mut visited = HashSet::new();
    while let Some(offset) = pending.pop() {
        if offset == 0 || !visited.insert(offset) || offset + 2 > tiff.len() {
            continue;
        }
        let count = read_u16(tiff, offset, little_endian)? as usize;
        if count > 4096 || offset.checked_add(2 + count.checked_mul(12)?)? > tiff.len() {
            return None;
        }
        for index in 0..count {
            let entry = offset + 2 + index * 12;
            let tag = read_u16(tiff, entry, little_endian)?;
            let field_type = read_u16(tiff, entry + 2, little_endian)?;
            let value_count = read_u32(tiff, entry + 4, little_endian)? as usize;
            let value_or_offset = read_u32(tiff, entry + 8, little_endian)? as usize;
            if matches!(tag, 0x8769 | 0x8825) {
                pending.push(value_or_offset);
            }
            if tag != 0x9286 || !matches!(field_type, 1 | 2 | 7) {
                continue;
            }
            let value = if value_count <= 4 {
                tiff.get(entry + 8..entry + 8 + value_count)?
            } else {
                tiff.get(value_or_offset..value_or_offset.checked_add(value_count)?)?
            };
            if let Some(comment) = decode_user_comment(value) {
                return Some(comment);
            }
        }
    }
    None
}

fn decode_user_comment(value: &[u8]) -> Option<String> {
    let payload = if value.starts_with(b"ASCII\0\0\0")
        || value.starts_with(b"UNICODE\0")
        || value.starts_with(b"JIS\0\0\0\0\0")
    {
        value.get(8..)?
    } else {
        value
    };
    let decoded = String::from_utf8_lossy(payload)
        .trim_matches('\0')
        .trim()
        .to_owned();
    (!decoded.is_empty()).then_some(decoded)
}

fn read_u16(data: &[u8], offset: usize, little_endian: bool) -> Option<u16> {
    let bytes: [u8; 2] = data.get(offset..offset.checked_add(2)?)?.try_into().ok()?;
    Some(if little_endian {
        u16::from_le_bytes(bytes)
    } else {
        u16::from_be_bytes(bytes)
    })
}

fn read_u32(data: &[u8], offset: usize, little_endian: bool) -> Option<u32> {
    let bytes: [u8; 4] = data.get(offset..offset.checked_add(4)?)?.try_into().ok()?;
    Some(if little_endian {
        u32::from_le_bytes(bytes)
    } else {
        u32::from_be_bytes(bytes)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiff_with_user_comment(comment: &[u8]) -> Vec<u8> {
        let exif_ifd_offset = 26u32;
        let comment_offset = 44u32;
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II");
        tiff.extend_from_slice(&42u16.to_le_bytes());
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes());
        tiff.extend_from_slice(&0x8769u16.to_le_bytes());
        tiff.extend_from_slice(&4u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&exif_ifd_offset.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes());
        tiff.extend_from_slice(&0x9286u16.to_le_bytes());
        tiff.extend_from_slice(&7u16.to_le_bytes());
        tiff.extend_from_slice(&(comment.len() as u32).to_le_bytes());
        tiff.extend_from_slice(&comment_offset.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(comment);
        tiff
    }

    #[test]
    fn classifies_prefix_and_json_with_upstream_priority() {
        let both = classify_user_comment(Some("Oplus_4294967552"));
        assert_eq!(both.mode, Some(CaptureMode::Master));
        assert_eq!(both.status, ClassificationStatus::Categorized);

        let json = classify_user_comment(Some(r#"{"oplustag":"16"}"#));
        assert_eq!(json.mode, Some(CaptureMode::Portrait));
        assert_eq!(json.tag_flags, Some(16));
    }

    #[test]
    fn tracks_unknown_and_known_non_mode_flags() {
        let unknown = classify_user_comment(Some("oppo_1152921504606846976"));
        assert_eq!(unknown.status, ClassificationStatus::UnknownFlags);
        assert_eq!(unknown.unknown_flags, 1u64 << 60);
        assert_eq!(unknown.mode, None);

        let known_non_mode = classify_user_comment(Some("oppo_1"));
        assert_eq!(known_non_mode.status, ClassificationStatus::Categorized);
        assert_eq!(known_non_mode.mode, Some(CaptureMode::Normal));
    }

    #[test]
    fn extracts_user_comment_from_nested_tiff_exif() {
        let mut heif_exif = b"Exif\0\0".to_vec();
        heif_exif.extend_from_slice(&tiff_with_user_comment(b"ASCII\0\0\0Oplus_2048"));
        let classification = classify_bytes(&heif_exif);
        assert_eq!(classification.mode, Some(CaptureMode::Night));
        assert_eq!(classification.status, ClassificationStatus::Categorized);
    }

    #[test]
    fn raw_fallbacks_are_supported() {
        assert_eq!(
            extract_user_comment(b"junk oPpO_16384 tail").as_deref(),
            Some("Oppo_16384")
        );
        assert_eq!(
            classify_bytes(br#"metadata {"oplustag": "4"}"#).mode,
            Some(CaptureMode::Panorama)
        );
    }
}
