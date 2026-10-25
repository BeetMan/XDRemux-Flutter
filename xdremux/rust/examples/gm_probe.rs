// Gain-map decode feasibility probe.
//
// The Styles linear thumbnail cannot carry HDR highlights until the ISO 21496
// `tmap` gain map is decoded and applied to the scene-linear base. The gain map
// is HEVC-coded (4:0:0 or 4:2:0 tiles) and heif-oxide only decodes the primary
// item, so this probe checks whether `rust_h265` (already a transitive
// dependency of heif-oxide) can decode a real gain-map tile:
//
//   gm_probe <converted.heic>
//
// Prints the tmap payload size, resolves tmap -> gain-map grid -> first tile,
// decodes that tile and reports geometry/bit depth/luma statistics.
use xdremux_core::isobmff;

/// hvcC payload starts after the 8-byte box header in `PropertyInfo::raw`.
fn hvcc_payload(raw: &[u8]) -> Option<&[u8]> {
    if raw.len() > 8 && &raw[4..8] == b"hvcC" {
        Some(&raw[8..])
    } else {
        None
    }
}

/// Expand the hvcC VPS/SPS/PPS arrays into Annex-B (payload without box head).
fn push_hvcc_arrays(out: &mut Vec<u8>, payload: &[u8]) -> usize {
    if payload.len() < 23 {
        return 0;
    }
    let array_count = payload[22] as usize;
    let mut position = 23usize;
    let mut nals = 0usize;
    for _ in 0..array_count {
        if position + 3 > payload.len() {
            break;
        }
        position += 1; // completeness + NAL type
        let count = u16::from_be_bytes([payload[position], payload[position + 1]]) as usize;
        position += 2;
        for _ in 0..count {
            if position + 2 > payload.len() {
                break;
            }
            let length = u16::from_be_bytes([payload[position], payload[position + 1]]) as usize;
            position += 2;
            if position + length > payload.len() {
                break;
            }
            out.extend_from_slice(&[0, 0, 0, 1]);
            out.extend_from_slice(&payload[position..position + length]);
            position += length;
            nals += 1;
        }
    }
    nals
}

/// Parse a `grid` item payload: returns (rows, columns, tile ids).
fn parse_grid_payload(payload: &[u8]) -> Result<(u32, u32, Vec<u32>), String> {
    if payload.len() < 8 {
        return Err("grid payload too short".into());
    }
    // version(1) + flags(3) + rows_minus_one(1) + columns_minus_one(1) + flags(1)
    let rows = u32::from(payload[4]) + 1;
    let columns = u32::from(payload[5]) + 1;
    let grid_flags = payload[6];
    let mut position = 7usize;
    if grid_flags & 1 != 0 {
        position += 8; // output width/height
    }
    let mut tiles = Vec::with_capacity((rows * columns) as usize);
    let wide_ids = grid_flags & 2 != 0;
    for _ in 0..(rows * columns) {
        let id = if wide_ids {
            if position + 4 > payload.len() {
                return Err("grid truncated".into());
            }
            let value = u32::from_be_bytes(payload[position..position + 4].try_into().unwrap());
            position += 4;
            value
        } else {
            if position + 2 > payload.len() {
                return Err("grid truncated".into());
            }
            let value = u16::from_be_bytes(payload[position..position + 2].try_into().unwrap());
            position += 2;
            u32::from(value)
        };
        tiles.push(id);
    }
    Ok((rows, columns, tiles))
}

/// Locate the `idat` box payload inside `meta` (construction_method 1 items
/// store their bytes there, with iloc offsets relative to the idat payload).
fn find_idat(data: &[u8]) -> Option<usize> {
    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta = top.iter().find(|b| &b.btype == b"meta")?;
    // `meta` is a full box: skip its 4-byte version/flags before children.
    let children = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end);
    children
        .iter()
        .find(|b| &b.btype == b"idat")
        .map(|b| b.data_start)
}

