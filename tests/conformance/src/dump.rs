//! Tier 3: ISOBMFF structural dump for cross-implementation comparison.
//!
//! Extracts a canonical JSON representation of an output HEIC file's
//! box structure, suitable for comparing Rust vs Python vs Swift implementations.
//!
//! The dump includes:
//! - ftyp (major brand, compatible brands)
//! - meta/hdlr (handler type)
//! - meta/pitm (primary item ID)
//! - meta/iinf (item info entries)
//! - meta/iref (item references)
//! - meta/iprp/ipco (item properties with key fields extracted)
//! - meta/iprp/ipma (item-property associations)
//! - meta/iloc (item locations, construction method + extent count only)
//!
//! Normalization rules:
//! - ipco properties sorted by (type, index)
//! - ipma associations sorted by (property_index, essential)
//! - iinf entries sorted by (type, id)
//! - iref entries sorted by (type, from)
//! - iloc entries sorted by id

use std::fs;
use std::path::Path;

use xdremux_core::isobmff::{
    parse_boxes, parse_ipma, parse_iref, parse_iprp_properties, parse_iinf, parse_iloc,
    parse_pitm, parse_source_meta, BoxHeader, PropertyInfo,
};

use crate::json;

const SCHEMA_VERSION: &str = "xdremux-conformance-dump/1";
const CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Run the dump subcommand and write a canonical JSON document to `out`.
pub fn run<P: AsRef<Path>, Q: AsRef<Path>>(
    input: P,
    out: Q,
    implementation: &str,
) -> Result<(), String> {
    let data = fs::read(input.as_ref())
        .map_err(|e| format!("cannot read {}: {e}", input.as_ref().display()))?;
    let json = build_json(&data, input.as_ref(), implementation)?;
    fs::write(out.as_ref(), json)
        .map_err(|e| format!("cannot write {}: {e}", out.as_ref().display()))?;
    Ok(())
}

/// Build the canonical JSON string for an output HEIC file.
pub fn build_json(data: &[u8], input_path: &Path, implementation: &str) -> Result<String, String> {
    let mut s = String::with_capacity(8192);

    s.push('{');
    kv_str(&mut s, "schema", SCHEMA_VERSION, false);
    s.push(',');
    kv_str(&mut s, "implementation", implementation, false);
    s.push(',');
    kv_str(&mut s, "version", CRATE_VERSION, false);
    s.push(',');
    kv_str(&mut s, "source", &input_path.display().to_string(), false);
    s.push(',');

    // ftyp
    write_ftyp(&mut s, data)?;
    s.push(',');

    // meta
    write_meta(&mut s, data)?;

    s.push('}');
    Ok(s)
}

fn write_ftyp(s: &mut String, data: &[u8]) -> Result<(), String> {
    let top = parse_boxes(data, 0, data.len());
    let ftyp = top
        .iter()
        .find(|b| &b.btype == b"ftyp")
        .ok_or("ftyp box not found")?;

    let payload = &data[ftyp.data_start..ftyp.data_end];
    if payload.len() < 8 {
        return Err("ftyp payload too short".to_string());
    }

    let major = std::str::from_utf8(&payload[0..4]).unwrap_or("????").to_string();
    let _minor = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
    let brands: Vec<String> = payload[8..]
        .chunks(4)
        .filter_map(|c| std::str::from_utf8(c).ok().map(|s| s.to_string()))
        .collect();

    s.push_str("\"ftyp\":{");
    kv_str(s, "major_brand", &major, false);
    s.push(',');
    s.push_str("\"compatible_brands\":[");
    for (i, brand) in brands.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('"');
        json::write_escaped(s, brand);
        s.push('"');
    }
    s.push(']');
    s.push('}');
    Ok(())
}

