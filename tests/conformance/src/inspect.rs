//! `inspect` subcommand: produce a canonical JSON description of a source HEIC
//! file, including the parsed LHDR/UHDR numerics and the tmap payload bytes
//! that the implementation would emit.
//!
//! Schema (versioned as `xdremux-conformance/1`):
//!
//! ```text
//! {
//!   "schema": "xdremux-conformance/1",
//!   "implementation": "rust" | "python" | "swift",
//!   "version": "<pkg version>",
//!   "source": "<input filename>",
//!   "lhdr": {
//!     "mode": "lhdr" | "uhdr" | "error: <msg>",
//!     "meta_floats": [<f32>...],   // length 19+; truncated to 32 entries
//!     "mask_data_len": <int|null>,
//!     "gainmap_data_len": <int|null>,
//!     "container_status": "ok" | "error: <msg>"
//!   },
//!   "edr_scale": <f32>,
//!   "family": "x6" | "x7",
//!   "iso_meta": {
//!     "channel_count": 1 | 3,
//!     "gain_map_min": [<f32>...],
//!     "gain_map_max": [<f32>...],
//!     "gamma":         [<f32>...],
//!     "offset_sdr":    [<f32>...],
//!     "offset_hdr":    [<f32>...],
//!     "hdr_capacity_min": <f32>,
//!     "hdr_capacity_max": <f32>,
//!     "base_rendition_is_hdr": <bool>,
//!     "scale": <f32>
//!   },
//!   "tmap_payloads": {
//!     "apple_62":     { "size": <int>, "md5": "<hex>", "first16": "<hex>" },
//!     "imageio_142":  { "size": <int>, "md5": "<hex>", "first16": "<hex>" },
//!     "iso21496_144": { "size": <int|null>, "md5": "<hex|null>", "first16": "<hex>" }
//!   },
//!   "xmp": {
//!     "length": <int>,
//!     "md5": "<hex>",
//!     "hdrgm": {
//!       "version": "1.0",
//!       "gainMapMax": "...",
//!       "gainMapMin": "...",
//!       "hdrCapacityMax": "..."
//!     }
//!   }
//! }
//! ```

use std::fs;
use std::io::Write;
use std::path::Path;

use xdremux_core::container::{self, ExtractedLhdr};
use xdremux_core::edr;
use xdremux_core::iso21496::{
    self, build_iso_metadata, build_iso_metadata_from_uhdr, format_hdrgm_xmp,
    make_apple_tmap_payload, make_imageio_native_tmap_payload, make_iso21496_metadata_payload,
    IsoMeta,
};

use crate::json;

const SCHEMA_VERSION: &str = "xdremux-conformance/1";
const CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");
const MAX_META_FLOATS: usize = 32;

/// Run the inspect subcommand and write a canonical JSON document to `out`.
pub fn run<P: AsRef<Path>, Q: AsRef<Path>>(
    input: P,
    out: Q,
    implementation: &str,
) -> Result<(), String> {
    let input_path = input.as_ref();
    let extracted = container::extract_lhdr(input_path.to_str().ok_or("non-utf8 path")?);

    let json = build_json(input_path, &extracted, implementation);
    let mut f = fs::File::create(out).map_err(|e| format!("cannot create output: {e}"))?;
    f.write_all(json.as_bytes())
        .map_err(|e| format!("cannot write output: {e}"))?;
    Ok(())
}

/// Pure version of `run` that returns the JSON string. Useful for tests.
pub fn build_json(input_path: &Path, extracted: &Result<ExtractedLhdr, String>, implementation: &str) -> String {
    let mut s = String::with_capacity(4096);

    s.push('{');
    kv_str(&mut s, "schema", SCHEMA_VERSION, false);
    s.push(',');
    kv_str(&mut s, "implementation", implementation, false);
    s.push(',');
    kv_str(&mut s, "version", CRATE_VERSION, false);
    s.push(',');
    kv_str(&mut s, "source", &input_path.display().to_string(), false);
    s.push(',');

    // lhdr block
    write_lhdr_block(&mut s, extracted);
    s.push(',');

    // edr_scale, family, iso_meta derived from extracted
    let (edr_scale, family, iso_meta_opt) = compute_metrics(extracted);

    kv_f32(&mut s, "edr_scale", edr_scale, false);
    s.push(',');
    kv_str(&mut s, "family", family, false);
    s.push(',');

    write_iso_meta(&mut s, iso_meta_opt.as_ref());

    s.push(',');
    write_tmap_payloads(&mut s, iso_meta_opt.as_ref());

    s.push(',');
    write_xmp_block(&mut s, iso_meta_opt.as_ref());

    s.push('}');
    s
}

