//! Hardened ISO-BMFF / HEIF container validation.
//!
//! Ported from upstream v1.4 `crates/xdremux-heif/src/validation.rs`
//! (`validate_gain_map_structure` + `validate_meta_integrity`), adapted to
//! this crate's `isobmff` structures. Every extent/index lookup is
//! bounds-checked; the validator refuses files whose meta graph disagrees
//! with itself rather than trusting item IDs blindly.
//!
//! This validates the portable tiled Gain Map HEIC structure that XDRemux
//! emits (primary + tmap + grid gain map + hvc1 tiles). Apple consumer
//! recognition remains a device-side gate.

use std::collections::{HashMap, HashSet};

use crate::isobmff::{
    parse_boxes, parse_source_meta, BoxHeader, IlocEntry, ParsedMeta,
};

/// Validated gain-map graph summary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GainMapStructure {
    pub primary_item_id: u32,
    pub tmap_item_id: u32,
    pub gain_map_item_id: u32,
    pub tile_item_ids: Vec<u32>,
    pub width: u32,
    pub height: u32,
    pub rows: u32,
    pub columns: u32,
    /// pixi channel count (1 = luminance-only, 3 = RGB).
    pub channel_count: u8,
    /// hvcC general_profile_idc of the (uniform) tiles.
    pub general_profile_idc: u8,
    pub chroma_format_idc: u8,
    pub luma_bit_depth: u8,
    pub chroma_bit_depth: u8,
}

fn invalid(message: impl Into<String>) -> String {
    format!("iso-bmff validation: {}", message.into())
}

fn one_top_level<'a>(
    boxes: &'a [BoxHeader],
    kind: &[u8; 4],
    context: &str,
) -> Result<&'a BoxHeader, String> {
    let mut matches = boxes.iter().filter(|h| &h.btype == kind);
    let first = matches
        .next()
        .ok_or_else(|| invalid(format!("{context} is missing")))?;
    if matches.next().is_some() {
        return Err(invalid(format!("{context} appears more than once")));
    }
    Ok(first)
}

/// Parse a property box's payload after re-checking its header.
fn property_box_bytes(raw: &[u8]) -> Result<&[u8], String> {
    let headers = parse_boxes(raw, 0, raw.len());
    if headers.len() != 1 {
        return Err(invalid("property does not contain exactly one box"));
    }
    Ok(&raw[headers[0].data_start..headers[0].data_end])
}

fn ispe_dims(property_raw: &[u8]) -> Result<(u32, u32), String> {
    let box_bytes = property_box_bytes(property_raw)?;
    let _ = box_bytes;
    isobmff_ispe(property_raw)
}

// Re-export locally to keep call sites terse.
fn isobmff_ispe(property_raw: &[u8]) -> Result<(u32, u32), String> {
    crate::isobmff::ispe_dimensions(property_raw)
}

