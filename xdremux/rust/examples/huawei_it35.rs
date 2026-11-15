//! Print the HDR Vivid `it35` item of a HEIF file field by field, read as
//! GB/T 48347-2026 UWAInfo. Read-only; prints no EXIF or GPS data.
//!
//! usage: cargo run -p xdremux-core --example huawei_it35 -- <file.heic>
//!
//! Field layout and evidence: docs/research/huawei-xmage-format.md §6.12.

use sha2::{Digest, Sha256};
use std::env;
use xdremux_core::huawei_heic::{self, UwaInfo};
use xdremux_core::isobmff;

fn main() {
    let path = env::args().nth(1).expect("usage: huawei_it35 <file.heic>");
    let data = std::fs::read(&path).expect("read HEIF file");
    let Some(payload) = huawei_heic::it35_payload(&data).expect("parse HEIF meta") else {
        println!("no it35 item");
        return;
    };
    let digest = Sha256::digest(&payload);
    println!(
        "it35: {} bytes, sha256 {}",
        payload.len(),
        hex(&digest[..8])
    );
    match huawei_heic::parse_uwa_info(&payload) {
        Ok(info) => {
            print_uwa_info(&info);
            print_cross_checks(&data, &info);
        }
        Err(error) => {
            println!("not UWAInfo: {error}");
            println!("raw: {}", hex(&payload));
        }
    }
}

/// Compare the static block with the file's `mdcv`/`clli` boxes and the
/// extension with the `tmap` item's first channel (ISO 21496-1).
fn print_cross_checks(data: &[u8], info: &UwaInfo) {
    let Ok(meta) = isobmff::parse_source_meta(data) else {
        return;
    };
    // PropertyInfo::raw includes the 8-byte box header.
    let property = |ptype: &str| {
        meta.props
            .iter()
            .find(|property| property.ptype == ptype)
            .and_then(|property| property.raw.get(8..))
    };
    println!("cross-checks against the same file:");
    if let (Some(metadata), Some(mdcv), Some(clli)) =
        (&info.metadata, property("mdcv"), property("clli"))
    {
        if mdcv.len() == 24 && clli.len() == 4 {
            // mdcv stores an x/y pair per primary; the static block stores
            // the three x values first, then the three y values.
            let mut expected = Vec::new();
            for primary in 0..3 {
                expected.extend_from_slice(&mdcv[primary * 4..primary * 4 + 2]);
            }
            for primary in 0..3 {
                expected.extend_from_slice(&mdcv[primary * 4 + 2..primary * 4 + 4]);
            }
            expected.extend_from_slice(&mdcv[12..]);
            expected.extend_from_slice(clli);
            println!(
                "  static_metadata == mdcv (primaries as x,x,x,y,y,y) + clli: {}",
                metadata.static_metadata == expected
            );
        }
    }
    let tmap = huawei_heic::first_item_payload(data, "tmap").ok().flatten();
    if let (Some(extension), Some(tmap)) = (&info.extension, tmap) {
        // Version-0 tmap: 6 header bytes + two headroom rationals, then
        // channel 0 = five 8-byte rationals at bytes 22..62.
        if let (Some(embedded), Some(channel)) = (extension.get(1..41), tmap.get(22..62)) {
            println!(
                "  extend_info_extension[1..41] == tmap[22..62] (ISO 21496-1 channel 0): {}",
                embedded == channel
            );
        }
    }
}

fn print_uwa_info(info: &UwaInfo) {
    println!("offset  bytes  field                            value");
    row(0, 1, "country_code", format!("{:#04x}", info.country_code));
    row(
        1,
        2,
        "terminal_provide_code",
        format!("{:#06x}", info.terminal_provide_code),
    );
    row(
        3,
        2,
        "terminal_provide_oriented_code",
        format!("{:#06x}", info.terminal_provide_oriented_code),
    );
    row(
        5,
        1,
        "extended_frame_number",
        info.extended_frame_number.to_string(),
    );
    row(
        6,
        4,
        "extended_type",
        format!(
            "{:#010x} (file_type={} meta_type={} enhance_type={} reserved={})",
            info.extended_type,
            info.file_type(),
            info.meta_type(),
            info.enhance_type(),
            info.extended_type & 0xff
        ),
    );
    let mut offset = 10;
    if let Some(metadata) = &info.metadata {
        let static_len = metadata.static_metadata.len();
        let dynamic_len = metadata.dynamic_metadata.len();
        row(
            offset,
            2,
            "metadata_size",
            format!(
                "{} ({}: static {static_len} + dynamic {dynamic_len})",
                metadata.metadata_size,
                metadata.metadata_size_kind.as_str()
            ),
        );
        row(
            offset + 2,
            2,
            "static_metadata_size",
            static_len.to_string(),
        );
        row(
            offset + 4,
            static_len,
            "static_metadata",
            hex(&metadata.static_metadata),
        );
        offset += 4 + static_len;
        row(offset, 2, "dynamic_metadata_size", dynamic_len.to_string());
        row(
            offset + 2,
            dynamic_len,
            "dynamic_metadata",
            hex(&metadata.dynamic_metadata),
        );
        offset += 2 + dynamic_len;
    }
    if let Some(extension) = &info.extension {
        row(offset, 2, "extension_size", extension.len().to_string());
        row(
            offset + 2,
            extension.len(),
            "extend_info_extension",
            hex(extension),
        );
    }
    if let Some(metadata) = &info.metadata {
        print_static(&metadata.static_metadata);
        print_dynamic(&metadata.dynamic_metadata);
    }
}

