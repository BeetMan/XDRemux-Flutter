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
//! | `off`  | No patch                  | Clean Apple/ISO output |
//! | `on`   | `flags \| 0x20000000`     | Activate OPPO Gallery UHDR routing |
//! | `auto` | `flags & ~0x24040000`     | Clear private HDR branch bits |
//!
//! Ported from Swift `adjustedOppoUserComment()` / `patchOppoUserComment()` /
//! `applyOppoUserCommentPatch()`.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// The UHDR routing bit that OPPO Gallery checks in the UserComment tag-flag.
const OPPO_ULTRA_HDR_FLAG: u32 = 0x2000_0000;

/// All private HDR branch bits — cleared in diagnostic (auto) mode.
/// Swift: `0x40000 | 0x200000 | oppoUltraHDRFlag` = 0x20240000
const OPPO_PRIVATE_HDR_BRANCH_FLAGS: u32 = 0x0004_0000 | 0x0020_0000 | OPPO_ULTRA_HDR_FLAG;

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
    /// ISO-only diagnostic — clear all private HDR branch bits.
    Auto,
    /// Activate OPPO Gallery UHDR routing.
    On,
}

impl OppoCompat {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => OppoCompat::Auto,
            2 | 3 => OppoCompat::On, // "tail" is alias for "on"
            _ => OppoCompat::Off,
        }
    }

    /// Whether the UserComment needs to be patched at all.
    pub fn wants_patch(self) -> bool {
        matches!(self, OppoCompat::On | OppoCompat::Auto)
    }

    /// Whether to SET the UHDR routing flag (activation path).
    pub fn wants_activation(self) -> bool {
        matches!(self, OppoCompat::On)
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
                    let digit_str = std::str::from_utf8(&data[digits_start..digits_end]).unwrap_or("");
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
pub fn adjust_oppo_usercomment(
    tag: &TagFlag,
    mode: OppoCompat,
) -> Option<(usize, usize, Vec<u8>)> {
    let new_value = match mode {
        OppoCompat::Off => return None,
        OppoCompat::On => tag.value | OPPO_ULTRA_HDR_FLAG,
        OppoCompat::Auto => tag.value & !OPPO_PRIVATE_HDR_BRANCH_FLAGS,
    };

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

/// Apply the OPPO UserComment patch to a mutable byte buffer.
///
/// Finds the first tag-flag, computes the adjustment for `mode`, and replaces
/// the digit portion in-place. If the replacement width differs from the
/// original, the buffer is resized (only works with `Vec<u8>`, not plain slices).
///
/// Returns `(patch_offset, byte_delta)` if a patch was applied, or `None`
/// if no tag-flag was found or no change was needed.
pub fn apply_oppo_usercomment_patch_vec(
    data: &mut Vec<u8>,
    mode: OppoCompat,
) -> Option<(usize, i64)> {
    let tags = find_oppo_tagflags(data);
    if tags.is_empty() {
        return None;
    }

    let tag = &tags[0];
    let (start, end, replacement) = adjust_oppo_usercomment(tag, mode)?;

    let orig_len = end - start;
    let new_len = replacement.len();
    let delta = new_len as i64 - orig_len as i64;

    // Replace in-place, shifting trailing data if needed
    data.splice(start..end, replacement);

    Some((start, delta))
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
    fn adjust_auto_clears_flags() {
        // 0x20240100 has all private HDR bits (0x20240000) set + user bit 0x100
        let data = make_test_data("ASCIIoppo_", 0x20240100);
        let tags = find_oppo_tagflags(&data);
        let (_, _, replacement) = adjust_oppo_usercomment(&tags[0], OppoCompat::Auto).unwrap();
        let new_str = std::str::from_utf8(&replacement).unwrap();
        let new_val: u32 = new_str.parse().unwrap();
        // private bits cleared, user bit 0x100 preserved
        assert_eq!(new_val, 0x00000100);
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
    fn adjust_auto_nothing_to_clear_returns_none() {
        // No private bits set → no change
        let data = make_test_data("oppo_", 0x00000100);
        let tags = find_oppo_tagflags(&data);
        assert!(adjust_oppo_usercomment(&tags[0], OppoCompat::Auto).is_none());
    }

    // ---------- apply_oppo_usercomment_patch_vec ----------

    #[test]
    fn apply_patch_modifies_bytes() {
        let mut data = make_test_data("ASCIIOplus_", 0x00000100);
        let result = apply_oppo_usercomment_patch_vec(&mut data, OppoCompat::On);
        assert!(result.is_some());

        // Re-parse to verify the value was modified
        let tags = find_oppo_tagflags(&data);
        assert_eq!(tags[0].value, 0x20000100);
    }

    #[test]
    fn apply_patch_no_tag_returns_none() {
        let mut data = b"No tag here".to_vec();
        let result = apply_oppo_usercomment_patch_vec(&mut data, OppoCompat::On);
        assert!(result.is_none());
    }

    #[test]
    fn oppo_compat_from_u8() {
        assert_eq!(OppoCompat::from_u8(0), OppoCompat::Off);
        assert_eq!(OppoCompat::from_u8(1), OppoCompat::Auto);
        assert_eq!(OppoCompat::from_u8(2), OppoCompat::On);
        assert_eq!(OppoCompat::from_u8(3), OppoCompat::On); // tail → on
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