fn compute_metrics(extracted: &Result<ExtractedLhdr, String>) -> (f32, &'static str, Option<IsoMeta>) {
    match extracted {
        Ok(e) => {
            let family = if e.meta_floats.first().copied().unwrap_or(0.0) >= 3.0 || e.mode == "uhdr" {
                "x7"
            } else {
                "x6"
            };
            let iso_meta = if e.mode == "uhdr" {
                if e.meta_floats.len() >= 20 {
                    build_iso_metadata_from_uhdr(&e.meta_floats).ok()
                } else {
                    // UHDR source with fewer than 20 floats: fall back to the
                    // first 19 floats and use the 0.18 index for scale.
                    let scale = e.meta_floats.get(18).copied().unwrap_or(1.0);
                    let ratio_max = e
                        .meta_floats
                        .get(4)
                        .copied()
                        .unwrap_or(0.0)
                        .max(e.meta_floats.get(5).copied().unwrap_or(0.0))
                        .max(e.meta_floats.get(6).copied().unwrap_or(0.0));
                    let cap_max = if ratio_max > 0.0 { ratio_max.log2() } else { 0.0 };
                    Some(iso21496::IsoMeta {
                        gain_map_min: vec![0.0; 3],
                        gain_map_max: vec![cap_max; 3],
                        gamma: vec![1.0; 3],
                        offset_sdr: vec![0.0; 3],
                        offset_hdr: vec![0.0; 3],
                        hdr_capacity_min: 0.0,
                        hdr_capacity_max: cap_max,
                        base_rendition_is_hdr: false,
                        scale,
                        channel_count: 3,
                    })
                }
            } else {
                let scale = edr::edr_scale_calculator(&e.meta_floats);
                Some(build_iso_metadata(scale))
            };
            let scale_for_output = match &iso_meta {
                Some(m) => m.scale,
                None => 1.0,
            };
            (scale_for_output, family, iso_meta)
        }
        Err(_) => (0.0, "x6", None),
    }
}

fn write_lhdr_block(s: &mut String, extracted: &Result<ExtractedLhdr, String>) {
    s.push_str("\"lhdr\":{");
    match extracted {
        Ok(e) => {
            kv_str(s, "mode", &e.mode, false);
            s.push(',');
            s.push_str("\"meta_floats\":[");
            for (i, f) in e.meta_floats.iter().take(MAX_META_FLOATS).enumerate() {
                if i > 0 {
                    s.push(',');
                }
                json::write_f32(s, *f);
            }
            s.push(']');
            s.push(',');
            kv_str(s, "meta_floats_truncated", if e.meta_floats.len() > MAX_META_FLOATS { "true" } else { "false" }, false);
            s.push(',');
            kv_usize_opt(s, "mask_data_len", e.mask_data.as_ref().map(|d| d.len()), false);
            s.push(',');
            kv_usize_opt(s, "gainmap_data_len", e.gainmap_data.as_ref().map(|d| d.len()), false);
            s.push(',');
            kv_str(s, "container_status", "ok", false);
        }
        Err(msg) => {
            kv_str(s, "mode", &format!("error: {msg}"), false);
            s.push(',');
            s.push_str("\"meta_floats\":[]");
            s.push(',');
            kv_str(s, "meta_floats_truncated", "false", false);
            s.push(',');
            s.push_str("\"mask_data_len\":null");
            s.push(',');
            s.push_str("\"gainmap_data_len\":null");
            s.push(',');
            kv_str(s, "container_status", &format!("error: {msg}"), false);
        }
    }
    s.push('}');
}

fn write_iso_meta(s: &mut String, m: Option<&IsoMeta>) {
    s.push_str("\"iso_meta\":");
    match m {
        Some(m) => {
            s.push('{');
            kv_usize(s, "channel_count", m.channel_count, false);
            s.push(',');
            write_f32_vec(s, "gain_map_min", &m.gain_map_min);
            s.push(',');
            write_f32_vec(s, "gain_map_max", &m.gain_map_max);
            s.push(',');
            write_f32_vec(s, "gamma", &m.gamma);
            s.push(',');
            write_f32_vec(s, "offset_sdr", &m.offset_sdr);
            s.push(',');
            write_f32_vec(s, "offset_hdr", &m.offset_hdr);
            s.push(',');
            kv_f32(s, "hdr_capacity_min", m.hdr_capacity_min, false);
            s.push(',');
            kv_f32(s, "hdr_capacity_max", m.hdr_capacity_max, false);
            s.push(',');
            kv_bool(s, "base_rendition_is_hdr", m.base_rendition_is_hdr, false);
            s.push(',');
            kv_f32(s, "scale", m.scale, false);
            s.push('}');
        }
        None => s.push_str("null"),
    }
}

