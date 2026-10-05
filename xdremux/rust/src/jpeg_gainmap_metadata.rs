//! JPEG-specific ISO 21496-1 and Apple gain-map metadata. No native codec needed.
//! ISO APP2 is a packed stream (unlike the project's padded HEIF payload).
use quick_xml::{events::Event, name::ResolveResult, NsReader};

pub(crate) const ISO_NAMESPACE: &[u8] = b"urn:iso:std:iso:ts:21496:-1\0";
const APPLE_NAMESPACE: &str = "http://ns.apple.com/HDRGainMap/1.0/";

pub(crate) struct Metadata {
    pub floats: Vec<f32>,
    pub use_base_color_space: bool,
}

pub(crate) fn validate(f: &[f32]) -> Result<(), String> {
    if f.len() != 20 || f.iter().any(|v| !v.is_finite()) {
        return Err("gain-map metadata must contain 20 finite values".into());
    }
    for c in 0..3 {
        if f[c] <= 0.0 || f[4 + c] < f[c] || f[7 + c] <= 0.0 || f[10 + c] < 0.0 || f[13 + c] < 0.0 {
            return Err("gain-map metadata has invalid boost, gamma or offset".into());
        }
    }
    if f[16] < 1.0 || f[17] < f[16] || f[18] <= 0.0 {
        return Err("gain-map metadata has invalid HDR capacity".into());
    }
    Ok(())
}

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}
impl Cursor<'_> {
    fn take<const N: usize>(&mut self) -> Result<[u8; N], String> {
        let end = self
            .pos
            .checked_add(N)
            .ok_or("ISO metadata offset overflow")?;
        let bytes = self
            .data
            .get(self.pos..end)
            .ok_or("truncated ISO gain-map metadata")?;
        self.pos = end;
        Ok(bytes.try_into().unwrap())
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_be_bytes(self.take()?))
    }
    fn rational(&mut self, signed: bool, common: Option<u32>) -> Result<f32, String> {
        let n = self.take::<4>()?;
        let numerator = if signed {
            i32::from_be_bytes(n) as f64
        } else {
            u32::from_be_bytes(n) as f64
        };
        let denominator = match common {
            Some(d) => d,
            None => self.u32()?,
        };
        if denominator == 0 {
            return Err("ISO gain-map denominator is zero".into());
        }
        Ok((numerator / denominator as f64) as f32)
    }
}

pub(crate) fn parse_iso(data: &[u8]) -> Result<Metadata, String> {
    let mut r = Cursor { data, pos: 0 };
    let min_version = u16::from_be_bytes(r.take()?);
    let writer_version = u16::from_be_bytes(r.take()?);
    if min_version != 0 {
        return Err(format!(
            "unsupported ISO JPEG minimum version {min_version}"
        ));
    }
    let flags = r.take::<1>()?[0];
    if flags & 4 != 0 {
        return Err("HDR-base ISO JPEG gain maps are not supported".into());
    }
    if flags & 0x33 != 0 {
        return Err("unsupported ISO JPEG gain-map flags".into());
    }
    let channels = if flags & 0x80 != 0 { 3 } else { 1 };
    let common = if flags & 8 != 0 { Some(r.u32()?) } else { None };
    let mut f = vec![0.0; 20];
    f[16] = r.rational(false, common)?.exp2();
    f[17] = r.rational(false, common)?.exp2();
    f[18] = f[17];
    for c in 0..channels {
        f[c] = r.rational(true, common)?.exp2();
        f[4 + c] = r.rational(true, common)?.exp2();
        f[7 + c] = r.rational(false, common)?;
        f[10 + c] = r.rational(true, common)?;
        f[13 + c] = r.rational(true, common)?;
    }
    if channels == 1 {
        for start in [0, 4, 7, 10, 13] {
            f[start + 1] = f[start];
            f[start + 2] = f[start];
        }
    }
    if writer_version == 0 && r.pos != data.len() {
        return Err("unexpected trailing ISO JPEG metadata bytes".into());
    }
    validate(&f)?;
    Ok(Metadata {
        floats: f,
        use_base_color_space: flags & 0x40 != 0,
    })
}