fn parse_pixi_property(property_raw: &[u8]) -> Result<(u8, Vec<u8>), String> {
    let payload = property_box_bytes(property_raw)?;
    if payload.len() < 5 || payload[..4] != [0, 0, 0, 0] {
        return Err(invalid("pixi must use version 0 with zero flags"));
    }
    let channel_count = payload[4];
    if channel_count == 0 {
        return Err(invalid("pixi declares zero channels"));
    }
    let expected = usize::from(channel_count)
        .checked_add(5)
        .ok_or_else(|| invalid("pixi channel count overflows"))?;
    if payload.len() != expected {
        return Err(invalid(format!(
            "pixi declares {channel_count} channels but has {} payload bytes",
            payload.len()
        )));
    }
    Ok((channel_count, payload[5..].to_vec()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HvcCProfile {
    general_profile_idc: u8,
    chroma_format_idc: u8,
    luma_bit_depth: u8,
    chroma_bit_depth: u8,
}

/// Parse the fixed-size prefix of an hvcC HEVCDecoderConfigurationRecord.
/// Offsets: 0 configVersion, 1 profile byte, 2..6 compat, 6..12 constraint,
/// 12 level, 13..15 segmentation, 15 parallelism, 16 chroma, 17/18 depths.
fn parse_hvcc_profile(payload: &[u8]) -> Result<HvcCProfile, String> {
    if payload.len() < 23 {
        return Err(invalid("hvcC record is shorter than its fixed prefix"));
    }
    if payload[0] != 1 {
        return Err(invalid(format!(
            "hvcC configurationVersion {} is unsupported",
            payload[0]
        )));
    }
    Ok(HvcCProfile {
        general_profile_idc: payload[1] & 0x1f,
        chroma_format_idc: payload[16] & 0x03,
        luma_bit_depth: (payload[17] & 0x07) + 8,
        chroma_bit_depth: (payload[18] & 0x07) + 8,
    })
}

/// Locate the meta box's idat payload range, if present. meta is a full
/// box: skip its 4-byte version/flags before scanning children.
fn find_idat(data: &[u8], meta_box: &BoxHeader) -> Result<Option<(usize, usize)>, String> {
    let children = parse_boxes(data, meta_box.data_start + 4, meta_box.data_end);
    Ok(children
        .iter()
        .find(|h| &h.btype == b"idat")
        .map(|h| (h.data_start, h.data_end)))
}

/// Bounds-checked item payload read (construction methods 0 = file offset,
/// 1 = idat). Mirrors upstream `item_extent_range` overflow/bounds checks.
fn item_payload(
    data: &[u8],
    idat: Option<(usize, usize)>,
    entry: &IlocEntry,
) -> Result<Vec<u8>, String> {
    if entry.data_reference_index != 0 {
        return Err(invalid(format!(
            "item {} uses unsupported data_reference_index {}",
            entry.item_id, entry.data_reference_index
        )));
    }
    let mut payload = Vec::new();
    for &(offset, length) in &entry.extents {
        let length = usize::try_from(length)
            .map_err(|_| invalid(format!("item {} extent length exceeds usize", entry.item_id)))?;
        let start = match entry.construction_method {
            0 => usize::try_from(offset)
                .map_err(|_| invalid(format!("item {} offset exceeds usize", entry.item_id)))?,
            1 => {
                let (idat_start, idat_end) =
                    idat.ok_or_else(|| invalid(format!("item {} uses idat without an idat box", entry.item_id)))?;
                let relative = usize::try_from(offset).map_err(|_| {
                    invalid(format!("item {} idat offset exceeds usize", entry.item_id))
                })?;
                if idat_start + relative > idat_end {
                    return Err(invalid(format!(
                        "item {} idat extent starts outside idat",
                        entry.item_id
                    )));
                }
                idat_start + relative
            }
            method => {
                return Err(invalid(format!(
                    "item {} uses unsupported construction_method {method}",
                    entry.item_id
                )))
            }
        };
        let end = start
            .checked_add(length)
            .ok_or_else(|| invalid(format!("item {} extent end overflows", entry.item_id)))?;
        let limit = if entry.construction_method == 1 {
            idat.map(|(_, e)| e).unwrap_or(0)
        } else {
            data.len()
        };
        if end > limit {
            return Err(invalid(format!(
                "item {} extent {start}..{end} exceeds its backing storage ending at {limit}",
                entry.item_id
            )));
        }
        payload.extend_from_slice(&data[start..end]);
    }
    Ok(payload)
}

struct MetaIndex<'a> {
    items: HashMap<u32, &'a crate::isobmff::ItemInfo>,
    locations: HashMap<u32, &'a IlocEntry>,
    ipma_by_item: HashMap<u32, &'a crate::isobmff::IpmaEntry>,
    properties: HashMap<u32, &'a crate::isobmff::PropertyInfo>,
    idat: Option<(usize, usize)>,
}

fn validate_meta_integrity<'a>(
    data: &[u8],
    meta: &'a ParsedMeta,
    meta_box: &BoxHeader,
) -> Result<MetaIndex<'a>, String> {
    let mut items = HashMap::new();
    for item in &meta.items {
        if items.insert(item.item_id, item).is_some() {
            return Err(invalid(format!("duplicate iinf item ID {}", item.item_id)));
        }
    }
    if !items.contains_key(&meta.primary_id) {
        return Err(invalid(format!(
            "pitm references unknown item {}",
            meta.primary_id
        )));
    }

    let idat = find_idat(data, meta_box)?;
    let mut locations = HashMap::new();
    for entry in &meta.iloc_entries {
        if !items.contains_key(&entry.item_id) {
            return Err(invalid(format!(
                "iloc references unknown item {}",
                entry.item_id
            )));
        }
        if locations.insert(entry.item_id, entry).is_some() {
            return Err(invalid(format!("duplicate iloc item ID {}", entry.item_id)));
        }
        // Bounds-check every extent eagerly.
        let _ = item_payload(data, idat, entry)?;
    }

    let mut properties = HashMap::new();
    for property in &meta.props {
        if properties.insert(property.index, property).is_some() {
            return Err(invalid("duplicate ipco property index"));
        }
    }

    let mut ipma_by_item = HashMap::new();
    for entry in &meta.ipma_entries {
        if !items.contains_key(&entry.item_id) {
            return Err(invalid(format!(
                "ipma references unknown item {}",
                entry.item_id
            )));
        }
        if ipma_by_item.insert(entry.item_id, entry).is_some() {
            return Err(invalid(format!("duplicate ipma item ID {}", entry.item_id)));
        }
        let mut seen = HashSet::new();
        for &(index, _) in &entry.associations {
            if index == 0 {
                return Err(invalid(format!(
                    "item {} has an ipma association to property index 0",
                    entry.item_id
                )));
            }
            if !seen.insert(index) {
                return Err(invalid(format!(
                    "item {} repeats ipma property index {index}",
                    entry.item_id
                )));
            }
            if !properties.contains_key(&index) {
                return Err(invalid(format!(
                    "item {} references missing ipco property {index}",
                    entry.item_id
                )));
            }
        }
    }

    for reference in &meta.refs {
        if !items.contains_key(&reference.from) {
            return Err(invalid(format!(
                "{} reference originates from unknown item {}",
                reference.rtype, reference.from
            )));
        }
        for target in &reference.to {
            if !items.contains_key(target) {
                return Err(invalid(format!(
                    "{} reference from item {} targets unknown item {target}",
                    reference.rtype, reference.from
                )));
            }
        }
    }

    Ok(MetaIndex {
        items,
        locations,
        ipma_by_item,
        properties,
        idat,
    })
}