fn write_tmap_payloads(s: &mut String, m: Option<&IsoMeta>) {
    s.push_str("\"tmap_payloads\":{");

    // 62-byte Apple baseline: derived from the 20-float info block
    // (or from a synthesized 20-float block for LHDR/ISO metadata).
    match m {
        Some(m) => {
            // Apple 62-byte: from info_floats-style 20 floats
            let info_floats = synthesize_info_floats(m);
            let payload = make_apple_tmap_payload(&info_floats);
            write_payload_entry(s, "apple_62", &payload, false);

            s.push(',');
            let payload = make_imageio_native_tmap_payload(&info_floats);
            write_payload_entry(s, "imageio_142", &payload, false);

            s.push(',');
            // Strict ISO 21496-1: only available for the canonical UHDR
            // 3-channel form (1-channel LHDR produces 64B which we still
            // surface, but the multichannel 144B is the cross-implementation
            // comparison target).
            let payload = make_iso21496_metadata_payload(m);
            write_payload_entry(s, "iso21496", &payload, false);

            // Also dump the synthesized 20-float info block for cross-impl
            // inspection of the input contract.
            s.push(',');
            s.push_str("\"info_floats\":[");
            for (i, f) in info_floats.iter().enumerate() {
                if i > 0 {
                    s.push(',');
                }
                json::write_f32(s, *f);
            }
            s.push(']');
        }
        None => {
            kv_null(s, "apple_62", false);
            s.push(',');
            kv_null(s, "imageio_142", false);
            s.push(',');
            kv_null(s, "iso21496", false);
        }
    }
    s.push('}');
}

fn write_xmp_block(s: &mut String, m: Option<&IsoMeta>) {
    s.push_str("\"xmp\":");
    match m {
        Some(m) => {
            let xmp = format_hdrgm_xmp(m);
            let payload = xmp.into_bytes();
            let md5 = md5_hex(&payload);
            s.push('{');
            kv_usize(s, "length", payload.len(), false);
            s.push(',');
            kv_str(s, "md5", &md5, false);
            s.push(',');
            s.push_str("\"hdrgm\":{");
            kv_str(s, "version", extract_xmp_field(&payload, "hdrgm:Version").as_deref().unwrap_or(""), false);
            s.push(',');
            kv_str(s, "gainMapMax", extract_xmp_field(&payload, "hdrgm:GainMapMax").as_deref().unwrap_or(""), false);
            s.push(',');
            kv_str(s, "gainMapMin", extract_xmp_field(&payload, "hdrgm:GainMapMin").as_deref().unwrap_or(""), false);
            s.push(',');
            kv_str(s, "hdrCapacityMax", extract_xmp_field(&payload, "hdrgm:HDRCapacityMax").as_deref().unwrap_or(""), false);
            s.push('}');
            s.push('}');
        }
        None => s.push_str("null"),
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn kv_str(s: &mut String, k: &str, v: &str, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    json::write_escaped(s, k);
    s.push_str("\":\"");
    json::write_escaped(s, v);
    s.push('"');
}

fn kv_usize(s: &mut String, k: &str, v: usize, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(&v.to_string());
}

fn kv_usize_opt(s: &mut String, k: &str, v: Option<usize>, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    match v {
        Some(n) => s.push_str(&n.to_string()),
        None => s.push_str("null"),
    }
}

fn kv_f32(s: &mut String, k: &str, v: f32, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    json::write_f32(s, v);
}

fn kv_bool(s: &mut String, k: &str, v: bool, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(if v { "true" } else { "false" });
}

fn kv_null(s: &mut String, k: &str, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":null");
}

fn write_f32_vec(s: &mut String, k: &str, v: &[f32]) {
    s.push('"');
    s.push_str(k);
    s.push_str("\":[");
    for (i, f) in v.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        json::write_f32(s, *f);
    }
    s.push(']');
}

fn write_payload_entry(s: &mut String, k: &str, payload: &[u8], leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":{");
    kv_usize(s, "size", payload.len(), false);
    s.push(',');
    kv_str(s, "md5", &md5_hex(payload), false);
    s.push(',');
    let first16: Vec<u8> = payload.iter().take(16).copied().collect();
    kv_str(s, "first16", &hex(&first16), false);
    s.push('}');
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(hex_nibble(b >> 4));
        s.push(hex_nibble(b & 0x0f));
    }
    s
}