/// Apple v1 stores headroom in EXIF MakerNote tags 33/48; v2 can declare it
/// directly as log2 HDRGainMapHeadroom in XMP. Formula matches libultrahdr 2.0.2.
pub(crate) fn parse_apple(
    xmp: &[u8],
    exif_tiff: Option<&[u8]>,
) -> Result<Option<Metadata>, String> {
    let mut reader = NsReader::from_reader(xmp);
    let mut version = None;
    let mut headroom = None;
    let mut current = None;
    loop {
        let (ns, event) = reader
            .read_resolved_event()
            .map_err(|_| "malformed Apple gain-map XMP")?;
        match event {
            Event::Start(e) | Event::Empty(e) => {
                current = None;
                if matches!(ns, ResolveResult::Bound(ref n) if n.as_ref() == APPLE_NAMESPACE) {
                    match e.local_name().as_ref() {
                        "HDRGainMapVersion" => current = Some(false),
                        "HDRGainMapHeadroom" => current = Some(true),
                        _ => (),
                    }
                }
                for attr in e.attributes() {
                    let attr = attr.map_err(|_| "malformed Apple XMP attribute")?;
                    let (ns, local) = reader.resolver().resolve_attribute(attr.key);
                    if matches!(ns, ResolveResult::Bound(ref n) if n.as_ref() == APPLE_NAMESPACE) {
                        let text = attr.value.as_ref();
                        match local.as_ref() {
                            "HDRGainMapVersion" => {
                                version = Some(
                                    text.trim()
                                        .parse::<u32>()
                                        .map_err(|_| "invalid Apple gain-map version")?,
                                )
                            }
                            "HDRGainMapHeadroom" => {
                                headroom = Some(
                                    text.trim()
                                        .parse::<f32>()
                                        .map_err(|_| "invalid Apple gain-map headroom")?,
                                )
                            }
                            _ => (),
                        }
                    }
                }
            }
            Event::Text(e) => {
                if let Some(is_headroom) = current {
                    let text = e.as_ref().trim();
                    if is_headroom {
                        headroom = Some(
                            text.parse::<f32>()
                                .map_err(|_| "invalid Apple gain-map headroom")?,
                        );
                    } else {
                        version = Some(
                            text.parse::<u32>()
                                .map_err(|_| "invalid Apple gain-map version")?,
                        );
                    }
                }
            }
            Event::End(_) => current = None,
            Event::Eof => break,
            _ => (),
        }
    }
    let Some(version) = version else {
        return Ok(None);
    };
    if !matches!(version, 65536 | 131072) {
        return Err(format!("unsupported Apple gain-map version {version}"));
    }
    let stops = match headroom {
        Some(v) => v,
        None => apple_exif_stops(exif_tiff.ok_or("Apple gain map lacks XMP headroom and EXIF")?)?,
    };
    let boost = stops.exp2();
    let f = vec![
        1.0, 1.0, 1.0, 0.0, boost, boost, boost, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
        boost, boost, 0.0,
    ];
    validate(&f)?;
    Ok(Some(Metadata {
        floats: f,
        use_base_color_space: false,
    }))
}

fn apple_exif_stops(tiff: &[u8]) -> Result<f32, String> {
    let le = match tiff.get(..4) {
        Some(b"II*\0") => true,
        Some(b"MM\0*") => false,
        _ => return Err("invalid Apple EXIF TIFF header".into()),
    };
    let ifd0 = read_u32(tiff, 4, le)? as usize;
    let exif = ifd_entry(tiff, ifd0, 0x8769, le)?.ok_or("Apple EXIF lacks ExifIFD")?;
    if read_u16(tiff, exif + 2, le)? != 4 || read_u32(tiff, exif + 4, le)? != 1 {
        return Err("invalid Apple ExifIFD pointer".into());
    }
    let exif_ifd = read_u32(tiff, exif + 8, le)? as usize;
    let entry = ifd_entry(tiff, exif_ifd, 0x927c, le)?.ok_or("Apple EXIF lacks MakerNote")?;
    if read_u16(tiff, entry + 2, le)? != 7 {
        return Err("invalid Apple MakerNote type".into());
    }
    let size = read_u32(tiff, entry + 4, le)? as usize;
    let start = read_u32(tiff, entry + 8, le)? as usize;
    let end = start
        .checked_add(size)
        .ok_or("Apple MakerNote extent overflow")?;
    let note = tiff.get(start..end).ok_or("truncated Apple MakerNote")?;
    if !note.starts_with(b"Apple iOS\0\0\x01MM") {
        return Err("unsupported Apple MakerNote header".into());
    }
    let value = |tag| -> Result<Option<f64>, String> {
        let Some(e) = ifd_entry(note, 14, tag, false)? else {
            return Ok(None);
        };
        if read_u16(note, e + 2, false)? != 10 || read_u32(note, e + 4, false)? != 1 {
            return Err("invalid Apple headroom rational type/count".into());
        }
        let pos = read_u32(note, e + 8, false)? as usize;
        let n = read_u32(note, pos, false)? as i32;
        let d = read_u32(
            note,
            pos.checked_add(4).ok_or("Apple rational offset overflow")?,
            false,
        )? as i32;
        if d <= 0 {
            return Err("invalid Apple headroom rational denominator".into());
        }
        Ok(Some(n as f64 / d as f64))
    };
    let m33 = value(33)?;
    let m48 = value(48)?;
    if m33.is_none() && m48.is_none() {
        return Err("Apple MakerNote lacks headroom tags 33/48".into());
    }
    let a = m33.unwrap_or(0.0);
    let b = m48.unwrap_or(0.0);
    Ok(if a < 1.0 {
        if b <= 0.01 {
            -20.0 * b + 1.8
        } else {
            -0.101 * b + 1.601
        }
    } else if b <= 0.01 {
        -70.0 * b + 3.0
    } else {
        -0.303 * b + 2.303
    } as f32)
}