fn associated_property<'a>(
    item_id: u32,
    kind: &[u8; 4],
    index: &MetaIndex<'a>,
) -> Result<&'a crate::isobmff::PropertyInfo, String> {
    let entry = index
        .ipma_by_item
        .get(&item_id)
        .ok_or_else(|| invalid(format!("item {item_id} has no ipma entry")))?;
    let kind_str = String::from_utf8_lossy(kind).to_string();
    let mut matches = entry
        .associations
        .iter()
        .filter_map(|&(prop_index, _)| {
            let property = index.properties.get(&prop_index)?;
            (property.ptype == kind_str).then_some(property)
        });
    let Some(property) = matches.next() else {
        return Err(invalid(format!(
            "item {item_id} is missing {kind_str}"
        )));
    };
    if matches.next().is_some() {
        return Err(invalid(format!(
            "item {item_id} has more than one {kind_str}"
        )));
    }
    Ok(property)
}

fn parse_grid_payload(payload: &[u8]) -> Result<(u32, u32, u32, u32), String> {
    if payload.len() < 4 {
        return Err(invalid("grid payload is shorter than its header"));
    }
    if payload[0] != 0 {
        return Err(invalid(format!("grid version {} is unsupported", payload[0])));
    }
    if payload[1] & !1 != 0 {
        return Err(invalid(format!(
            "grid flags 0x{:02x} contain unsupported bits",
            payload[1]
        )));
    }
    let rows = u32::from(payload[2]) + 1;
    let columns = u32::from(payload[3]) + 1;
    let (width, height) = if payload[1] & 1 != 0 {
        if payload.len() != 12 {
            return Err(invalid("large grid payload must be exactly 12 bytes"));
        }
        (
            u32::from_be_bytes(payload[4..8].try_into().unwrap()),
            u32::from_be_bytes(payload[8..12].try_into().unwrap()),
        )
    } else {
        if payload.len() != 8 {
            return Err(invalid("small grid payload must be exactly 8 bytes"));
        }
        (
            u32::from(u16::from_be_bytes(payload[4..6].try_into().unwrap())),
            u32::from(u16::from_be_bytes(payload[6..8].try_into().unwrap())),
        )
    };
    if width == 0 || height == 0 {
        return Err(invalid("grid dimensions must be non-zero"));
    }
    Ok((rows, columns, width, height))
}

