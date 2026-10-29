//! JPEG RGB color profiles. Preserve device RGB coordinates; no implicit CMS
//! transform or guess based on the profile description / camera brand.

const ICC_MARKER: &[u8] = b"ICC_PROFILE\0";
const MAX_ICC_BYTES: usize = 16 * 1024 * 1024;

pub(crate) fn validate_rgb_icc(profile: &[u8]) -> Result<(), String> {
    if profile.len() < 132 || profile.len() > MAX_ICC_BYTES {
        return Err("JPEG ICC profile has an invalid size".into());
    }
    let u32_at = |p| u32::from_be_bytes(profile[p..p + 4].try_into().unwrap()) as usize;
    if u32_at(0) != profile.len() || &profile[36..40] != b"acsp" {
        return Err("JPEG ICC profile has an invalid header or declared size".into());
    }
    if !matches!(profile[8], 2 | 4) {
        return Err("unsupported JPEG ICC profile version (expected v2 or v4)".into());
    }
    if &profile[16..20] != b"RGB " {
        return Err("JPEG ICC profile is not RGB; a color-managed conversion is required".into());
    }
    if !matches!(&profile[12..16], b"scnr" | b"mntr" | b"prtr" | b"spac")
        || !matches!(&profile[20..24], b"XYZ " | b"Lab ")
    {
        return Err("unsupported JPEG ICC profile class or connection space".into());
    }
    let tags = u32_at(128);
    let table_end = 132usize
        .checked_add(tags.checked_mul(12).ok_or("ICC tag count overflow")?)
        .filter(|&end| end <= profile.len())
        .ok_or("truncated ICC tag table")?;
    for i in 0..tags {
        let pos = 132 + i * 12;
        let (offset, size) = (u32_at(pos + 4), u32_at(pos + 8));
        if offset < table_end
            || offset % 4 != 0
            || size < 8
            || offset
                .checked_add(size)
                .is_none_or(|end| end > profile.len())
        {
            return Err("JPEG ICC tag extent is invalid".into());
        }
    }
    Ok(())
}

/// Reassemble APP2 chunks by sequence number, not file order. Invalid declared
/// profiles are errors, never silently treated as an untagged sRGB photograph.
pub(crate) fn read_rgb_icc(data: &[u8]) -> Result<Option<Vec<u8>>, String> {
    if !data.starts_with(b"\xff\xd8") {
        return Ok(None);
    }
    let mut chunks: Vec<Option<&[u8]>> = Vec::new();
    let mut total = 0usize;
    let mut components = None;
    let mut p = 2usize;
    while p + 1 < data.len() {
        if data[p] != 0xff {
            return Err("malformed JPEG marker while reading ICC".into());
        }
        while p < data.len() && data[p] == 0xff {
            p += 1;
        }
        let marker = *data.get(p).ok_or("truncated JPEG marker")?;
        p += 1;
        if marker == 0xda || marker == 0xd9 {
            break;
        }
        if (0xd0..=0xd7).contains(&marker) || marker == 1 {
            continue;
        }
        let length = data.get(p..p + 2).ok_or("truncated JPEG segment")?;
        let length = u16::from_be_bytes(length.try_into().unwrap()) as usize;
        let end = p
            .checked_add(length)
            .filter(|&end| length >= 2 && end <= data.len())
            .ok_or("invalid JPEG segment extent while reading ICC")?;
        let payload = &data[p + 2..end];
        if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            components = payload.get(5).copied();
        }
        if marker == 0xe2 && payload.starts_with(ICC_MARKER) {
            if payload.len() < 14 {
                return Err("truncated JPEG ICC chunk header".into());
            }
            let (sequence, count) = (payload[12] as usize, payload[13] as usize);
            if count == 0 || sequence == 0 || sequence > count {
                return Err("invalid JPEG ICC chunk sequence".into());
            }
            if chunks.is_empty() {
                chunks.resize(count, None);
            }
            if chunks.len() != count || chunks[sequence - 1].is_some() {
                return Err("inconsistent or duplicate JPEG ICC chunks".into());
            }
            total = total
                .checked_add(payload.len() - 14)
                .filter(|&n| n <= MAX_ICC_BYTES)
                .ok_or("JPEG ICC profile exceeds size limit")?;
            chunks[sequence - 1] = Some(&payload[14..]);
        }
        p = end;
    }
    if chunks.is_empty() {
        return Ok(None);
    }
    if components.is_some_and(|n| n != 3) {
        return Err("JPEG RGB ICC requires a three-component source image".into());
    }
    let mut profile = Vec::with_capacity(total);
    for chunk in chunks {
        profile.extend_from_slice(chunk.ok_or("missing JPEG ICC chunk")?);
    }
    validate_rgb_icc(&profile)?;
    Ok(Some(profile))
}