fn read_u16(data: &[u8], pos: usize, le: bool) -> Result<u16, String> {
    let bytes: [u8; 2] = data
        .get(pos..pos.checked_add(2).ok_or("TIFF offset overflow")?)
        .ok_or("truncated Apple EXIF")?
        .try_into()
        .unwrap();
    Ok(if le {
        u16::from_le_bytes(bytes)
    } else {
        u16::from_be_bytes(bytes)
    })
}
fn read_u32(data: &[u8], pos: usize, le: bool) -> Result<u32, String> {
    let bytes: [u8; 4] = data
        .get(pos..pos.checked_add(4).ok_or("TIFF offset overflow")?)
        .ok_or("truncated Apple EXIF")?
        .try_into()
        .unwrap();
    Ok(if le {
        u32::from_le_bytes(bytes)
    } else {
        u32::from_be_bytes(bytes)
    })
}
fn ifd_entry(data: &[u8], pos: usize, tag: u16, le: bool) -> Result<Option<usize>, String> {
    let count = read_u16(data, pos, le)? as usize;
    let start = pos.checked_add(2).ok_or("TIFF IFD overflow")?;
    let end = start.checked_add(count * 12).ok_or("TIFF IFD overflow")?;
    if end > data.len() {
        return Err("truncated Apple EXIF IFD".into());
    }
    for i in 0..count {
        let entry = start + i * 12;
        if read_u16(data, entry, le)? == tag {
            return Ok(Some(entry));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn iso(common: bool, multichannel: bool) -> Vec<u8> {
        let mut bytes = vec![
            0,
            0,
            0,
            0,
            0x40 | if common { 8 } else { 0 } | if multichannel { 0x80 } else { 0 },
        ];
        let d = 100u32;
        if common {
            bytes.extend(d.to_be_bytes());
        }
        let mut rational = |n: i32| {
            bytes.extend(n.to_be_bytes());
            if !common {
                bytes.extend(d.to_be_bytes());
            }
        };
        rational(0);
        rational(300);
        for c in 0..if multichannel { 3 } else { 1 } {
            for n in [-100, 300 + c * 100, 100, 0, 0] {
                rational(n);
            }
        }
        bytes
    }
    #[test]
    fn iso_scalar_common_and_individual_denominators_agree() {
        let a = parse_iso(&iso(true, false)).unwrap();
        let b = parse_iso(&iso(false, false)).unwrap();
        assert_eq!(a.floats, b.floats);
        assert_eq!(&a.floats[..3], &[0.5; 3]);
        assert_eq!(&a.floats[4..7], &[8.0; 3]);
        assert!(a.use_base_color_space);
    }
    #[test]
    fn iso_keeps_distinct_channels_and_application_color_space() {
        let mut bytes = iso(false, true);
        bytes[4] &= !0x40;
        let metadata = parse_iso(&bytes).unwrap();
        assert_eq!(&metadata.floats[4..7], &[8.0, 16.0, 32.0]);
        assert!(!metadata.use_base_color_space);
    }
    #[test]
    fn iso_rejects_every_truncated_prefix() {
        for common in [false, true] {
            for multi in [false, true] {
                let data = iso(common, multi);
                for len in 0..data.len() {
                    assert!(parse_iso(&data[..len]).is_err(), "prefix {len}");
                }
            }
        }
    }
    #[test]
    fn iso_rejects_bad_version_flags_denominators_and_overflow() {
        let mut data = iso(true, false);
        data[1] = 1;
        assert!(parse_iso(&data).is_err());
        data[1] = 0;
        data[4] |= 4;
        assert!(parse_iso(&data).is_err());
        data[4] &= !4;
        data[4] |= 1;
        assert!(parse_iso(&data).is_err());
        data[4] &= !1;
        data[5..9].fill(0);
        assert!(parse_iso(&data).is_err());
        let mut data = iso(false, false);
        data[9..13].fill(0);
        assert!(parse_iso(&data).is_err());
        let mut data = iso(true, false);
        data[13..17].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(parse_iso(&data).is_err());
        let mut data = iso(true, false);
        data.push(0);
        assert!(parse_iso(&data).is_err());
    }
    fn apple_xmp(fields: &str) -> Vec<u8> {
        format!("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" xmlns:h=\"http://ns.apple.com/HDRGainMap/1.0/\">{fields}</x:xmpmeta>").into_bytes()
    }
    #[test]
    fn apple_xmp_headroom_is_log2_and_namespace_alias_independent() {
        let xmp = apple_xmp("<h:HDRGainMapVersion>131072</h:HDRGainMapVersion><h:HDRGainMapHeadroom>3</h:HDRGainMapHeadroom>");
        let metadata = parse_apple(&xmp, None).unwrap().unwrap();
        assert_eq!(&metadata.floats[4..7], &[8.0; 3]);
        assert!(!metadata.use_base_color_space);
        let attrs =
            apple_xmp("<description h:HDRGainMapVersion=\"131072\" h:HDRGainMapHeadroom=\"3\"/>");
        assert_eq!(
            metadata.floats,
            parse_apple(&attrs, None).unwrap().unwrap().floats
        );
    }
    #[test]
    fn apple_requires_real_headroom_and_known_version() {
        assert!(parse_apple(
            &apple_xmp("<h:HDRGainMapVersion>65536</h:HDRGainMapVersion>"),
            None
        )
        .is_err());
        assert!(parse_apple(
            &apple_xmp("<h:HDRGainMapVersion>7</h:HDRGainMapVersion>"),
            None
        )
        .is_err());
        for value in ["NaN", "inf", "-1", "nonsense"] {
            let fields = format!("<h:HDRGainMapVersion>131072</h:HDRGainMapVersion><h:HDRGainMapHeadroom>{value}</h:HDRGainMapHeadroom>");
            assert!(parse_apple(&apple_xmp(&fields), None).is_err());
        }
    }
    #[test]
    fn apple_rejects_namespace_spoof_and_malformed_xml() {
        let xmp = apple_xmp("<h:HDRGainMapVersion>65536</h:HDRGainMapVersion>");
        let spoof = String::from_utf8(xmp)
            .unwrap()
            .replace(APPLE_NAMESPACE, "https://example.invalid/");
        assert!(parse_apple(spoof.as_bytes(), None).unwrap().is_none());
        assert!(parse_apple(b"<broken", None).is_err());
    }
    fn apple_tiff() -> Vec<u8> {
        let mut tiff = b"II*\0\x08\0\0\0".to_vec();
        // IFD0 -> ExifIFD at 26 -> MakerNote at 44.
        tiff.extend(1u16.to_le_bytes());
        tiff.extend(0x8769u16.to_le_bytes());
        tiff.extend(4u16.to_le_bytes());
        tiff.extend(1u32.to_le_bytes());
        tiff.extend(26u32.to_le_bytes());
        tiff.extend([0; 4]);
        tiff.extend(1u16.to_le_bytes());
        tiff.extend(0x927cu16.to_le_bytes());
        tiff.extend(7u16.to_le_bytes());
        tiff.extend(40u32.to_le_bytes());
        tiff.extend(44u32.to_le_bytes());
        tiff.extend([0; 4]);
        tiff.extend(b"Apple iOS\0\0\x01MM");
        tiff.extend(1u16.to_be_bytes());
        tiff.extend(33u16.to_be_bytes());
        tiff.extend(10u16.to_be_bytes());
        tiff.extend(1u32.to_be_bytes());
        tiff.extend(32u32.to_be_bytes());
        tiff.extend([0; 4]);
        tiff.extend(1i32.to_be_bytes());
        tiff.extend(1i32.to_be_bytes());
        tiff
    }
    #[test]
    fn apple_v1_uses_exif_headroom_without_guessing_a_fixed_boost() {
        let xmp = apple_xmp("<h:HDRGainMapVersion>65536</h:HDRGainMapVersion>");
        let tiff = apple_tiff();
        let metadata = parse_apple(&xmp, Some(&tiff)).unwrap().unwrap();
        assert_eq!(metadata.floats[17], 8.0);
        for end in 0..tiff.len() {
            assert!(apple_exif_stops(&tiff[..end]).is_err());
        }
        let mut bad = tiff;
        let end = bad.len();
        bad[end - 4..].fill(0);
        assert!(apple_exif_stops(&bad).is_err());
    }
    #[test]
    fn metadata_validation_rejects_nonfinite_and_inverted_ranges() {
        let original = parse_iso(&iso(false, false)).unwrap().floats;
        for (index, value) in [(7, 0.0), (10, -1.0), (4, 0.1), (17, 0.5), (0, f32::NAN)] {
            let mut f = original.clone();
            f[index] = value;
            assert!(validate(&f).is_err());
        }
    }
}
