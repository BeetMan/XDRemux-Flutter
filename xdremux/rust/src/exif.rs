//! EXIF UserComment binary patching for OPPO ProXDR compatibility.
//!
//! OPPO/OnePlus/realme devices store a private UHDR routing flag inside the
//! EXIF UserComment tag (tag 0x9286) as an ASCII string like:
//!
//! ```text
//! ASCIIOplus_12345678
//! ```
//!
//! Five known prefixes are supported:
//!
//! ```text
//! ASCIIOplus_  ASCIIoppo_  Oplus_  oplus_  oppo_
//! ```
//!
//! ## Modes
//!
//! | Mode   | Operation                 | Effect |
//! |--------|---------------------------|--------|
//! | `off`          | No patch                                      | Clean Apple/ISO output |
//! | `auto`         | No patch                                      | Preserve source routing |
//! | `on` / `tail`  | `flags \| 0x20000000`                         | Activate OPPO Gallery UHDR routing |
//! | `iso`          | `(flags & ~0x20000000) \| 0x00200000`          | Prefer ISO UHDR routing |
//! | `iso-no-local` | `(flags & ~0x20040000) \| 0x00200000`          | ISO routing without local HDR |
//! | `iso-graph`    | `flags & ~0x20200000`                          | Remove OPPO/ISO routing bits |
//!
//! Ported from Swift `adjustedOppoUserComment()` / `patchOppoUserComment()` /
//! `applyOppoUserCommentPatch()`.

use crate::isobmff::{BoxHeader, IlocEntry, ItemInfo};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// The UHDR routing bit that OPPO Gallery checks in the UserComment tag-flag.
pub const OPPO_ULTRA_HDR_FLAG: u32 = 0x2000_0000;

/// The ISO UHDR routing bit stored by OPPO-family cameras.
pub const ISO_ULTRA_HDR_FLAG: u32 = 0x0020_0000;

/// The local HDR routing bit stored by OPPO-family cameras.
pub const LOCAL_HDR_FLAG: u32 = 0x0004_0000;

/// Known OPPO UserComment tag-flag prefixes (in descending-length order so
/// we match the most specific prefix first).
const TAGFLAG_PREFIXES: &[&[u8]] = &[
    b"ASCIIOplus_",
    b"ASCIIoppo_",
    b"Oplus_",
    b"oplus_",
    b"oppo_",
];

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// OPPO compatibility mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OppoCompat {
    /// Clean ISO output — no UserComment patching.
    Off,
    /// Preserve the source routing flags while emitting OPPO-compatible output.
    Auto,
    /// Activate OPPO Gallery UHDR routing.
    On,
    /// Activate OPPO routing while preserving the complete camera tail.
    Tail,
    /// Prefer the ISO UHDR routing bit over the OPPO routing bit.
    Iso,
    /// ISO routing with the local HDR bit removed.
    IsoNoLocal,
    /// Remove both OPPO and ISO routing bits.
    IsoGraph,
}

/// EXIF orientation values used to align an auxiliary gain map with the
/// primary image. The transform maps source storage coordinates to the
/// primary image's presentation coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExifOrientation {
    Normal,
    FlipHorizontal,
    Rotate180,
    FlipVertical,
    Transpose,
    Rotate90Clockwise,
    Transverse,
    Rotate90CounterClockwise,
}

impl ExifOrientation {
    pub fn from_u16(value: u16) -> Result<Self, String> {
        match value {
            1 => Ok(Self::Normal),
            2 => Ok(Self::FlipHorizontal),
            3 => Ok(Self::Rotate180),
            4 => Ok(Self::FlipVertical),
            5 => Ok(Self::Transpose),
            6 => Ok(Self::Rotate90Clockwise),
            7 => Ok(Self::Transverse),
            8 => Ok(Self::Rotate90CounterClockwise),
            _ => Err(format!("unsupported EXIF orientation: {value}")),
        }
    }

    /// HEIF `irot` stores counter-clockwise quarter turns. Mirror-only EXIF
    /// orientations cannot be expressed by `irot`, so they use zero turns.
    pub const fn irot_quarter_turns_ccw(self) -> u8 {
        match self {
            Self::Rotate180 => 2,
            Self::Rotate90Clockwise => 3,
            Self::Rotate90CounterClockwise => 1,
            _ => 0,
        }
    }

    pub const fn swaps_axes(self) -> bool {
        matches!(
            self,
            Self::Transpose
                | Self::Rotate90Clockwise
                | Self::Transverse
                | Self::Rotate90CounterClockwise
        )
    }

    pub const fn output_dimensions(self, width: u32, height: u32) -> (u32, u32) {
        if self.swaps_axes() {
            (height, width)
        } else {
            (width, height)
        }
    }
}