fn write_meta(s: &mut String, data: &[u8]) -> Result<(), String> {
    let meta = parse_source_meta(data)?;

    s.push_str("\"meta\":{");

    // pitm
    kv_u32(s, "pitm", meta.primary_id, false);
    s.push(',');

    // iinf (sorted by type, id)
    let mut items = meta.items.clone();
    items.sort_by(|a, b| a.itype.cmp(&b.itype).then(a.item_id.cmp(&b.item_id)));
    s.push_str("\"iinf\":[");
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('{');
        kv_u32(s, "id", item.item_id, false);
        s.push(',');
        kv_str(s, "type", &item.itype, false);
        s.push(',');
        kv_bool(s, "hidden", (item.flags & 1) != 0, false);
        s.push('}');
    }
    s.push(']');
    s.push(',');

    // iref (sorted by type, from)
    let mut refs = meta.refs.clone();
    refs.sort_by(|a, b| a.rtype.cmp(&b.rtype).then(a.from.cmp(&b.from)));
    s.push_str("\"iref\":[");
    for (i, r) in refs.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('{');
        kv_str(s, "type", &r.rtype, false);
        s.push(',');
        kv_u32(s, "from", r.from, false);
        s.push(',');
        s.push_str("\"to\":[");
        for (j, &to_id) in r.to.iter().enumerate() {
            if j > 0 {
                s.push(',');
            }
            s.push_str(&to_id.to_string());
        }
        s.push(']');
        s.push('}');
    }
    s.push(']');
    s.push(',');

    // ipco (sorted by type, index)
    let mut props = meta.props.clone();
    props.sort_by(|a, b| a.ptype.cmp(&b.ptype).then(a.index.cmp(&b.index)));
    s.push_str("\"ipco\":[");
    for (i, prop) in props.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        write_property(s, data, prop)?;
    }
    s.push(']');
    s.push(',');

    // ipma (sorted by item_id)
    let mut ipma = meta.ipma_entries.clone();
    ipma.sort_by_key(|e| e.item_id);
    s.push_str("\"ipma\":[");
    for (i, entry) in ipma.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('{');
        kv_u32(s, "id", entry.item_id, false);
        s.push(',');
        let mut assocs = entry.associations.clone();
        assocs.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        s.push_str("\"props\":[");
        for (j, &(idx, ess)) in assocs.iter().enumerate() {
            if j > 0 {
                s.push(',');
            }
            s.push('{');
            kv_u32(s, "index", idx, false);
            s.push(',');
            kv_bool(s, "essential", ess, false);
            s.push('}');
        }
        s.push(']');
        s.push('}');
    }
    s.push(']');
    s.push(',');

    // iloc (sorted by id, only construction_method + extent_count)
    let mut iloc = meta.iloc_entries.clone();
    iloc.sort_by_key(|e| e.item_id);
    s.push_str("\"iloc\":[");
    for (i, entry) in iloc.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('{');
        kv_u32(s, "id", entry.item_id, false);
        s.push(',');
        kv_u16(s, "cm", entry.construction_method, false);
        s.push(',');
        kv_usize(s, "extents", entry.extents.len(), false);
        s.push('}');
    }
    s.push(']');

    s.push('}');
    Ok(())
}