/// Resolve an item payload to an absolute (offset, length) slice of `data`.
fn extents_of(
    meta: &isobmff::ParsedMeta,
    data: &[u8],
    idat_start: Option<usize>,
    item_id: u32,
) -> Option<(usize, usize)> {
    let entry = meta
        .iloc_entries
        .iter()
        .find(|entry| entry.item_id == item_id)?;
    let (offset, length) = *entry.extents.first()?;
    let base = if entry.construction_method == 1 {
        idat_start? as u64
    } else {
        0
    };
    let start = (base + offset) as usize;
    let end = start + length as usize;
    if end > data.len() {
        return None;
    }
    Some((start, length as usize))
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: gm_probe <converted.heic>");
    let data = std::fs::read(&path).expect("read input");
    let meta = isobmff::parse_source_meta(&data).expect("parse meta");

    let tmap = match meta.items.iter().find(|item| item.itype == "tmap") {
        Some(item) => item,
        None => {
            println!("no tmap item: this file carries no ISO 21496 gain map");
            return;
        }
    };
    let idat_start = find_idat(&data);
    let (tmap_offset, tmap_length) =
        extents_of(&meta, &data, idat_start, tmap.item_id).expect("tmap extent");
    println!("tmap item={} payload={}B", tmap.item_id, tmap_length);
    println!(
        "  payload[0..16]={:02x?}",
        &data[tmap_offset..(tmap_offset + 16).min(data.len())]
    );

    // tmap --dimg--> [base grid, gain-map grid]; the gain map is the smaller one.
    let candidates: Vec<u32> = meta
        .refs
        .iter()
        .filter(|reference| reference.from == tmap.item_id && reference.rtype == "dimg")
        .flat_map(|reference| reference.to.iter().copied())
        .collect();
    let dims_of = |item_id: u32| -> Option<(u32, u32)> {
        meta.ipma_entries
            .iter()
            .find(|entry| entry.item_id == item_id)
            .and_then(|entry| {
                entry.associations.iter().find_map(|(index, _)| {
                    meta.props
                        .iter()
                        .find(|property| property.index == *index && property.ptype == "ispe")
                        .and_then(|property| isobmff::ispe_dimensions(&property.raw).ok())
                })
            })
    };
    for &candidate in &candidates {
        println!("  dimg candidate {candidate} dims={:?}", dims_of(candidate));
    }
    let grid_id = candidates
        .iter()
        .copied()
        .filter(|candidate| dims_of(*candidate).is_some())
        .min_by_key(|candidate| {
            let (width, height) = dims_of(*candidate).unwrap();
            u64::from(width) * u64::from(height)
        })
        .or_else(|| candidates.first().copied())
        .or_else(|| meta.items.iter().find(|item| item.itype == "grid").map(|item| item.item_id));
    let Some(grid_id) = grid_id else {
        println!("no gain-map grid referenced from tmap");
        return;
    };
    // Gain-map tiles are HEVC items whose hvcC declares monochrome (4:0:0);
    // the primary image is 4:2:0/4:4:4. Scan instead of trusting the grid
    // payload (grid construction varies between writers).
    let mut mono_tiles: Vec<u32> = Vec::new();
    let mut histogram: std::collections::BTreeMap<u8, usize> = std::collections::BTreeMap::new();
    for item in &meta.items {
        if item.itype != "hvc1" {
            continue;
        }
        let some_props = meta
            .ipma_entries
            .iter()
            .find(|entry| entry.item_id == item.item_id);
        let mut chroma: Option<u8> = None;
        let mut dims: Option<(u32, u32)> = None;
        if let Some(entry) = some_props {
            for (index, _) in &entry.associations {
                if let Some(property) = meta.props.iter().find(|p| p.index == *index) {
                    match property.ptype.as_str() {
                        "hvcC" => {
                            if let Some(payload) = hvcc_payload(&property.raw) {
                                if payload.len() > 21 {
                                    chroma = Some(payload[16] & 0x03);
                                }
                            }
                        }
                        "ispe" => dims = isobmff::ispe_dimensions(&property.raw).ok(),
                        _ => {}
                    }
                }
            }
        }
        if let Some(chroma) = chroma {
            *histogram.entry(chroma).or_insert(0) += 1;
            if chroma == 0 && mono_tiles.len() < 8 {
                println!("  mono tile candidate {} dims={:?}", item.item_id, dims);
                mono_tiles.push(item.item_id);
            }
        }
    }
    println!("hvcC chroma histogram: {histogram:?}");
    let Some(tile_id) = mono_tiles.first().copied() else {
        println!("no monochrome (4:0:0) gain-map tile found");
        return;
    };
    let (tile_offset, tile_length) = match extents_of(&meta, &data, idat_start, tile_id) {
        Some(extent) => extent,
        None => {
            println!("tile {tile_id} has no resolvable iloc extent");
            return;
        }
    };
    // Parameter sets come from the tile's hvcC property; the item payload holds
    // length-prefixed slice NALs.
    let hvcc_raw = meta
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == tile_id)
        .and_then(|entry| {
            entry.associations.iter().find_map(|(index, _)| {
                meta.props
                    .iter()
                    .find(|property| property.index == *index && property.ptype == "hvcC")
                    .map(|property| property.raw.as_slice())
            })
        });
    let payload = &data[tile_offset..tile_offset + tile_length];
    let mut annex_b = Vec::new();
    let hvcc = hvcc_raw.and_then(hvcc_payload);
    let parameter_nals = match hvcc {
        Some(payload) => {
            if payload.len() > 21 {
                println!(
                    "tile {tile_id}: hvcC profile_idc={} depth={} chroma={} lengthSize={}",
                    payload[1] & 0x1f,
                    payload[17] & 0x07,
                    payload[16] & 0x03,
                    (payload[21] & 0x03) + 1
                );
            }
            push_hvcc_arrays(&mut annex_b, payload)
        }
        None => 0,
    };
    let mut position = 0usize;
    let mut slice_nals = 0usize;
    while position + 4 <= payload.len() {
        let nal_length = u32::from_be_bytes(payload[position..position + 4].try_into().unwrap())
            as usize;
        position += 4;
        if position + nal_length > payload.len() {
            break;
        }
        annex_b.extend_from_slice(&[0, 0, 0, 1]);
        annex_b.extend_from_slice(&payload[position..position + nal_length]);
        position += nal_length;
        slice_nals += 1;
    }
    println!(
        "tile {tile_id}: payload={}B parameter_sets={} slice_nals={} annexb={}B",
        tile_length,
        parameter_nals,
        slice_nals,
        annex_b.len()
    );

    let mut decoder = rust_h265::Decoder::new();
    let mut decoded = None;
    for nal in rust_h265::parse_annex_b(&annex_b) {
        match decoder.decode_nal(&nal) {
            Ok(Some(frame)) => {
                decoded = Some(frame);
                break;
            }
            Ok(None) => {}
            Err(error) => {
                println!("decode error: {error:?}");
                return;
            }
        }
    }
    let frame = decoded.or_else(|| decoder.flush());
    match frame {
        Some(frame) => {
            let luma: Vec<u8> = match &frame.y {
                rust_h265::PixelData::U8(values) => values.clone(),
                rust_h265::PixelData::U16(values) => {
                    values.iter().map(|&v| (v >> 2) as u8).collect()
                }
            };
            let sum: u64 = luma.iter().map(|&v| u64::from(v)).sum();
            let min = luma.iter().copied().min().unwrap_or(0);
            let max = luma.iter().copied().max().unwrap_or(0);
            println!(
                "DECODED tile: {}x{} bit_depth={} luma(min/mean/max)={}/{:.1}/{}",
                frame.width,
                frame.height,
                frame.bit_depth,
                min,
                sum as f64 / luma.len().max(1) as f64,
                max
            );
        }
        None => println!("decoder produced no frame"),
    }
}