/// Read the primary image's EXIF orientation from an HEIF Exif item.
///
/// Missing EXIF or a missing orientation tag are both normal and map to
/// orientation 1. A malformed Exif item is an error because silently using an
/// unaligned gain map would produce visibly incorrect HDR output.
pub fn read_heif_exif_orientation(
    data: &[u8],
    items: &[ItemInfo],
    iloc_entries: &[IlocEntry],
    idat: Option<&BoxHeader>,
) -> Result<ExifOrientation, String> {
    let Some(exif_item) = items.iter().find(|item| item.itype == "Exif") else {
        return Ok(ExifOrientation::Normal);
    };
    let entry = iloc_entries
        .iter()
        .find(|entry| entry.item_id == exif_item.item_id)
        .ok_or_else(|| format!("Exif item {} has no iloc entry", exif_item.item_id))?;
    let exif_blob = read_heif_item_payload(data, entry, idat)?;
    parse_heif_exif_orientation(&exif_blob)
}

fn read_heif_item_payload(
    data: &[u8],
    entry: &IlocEntry,
    idat: Option<&BoxHeader>,
) -> Result<Vec<u8>, String> {
    if entry.extents.is_empty() {
        return Err(format!("item {} has no extents", entry.item_id));
    }

    let mut payload = Vec::new();
    for &(offset, length) in &entry.extents {
        let base = match entry.construction_method {
            0 => 0usize,
            1 => {
                idat.ok_or_else(|| format!("item {} references missing idat", entry.item_id))?
                    .data_start
            }
            other => {
                return Err(format!(
                    "item {} has unsupported construction method {other}",
                    entry.item_id
                ))
            }
        };
        let start = base
            .checked_add(usize::try_from(offset).map_err(|_| "item offset exceeds usize")?)
            .ok_or("item offset overflow")?;
        let end = start
            .checked_add(usize::try_from(length).map_err(|_| "item length exceeds usize")?)
            .ok_or("item extent overflow")?;
        let bytes = data
            .get(start..end)
            .ok_or_else(|| format!("item {} extent is outside the file", entry.item_id))?;
        payload.extend_from_slice(bytes);
    }
    Ok(payload)
}

fn parse_heif_exif_orientation(exif_blob: &[u8]) -> Result<ExifOrientation, String> {
    let tiff = if exif_blob.starts_with(b"II") || exif_blob.starts_with(b"MM") {
        exif_blob
    } else {
        let offset_bytes: [u8; 4] = exif_blob
            .get(0..4)
            .ok_or("Exif item is shorter than its TIFF offset")?
            .try_into()
            .expect("four-byte Exif TIFF offset");
        let offset = u32::from_be_bytes(offset_bytes) as usize;
        // HEIF Exif writers in the wild use both the item start and the byte
        // immediately after this 4-byte field as the offset base. Accept the
        // first candidate that actually points at a TIFF byte-order marker.
        [
            offset,
            offset.checked_add(4).ok_or("Exif TIFF offset overflow")?,
        ]
        .into_iter()
        .find_map(|start| {
            exif_blob
                .get(start..)
                .filter(|candidate| candidate.starts_with(b"II") || candidate.starts_with(b"MM"))
        })
        .ok_or("Exif TIFF offset is outside the Exif item or not a TIFF header")?
    };

    if tiff.len() < 8 {
        return Err("Exif TIFF header is truncated".into());
    }
    let little_endian = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return Err("Exif TIFF byte order is invalid".into()),
    };
    if read_tiff_u16(tiff, 2, little_endian)? != 42 {
        return Err("Exif TIFF magic is invalid".into());
    }

    let ifd0_offset = read_tiff_u32(tiff, 4, little_endian)? as usize;
    if ifd0_offset == 0 {
        return Ok(ExifOrientation::Normal);
    }
    let entry_count = read_tiff_u16(tiff, ifd0_offset, little_endian)? as usize;
    let entries_start = ifd0_offset
        .checked_add(2)
        .ok_or("Exif IFD0 offset overflow")?;
    let entries_len = entry_count
        .checked_mul(12)
        .ok_or("Exif IFD0 entry count overflow")?;
    let entries_end = entries_start
        .checked_add(entries_len)
        .ok_or("Exif IFD0 length overflow")?;
    if entries_end.checked_add(4).is_none() || entries_end + 4 > tiff.len() {
        return Err("Exif IFD0 is truncated".into());
    }

    for index in 0..entry_count {
        let entry = entries_start + index * 12;
        if read_tiff_u16(tiff, entry, little_endian)? != 0x0112 {
            continue;
        }
        let field_type = read_tiff_u16(tiff, entry + 2, little_endian)?;
        let count = read_tiff_u32(tiff, entry + 4, little_endian)?;
        if count != 1 {
            return Err("EXIF orientation must contain exactly one value".into());
        }
        let value = match field_type {
            3 => read_tiff_u16(tiff, entry + 8, little_endian)?,
            4 => u16::try_from(read_tiff_u32(tiff, entry + 8, little_endian)?)
                .map_err(|_| "EXIF orientation LONG value exceeds u16")?,
            _ => {
                return Err(format!(
                    "unsupported EXIF orientation field type {field_type}"
                ))
            }
        };
        return ExifOrientation::from_u16(value);
    }

    Ok(ExifOrientation::Normal)
}