/// Validate the tiled Gain Map structure of an ISO HDR HEIC and return the
/// resolved graph summary.
pub fn validate_gain_map_structure(source: &[u8]) -> Result<GainMapStructure, String> {
    let top = parse_boxes(source, 0, source.len());
    let _ftyp = one_top_level(&top, b"ftyp", "ftyp")?;
    let meta_box = one_top_level(&top, b"meta", "meta")?;
    let _mdat = one_top_level(&top, b"mdat", "mdat")?;

    let meta = parse_source_meta(source)?;
    let index = validate_meta_integrity(source, &meta, meta_box)?;

    // Exactly one tmap item.
    let tmap_items: Vec<_> = meta
        .items
        .iter()
        .filter(|item| item.itype == "tmap")
        .collect();
    if tmap_items.len() != 1 {
        return Err(invalid(format!(
            "expected exactly one tmap item, found {}",
            tmap_items.len()
        )));
    }
    let tmap_item_id = tmap_items[0].item_id;

    // tmap must dimg-reference exactly [primary, gain-map].
    let tmap_refs: Vec<_> = meta
        .refs
        .iter()
        .filter(|r| r.rtype == "dimg" && r.from == tmap_item_id)
        .collect();
    if tmap_refs.len() != 1 {
        return Err(invalid(format!(
            "tmap item {tmap_item_id} must have exactly one dimg reference"
        )));
    }
    let targets = &tmap_refs[0].to;
    if targets.len() != 2 || targets[0] != meta.primary_id {
        return Err(invalid(format!(
            "tmap item {tmap_item_id} must dimg-reference [primary, gain-map] in that order"
        )));
    }
    let gain_map_item_id = targets[1];
    let gain_map_item = index
        .items
        .get(&gain_map_item_id)
        .ok_or_else(|| invalid(format!("gain-map item {gain_map_item_id} is missing")))?;
    if gain_map_item.itype != "grid" {
        return Err(invalid(format!(
            "gain-map item {gain_map_item_id} is {}, expected grid",
            gain_map_item.itype
        )));
    }

    // Gain map grid: exactly one non-empty dimg with unique tile IDs.
    let gain_refs: Vec<_> = meta
        .refs
        .iter()
        .filter(|r| r.rtype == "dimg" && r.from == gain_map_item_id)
        .collect();
    if gain_refs.len() != 1 || gain_refs[0].to.is_empty() {
        return Err(invalid(format!(
            "grid gain-map item {gain_map_item_id} must have exactly one non-empty dimg reference"
        )));
    }
    let tile_item_ids = gain_refs[0].to.clone();
    let unique: HashSet<u32> = tile_item_ids.iter().copied().collect();
    if unique.len() != tile_item_ids.len() {
        return Err(invalid("gain-map dimg reference repeats a tile item ID"));
    }

    let gain_location = index
        .locations
        .get(&gain_map_item_id)
        .ok_or_else(|| invalid(format!("gain-map item {gain_map_item_id} has no iloc entry")))?;
    let grid_payload = item_payload(source, index.idat, gain_location)?;
    let (rows, columns, width, height) = parse_grid_payload(&grid_payload)?;
    let expected_tiles = rows
        .checked_mul(columns)
        .ok_or_else(|| invalid("grid tile count overflows"))?;
    if usize::try_from(expected_tiles).ok() != Some(tile_item_ids.len()) {
        return Err(invalid(format!(
            "grid declares {rows}x{columns} tiles but dimg contains {} items",
            tile_item_ids.len()
        )));
    }

    // Gain map ispe must agree with the grid payload dimensions.
    let gain_ispe = associated_property(gain_map_item_id, b"ispe", &index)?;
    let (ispe_w, ispe_h) = ispe_dims(&gain_ispe.raw)?;
    if (ispe_w, ispe_h) != (width, height) {
        return Err(invalid(format!(
            "grid payload dimensions {width}x{height} disagree with ispe {ispe_w}x{ispe_h}"
        )));
    }
    let gain_pixi = associated_property(gain_map_item_id, b"pixi", &index)?;
    let (channel_count, channel_bits) = parse_pixi_property(&gain_pixi.raw)?;
    if !matches!(channel_count, 1 | 3) {
        return Err(invalid(format!(
            "gain-map pixi must declare one or three channels, got {channel_count}"
        )));
    }

    // tmap carries ispe + pixi as well.
    let _ = ispe_dims(&associated_property(tmap_item_id, b"ispe", &index)?.raw)?;
    let _ = parse_pixi_property(&associated_property(tmap_item_id, b"pixi", &index)?.raw)?;

    // Every tile: hvc1, located, ispe'd, and a consistent hvcC.
    let mut codec: Option<HvcCProfile> = None;
    for &tile_item_id in &tile_item_ids {
        let tile_item = index
            .items
            .get(&tile_item_id)
            .ok_or_else(|| invalid(format!("tile item {tile_item_id} is missing")))?;
        if tile_item.itype != "hvc1" {
            return Err(invalid(format!(
                "gain-map tile {tile_item_id} is {}, expected hvc1",
                tile_item.itype
            )));
        }
        if !index.locations.contains_key(&tile_item_id) {
            return Err(invalid(format!(
                "tile item {tile_item_id} has no iloc entry"
            )));
        }
        let _ = ispe_dims(&associated_property(tile_item_id, b"ispe", &index)?.raw)?;
        let hvcc = associated_property(tile_item_id, b"hvcC", &index)?;
        let parsed = parse_hvcc_profile(property_box_bytes(&hvcc.raw)?)?;
        if let Some(expected) = codec {
            if parsed != expected {
                return Err(invalid(format!(
                    "tile item {tile_item_id} uses a different hvcC channel layout"
                )));
            }
        } else {
            codec = Some(parsed);
        }
    }
    let codec = codec.ok_or_else(|| invalid("gain-map contains no HEVC tiles"))?;
    // Upstream requires pixi channels to equal the hvcC semantic channel
    // count (mono ⇒ 4:0:0 only). Deviation: OPPO donor graphs legitimately
    // carry a mono gain map in 4:2:0 (chroma planes ignored), and we must
    // keep validating files converted with donor-canvas preservation.
    // pixi=1 therefore accepts 4:0:0 and 4:2:0 carriers; pixi=3 requires a
    // chroma-carrying format.
    let chroma_ok = match channel_count {
        1 => codec.chroma_format_idc <= 3,
        3 => matches!(codec.chroma_format_idc, 1..=3),
        _ => false,
    };
    if !chroma_ok {
        return Err(invalid(format!(
            "gain-map pixi declares {channel_count} channels but hvcC chroma_format_idc {} cannot carry it",
            codec.chroma_format_idc
        )));
    }
    let expected_bits: Vec<u8> = if channel_count == 1 {
        vec![codec.luma_bit_depth]
    } else {
        vec![
            codec.luma_bit_depth,
            codec.chroma_bit_depth,
            codec.chroma_bit_depth,
        ]
    };
    if channel_bits != expected_bits {
        return Err(invalid(format!(
            "gain-map pixi bit depths {channel_bits:?} disagree with hvcC {}/{}",
            codec.luma_bit_depth, codec.chroma_bit_depth
        )));
    }

    Ok(GainMapStructure {
        primary_item_id: meta.primary_id,
        tmap_item_id,
        gain_map_item_id,
        tile_item_ids,
        width,
        height,
        rows,
        columns,
        channel_count,
        general_profile_idc: codec.general_profile_idc,
        chroma_format_idc: codec.chroma_format_idc,
        luma_bit_depth: codec.luma_bit_depth,
        chroma_bit_depth: codec.chroma_bit_depth,
    })
}