/// HEVC converts device RGB with a BT.709 YCbCr matrix in full range. The ICC
/// defines primaries and transfer, so do not also declare a conflicting gamut.
pub(crate) fn icc_colr(profile: &[u8]) -> Vec<u8> {
    let mut payload = b"prof".to_vec();
    payload.extend_from_slice(profile);
    crate::isobmff::make_box(b"colr", &payload)
}

pub(crate) const ICC_MATRIX_COLR: &[u8] = &[
    0, 0, 0, 19, b'c', b'o', b'l', b'r', b'n', b'c', b'l', b'x', 0, 2, 0, 2, 0, 1, 0x80,
];

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn rgb_profile() -> Vec<u8> {
        // Envelope fixture only; real matrix/TRC profiles are covered by the
        // opt-in sample test. No private photo/profile is embedded in source.
        let mut p = vec![0; 132];
        p[..4].copy_from_slice(&132u32.to_be_bytes());
        p[8] = 4;
        p[12..16].copy_from_slice(b"mntr");
        p[16..20].copy_from_slice(b"RGB ");
        p[20..24].copy_from_slice(b"XYZ ");
        p[36..40].copy_from_slice(b"acsp");
        p
    }

    pub(crate) fn add_icc(jpeg: &[u8], parts: &[(u8, u8, &[u8])]) -> Vec<u8> {
        let mut out = vec![0xff, 0xd8];
        for &(sequence, count, bytes) in parts {
            let mut segment = ICC_MARKER.to_vec();
            segment.extend([sequence, count]);
            segment.extend_from_slice(bytes);
            out.extend([0xff, 0xe2]);
            out.extend(((segment.len() + 2) as u16).to_be_bytes());
            out.extend(segment);
        }
        out.extend_from_slice(&jpeg[2..]);
        out
    }

    #[test]
    fn icc_multipart_is_order_independent_and_byte_exact() {
        let profile = rgb_profile();
        let jpeg = add_icc(
            &[0xff, 0xd8, 0xff, 0xd9],
            &[(2, 2, &profile[40..]), (1, 2, &profile[..40])],
        );
        assert_eq!(read_rgb_icc(&jpeg).unwrap().unwrap(), profile);
        assert!(read_rgb_icc(&[0xff, 0xd8, 0xff, 0xd9]).unwrap().is_none());
    }

    #[test]
    fn malformed_icc_is_not_silently_discarded() {
        let p = rgb_profile();
        for parts in [
            vec![(0, 1, &p[..])],
            vec![(1, 0, &p[..])],
            vec![(1, 2, &p[..])],
            vec![(1, 1, &p[..]), (1, 1, &p[..])],
            vec![(1, 2, &p[..20]), (2, 3, &p[20..])],
        ] {
            assert!(read_rgb_icc(&add_icc(&[0xff, 0xd8, 0xff, 0xd9], &parts)).is_err());
        }
        for (offset, value) in [(3, 0), (16, b'C'), (36, 0), (128, 255)] {
            let mut bad = p.clone();
            bad[offset] = value;
            assert!(validate_rgb_icc(&bad).is_err());
        }
        assert!(read_rgb_icc(&[0xff, 0xd8, 0xff, 0xe2, 0xff, 0xff]).is_err());
    }

    #[test]
    fn icc_tag_bounds_and_non_rgb_sources_fail_closed() {
        let mut p = rgb_profile();
        for end in 0..p.len() {
            assert!(validate_rgb_icc(&p[..end]).is_err());
        }
        p.resize(152, 0);
        p[..4].copy_from_slice(&152u32.to_be_bytes());
        p[128..132].copy_from_slice(&1u32.to_be_bytes());
        p[132..136].copy_from_slice(b"desc");
        p[136..140].copy_from_slice(&144u32.to_be_bytes());
        p[140..144].copy_from_slice(&8u32.to_be_bytes());
        assert!(validate_rgb_icc(&p).is_ok());
        for offset in [140u32, 145, 152, u32::MAX] {
            let mut bad = p.clone();
            bad[136..140].copy_from_slice(&offset.to_be_bytes());
            assert!(validate_rgb_icc(&bad).is_err());
        }
        let cmyk = [0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 1, 0, 1, 4, 0xff, 0xd9];
        assert!(read_rgb_icc(&add_icc(&cmyk, &[(1, 1, &p)])).is_err());
    }
}