fn read_tiff_u16(data: &[u8], offset: usize, little_endian: bool) -> Result<u16, String> {
    let bytes: [u8; 2] = data
        .get(offset..offset + 2)
        .ok_or("Exif TIFF u16 is truncated")?
        .try_into()
        .expect("two-byte TIFF u16");
    Ok(if little_endian {
        u16::from_le_bytes(bytes)
    } else {
        u16::from_be_bytes(bytes)
    })
}

fn read_tiff_u32(data: &[u8], offset: usize, little_endian: bool) -> Result<u32, String> {
    let bytes: [u8; 4] = data
        .get(offset..offset + 4)
        .ok_or("Exif TIFF u32 is truncated")?
        .try_into()
        .expect("four-byte TIFF u32");
    Ok(if little_endian {
        u32::from_le_bytes(bytes)
    } else {
        u32::from_be_bytes(bytes)
    })
}

impl OppoCompat {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => OppoCompat::Auto,
            2 => OppoCompat::On,
            3 => OppoCompat::Tail,
            4 => OppoCompat::Iso,
            5 => OppoCompat::IsoNoLocal,
            6 => OppoCompat::IsoGraph,
            _ => OppoCompat::Off,
        }
    }

    /// Whether the UserComment needs to be patched at all.
    pub fn wants_patch(self) -> bool {
        matches!(
            self,
            OppoCompat::On
                | OppoCompat::Tail
                | OppoCompat::Iso
                | OppoCompat::IsoNoLocal
                | OppoCompat::IsoGraph
        )
    }

    /// Whether to SET the UHDR routing flag (activation path).
    pub fn wants_activation(self) -> bool {
        matches!(self, OppoCompat::On | OppoCompat::Tail)
    }

    /// Whether this mode writes OPPO-oriented gain-map and tail metadata.
    pub const fn wants_oppo_compat(self) -> bool {
        !matches!(self, OppoCompat::Off)
    }
}

/// Compute the desired OPPO-family UserComment routing flags for `mode`.
pub const fn target_oppo_tag_flags(source: u32, mode: OppoCompat) -> u32 {
    match mode {
        OppoCompat::Off | OppoCompat::Auto => source,
        OppoCompat::On | OppoCompat::Tail => source | OPPO_ULTRA_HDR_FLAG,
        OppoCompat::Iso => (source & !OPPO_ULTRA_HDR_FLAG) | ISO_ULTRA_HDR_FLAG,
        OppoCompat::IsoNoLocal => {
            (source & !OPPO_ULTRA_HDR_FLAG & !LOCAL_HDR_FLAG) | ISO_ULTRA_HDR_FLAG
        }
        OppoCompat::IsoGraph => source & !OPPO_ULTRA_HDR_FLAG & !ISO_ULTRA_HDR_FLAG,
    }
}

/// A located OPPO tag-flag within a byte buffer.
#[derive(Debug, Clone)]
pub struct TagFlag {
    /// Which prefix was matched (e.g. "ASCIIOplus_").
    pub prefix: String,
    /// Offset of the prefix start in the buffer.
    pub offset: usize,
    /// Offset of the first digit character.
    pub digits_start: usize,
    /// Offset one past the last digit character.
    pub digits_end: usize,
    /// The parsed integer value.
    pub value: u32,
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

/// Find all OPPO UserComment tag-flag strings in `data`.
///
/// Scans for any of the five known prefixes followed by decimal digits.
pub fn find_oppo_tagflags(data: &[u8]) -> Vec<TagFlag> {
    let mut results = Vec::new();
    let mut pos = 0usize;

    while pos < data.len() {
        let mut found = false;

        for prefix in TAGFLAG_PREFIXES {
            if data[pos..].starts_with(prefix) {
                let digits_start = pos + prefix.len();
                let mut digits_end = digits_start;

                // Collect consecutive ASCII digits
                while digits_end < data.len() && data[digits_end].is_ascii_digit() {
                    digits_end += 1;
                }

                if digits_end > digits_start {
                    // Parse the integer value
                    let digit_str =
                        std::str::from_utf8(&data[digits_start..digits_end]).unwrap_or("");
                    if let Ok(value) = digit_str.parse::<u32>() {
                        results.push(TagFlag {
                            prefix: String::from_utf8_lossy(prefix).to_string(),
                            offset: pos,
                            digits_start,
                            digits_end,
                            value,
                        });
                    }
                }

                pos = digits_start; // skip past prefix for next search
                found = true;
                break;
            }
        }

        if !found {
            pos += 1;
        }
    }

    results
}

// ---------------------------------------------------------------------------
// Patching
// ---------------------------------------------------------------------------

/// Compute the adjusted UserComment tag-flag bytes for the given mode.
///
/// Returns `None` if no change is needed (the value already matches the
/// desired state).
///
/// When a change IS needed, returns `(digits_start, digits_end, replacement_bytes)`
/// where the replacement is the new digit string, zero-padded to the same width
/// as the original.
pub fn adjust_oppo_usercomment(tag: &TagFlag, mode: OppoCompat) -> Option<(usize, usize, Vec<u8>)> {
    if !mode.wants_patch() {
        return None;
    }
    let new_value = target_oppo_tag_flags(tag.value, mode);

    if new_value == tag.value {
        return None;
    }

    let width = tag.digits_end - tag.digits_start;
    // Zero-pad to AT LEAST the original width. If the new value needs more
    // digits (e.g. OR-ing 0x20000000 into a smaller number), expand the field.
    // The file size change (delta) is tracked by apply_oppo_usercomment_patch.
    let replacement_str = format!("{:0width$}", new_value, width = width.max(1));
    let replacement = replacement_str.into_bytes();

    Some((tag.digits_start, tag.digits_end, replacement))
}

/// Result of patching the OPPO UserComment inside the source Exif item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OppoUserCommentPatch {
    /// Absolute offset range (in the source file) of the Exif item extent
    /// whose payload grew/shrunk.
    pub source_range: (usize, usize),
    /// Byte delta applied to the Exif extent (positive = grew).
    pub delta: i64,
}