fn write_property(s: &mut String, _data: &[u8], prop: &PropertyInfo) -> Result<(), String> {
    s.push('{');
    kv_u32(s, "index", prop.index, false);
    s.push(',');
    kv_str(s, "type", &prop.ptype, false);

    // Extract key fields based on property type
    match prop.ptype.as_str() {
        "ispe" => {
            if prop.raw.len() >= 16 {
                let w = u32::from_be_bytes([prop.raw[12], prop.raw[13], prop.raw[14], prop.raw[15]]);
                let h = u32::from_be_bytes([prop.raw[16], prop.raw[17], prop.raw[18], prop.raw[19]]);
                s.push(',');
                kv_u32(s, "width", w, false);
                s.push(',');
                kv_u32(s, "height", h, false);
            }
        }
        "colr" => {
            if prop.raw.len() >= 12 {
                let kind = std::str::from_utf8(&prop.raw[8..12]).unwrap_or("????").to_string();
                s.push(',');
                kv_str(s, "kind", &kind, false);
                if kind == "nclx" && prop.raw.len() >= 19 {
                    s.push(',');
                    kv_u8(s, "primaries", prop.raw[12], false);
                    s.push(',');
                    kv_u8(s, "transfer", prop.raw[13], false);
                    s.push(',');
                    kv_u8(s, "matrix", prop.raw[14], false);
                    s.push(',');
                    kv_bool(s, "full_range", (prop.raw[15] & 0x80) != 0, false);
                }
            }
        }
        "pixi" => {
            if prop.raw.len() >= 12 {
                let num_channels = prop.raw[12];
                s.push(',');
                kv_u8(s, "num_channels", num_channels, false);
                s.push(',');
                s.push_str("\"bits\":[");
                for i in 0..num_channels as usize {
                    if i > 0 {
                        s.push(',');
                    }
                    s.push_str(&prop.raw[13 + i].to_string());
                }
                s.push(']');
            }
        }
        "hvcC" => {
            // Extract chroma_format_idc, bit_depth_luma_minus8, bit_depth_chroma_minus8
            // from the HEVC decoder configuration record.
            // Layout: configurationVersion(1), general_profile_space(2 bits) + tier_flag(1) + profile_idc(5),
            //         profile_compatibility_flags(32), ...
            //         min_spatial_segmentation_idc(12), parallelismType(2), chromaFormatIdc(2),
            //         bitDepthLumaMinus8(3), bitDepthChromaMinus8(3), ...
            if prop.raw.len() >= 23 {
                let chroma = prop.raw[18] & 0x03;
                let luma_depth = (prop.raw[19] & 0x07) + 8;
                let chroma_depth = (prop.raw[20] & 0x07) + 8;
                s.push(',');
                kv_u8(s, "chroma_format_idc", chroma, false);
                s.push(',');
                kv_u8(s, "bit_depth_luma", luma_depth, false);
                s.push(',');
                kv_u8(s, "bit_depth_chroma", chroma_depth, false);
            }
        }
        "auxC" => {
            // Extract the URN string (null-terminated)
            if prop.raw.len() > 12 {
                let urn_bytes = &prop.raw[12..];
                let urn_end = urn_bytes.iter().position(|&b| b == 0).unwrap_or(urn_bytes.len());
                let urn = std::str::from_utf8(&urn_bytes[..urn_end]).unwrap_or("").to_string();
                s.push(',');
                kv_str(s, "urn", &urn, false);
            }
        }
        _ => {
            // Other property types: just include size
            s.push(',');
            kv_usize(s, "size", prop.raw.len(), false);
        }
    }

    s.push('}');
    Ok(())
}

// ---------------------------------------------------------------------------
// JSON helpers
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

fn kv_u32(s: &mut String, k: &str, v: u32, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(&v.to_string());
}

fn kv_u16(s: &mut String, k: &str, v: u16, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(&v.to_string());
}

fn kv_u8(s: &mut String, k: &str, v: u8, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(&v.to_string());
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

fn kv_bool(s: &mut String, k: &str, v: bool, leading_comma: bool) {
    if leading_comma {
        s.push(',');
    }
    s.push('"');
    s.push_str(k);
    s.push_str("\":");
    s.push_str(if v { "true" } else { "false" });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dump_minimal_heic() {
        // Construct a minimal valid HEIC with ftyp + meta boxes
        let mut data = Vec::new();
        // ftyp: major="heic", minor=0, brands=["heic","mif1"]
        data.extend_from_slice(&[0, 0, 0, 20]); // size=20
        data.extend_from_slice(b"ftyp");
        data.extend_from_slice(b"heic");
        data.extend_from_slice(&[0, 0, 0, 0]); // minor
        data.extend_from_slice(b"heic");
        data.extend_from_slice(b"mif1");

        // meta box with minimal children (this will fail parse_source_meta,
        // but we're just testing the ftyp extraction here)
        let json = build_json(&data, Path::new("test.heic"), "test").unwrap();
        assert!(json.contains("\"major_brand\":\"heic\""));
        assert!(json.contains("\"compatible_brands\":[\"heic\",\"mif1\"]"));
    }
}