fn print_static(block: &[u8]) {
    let Some(s) = huawei_heic::observe_uwa_static_metadata(block) else {
        println!("static_metadata: {} bytes, no observed layout", block.len());
        return;
    };
    println!("static_metadata (observed layout, compare mdcv/clli):");
    let chroma = |v: u16| format!("{v} ({:.4})", f64::from(v) * 0.00002);
    for (i, (x, y)) in s
        .display_primaries_x
        .iter()
        .zip(s.display_primaries_y.iter())
        .enumerate()
    {
        println!("  primary[{i}]  x={}  y={}", chroma(*x), chroma(*y));
    }
    println!(
        "  white_point  x={}  y={}",
        chroma(s.white_point_x),
        chroma(s.white_point_y)
    );
    println!(
        "  max_display_mastering_luminance  {} ({} cd/m2)",
        s.max_display_mastering_luminance,
        f64::from(s.max_display_mastering_luminance) * 0.0001
    );
    println!(
        "  min_display_mastering_luminance  {} ({} cd/m2)",
        s.min_display_mastering_luminance,
        f64::from(s.min_display_mastering_luminance) * 0.0001
    );
    println!("  max_content_light_level  {}", s.max_content_light_level);
    println!(
        "  max_pic_average_light_level  {}",
        s.max_pic_average_light_level
    );
}

fn print_dynamic(block: &[u8]) {
    let d = match huawei_heic::parse_hdr_vivid_dynamic_metadata(block) {
        Ok(d) => d,
        Err(error) => {
            println!("dynamic_metadata: not T/UWA 005.1 table 11: {error}");
            return;
        }
    };
    let q = |v: u32, den: u32| format!("{v} ({:.4})", f64::from(v) / f64::from(den));
    println!("dynamic_metadata (T/UWA 005.1-2022 table 11):");
    println!("  system_start_code  {}", d.system_start_code);
    println!("  minimum_maxrgb  {}", q(d.minimum_maxrgb.into(), 4095));
    println!("  average_maxrgb  {}", q(d.average_maxrgb.into(), 4095));
    println!("  variance_maxrgb  {}", q(d.variance_maxrgb.into(), 4095));
    println!("  maximum_maxrgb  {}", q(d.maximum_maxrgb.into(), 4095));
    println!(
        "  tone_mapping_mode_flag  {}  tone_mapping_param_num  {}",
        u8::from(!d.tone_mapping.is_empty()),
        d.tone_mapping.len()
    );
    for (i, t) in d.tone_mapping.iter().enumerate() {
        println!(
            "  [{i}] targeted_system_display_maximum_luminance  {}",
            q(t.targeted_system_display_maximum_luminance.into(), 4095)
        );
        match &t.base_curve {
            Some(b) => println!(
                "  [{i}] base: m_p {} m_m {} m_a {} m_b {} m_n {} k1 {} k2 {} k3 {} \
                 Delta_enable_mode {} Delta {}",
                q(b.m_p.into(), 16383),
                q(b.m_m.into(), 10),
                q(b.m_a.into(), 1023),
                q(b.m_b.into(), 1023),
                q(b.m_n.into(), 10),
                b.k1,
                b.k2,
                b.k3,
                b.delta_enable_mode,
                q(b.delta.into(), 127)
            ),
            None => println!("  [{i}] base_enable_flag  0"),
        }
        for (j, s) in t.three_spline.iter().enumerate() {
            println!(
                "  [{i}][{j}] three_Spline: TH_mode {} TH_enable_MB {} TH_enable {} \
                 TH_Delta1 {} TH_Delta2 {} enable_Strength {}",
                s.th_mode,
                s.th_enable_mb
                    .map(|v| q(v.into(), 255))
                    .unwrap_or_else(|| "-".into()),
                q(s.th_enable.into(), 4095),
                q(s.th_delta1.into(), 1023),
                q(s.th_delta2.into(), 1023),
                q(s.enable_strength.into(), 255)
            );
        }
    }
    match &d.color_saturation_gain {
        Some(gains) => println!(
            "  color_saturation_num  {}  gains  {:?}",
            gains.len(),
            gains
        ),
        None => println!("  color_saturation_mapping_flag  0"),
    }
    let used = d.bits_read.div_ceil(8);
    println!(
        "  table 11 used {} bits; {} of {} bytes follow that table 11 does not describe: {}",
        d.bits_read,
        block.len() - used,
        block.len(),
        hex(&block[used..])
    );
}

fn row(offset: usize, len: usize, name: &str, value: String) {
    println!("{offset:<7} {len:<6} {name:<32} {value}");
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