/// Locate the iloc entry of the source Exif item.
pub fn find_exif_iloc_entry<'a>(
    items: &'a [ItemInfo],
    iloc_entries: &'a [IlocEntry],
) -> Option<&'a IlocEntry> {
    let exif_id = items.iter().find(|item| item.itype == "Exif")?.item_id;
    iloc_entries
        .iter()
        .find(|entry| entry.item_id == exif_id)
}

/// Apply the OPPO UserComment patch to the source mdat payload, confined to
/// the Exif item extent. Ported from Swift `applyOppoUserCommentPatch`.
///
/// The Exif item is located via its iloc extent (construction method 0), the
/// UserComment entry is found by walking the TIFF IFD chain, and the adjusted
/// value is **appended to the end of the Exif payload** with the entry's count
/// and offset rewritten. Bytes outside the Exif item (GPS sub-IFD tables,
/// primary-image tiles, later items) are never touched, so a length change only
/// shifts the item extent — not the surrounding data.
///
/// `mdat_data_start` is the source mdat content start (matching the absolute
/// extent offsets returned by `parse_iloc`).
pub fn apply_oppo_usercomment_patch(
    mdat_payload: &mut Vec<u8>,
    mdat_data_start: usize,
    exif_entry: &IlocEntry,
    mode: OppoCompat,
) -> Option<OppoUserCommentPatch> {
    if exif_entry.construction_method != 0 || exif_entry.extents.len() != 1 {
        return None;
    }
    let (offset, length) = exif_entry.extents[0];
    if length == 0 {
        return None;
    }
    let local_start = offset as i64 - mdat_data_start as i64;
    if local_start < 0 {
        return None;
    }
    let local_start = local_start as usize;
    let local_end = local_start.checked_add(length as usize)?;
    if local_end > mdat_payload.len() {
        return None;
    }
    let mut exif_payload = mdat_payload[local_start..local_end].to_vec();
    if exif_payload.len() < 12 {
        return None;
    }

    // TIFF byte-order marker sits after the 4-byte Exif-to-TIFF offset field
    // ("Exif\0\0"). Swift reads that field as a BE u32; OPPO files use 6.
    let tiff_offset = u32::from_be_bytes(exif_payload[0..4].try_into().expect("4-byte field")) as usize;
    let tiff_start = 4 + tiff_offset;
    if tiff_start < 4 || tiff_start + 8 > exif_payload.len() {
        return None;
    }
    let little_endian = match &exif_payload[tiff_start..tiff_start + 2] {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let Ok(magic) = read_tiff_u16(&exif_payload, tiff_start + 2, little_endian) else {
        return None;
    };
    if magic != 42 {
        return None;
    }
    let Ok(first_ifd) = read_tiff_u32(&exif_payload, tiff_start + 4, little_endian) else {
        return None;
    };

    // Walk the IFD chain (dedup by relative offset, cap entry count) to find
    // the UserComment entry (tag 0x9286), following ExifIFD/GPSIFD pointers.
    let mut pending = vec![first_ifd as usize];
    let mut visited = std::collections::HashSet::new();
    let mut user_comment_entry: Option<usize> = None;
    while let Some(relative_ifd) = pending.pop() {
        if user_comment_entry.is_some() {
            break;
        }
        if !visited.insert(relative_ifd) {
            continue;
        }
        let ifd = tiff_start + relative_ifd;
        let Ok(count) = read_tiff_u16(&exif_payload, ifd, little_endian) else {
            return None;
        };
        if count > 4096 {
            return None;
        }
        for index in 0..count as usize {
            let entry = ifd + 2 + index * 12;
            if entry + 12 > exif_payload.len() {
                return None;
            }
            let Ok(tag) = read_tiff_u16(&exif_payload, entry, little_endian) else {
                return None;
            };
            if tag == 0x9286 {
                user_comment_entry = Some(entry);
                break;
            }
            if tag == 0x8769 || tag == 0x8825 {
                let Ok(child) = read_tiff_u32(&exif_payload, entry + 8, little_endian) else {
                    return None;
                };
                pending.push(child as usize);
            }
        }
    }

    let entry = user_comment_entry?;
    let Ok(field_type) = read_tiff_u16(&exif_payload, entry + 2, little_endian) else {
        return None;
    };
    if field_type != 7 {
        return None;
    }
    let Ok(old_count) = read_tiff_u32(&exif_payload, entry + 4, little_endian) else {
        return None;
    };
    if old_count == 0 {
        return None;
    }
    let Ok(old_value_offset) = read_tiff_u32(&exif_payload, entry + 8, little_endian) else {
        return None;
    };
    let old_value_start = if old_count <= 4 {
        entry + 8
    } else {
        tiff_start + old_value_offset as usize
    };
    let old_value_end = old_value_start.checked_add(old_count as usize)?;
    if old_value_end > exif_payload.len() {
        return None;
    }
    let mut new_value = exif_payload[old_value_start..old_value_end].to_vec();

    // Find the OPPO tag-flag (prefix + digits) inside the UserComment value.
    let tags = find_oppo_tagflags(&new_value);
    if tags.is_empty() {
        return None;
    }
    let tag = &tags[0];
    let (digits_start, digits_end, replacement) = adjust_oppo_usercomment(tag, mode)?;

    // Rebuild the value: bytes before prefix + prefix + new digits + trailing.
    let mut rebuilt =
        Vec::with_capacity(new_value.len() + replacement.len().saturating_sub(digits_end - digits_start));
    rebuilt.extend_from_slice(&new_value[..tag.offset]);
    rebuilt.extend_from_slice(&new_value[tag.offset..digits_start]);
    rebuilt.extend_from_slice(&replacement);
    rebuilt.extend_from_slice(&new_value[digits_end..]);
    new_value = rebuilt;

    // Append the adjusted value at the end of the Exif item, 4-byte aligned.
    while exif_payload.len() % 4 != 0 {
        exif_payload.push(0);
    }
    let new_value_offset = exif_payload.len() - tiff_start;
    let new_value_len = new_value.len();
    exif_payload.append(&mut new_value);

    // Rewrite count + offset in the UserComment entry.
    let count_bytes = if little_endian {
        (new_value_len as u32).to_le_bytes()
    } else {
        (new_value_len as u32).to_be_bytes()
    };
    exif_payload[entry + 4..entry + 8].copy_from_slice(&count_bytes);
    let offset_bytes = if little_endian {
        (new_value_offset as u32).to_le_bytes()
    } else {
        (new_value_offset as u32).to_be_bytes()
    };
    exif_payload[entry + 8..entry + 12].copy_from_slice(&offset_bytes);

    let delta = exif_payload.len() as i64 - length as i64;
    let source_range = (offset as usize, (offset + length) as usize);
    mdat_payload.splice(local_start..local_end, exif_payload);
    Some(OppoUserCommentPatch {
        source_range,
        delta,
    })
}

/// Adjust a construction-method-0 item extent for the bytes inserted/removed
/// inside the Exif item. Ported from Swift `adjustedExtentForOppoUserCommentPatch`.
///
/// - extent entirely before the Exif item → unchanged
/// - extent entirely after → offset shifted by `delta`
/// - the Exif item itself (patch lies inside it) → length grows by `delta`, offset kept
/// - any other extent straddling the boundary → `None` (invalid container)
pub fn adjusted_extent_for_patch(
    offset: u64,
    length: u64,
    patch: Option<&OppoUserCommentPatch>,
) -> Option<(u64, u64)> {
    let Some(patch) = patch else {
        return Some((offset, length));
    };
    if patch.delta == 0 {
        return Some((offset, length));
    }
    let upper = offset.checked_add(length)?;
    let patch_lower = patch.source_range.0 as u64;
    let patch_upper = patch.source_range.1 as u64;
    if upper <= patch_lower {
        return Some((offset, length));
    }
    if offset >= patch_upper {
        return Some(((offset as i128 + patch.delta as i128) as u64, length));
    }
    if offset <= patch_lower && upper >= patch_upper {
        return Some((offset, (length as i128 + patch.delta as i128) as u64));
    }
    None
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a test buffer containing an OPPO tag-flag.
    ///
    /// Real OPPO flags are always 8 decimal digits (zero-padded).
    fn make_test_data(prefix: &str, flags: u32) -> Vec<u8> {
        let s = format!("before{}{:08}after", prefix, flags);
        s.into_bytes()
    }

    fn tiff_with_orientation(orientation: Option<u16>) -> Vec<u8> {
        let entry_count = usize::from(orientation.is_some());
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II");
        tiff.extend_from_slice(&42u16.to_le_bytes());
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&(entry_count as u16).to_le_bytes());
        if let Some(value) = orientation {
            tiff.extend_from_slice(&0x0112u16.to_le_bytes());
            tiff.extend_from_slice(&3u16.to_le_bytes());
            tiff.extend_from_slice(&1u32.to_le_bytes());
            tiff.extend_from_slice(&value.to_le_bytes());
            tiff.extend_from_slice(&[0, 0]);
        }
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff
    }

    fn heif_exif_blob(orientation: Option<u16>) -> Vec<u8> {
        let mut blob = 6u32.to_be_bytes().to_vec();
        blob.extend_from_slice(b"Exif\0\0");
        blob.extend_from_slice(&tiff_with_orientation(orientation));
        blob
    }

    #[test]
    fn exif_orientation_maps_to_expected_irot_and_geometry() {
        let cases = [
            (1, 0, false),
            (2, 0, false),
            (3, 2, false),
            (4, 0, false),
            (5, 0, true),
            (6, 3, true),
            (7, 0, true),
            (8, 1, true),
        ];
        for (value, irot, swaps_axes) in cases {
            let orientation = ExifOrientation::from_u16(value).unwrap();
            assert_eq!(orientation.irot_quarter_turns_ccw(), irot, "EXIF {value}");
            assert_eq!(orientation.swaps_axes(), swaps_axes, "EXIF {value}");
            assert_eq!(
                orientation.output_dimensions(640, 480),
                if swaps_axes { (480, 640) } else { (640, 480) },
                "EXIF {value}"
            );
        }
    }

    #[test]
    fn heif_exif_orientation_reads_ifd0_tag() {
        let blob = heif_exif_blob(Some(6));
        assert_eq!(
            parse_heif_exif_orientation(&blob).unwrap(),
            ExifOrientation::Rotate90Clockwise
        );
    }

    #[test]
    fn heif_exif_orientation_defaults_when_tag_is_absent() {
        assert_eq!(
            parse_heif_exif_orientation(&heif_exif_blob(None)).unwrap(),
            ExifOrientation::Normal
        );
    }

    #[test]
    fn heif_exif_orientation_resolves_mdat_item_extent() {
        let blob = heif_exif_blob(Some(8));
        let mut data = vec![0u8; 11];
        data.extend_from_slice(&blob);
        let items = vec![ItemInfo {
            item_id: 7,
            itype: "Exif".into(),
            flags: 0,
            raw_infe: Vec::new(),
        }];
        let entries = vec![IlocEntry {
            item_id: 7,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(11, blob.len() as u64)],
        }];
        assert_eq!(
            read_heif_exif_orientation(&data, &items, &entries, None).unwrap(),
            ExifOrientation::Rotate90CounterClockwise
        );
    }

    // ---------- find_oppo_tagflags ----------

    #[test]
    fn find_ascii_oplus_flag() {
        let data = make_test_data("ASCIIOplus_", 0x00000100);
        let tags = find_oppo_tagflags(&data);
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].prefix, "ASCIIOplus_");
        assert_eq!(tags[0].value, 0x00000100);
    }

    #[test]
    fn find_oppo_lowercase_flag() {
        let data = make_test_data("oppo_", 42);
        let tags = find_oppo_tagflags(&data);
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].prefix, "oppo_");
        assert_eq!(tags[0].value, 42);
    }

    #[test]
    fn find_oplus_flag() {
        let data = make_test_data("Oplus_", 0x0000DEAD);
        let tags = find_oppo_tagflags(&data);
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].value, 0x0000DEAD);
    }

    #[test]
    fn no_tagflag_returns_empty() {
        let data = b"No OPPO tags here, just some random text 12345".to_vec();
        let tags = find_oppo_tagflags(&data);
        assert!(tags.is_empty());
    }

    #[test]
    fn prefix_without_digits_not_matched() {
        // "ASCIIOplus_" followed by non-digits should not produce a tag
        let data = b"before ASCIIOplus_ABC after".to_vec();
        let tags = find_oppo_tagflags(&data);
        assert!(tags.is_empty(), "prefix without digits should not match");
    }

    #[test]
    fn multiple_prefixes_finds_all() {
        let data = b"oppo_123 middle Oplus_456 end".to_vec();
        let tags = find_oppo_tagflags(&data);
        assert_eq!(tags.len(), 2);
    }

    // ---------- adjust_oppo_usercomment ----------

    #[test]
    fn adjust_on_sets_flag() {
        let data = make_test_data("ASCIIOplus_", 0x00000100);
        let tags = find_oppo_tagflags(&data);
        let (start, end, replacement) = adjust_oppo_usercomment(&tags[0], OppoCompat::On).unwrap();
        // "before" + prefix, no space in test data
        assert!(&data[..start].starts_with(b"beforeASCIIOplus_"));
        let new_str = std::str::from_utf8(&replacement).unwrap();
        let new_val: u32 = new_str.parse().unwrap();
        assert_eq!(new_val, 0x00000100 | 0x20000000);
        // Replacement is zero-padded, may be wider than original if needed
        assert!(replacement.len() >= end - start);
    }

    #[test]
    fn routing_modes_adjust_only_their_documented_bits() {
        // 0x20240100 has OPPO, ISO and local HDR bits set + user bit 0x100.
        let data = make_test_data("ASCIIoppo_", 0x20240100);
        let tags = find_oppo_tagflags(&data);
        let adjusted = |mode| {
            let (_, _, replacement) = adjust_oppo_usercomment(&tags[0], mode).unwrap();
            std::str::from_utf8(&replacement)
                .unwrap()
                .parse::<u32>()
                .unwrap()
        };
        assert_eq!(adjusted(OppoCompat::Iso), 0x0024_0100);
        assert_eq!(adjusted(OppoCompat::IsoNoLocal), 0x0020_0100);
        assert_eq!(adjusted(OppoCompat::IsoGraph), 0x0004_0100);
    }

    #[test]
    fn adjust_off_returns_none() {
        let data = make_test_data("ASCIIOplus_", 0x00000100);
        let tags = find_oppo_tagflags(&data);
        assert!(adjust_oppo_usercomment(&tags[0], OppoCompat::Off).is_none());
    }

    #[test]
    fn adjust_on_already_set_returns_none() {
        // If the flag is already set, no change needed
        let data = make_test_data("ASCIIOplus_", 0x20000100);
        let tags = find_oppo_tagflags(&data);
        assert!(adjust_oppo_usercomment(&tags[0], OppoCompat::On).is_none());
    }

    #[test]
    fn auto_preserves_user_comment() {
        let data = make_test_data("oppo_", 0x00000100);
        let tags = find_oppo_tagflags(&data);
        assert!(adjust_oppo_usercomment(&tags[0], OppoCompat::Auto).is_none());
    }

    // ---------- apply_oppo_usercomment_patch ----------

    #[test]
    fn apply_patch_modifies_bytes() {
        // Build a minimal Exif payload: "Exif\0\0" + TIFF with IFD0 → ExifIFD →
        // UserComment. Confine it to an iloc extent; the patch must append the
        // new value to the extent and never touch the trailing marker.
        let mut payload = Vec::new();
        payload.extend_from_slice(&6u32.to_be_bytes()); // Exif→TIFF offset
        payload.extend_from_slice(b"Exif\0\0");
        let tiff_origin = payload.len(); // == 10
        payload.extend_from_slice(b"II");
        payload.extend_from_slice(&42u16.to_le_bytes());
        payload.extend_from_slice(&8u32.to_le_bytes()); // IFD0 at +8

        // IFD0 (1 entry): ExifIFD sub-IFD pointer. The pointer value must be
        // recorded after the whole IFD0 (entries + next-IFD) is laid out.
        let ifd0_entry = payload.len();
        payload.extend_from_slice(&1u16.to_le_bytes()); // entry count
        payload.extend_from_slice(&0x8769u16.to_le_bytes()); // ExifIFD tag
        payload.extend_from_slice(&4u16.to_le_bytes()); // type LONG
        payload.extend_from_slice(&1u32.to_le_bytes());
        payload.extend_from_slice(&0u32.to_le_bytes()); // placeholder offset
        payload.extend_from_slice(&0u32.to_le_bytes()); // next IFD = 0
        let exif_ifd_rel = (payload.len() - tiff_origin) as u32;
        payload[ifd0_entry + 10..ifd0_entry + 14].copy_from_slice(&exif_ifd_rel.to_le_bytes());

        // ExifIFD (1 entry): UserComment type=7, value out-of-line.
        payload.extend_from_slice(&1u16.to_le_bytes());
        payload.extend_from_slice(&0x9286u16.to_le_bytes());
        payload.extend_from_slice(&7u16.to_le_bytes());
        payload.extend_from_slice(&21u32.to_le_bytes()); // count of value bytes
        let uc_entry_slot = payload.len();
        payload.extend_from_slice(&0u32.to_le_bytes()); // placeholder offset
        let uc_offset_rel = (payload.len() - tiff_origin) as u32;
        let slot = &mut payload[uc_entry_slot..uc_entry_slot + 4];
        slot.copy_from_slice(&uc_offset_rel.to_le_bytes());
        payload.extend_from_slice(b"ASCII\0\0\0oplus_1441792");
        // trailing bytes that must survive untouched at their original offset
        let trailing = b"TAIL-DATA";
        let trailing_start = payload.len();
        payload.extend_from_slice(trailing);
        assert_eq!(uc_entry_slot + 4 + 21, trailing_start, "value is 21 bytes after the offset field");

        let extent_off = 100u64;
        let mut mdat = vec![0u8; extent_off as usize];
        mdat.extend_from_slice(&payload);
        let entry = IlocEntry {
            item_id: 7,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(extent_off, payload.len() as u64)],
        };
        let patch = apply_oppo_usercomment_patch(&mut mdat, 0, &entry, OppoCompat::On).unwrap();
        assert!(patch.delta > 0);
        assert_eq!(patch.source_range, (100, 100 + payload.len()));

        // The UserComment entry must now point at the new value appended at the
        // end of the item (the old value bytes remain as dead data, matching
        // Swift), and the trailing marker stays untouched.
        let new_payload = &mdat[100..];
        let tiff = tiff_start_of(&new_payload);
        let le = new_payload[tiff] == b'I';
        let ifd0 = read_tiff_u32(new_payload, tiff + 4, le).unwrap() as usize;
        let exif_ifd_rel = read_tiff_u32(new_payload, tiff + ifd0 + 10, le).unwrap() as usize;
        let exif_ifd = tiff + exif_ifd_rel;
        let entry_off = exif_ifd + 2;
        assert_eq!(read_tiff_u16(new_payload, entry_off, le).unwrap(), 0x9286);
        assert_eq!(read_tiff_u16(new_payload, entry_off + 2, le).unwrap(), 7);
        let count = read_tiff_u32(new_payload, entry_off + 4, le).unwrap();
        let val_off = read_tiff_u32(new_payload, entry_off + 8, le).unwrap() as usize;
        let val_start = tiff + val_off;
        let value = String::from_utf8_lossy(&new_payload[val_start..val_start + count as usize]);
        assert!(value.contains("538312704"), "got: {value}");
        assert_eq!(
            &new_payload[trailing_start..trailing_start + trailing.len()],
            trailing
        );
    }

    /// Locate the TIFF byte-order marker in an Exif item payload (which may be
    /// bare TIFF or "offset + Exif\0\0" prefixed), matching `parse_heif_exif_orientation`.
    fn tiff_start_of(exif_blob: &[u8]) -> usize {
        if exif_blob.starts_with(b"II") || exif_blob.starts_with(b"MM") {
            return 0;
        }
        let offset = u32::from_be_bytes(exif_blob[0..4].try_into().expect("4-byte field")) as usize;
        [offset, offset + 4]
            .into_iter()
            .find(|&start| {
                exif_blob
                    .get(start..)
                    .is_some_and(|c| c.starts_with(b"II") || c.starts_with(b"MM"))
            })
            .unwrap()
    }

    #[test]
    fn apply_patch_no_tag_returns_none() {
        let mut payload = Vec::new();
        payload.extend_from_slice(&6u32.to_be_bytes());
        payload.extend_from_slice(b"Exif\0\0");
        payload.extend_from_slice(b"II");
        payload.extend_from_slice(&42u16.to_le_bytes());
        payload.extend_from_slice(&8u32.to_le_bytes());
        payload.extend_from_slice(&0u16.to_le_bytes()); // no entries
        payload.extend_from_slice(&0u32.to_le_bytes());
        let entry = IlocEntry {
            item_id: 7,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, payload.len() as u64)],
        };
        let mut mdat = payload.clone();
        assert!(apply_oppo_usercomment_patch(&mut mdat, 0, &entry, OppoCompat::On).is_none());
    }

    #[test]
    fn oppo_compat_from_u8() {
        assert_eq!(OppoCompat::from_u8(0), OppoCompat::Off);
        assert_eq!(OppoCompat::from_u8(1), OppoCompat::Auto);
        assert_eq!(OppoCompat::from_u8(2), OppoCompat::On);
        assert_eq!(OppoCompat::from_u8(3), OppoCompat::Tail);
        assert_eq!(OppoCompat::from_u8(4), OppoCompat::Iso);
        assert_eq!(OppoCompat::from_u8(5), OppoCompat::IsoNoLocal);
        assert_eq!(OppoCompat::from_u8(6), OppoCompat::IsoGraph);
        assert_eq!(OppoCompat::from_u8(99), OppoCompat::Off);
    }

    #[test]
    fn target_routing_flags_match_mode_contract() {
        let source = OPPO_ULTRA_HDR_FLAG | ISO_ULTRA_HDR_FLAG | LOCAL_HDR_FLAG | 0x100;
        assert_eq!(target_oppo_tag_flags(source, OppoCompat::Off), source);
        assert_eq!(target_oppo_tag_flags(source, OppoCompat::Auto), source);
        assert_eq!(target_oppo_tag_flags(source, OppoCompat::On), source);
        assert_eq!(target_oppo_tag_flags(source, OppoCompat::Tail), source);
        assert_eq!(
            target_oppo_tag_flags(source, OppoCompat::Iso),
            ISO_ULTRA_HDR_FLAG | LOCAL_HDR_FLAG | 0x100
        );
        assert_eq!(
            target_oppo_tag_flags(source, OppoCompat::IsoNoLocal),
            ISO_ULTRA_HDR_FLAG | 0x100
        );
        assert_eq!(
            target_oppo_tag_flags(source, OppoCompat::IsoGraph),
            LOCAL_HDR_FLAG | 0x100
        );
    }

    #[test]
    fn zero_padding_preserves_width() {
        // flags=0 should produce "00000000", not "0"
        let data = make_test_data("oppo_", 0);
        let tags = find_oppo_tagflags(&data);
        let (_, _, replacement) = adjust_oppo_usercomment(&tags[0], OppoCompat::On).unwrap();
        // Replacement is at least as wide as the original
        assert!(replacement.len() >= tags[0].digits_end - tags[0].digits_start);
        // All chars should be digits
        assert!(replacement.iter().all(|b| b.is_ascii_digit()));
    }
}
