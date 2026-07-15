//! ISO 21496-1 HDR metadata construction.
//!
//! Builds the standardized `hdrgm:*` XMP metadata block and tmap payloads
//! from EDR scale projections. Two tmap payload formats are supported:
//!
//! | Format | Size | Use case |
//! |--------|------|----------|
//! | Apple baseline | 62 bytes | Clean ISO output |
//! | ImageIO-native | 142 bytes | OPPO Gallery compatibility |
//!
//! Also handles UHDR 20-float info parsing and reverse construction.

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// ISO 21496-1 gain map metadata in linear domain.
///
/// Per-channel fields are `Vec<f32>` with length equal to `channel_count`.
#[derive(Debug, Clone, PartialEq)]
pub struct IsoMeta {
    pub gain_map_min: Vec<f32>,
    pub gain_map_max: Vec<f32>,
    pub gamma: Vec<f32>,
    pub offset_sdr: Vec<f32>,
    pub offset_hdr: Vec<f32>,
    pub hdr_capacity_min: f32,
    pub hdr_capacity_max: f32,
    pub base_rendition_is_hdr: bool,
    pub scale: f32,
    pub channel_count: usize,
}

/// Parsed OPPO UHDR 20-float info block.
#[derive(Debug, Clone)]
pub struct OppoUhdrInfo {
    pub ratio_min: [f32; 3],
    pub ratio_max: [f32; 3],
    pub gamma: [f32; 3],
    pub epsilon_sdr: [f32; 3],
    pub epsilon_hdr: [f32; 3],
    pub display_ratio_sdr: f32,
    pub display_ratio_hdr: f32,
    pub scale: f32,
    pub base_image_type: f32,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Safe log2: returns 0.0 for values ≤ 0.
fn safe_log2(v: f32) -> f32 {
    if v > 0.0 { v.log2() } else { 0.0 }
}

fn fmt_float(value: f32) -> String {
    format!("{value:.6}")
}

fn fmt_slice(values: &[f32]) -> String {
    values
        .iter()
        .map(|v| fmt_float(*v))
        .collect::<Vec<_>>()
        .join(" ")
}

fn make_vector3(value: &[f32], default: f32) -> [f32; 3] {
    let mut result = [default; 3];
    for (i, &v) in value.iter().enumerate().take(3) {
        result[i] = v;
    }
    result
}

// ---------------------------------------------------------------------------
// UHDR 20-float parsing
// ---------------------------------------------------------------------------

/// Parse the confirmed 20-float OPPO UHDR info layout.
///
/// Field layout:
/// ```text
/// [0..2]  = ratioMin
/// [3]     = padding
/// [4..6]  = ratioMax
/// [7..9]  = gamma
/// [10..12] = epsilonSdr
/// [13..15] = epsilonHdr
/// [16]    = displayRatioSdr
/// [17]    = displayRatioHdr
/// [18]    = scale
/// [19]    = baseImageType
/// ```
pub fn parse_oppo_uhdr_info(floats: &[f32]) -> Result<OppoUhdrInfo, String> {
    if floats.len() < 20 {
        return Err(format!(
            "local.uhdr.gainmap.info must contain at least 20 float32 values (got {})",
            floats.len()
        ));
    }

    Ok(OppoUhdrInfo {
        ratio_min: [floats[0], floats[1], floats[2]],
        ratio_max: [floats[4], floats[5], floats[6]],
        gamma: [floats[7], floats[8], floats[9]],
        epsilon_sdr: [floats[10], floats[11], floats[12]],
        epsilon_hdr: [floats[13], floats[14], floats[15]],
        display_ratio_sdr: floats[16],
        display_ratio_hdr: floats[17],
        scale: floats[18],
        base_image_type: floats[19],
    })
}

// ---------------------------------------------------------------------------
// ISO metadata construction
// ---------------------------------------------------------------------------

/// Build ISO 21496-1 metadata from UHDR 20-float info block.
pub fn build_iso_metadata_from_uhdr(floats: &[f32]) -> Result<IsoMeta, String> {
    let info = parse_oppo_uhdr_info(floats)?;

    let gain_map_min: Vec<f32> = info
        .ratio_min
        .iter()
        .map(|&v| safe_log2(v).max(0.0))
        .collect();
    let gain_map_max: Vec<f32> = info
        .ratio_max
        .iter()
        .map(|&v| safe_log2(v))
        .collect();
    let cap_min = safe_log2(info.display_ratio_sdr).max(0.0);
    let cap_max = safe_log2(info.display_ratio_hdr);
    let base_hdr = info.base_image_type > 0.5;

    Ok(IsoMeta {
        gain_map_min,
        gain_map_max,
        gamma: info.gamma.to_vec(),
        offset_sdr: info.epsilon_sdr.to_vec(),
        offset_hdr: info.epsilon_hdr.to_vec(),
        hdr_capacity_min: cap_min,
        hdr_capacity_max: cap_max,
        base_rendition_is_hdr: base_hdr,
        scale: info.scale,
        channel_count: 3,
    })
}

/// Build ISO 21496-1 metadata from LHDR EDR scale.
///
/// For LHDR, the gain map is monochrome (channel_count = 1) and derived
/// purely from the EDR scale factor.
pub fn build_iso_metadata(edr_scale: f32) -> IsoMeta {
    let edr = edr_scale.max(1.0);
    let gm_max = safe_log2(edr);

    IsoMeta {
        gain_map_min: vec![0.0],
        gain_map_max: vec![gm_max],
        gamma: vec![1.0],
        offset_sdr: vec![0.0],
        offset_hdr: vec![0.0],
        hdr_capacity_min: 0.0,
        hdr_capacity_max: gm_max,
        base_rendition_is_hdr: false,
        scale: edr,
        channel_count: 1,
    }
}

// ---------------------------------------------------------------------------
// UHDR info bytes (reverse: ISO meta → 80-byte OPPO payload)
// ---------------------------------------------------------------------------

/// Build OPPO's 80-byte `local.uhdr.gainmap.info` payload from ISO metadata.
pub fn build_oppo_uhdr_info_bytes(meta: &IsoMeta) -> Vec<u8> {
    let gm_min = make_vector3(&meta.gain_map_min, 0.0);
    let gm_max = make_vector3(&meta.gain_map_max, 0.0);
    let gamma = make_vector3(&meta.gamma, 1.0);
    let offset_sdr = make_vector3(&meta.offset_sdr, 0.0);
    let offset_hdr = make_vector3(&meta.offset_hdr, 0.0);

    let display_ratio_sdr = if meta.hdr_capacity_min > 0.0 {
        2.0_f32.powf(meta.hdr_capacity_min)
    } else {
        1.0
    };
    let display_ratio_hdr = if meta.hdr_capacity_max > 0.0 {
        2.0_f32.powf(meta.hdr_capacity_max)
    } else {
        1.0
    };
    let scale_val = meta.scale;

    let floats: [f32; 20] = [
        2.0_f32.powf(gm_min[0]),
        2.0_f32.powf(gm_min[1]),
        2.0_f32.powf(gm_min[2]),
        1.0, // padding
        2.0_f32.powf(gm_max[0]),
        2.0_f32.powf(gm_max[1]),
        2.0_f32.powf(gm_max[2]),
        gamma[0],
        gamma[1],
        gamma[2],
        offset_sdr[0],
        offset_sdr[1],
        offset_sdr[2],
        offset_hdr[0],
        offset_hdr[1],
        offset_hdr[2],
        display_ratio_sdr,
        display_ratio_hdr,
        scale_val,
        0.0, // base image type (placeholder)
    ];

    let mut out = Vec::with_capacity(80);
    for f in &floats {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}

// ---------------------------------------------------------------------------
// XMP formatting
// ---------------------------------------------------------------------------

/// Format ISO 21496 metadata as `hdrgm` XMP string.
///
/// Produces a full XMP document with `<x:xmpmeta>` wrapper and xmlns
/// declarations matching Apple CGImageDestination output, which is
/// required for CIImage `expandToHDR` Headroom detection.
pub fn format_hdrgm_xmp(meta: &IsoMeta) -> String {
    format!(
        r##"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <hdrgm:Version>1.0</hdrgm:Version>
         <hdrgm:GainMapMin>{gain_map_min}</hdrgm:GainMapMin>
         <hdrgm:GainMapMax>{gain_map_max}</hdrgm:GainMapMax>
         <hdrgm:Gamma>{gamma}</hdrgm:Gamma>
         <hdrgm:OffsetSDR>{offset_sdr}</hdrgm:OffsetSDR>
         <hdrgm:OffsetHDR>{offset_hdr}</hdrgm:OffsetHDR>
         <hdrgm:HDRCapacityMin>{hdr_capacity_min}</hdrgm:HDRCapacityMin>
         <hdrgm:HDRCapacityMax>{hdr_capacity_max}</hdrgm:HDRCapacityMax>
         <hdrgm:BaseRenditionIsHDR>{base_hdr}</hdrgm:BaseRenditionIsHDR>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"##,
        gain_map_min = fmt_slice(&meta.gain_map_min),
        gain_map_max = fmt_slice(&meta.gain_map_max),
        gamma = fmt_slice(&meta.gamma),
        offset_sdr = fmt_slice(&meta.offset_sdr),
        offset_hdr = fmt_slice(&meta.offset_hdr),
        hdr_capacity_min = fmt_float(meta.hdr_capacity_min),
        hdr_capacity_max = fmt_float(meta.hdr_capacity_max),
        base_hdr = if meta.base_rendition_is_hdr {
            "True"
        } else {
            "False"
        },
    )
}

/// Minimal XMP for OPPO Gallery compatibility mode.
///
/// OPPO Gallery does not expect `hdrgm:*` tags in the XMP block; the 142-byte
/// ImageIO-native tmap payload carries all HDR metadata. This minimal block
/// contains only the core XMP/Photoshop date tags observed in Mac Swift CLI
/// OPPO output.
pub fn format_minimal_xmp() -> String {
    r##"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"##.to_string()
}

// ---------------------------------------------------------------------------
// tmap payloads
// ---------------------------------------------------------------------------

const RATIONAL_DEN: i64 = 100_000;

fn append_i32be(value: i32, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn append_u16be(value: u16, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn append_u32be(value: u32, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn fixed_i32(value: f32) -> i32 {
    (value as f64 * RATIONAL_DEN as f64).round() as i32
}

fn fixed_u32(value: f32) -> u32 {
    (value as f64 * RATIONAL_DEN as f64).round() as u32
}

/// Encode the ratio `numerator / RATIONAL_DEN` as a fixed-point rational.
/// When `numerator` is exactly 0.0, Python writes 1 instead.
fn _fixed_i32_zero_as_one(value: f32) -> i32 {
    if value == 0.0 {
        1
    } else {
        fixed_i32(value)
    }
}

/// Generate the 62-byte Apple baseline tmap payload.
///
/// Fixed-point rational format with denominator 100,000.
/// Uses the same values for all channels (monochrome-compatible).
///
/// Payload layout:
/// ```text
/// [0x00, 0x00, 0x00, 0x00, 0x00, 0x40]  // header (6 bytes)
/// + 14 × i32be fixed-point values       // 56 bytes
/// = 62 bytes
/// ```
pub fn make_apple_tmap_payload(info_floats: &[f32]) -> Vec<u8> {
    let cap_min = safe_log2(info_floats.get(16).copied().unwrap_or(1.0).max(1.0)).max(0.0);
    let cap_max = safe_log2(info_floats.get(17).copied().unwrap_or(1.0).max(1.0));
    let gain_min = safe_log2(info_floats.first().copied().unwrap_or(1.0).max(1.0)).max(0.0);
    let gain_max = safe_log2(info_floats.get(4).copied().unwrap_or(1.0).max(1.0));
    let gamma = info_floats.get(7).copied().unwrap_or(1.0);
    let base_offset = info_floats.get(10).copied().unwrap_or(0.0);
    let alt_offset = info_floats.get(13).copied().unwrap_or(0.0);

    // 14 values in the exact order from Swift makeAppleTmapPayload
    let values: [f32; 14] = [
        cap_min, 1.0,
        cap_max, 1.0,
        gain_min, 1.0,
        gain_max, 1.0,
        gamma, 1.0,
        base_offset, 1.0,
        alt_offset, 1.0,
    ];

    let mut out = Vec::with_capacity(62);
    // Header: 6 bytes
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x40]);
    // 14 × i32be fixed-point values. Base/alternate offset use
    // zero_as_one — writing 1/100000 instead of 0/100000.
    for (i, v) in values.iter().enumerate() {
        let pair_idx = i / 2;
        let num = if (pair_idx == 5 || pair_idx == 6) && *v == 0.0 {
            1
        } else {
            fixed_i32(*v)
        };
        append_i32be(num, &mut out);
    }

    debug_assert_eq!(out.len(), 62, "Apple tmap payload must be exactly 62 bytes");
    out
}

/// Generate the 142-byte ImageIO-native tmap payload.
///
/// This compatibility form is intentionally distinct from strict ISO 21496-1's
/// padded 145-byte check. Observed in OPPO-recognized CoreImage output.
///
/// Payload layout:
/// ```text
/// 0x00                                    // version (1 byte)
/// + u16be(0) u16be(0) 0xC0                // min_version, writer_version, flags (5 bytes)
/// + u32be(capMin*100k) u32be(100k)         // base_hdr_headroom (8 bytes)
/// + u32be(capMax*100k) u32be(100k)         // alternate_hdr_headroom (8 bytes)
/// + 3 channels × (                          // (1+21+120 = 142 bytes)
///     i32be(gainMin*100k) u32be(100k)       //   gain_map_min (8 bytes)
///     i32be(gainMax*100k) u32be(100k)       //   gain_map_max (8 bytes)
///     i32be(gamma*100k) u32be(100k)         //   gamma (8 bytes)
///     i32be(baseOffset*100k) u32be(100k)    //   base_offset (8 bytes)
///     i32be(altOffset*100k) u32be(100k)     //   alternate_offset (8 bytes)
///   )
/// = 142 bytes
/// ```
pub fn make_imageio_native_tmap_payload(info_floats: &[f32]) -> Vec<u8> {
    let gain_min = safe_log2(info_floats.first().copied().unwrap_or(1.0).max(1.0)).max(0.0);
    let gain_max = safe_log2(info_floats.get(4).copied().unwrap_or(1.0).max(1.0));
    let gamma = info_floats.get(7).copied().unwrap_or(1.0);
    let base_offset = info_floats.get(10).copied().unwrap_or(0.0);
    let alt_offset = info_floats.get(13).copied().unwrap_or(0.0);
    let cap_min = safe_log2(info_floats.get(16).copied().unwrap_or(1.0).max(1.0)).max(0.0);
    let cap_max = safe_log2(info_floats.get(17).copied().unwrap_or(1.0).max(1.0));

    // Python's `_build_imageio_native_tmap_config` does NOT apply
    // `zero_as_one` to base/alt offset here (it does in the 62B Apple
    // payload). Mirroring Python's behavior for byte-equivalence.
    let base_num = base_offset;
    let alt_num = alt_offset;

    let mut out = Vec::with_capacity(142);

    // Version byte
    out.push(0x00);

    // Common header (21 bytes)
    append_u16be(0, &mut out);  // minimum_version
    append_u16be(0, &mut out);  // writer_version
    out.push(0xC0);             // flags: multichannel=1, use_base_colour_space=1
    append_u32be(fixed_u32(cap_min), &mut out);  // base_hdr_headroom numerator
    append_u32be(RATIONAL_DEN as u32, &mut out); // base_hdr_headroom denominator
    append_u32be(fixed_u32(cap_max), &mut out);  // alternate_hdr_headroom numerator
    append_u32be(RATIONAL_DEN as u32, &mut out); // alternate_hdr_headroom denominator

    // 3 channels × 40 bytes (same values for all channels, matching 62B payload)
    for _ in 0..3 {
        append_i32be(fixed_i32(gain_min), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(gain_max), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_u32be(fixed_u32(gamma), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(base_num), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(alt_num), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
    }

    debug_assert_eq!(out.len(), 142, "ImageIO-native tmap payload must be exactly 142 bytes");
    out
}

// ---------------------------------------------------------------------------
// Strict ISO 21496-1 GainMapMetadata (C.2.2)
// ---------------------------------------------------------------------------

/// Detect the channel count from a per-channel metadata block, mirroring
/// Python's `_iso_channel_count` helper in `isobmff_patch.py`.
///
/// Returns 3 if any of the channel-valued fields has at least 3 values that
/// differ by more than a small tolerance. Returns 1 otherwise. The two values
/// in a 2-element list never trigger multichannel — only 3 differing values do.
fn channel_count_for_iso_meta(meta: &IsoMeta) -> usize {
    let check = |v: &[f32]| {
        v.len() >= 3
            && (v[0] - v[1]).abs() > 1e-6
            && (v[0] - v[2]).abs() > 1e-6
            && (v[1] - v[2]).abs() > 1e-6
    };
    if check(&meta.gain_map_min)
        || check(&meta.gain_map_max)
        || check(&meta.gamma)
        || check(&meta.offset_sdr)
        || check(&meta.offset_hdr)
    {
        3
    } else {
        1
    }
}

/// Build a strict ISO 21496-1 GainMapMetadata (Appendix C.2.2) binary payload.
///
/// Layout (matches the Python reference implementation):
/// ```text
/// [u16be minimum_version=0][u16be writer_version=0]   // 4 bytes
/// [u8 flags][u8 0][u8 0][u8 0]                        // 4 bytes
/// [u32be base_hdr_headroom_num][u32be 100000]         // 8 bytes
/// [u32be alt_hdr_headroom_num][u32be 100000]          // 8 bytes
/// per channel:
///     i32be gain_min *100k      u32be 100000          // 8 bytes
///     i32be gain_max *100k      u32be 100000          // 8 bytes
///     u32be gamma *100k         u32be 100000          // 8 bytes
///     i32be base_offset *100k   u32be 100000          // 8 bytes
///     i32be alt_offset *100k    u32be 100000          // 8 bytes
/// = 64 bytes (1 channel) or 144 bytes (3 channels)
/// ```
///
/// Mirrors the Python `_build_iso_gainmap_metadata_payload` helper so
/// conformance Tier 2 byte-compares cleanly across implementations.
pub fn make_iso21496_metadata_payload(meta: &IsoMeta) -> Vec<u8> {
    let base_headroom = meta.hdr_capacity_min;
    let alternate_headroom = meta.hdr_capacity_max;

    let channel_count = channel_count_for_iso_meta(meta);
    let is_multichannel = channel_count == 3;
    let use_base_color_space = true; // matches Python default
    let flags: u8 = (if is_multichannel { 0x80 } else { 0 })
        | (if use_base_color_space { 0x40 } else { 0 });

    let mut out = Vec::with_capacity(if is_multichannel { 144 } else { 64 });

    // GainMapVersion
    append_u16be(0, &mut out); // minimum_version
    append_u16be(0, &mut out); // writer_version
    // flags byte + 3 padding bytes
    out.push(flags);
    out.push(0);
    out.push(0);
    out.push(0);

    // Headroom rationals
    append_u32be(fixed_u32(base_headroom), &mut out);
    append_u32be(RATIONAL_DEN as u32, &mut out);
    append_u32be(fixed_u32(alternate_headroom), &mut out);
    append_u32be(RATIONAL_DEN as u32, &mut out);

    for channel in 0..channel_count {
        let gain_min = meta.gain_map_min.get(channel).copied().unwrap_or(0.0);
        let gain_max = meta
            .gain_map_max
            .get(channel)
            .copied()
            .unwrap_or(alternate_headroom);
        let gamma = meta.gamma.get(channel).copied().unwrap_or(1.0);
        let base_offset = meta.offset_sdr.get(channel).copied().unwrap_or(0.0);
        let alt_offset = meta.offset_hdr.get(channel).copied().unwrap_or(0.0);

        // gain_min / gain_max / base_offset / alt_offset are signed rationals
        append_i32be(fixed_i32(gain_min), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(gain_max), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        // gamma is unsigned rational
        append_u32be(fixed_u32(gamma), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(base_offset), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
        append_i32be(fixed_i32(alt_offset), &mut out);
        append_u32be(RATIONAL_DEN as u32, &mut out);
    }

    debug_assert_eq!(
        out.len(),
        if is_multichannel { 144 } else { 64 },
        "ISO 21496-1 GainMapMetadata must be 64 or 144 bytes"
    );
    out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_sample_uhdr_floats() -> Vec<f32> {
        vec![
            1.0, 1.0, 1.0,   // ratioMin
            1.0,              // padding
            4.926, 4.926, 4.926, // ratioMax
            1.0, 1.0, 1.0,   // gamma
            0.0, 0.0, 0.0,   // epsilonSdr
            0.0, 0.0, 0.0,   // epsilonHdr
            1.0,              // displayRatioSdr
            4.926,            // displayRatioHdr
            4.926,            // scale
            0.0,              // baseImageType
        ]
    }

    // ---------- safe_log2 ----------

    #[test]
    fn safe_log2_zero() {
        assert_eq!(safe_log2(0.0), 0.0);
    }

    #[test]
    fn safe_log2_negative() {
        assert_eq!(safe_log2(-5.0), 0.0);
    }

    #[test]
    fn safe_log2_positive() {
        assert!((safe_log2(4.0) - 2.0).abs() < 0.001);
    }

    // ---------- UHDR parsing ----------

    #[test]
    fn parse_uhdr_20_float() {
        let floats = make_sample_uhdr_floats();
        let info = parse_oppo_uhdr_info(&floats).unwrap();
        assert!((info.ratio_min[0] - 1.0).abs() < 0.001);
        assert!((info.ratio_max[0] - 4.926).abs() < 0.001);
        assert!((info.gamma[0] - 1.0).abs() < 0.001);
        assert!((info.display_ratio_hdr - 4.926).abs() < 0.001);
        assert!((info.scale - 4.926).abs() < 0.001);
    }

    #[test]
    fn parse_uhdr_too_few_floats() {
        let floats = vec![1.0; 10];
        assert!(parse_oppo_uhdr_info(&floats).is_err());
    }

    // ---------- ISO metadata ----------

    #[test]
    fn build_iso_from_uhdr_known_values() {
        let floats = make_sample_uhdr_floats();
        let meta = build_iso_metadata_from_uhdr(&floats).unwrap();
        assert_eq!(meta.channel_count, 3);
        // gainMapMin = log2(1.0) = 0.0
        assert!((meta.gain_map_min[0] - 0.0).abs() < 0.001);
        // gainMapMax = log2(4.926)
        let expected = 4.926_f32.log2();
        assert!((meta.gain_map_max[0] - expected).abs() < 0.01);
        assert_eq!(meta.base_rendition_is_hdr, false);
    }

    #[test]
    fn build_iso_from_edr() {
        let meta = build_iso_metadata(4.0);
        assert_eq!(meta.channel_count, 1);
        // gainMapMax = log2(4.0) = 2.0
        assert!((meta.gain_map_max[0] - 2.0).abs() < 0.001);
        assert_eq!(meta.gain_map_min[0], 0.0);
        assert_eq!(meta.base_rendition_is_hdr, false);
    }

    #[test]
    fn build_iso_from_edr_one() {
        let meta = build_iso_metadata(1.0);
        assert_eq!(meta.channel_count, 1);
        assert!((meta.hdr_capacity_max - 0.0).abs() < 0.001);
    }

    // ---------- XMP ----------

    #[test]
    fn xmp_contains_namespaces() {
        let meta = build_iso_metadata(4.0);
        let xmp = format_hdrgm_xmp(&meta);
        assert!(xmp.contains("http://ns.adobe.com/hdr-gain-map/1.0/"));
        assert!(xmp.contains("adobe:ns:meta/"));
        assert!(xmp.contains("hdrgm:Version"));
        assert!(xmp.contains("hdrgm:GainMapMin"));
        assert!(xmp.contains("hdrgm:GainMapMax"));
        assert!(xmp.contains("hdrgm:Gamma"));
        assert!(xmp.contains("hdrgm:OffsetSDR"));
        assert!(xmp.contains("hdrgm:OffsetHDR"));
        assert!(xmp.contains("hdrgm:HDRCapacityMin"));
        assert!(xmp.contains("hdrgm:HDRCapacityMax"));
        assert!(xmp.contains("hdrgm:BaseRenditionIsHDR"));
    }

    #[test]
    fn xmp_contains_known_values() {
        let meta = build_iso_metadata(4.0);
        let xmp = format_hdrgm_xmp(&meta);
        // gainMapMin = 0.0
        assert!(xmp.contains("0.000000"), "expected '0.000000' in XMP, got: {xmp}");
        // gainMapMax = 2.0
        assert!(xmp.contains("2.000000"), "expected '2.000000' in XMP, got: {xmp}");
        assert!(xmp.contains("False"), "expected 'False' in XMP, got: {xmp}");
    }

    #[test]
    fn xmp_wraps_with_xpacket() {
        let meta = build_iso_metadata(4.0);
        let xmp = format_hdrgm_xmp(&meta);
        assert!(xmp.starts_with("<?xpacket begin"));
        assert!(xmp.ends_with("<?xpacket end=\"w\"?>"));
    }

    // ---------- tmap ----------

    #[test]
    fn apple_tmap_62_bytes() {
        let floats = make_sample_uhdr_floats();
        let payload = make_apple_tmap_payload(&floats);
        assert_eq!(payload.len(), 62);
    }

    #[test]
    fn apple_tmap_header_bytes() {
        let floats = make_sample_uhdr_floats();
        let payload = make_apple_tmap_payload(&floats);
        assert_eq!(&payload[..6], &[0x00, 0x00, 0x00, 0x00, 0x00, 0x40]);
    }

    #[test]
    fn imageio_tmap_142_bytes() {
        let floats = make_sample_uhdr_floats();
        let payload = make_imageio_native_tmap_payload(&floats);
        assert_eq!(payload.len(), 142);
    }

    #[test]
    fn imageio_tmap_version_byte_zero() {
        let floats = make_sample_uhdr_floats();
        let payload = make_imageio_native_tmap_payload(&floats);
        assert_eq!(payload[0], 0x00);
    }

    #[test]
    fn imageio_tmap_flags_byte() {
        let floats = make_sample_uhdr_floats();
        let payload = make_imageio_native_tmap_payload(&floats);
        // flags at offset 5 (after version + two u16)
        assert_eq!(payload[5], 0xC0);
    }

    #[test]
    fn tmap_from_minimal_floats() {
        // Test with only a few floats (should use defaults)
        let floats = vec![2.0_f32; 5];
        let payload = make_apple_tmap_payload(&floats);
        assert_eq!(payload.len(), 62);
    }

    // ---------- UHDR info bytes ----------

    #[test]
    fn oppo_uhdr_info_bytes_80_bytes() {
        let meta = build_iso_metadata(4.0);
        let bytes = build_oppo_uhdr_info_bytes(&meta);
        assert_eq!(bytes.len(), 80);
    }

    #[test]
    fn oppo_uhdr_info_bytes_roundtrip() {
        let original_floats = make_sample_uhdr_floats();
        let meta = build_iso_metadata_from_uhdr(&original_floats).unwrap();
        let info_bytes = build_oppo_uhdr_info_bytes(&meta);

        // Parse the bytes back as f32s
        let parsed: Vec<f32> = info_bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();

        assert_eq!(parsed.len(), 20);
        // padding field should be 1.0
        assert!((parsed[3] - 1.0).abs() < 0.001);
        // gamma should be 1.0
        assert!((parsed[7] - 1.0).abs() < 0.1);
    }

    // ---------- strict ISO 21496-1 GainMapMetadata ----------

    #[test]
    fn iso21496_payload_multichannel_is_144_bytes() {
        // The sample UHDR floats produce *identical* per-channel values for
        // gain/gamma/offset. Python's _iso_channel_count returns 1 in that
        // case (it only escalates to 3 when channels actually differ), so
        // the strict-ISO payload is 64 bytes here. Use a meta with three
        // distinct per-channel gainMapMax values to exercise the 144-byte
        // path.
        let mut meta = build_iso_metadata(4.0);
        // Three distinct channels force channel_count=3 in the helper.
        meta.gain_map_max = vec![1.0, 2.0, 3.0];
        meta.gain_map_min = vec![0.0, 0.0, 0.0];
        meta.gamma = vec![1.0, 1.0, 1.0];
        meta.offset_sdr = vec![0.0, 0.0, 0.0];
        meta.offset_hdr = vec![0.0, 0.0, 0.0];
        meta.channel_count = 3;
        let payload = make_iso21496_metadata_payload(&meta);
        assert_eq!(payload.len(), 144, "multichannel ISO 21496-1 must be 144 bytes");
    }

    #[test]
    fn iso21496_payload_monochannel_is_64_bytes() {
        let meta = build_iso_metadata(4.0);
        let payload = make_iso21496_metadata_payload(&meta);
        assert_eq!(payload.len(), 64, "monochannel ISO 21496-1 must be 64 bytes");
    }

    #[test]
    fn iso21496_payload_header_layout() {
        let meta = build_iso_metadata(4.0);
        let payload = make_iso21496_metadata_payload(&meta);
        // version
        assert_eq!(&payload[0..2], &[0, 0]); // min_version
        assert_eq!(&payload[2..4], &[0, 0]); // writer_version
                                             // monochannel: flags = 0x40 (use_base_colour_space only)
        assert_eq!(payload[4], 0x40);
        // 3 padding bytes
        assert_eq!(&payload[5..8], &[0, 0, 0]);
        // base headroom num (hdr_capacity_min=0.0) → 0
        assert_eq!(&payload[8..12], &[0, 0, 0, 0]);
        // base headroom den (100000 = 0x000186A0)
        assert_eq!(&payload[12..16], &[0x00, 0x01, 0x86, 0xA0]);
        // alt headroom num (hdr_capacity_max = log2(4) = 2.0) → 200000 = 0x00030D40
        assert_eq!(&payload[16..20], &[0x00, 0x03, 0x0D, 0x40]);
        // alt headroom den (100000)
        assert_eq!(&payload[20..24], &[0x00, 0x01, 0x86, 0xA0]);
    }
}