fn hex_nibble(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        _ => (b'a' + (n - 10)) as char,
    }
}

fn md5_hex(bytes: &[u8]) -> String {
    // We don't pull in the `md-5` crate; a hand-rolled MD5 is ~80 lines
    // and the conformance tool already needs hex(). Use a tiny implementation.
    hex(&md5(bytes))
}

/// MD5 implementation (RFC 1321). Public domain reference port.
fn md5(message: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    let orig_len_bits = (message.len() as u64) * 8;
    let mut buf: Vec<u8> = message.to_vec();
    buf.push(0x80);
    while buf.len() % 64 != 56 {
        buf.push(0);
    }
    buf.extend_from_slice(&orig_len_bits.to_le_bytes());

    for chunk in buf.chunks(64) {
        let mut m = [0u32; 16];
        for (i, word) in chunk.chunks(4).enumerate() {
            m[i] = u32::from_le_bytes([word[0], word[1], word[2], word[3]]);
        }

        let mut a = a0;
        let mut b = b0;
        let mut c = c0;
        let mut d = d0;

        for i in 0..64 {
            let (f, g) = if i < 16 {
                ((b & c) | (!b & d), i)
            } else if i < 32 {
                ((d & b) | (!d & c), (5 * i + 1) % 16)
            } else if i < 48 {
                (b ^ c ^ d, (3 * i + 5) % 16)
            } else {
                (c ^ (b | !d), (7 * i) % 16)
            };
            let f = f.wrapping_add(a).wrapping_add(K[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(S[i]));
        }

        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    out
}

/// Reconstruct a 20-float info block in the same shape the LHDR/UHDR paths
/// expect when calling `make_apple_tmap_payload` / `make_imageio_native_tmap_payload`.
fn synthesize_info_floats(m: &IsoMeta) -> Vec<f32> {
    let exp = |v: f32| if v > 0.0 { 2.0_f32.powf(v) } else { 1.0 };
    let mut floats = vec![0.0_f32; 20];
    // ratioMin: 3 channels
    for i in 0..3 {
        let v = m.gain_map_min.get(i).copied().unwrap_or(0.0);
        floats[i] = exp(v);
    }
    floats[3] = 1.0; // padding
    // ratioMax
    for i in 0..3 {
        let v = m.gain_map_max.get(i).copied().unwrap_or(0.0);
        floats[4 + i] = exp(v);
    }
    // gamma
    for i in 0..3 {
        floats[7 + i] = m.gamma.get(i).copied().unwrap_or(1.0);
    }
    // offsetSdr
    for i in 0..3 {
        floats[10 + i] = m.offset_sdr.get(i).copied().unwrap_or(0.0);
    }
    // offsetHdr
    for i in 0..3 {
        floats[13 + i] = m.offset_hdr.get(i).copied().unwrap_or(0.0);
    }
    // displayRatioSdr
    floats[16] = if m.hdr_capacity_min > 0.0 { exp(m.hdr_capacity_min) } else { 1.0 };
    // displayRatioHdr
    floats[17] = if m.hdr_capacity_max > 0.0 { exp(m.hdr_capacity_max) } else { 1.0 };
    // scale
    floats[18] = m.scale;
    // baseImageType (placeholder, doesn't affect 62B/142B payload)
    floats[19] = if m.base_rendition_is_hdr { 1.0 } else { 0.0 };
    floats
}

/// Extract the text content of a simple XML element like `<hdrgm:GainMapMax>...</hdrgm:GainMapMax>`.
fn extract_xmp_field(xmp: &[u8], element: &str) -> Option<String> {
    let haystack = std::str::from_utf8(xmp).ok()?;
    let open = format!("<{element}>");
    let close = format!("</{element}>");
    let start = haystack.find(&open)? + open.len();
    let end = haystack[start..].find(&close)? + start;
    Some(haystack[start..end].trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_known_vector() {
        // RFC 1321 test vector
        let h = md5(b"");
        assert_eq!(hex(&h), "d41d8cd98f00b204e9800998ecf8427e");
    }

    #[test]
    fn md5_abc() {
        let h = md5(b"abc");
        assert_eq!(hex(&h), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn json_escape_basic() {
        let mut s = String::new();
        json::write_escaped(&mut s, "a\nb\"c");
        assert_eq!(s, "a\\nb\\\"c");
    }

    #[test]
    fn extract_xmp_field_basic() {
        let xmp = b"<x:foo><hdrgm:Version>1.0</hdrgm:Version></x:foo>";
        let v = extract_xmp_field(xmp, "hdrgm:Version");
        assert_eq!(v.as_deref(), Some("1.0"));
    }
}
