//! ISOBMFF box types, parsers, constructors, and byte-level helpers.
//!
//! Ported from the Swift production reference (`XDRemux.swift`):
//! - Box iteration: `isobmffBoxes(in:start:end:)` → `parse_boxes()`
//! - Parsers: `parseISOBMFFILoc/IInf/PITM/IPMA/IRefs/IPCOPropertyInfos/ItemInfos`
//! - Constructors: `makeBox/makePitmBox/makeIinfBox/makeIlocV1Box/makeIrefFullBox/...`
//! - Static box constants: `isoAuxCBox/isoDinfBox/isoIrotBox/isoColrSRGBBox/...`

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A parsed ISOBMFF box header.
#[derive(Debug, Clone)]
pub struct BoxHeader {
    /// Four-character box type code (e.g. `b"ftyp"`).
    pub btype: [u8; 4],
    /// Offset of the first payload byte (right after the 8- or 16-byte header).
    pub data_start: usize,
    /// Offset of the first byte past the box (data_start + payload_len).
    pub data_end: usize,
    /// Offset of the box start in the parent buffer.
    pub box_start: usize,
    /// Total box size including header (size field value).
    pub size: usize,
}

/// An iloc entry (item location).
#[derive(Debug, Clone)]
pub struct IlocEntry {
    pub item_id: u32,
    pub construction_method: u16,
    pub data_reference_index: u16,
    pub extents: Vec<(u64, u64)>, // (offset, length)
}

/// An ipma entry (item–property association).
#[derive(Debug, Clone)]
pub struct IpmaEntry {
    pub item_id: u32,
    /// Each element is (property_index, essential).
    pub associations: Vec<(u32, bool)>,
}

/// Parsed item-info entry from iinf.
#[derive(Debug, Clone)]
pub struct ItemInfo {
    pub item_id: u32,
    pub itype: String,
    pub flags: u32,
    pub raw_infe: Vec<u8>,
}

/// A single iref reference rule.
#[derive(Debug, Clone)]
pub struct IrefEntry {
    pub rtype: String,
    pub from: u32,
    pub to: Vec<u32>,
}

/// A property from ipco.
#[derive(Debug, Clone)]
pub struct PropertyInfo {
    /// 1-based index in the ipco box.
    pub index: u32,
    pub ptype: String,
    pub raw: Vec<u8>,
}

/// Complete parsed metadata from a source HEIC.
#[derive(Debug, Clone)]
pub struct ParsedMeta {
    pub iloc_entries: Vec<IlocEntry>,
    pub ipma_entries: Vec<IpmaEntry>,
    pub ipma_flags: u32,
    pub items: Vec<ItemInfo>,
    pub refs: Vec<IrefEntry>,
    pub props: Vec<PropertyInfo>,
    pub primary_id: u32,
    pub pitm_version: u8,
    pub iinf_version: u8,
}

// ---------------------------------------------------------------------------
// Static box constants (exact bytes from Swift)
// ---------------------------------------------------------------------------

/// ISO 21496-1 auxiliary type marker: `urn:iso:std:iso:ts:21496:-1`
pub const AUX_C_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x28, 0x61, 0x75, 0x78, 0x43,
    0x00, 0x00, 0x00, 0x00, 0x75, 0x72, 0x6e, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x73, 0x74, 0x64, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x74, 0x73, 0x3a, 0x32,
    0x31, 0x34, 0x39, 0x36, 0x3a, 0x2d, 0x31, 0x00,
];

/// Data information box with dref + url.
pub const DINF_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6e, 0x66,
    0x00, 0x00, 0x00, 0x1c, 0x64, 0x72, 0x65, 0x66,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x0c, 0x75, 0x72, 0x6c, 0x20,
    0x00, 0x00, 0x00, 0x01,
];

/// Image rotation box (rotation = 0).
pub const IROT_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x09, 0x69, 0x72, 0x6f, 0x74, 0x00,
];

/// sRGB color box (nclx: primaries=2, transfer=2, matrix=2).
pub const COLR_SRGB_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x02, 0x00, 0x02,
    0x00, 0x02, 0x80,
];

/// BT.2020 PQ color box (nclx: primaries=9, transfer=16, matrix=9).
pub const COLR_BT2020_PQ_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x09, 0x00, 0x10,
    0x00, 0x09, 0x80,
];

/// Pixel information: 3 channels × 8 bits.
pub const PIXI_RGB8_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x08, 0x08, 0x08,
];

/// Pixel information: 3 channels × 10 bits.
pub const PIXI_RGB10_BOX: &[u8] = &[
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x0a, 0x0a, 0x0a,
];

// ---------------------------------------------------------------------------
// Byte helpers — reading
// ---------------------------------------------------------------------------

/// Read a big-endian u16 at `offset`. Caller must ensure `offset+2 <= data.len()`.
pub fn read_u16be(data: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([data[offset], data[offset + 1]])
}

/// Read a big-endian u32 at `offset`. Caller must ensure `offset+4 <= data.len()`.
pub fn read_u32be(data: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
}

/// Read a big-endian u64 at `offset`. Caller must ensure `offset+8 <= data.len()`.
pub fn read_u64be(data: &[u8], offset: usize) -> u64 {
    u64::from_be_bytes([
        data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
        data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
    ])
}

// ---------------------------------------------------------------------------
// Byte helpers — writing
// ---------------------------------------------------------------------------

/// Append a big-endian u16 to `out`.
pub fn write_u16be(value: u16, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

/// Append a big-endian u32 to `out`.
pub fn write_u32be(value: u32, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

/// Append a big-endian i32 to `out`.
pub fn write_i32be(value: i32, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_be_bytes());
}

// ---------------------------------------------------------------------------
// Box construction
// ---------------------------------------------------------------------------

/// Build an ISOBMFF box: `[size:4][type:4][payload]`.
pub fn make_box(btype: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let size = (payload.len() + 8) as u32;
    let mut out = Vec::with_capacity(size as usize);
    write_u32be(size, &mut out);
    out.extend_from_slice(btype);
    out.extend_from_slice(payload);
    out
}

/// Build the ftyp box with required brands appended.
pub fn make_ftyp_box(original_ftyp_payload: &[u8]) -> Vec<u8> {
    let required_brands: &[&[u8]] = &[b"tmap", b"MiHE", b"miaf", b"MiHB"];

    // Collect existing brands from the original payload
    let existing_bytes: Vec<Vec<u8>> = original_ftyp_payload[8..]
        .chunks_exact(4)
        .take_while(|c| c.len() == 4)
        .map(|c| c.to_vec())
        .collect();

    let mut payload = original_ftyp_payload.to_vec();
    for brand in required_brands {
        if !existing_bytes.iter().any(|e| e.as_slice() == *brand) {
            payload.extend_from_slice(brand);
        }
    }
    make_box(b"ftyp", &payload)
}

/// Build the pitm box.
pub fn make_pitm_box(version: u8, primary_id: u32) -> Vec<u8> {
    let mut payload = vec![version, 0, 0, 0];
    if version >= 1 {
        write_u32be(primary_id, &mut payload);
    } else {
        write_u16be(primary_id as u16, &mut payload);
    }
    make_box(b"pitm", &payload)
}

/// Build the iinf box from raw infe entries.
pub fn make_iinf_box(version: u8, infes: &[Vec<u8>]) -> Vec<u8> {
    let mut payload = vec![version, 0, 0, 0];
    if version >= 1 {
        write_u32be(infes.len() as u32, &mut payload);
    } else {
        write_u16be(infes.len() as u16, &mut payload);
    }
    for infe in infes {
        payload.extend_from_slice(infe);
    }
    make_box(b"iinf", &payload)
}

/// Build an infe box for item types like hvc1, grid, tmap, jpeg.
pub fn make_infe_box(item_id: u32, itype: &str, flags: u32) -> Vec<u8> {
    let mut payload = vec![
        2u8,
        ((flags >> 16) & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
        (flags & 0xff) as u8,
    ];
    write_u16be(item_id as u16, &mut payload);
    write_u16be(0, &mut payload); // item_protection_index
    payload.extend_from_slice(itype.as_bytes());
    payload.push(0); // null terminator
    make_box(b"infe", &payload)
}

/// Build an infe box for mime-type items (XMP).
pub fn make_mime_infe_box(item_id: u32, flags: u32) -> Vec<u8> {
    let mut payload = vec![
        2u8,
        ((flags >> 16) & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
        (flags & 0xff) as u8,
    ];
    write_u16be(item_id as u16, &mut payload);
    write_u16be(0, &mut payload); // item_protection_index
    payload.extend_from_slice(b"mime");
    payload.extend_from_slice(b"hdrgm-xmp\0");
    payload.extend_from_slice(b"application/rdf+xml\0");
    payload.push(0); // null terminator
    make_box(b"infe", &payload)
}

/// Build the iloc box (always version 1, 4-byte offsets, 4-byte lengths).
pub fn make_iloc_box(entries: &[IlocEntry]) -> Vec<u8> {
    // version=1, flags=0, offset_size=4, length_size=4, base_offset_size=0, index_size=0
    let mut payload = vec![1u8, 0, 0, 0, 0x44, 0x00];
    write_u16be(entries.len() as u16, &mut payload);
    for entry in entries {
        write_u16be(entry.item_id as u16, &mut payload);
        write_u16be(entry.construction_method, &mut payload);
        write_u16be(entry.data_reference_index, &mut payload);
        write_u16be(entry.extents.len() as u16, &mut payload);
        for &(offset, length) in &entry.extents {
            write_u32be(offset as u32, &mut payload);
            write_u32be(length as u32, &mut payload);
        }
    }
    make_box(b"iloc", &payload)
}

/// Build the ispe (image spatial extents) box.
pub fn make_ispe_box(width: u32, height: u32) -> Vec<u8> {
    let mut payload = vec![0u8, 0, 0, 0]; // version + flags
    write_u32be(width, &mut payload);
    write_u32be(height, &mut payload);
    make_box(b"ispe", &payload)
}

/// Build a single iref reference entry.
pub fn make_iref_entry(rtype: &str, from: u32, to: &[u32], id_size_4: bool) -> Vec<u8> {
    let mut payload = Vec::new();
    if id_size_4 {
        write_u32be(from, &mut payload);
    } else {
        write_u16be(from as u16, &mut payload);
    }
    write_u16be(to.len() as u16, &mut payload);
    for &item in to {
        if id_size_4 {
            write_u32be(item, &mut payload);
        } else {
            write_u16be(item as u16, &mut payload);
        }
    }
    let btype: [u8; 4] = {
        let b = rtype.as_bytes();
        [b[0], b[1], b[2], b[3]]
    };
    make_box(&btype, &payload)
}

/// Build the iref full box containing multiple reference entries.
pub fn make_iref_full_box(version: u8, refs: &[IrefEntry]) -> Vec<u8> {
    let id_size_4 = version >= 1;
    let mut payload = vec![version, 0, 0, 0];
    for r in refs {
        let entry = make_iref_entry(&r.rtype, r.from, &r.to, id_size_4);
        payload.extend_from_slice(&entry);
    }
    make_box(b"iref", &payload)
}

/// Build a single ipma entry.
pub fn make_ipma_entry(item_id: u32, assocs: &[(u32, bool)], flags: u32) -> Vec<u8> {
    let use_large = (flags & 1) != 0;
    let mut out = Vec::new();
    if use_large {
        write_u32be(item_id, &mut out);
    } else {
        write_u16be(item_id as u16, &mut out);
    }
    out.push(assocs.len() as u8);
    for &(index, essential) in assocs {
        if use_large {
            let val = if essential { 0x8000 | (index as u16) } else { index as u16 };
            write_u16be(val, &mut out);
        } else {
            let val = if essential { 0x80 | (index as u8) } else { index as u8 };
            out.push(val);
        }
    }
    out
}

/// Build the grpl/altr box (entity group for alternate renditions).
pub fn make_grpl_altr_box(group_id: u32, tmap_id: u32, primary_id: u32) -> Vec<u8> {
    let mut altr_payload = vec![0u8; 4]; // version + flags
    write_u32be(group_id, &mut altr_payload);
    write_u32be(2, &mut altr_payload); // entity count
    write_u32be(tmap_id, &mut altr_payload);
    write_u32be(primary_id, &mut altr_payload);
    let grpl_child = make_box(b"altr", &altr_payload);
    make_box(b"grpl", &grpl_child)
}

/// Build a clli (content light level information) box.
pub fn make_clli_box(max_content_light_level: u32, max_pic_average_light_level: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(4);
    write_u16be(max_content_light_level as u16, &mut payload);
    write_u16be(max_pic_average_light_level as u16, &mut payload);
    make_box(b"clli", &payload)
}

/// Build a grid box for HEVC tile grids (ISOBMFF ImageGrid).
/// `output_width` and `output_height` are the composed image dimensions.
/// `tile_width` and `tile_height` are per-tile dimensions.
/// `cols` and `rows` define the grid layout.
pub fn make_grid_box(
    _tile_width: u32,
    _tile_height: u32,
    rows: u32,
    cols: u32,
    output_width: u32,
    output_height: u32,
) -> Vec<u8> {
    // Compact ImageGrid payload (per Apple idat convention):
    // version(1) flags(1) rows_minus_one(1) columns_minus_one(1)
    // output_width(2) output_height(2) = 8 bytes total.
    let mut payload = Vec::with_capacity(8);
    payload.push(0); // version
    payload.push(0); // flags (1 byte in compact form)
    payload.push((rows - 1) as u8); // rows_minus_one
    payload.push((cols - 1) as u8); // columns_minus_one
    write_u16be(output_width as u16, &mut payload);
    write_u16be(output_height as u16, &mut payload);
    make_box(b"grid", &payload)
}

// ---------------------------------------------------------------------------
// Box parsing
// ---------------------------------------------------------------------------

/// Iterate over top-level ISOBMFF boxes in `data[start..end]`.
pub fn parse_boxes(data: &[u8], start: usize, end: usize) -> Vec<BoxHeader> {
    let mut result = Vec::new();
    let mut pos = start;
    while pos + 8 <= end {
        let mut size = read_u32be(data, pos) as usize;
        let btype = [data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]];
        let mut header = 8;

        if size == 1 {
            // Extended 64-bit size
            if pos + 16 > end {
                break;
            }
            size = read_u64be(data, pos + 8) as usize;
            header = 16;
        } else if size == 0 {
            // Size extends to end of parent
            size = end - pos;
        }

        if size < header || pos + size > end {
            break;
        }

        result.push(BoxHeader {
            btype,
            data_start: pos + header,
            data_end: pos + size,
            box_start: pos,
            size,
        });
        pos += size;
    }
    result
}

/// Find the first box of a given type in `data`.
pub fn find_box(data: &[u8], btype: &[u8; 4], start: usize, end: usize) -> Option<BoxHeader> {
    parse_boxes(data, start, end)
        .into_iter()
        .find(|b| &b.btype == btype)
}

/// Parse iloc box. Supports version 0, 1, 2.
pub fn parse_iloc(data: &[u8], box_hdr: &BoxHeader) -> Result<Vec<IlocEntry>, String> {
    let version = data[box_hdr.data_start];
    let mut pos = box_hdr.data_start + 4;

    let sizes0 = data[pos];
    pos += 1;
    let sizes1 = data[pos];
    pos += 1;
    let offset_size = ((sizes0 >> 4) & 0x0f) as usize;
    let length_size = (sizes0 & 0x0f) as usize;
    let base_offset_size = ((sizes1 >> 4) & 0x0f) as usize;
    let index_size = if version == 1 || version == 2 {
        (sizes1 & 0x0f) as usize
    } else {
        0
    };

    let count: usize = if version >= 2 {
        let c = read_u32be(data, pos) as usize;
        pos += 4;
        c
    } else {
        let c = read_u16be(data, pos) as usize;
        pos += 2;
        c
    };

    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        let item_id: u32 = if version >= 2 {
            let id = read_u32be(data, pos);
            pos += 4;
            id
        } else {
            let id = read_u16be(data, pos) as u32;
            pos += 2;
            id
        };

        let construction_method = if version == 1 || version == 2 {
            let cm = read_u16be(data, pos) & 0x0f;
            pos += 2;
            cm
        } else {
            0
        };

        let data_ref = read_u16be(data, pos);
        pos += 2;

        // base_offset
        let mut base_offset: u64 = 0;
        for _ in 0..base_offset_size {
            base_offset = (base_offset << 8) | data[pos] as u64;
            pos += 1;
        }

        let extent_count = read_u16be(data, pos) as usize;
        pos += 2;

        let mut extents = Vec::with_capacity(extent_count);
        for _ in 0..extent_count {
            if index_size > 0 {
                pos += index_size;
            }
            let mut offset: u64 = base_offset;
            for _ in 0..offset_size {
                offset = (offset << 8) | data[pos] as u64;
                pos += 1;
            }
            let mut length: u64 = 0;
            for _ in 0..length_size {
                length = (length << 8) | data[pos] as u64;
                pos += 1;
            }
            extents.push((offset, length));
        }

        entries.push(IlocEntry {
            item_id,
            construction_method,
            data_reference_index: data_ref,
            extents,
        });
    }
    Ok(entries)
}

/// Parse iinf box. Returns version and item infos.
pub fn parse_iinf(data: &[u8], box_hdr: &BoxHeader) -> Result<Vec<ItemInfo>, String> {
    let version = data[box_hdr.data_start];
    let mut pos = box_hdr.data_start + 4;

    let _count: usize = if version >= 1 {
        let c = read_u32be(data, pos) as usize;
        pos += 4;
        c
    } else {
        let c = read_u16be(data, pos) as usize;
        pos += 2;
        c
    };

    let mut items = Vec::new();
    for child in parse_boxes(data, pos, box_hdr.data_end) {
        if &child.btype != b"infe" {
            continue;
        }
        let infe_start = child.box_start;
        let infe_end = child.data_end;
        if infe_end > data.len() {
            continue;
        }

        let v = data[child.data_start];
        let mut p = child.data_start + 4;

        // Parse item_id (width depends on version and type)
        let item_id: u32 = if v >= 2 {
            if p + 8 <= data.len() {
                let type_at_u16 = std::str::from_utf8(&data[p + 4..p + 8]).unwrap_or("");
                if ["hvc1", "grid", "Exif", "mime", "tmap", "jpeg"].contains(&type_at_u16) {
                    p += 2;
                    read_u16be(data, p - 2) as u32
                } else {
                    p += 4;
                    read_u32be(data, p - 4)
                }
            } else {
                read_u16be(data, p) as u32
            }
        } else {
            read_u16be(data, p) as u32
        };

        // Skip item_protection_index (u16)
        p += 2;

        // Read item type (4-char code, null-terminated)
        let type_start = p;
        while p < infe_end && data[p] != 0 {
            p += 1;
        }
        let itype = std::str::from_utf8(&data[type_start..p]).unwrap_or("????").to_string();
        // p is at null byte; advance past it
        p += 1;
        let _ = p; // suppress unused-assignment warning

        // For mime type, skip content type + content encoding null-terminated strings
        // (we don't need them for passthrough)

        let flags = if v >= 2 {
            ((data[child.data_start + 1] as u32) << 16)
                | ((data[child.data_start + 2] as u32) << 8)
                | (data[child.data_start + 3] as u32)
        } else {
            0
        };

        let raw_infe = data[infe_start..infe_end].to_vec();

        items.push(ItemInfo {
            item_id,
            itype,
            flags,
            raw_infe,
        });
    }
    Ok(items)
}

/// Parse pitm box. Returns the primary item ID.
pub fn parse_pitm(data: &[u8], box_hdr: &BoxHeader) -> u32 {
    let version = data[box_hdr.data_start];
    if version >= 1 {
        read_u32be(data, box_hdr.data_start + 4)
    } else {
        read_u16be(data, box_hdr.data_start + 4) as u32
    }
}

/// Parse ipma box. Returns (flags, entries).
pub fn parse_ipma(data: &[u8], box_hdr: &BoxHeader) -> (u32, Vec<IpmaEntry>) {
    let version_and_flags = read_u32be(data, box_hdr.data_start);
    let flags = version_and_flags & 0x00ff_ffff;
    let use_large = (flags & 1) != 0;
    let count = read_u32be(data, box_hdr.data_start + 4) as usize;

    let mut pos = box_hdr.data_start + 8;
    let mut entries = Vec::with_capacity(count);

    for _ in 0..count {
        // Read item_id; advance pos past it
        let item_id = if use_large {
            pos += 4;
            read_u32be(data, pos - 4)
        } else {
            pos += 2;
            read_u16be(data, pos - 2) as u32
        };

        let assoc_count = data[pos] as usize;
        pos += 1;

        let mut associations = Vec::with_capacity(assoc_count);
        for _ in 0..assoc_count {
            if use_large {
                let raw = read_u16be(data, pos);
                pos += 2;
                let essential = (raw & 0x8000) != 0;
                let index = (raw & 0x7fff) as u32;
                associations.push((index, essential));
            } else {
                let raw = data[pos];
                pos += 1;
                let essential = (raw & 0x80) != 0;
                let index = (raw & 0x7f) as u32;
                associations.push((index, essential));
            }
        }

        entries.push(IpmaEntry {
            item_id,
            associations,
        });
    }

    (flags, entries)
}

/// Parse iprp box → extract property infos from ipco.
pub fn parse_iprp_properties(data: &[u8], iprp_box: &BoxHeader) -> Result<Vec<PropertyInfo>, String> {
    let children = parse_boxes(data, iprp_box.data_start, iprp_box.data_end);
    let ipco = children
        .iter()
        .find(|b| &b.btype == b"ipco")
        .ok_or("ipco not found in iprp")?;

    let props = parse_boxes(data, ipco.data_start, ipco.data_end);
    let mut result = Vec::with_capacity(props.len());

    for (i, prop_box) in props.iter().enumerate() {
        let ptype = std::str::from_utf8(&prop_box.btype).unwrap_or("????").to_string();
        let raw = data[prop_box.box_start..prop_box.data_end].to_vec();
        result.push(PropertyInfo {
            index: (i + 1) as u32, // 1-based
            ptype,
            raw,
        });
    }

    Ok(result)
}

/// Parse iref box. Returns (version, entries).
pub fn parse_iref(data: &[u8], box_hdr: &BoxHeader) -> (u8, Vec<IrefEntry>) {
    let version = data[box_hdr.data_start];
    let id_size_4 = version >= 1;

    let children = parse_boxes(data, box_hdr.data_start + 4, box_hdr.data_end);
    let mut refs = Vec::with_capacity(children.len());

    for child in &children {
        let rtype = std::str::from_utf8(&child.btype).unwrap_or("????").to_string();
        let mut pos = child.data_start;

        let from: u32 = if id_size_4 {
            pos += 4;
            read_u32be(data, pos - 4)
        } else {
            pos += 2;
            read_u16be(data, pos - 2) as u32
        };

        let to_count = read_u16be(data, pos) as usize;
        pos += 2;

        let mut to = Vec::with_capacity(to_count);
        for _ in 0..to_count {
            let item: u32 = if id_size_4 {
                pos += 4;
                read_u32be(data, pos - 4)
            } else {
                pos += 2;
                read_u16be(data, pos - 2) as u32
            };
            to.push(item);
        }

        refs.push(IrefEntry { rtype, from, to });
    }

    (version, refs)
}

/// Parse all metadata from a source HEIC file.
///
/// This is the main entry point for reading an existing HEIC's ISOBMFF structure.
pub fn parse_source_meta(data: &[u8]) -> Result<ParsedMeta, String> {
    let top = parse_boxes(data, 0, data.len());

    let meta = top
        .iter()
        .find(|b| &b.btype == b"meta")
        .ok_or("meta box not found")?;

    let meta_children = parse_boxes(data, meta.data_start + 4, meta.data_end);

    // Find required boxes
    let iloc_box = meta_children
        .iter()
        .find(|b| &b.btype == b"iloc")
        .ok_or("iloc not found in meta")?;
    let iinf_box = meta_children
        .iter()
        .find(|b| &b.btype == b"iinf")
        .ok_or("iinf not found in meta")?;
    let pitm_box = meta_children
        .iter()
        .find(|b| &b.btype == b"pitm")
        .ok_or("pitm not found in meta")?;
    let iprp_box = meta_children
        .iter()
        .find(|b| &b.btype == b"iprp")
        .ok_or("iprp not found in meta")?;
    let iref_box = meta_children.iter().find(|b| &b.btype == b"iref");

    let iloc_entries = parse_iloc(data, iloc_box)?;
    let items = parse_iinf(data, iinf_box)?;
    let primary_id = parse_pitm(data, pitm_box);
    let ipma_data = parse_boxes(data, iprp_box.data_start, iprp_box.data_end);
    let ipma_box = ipma_data
        .iter()
        .find(|b| &b.btype == b"ipma")
        .ok_or("ipma not found in iprp")?;
    let (ipma_flags, ipma_entries) = parse_ipma(data, ipma_box);
    let props = parse_iprp_properties(data, iprp_box)?;
    let (_iref_version, refs) = if let Some(iref) = iref_box {
        parse_iref(data, iref)
    } else {
        (0, Vec::new())
    };

    Ok(ParsedMeta {
        iloc_entries,
        ipma_entries,
        ipma_flags,
        items,
        refs,
        props,
        primary_id,
        pitm_version: data[pitm_box.data_start],
        iinf_version: data[iinf_box.data_start],
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn make_box_roundtrip() {
        let payload = b"\x00\x01\x02\x03";
        let box_bytes = make_box(b"ftyp", payload);
        assert!(box_bytes.len() >= 8);
        let size = read_u32be(&box_bytes, 0);
        assert_eq!(size as usize, box_bytes.len());
        assert_eq!(&box_bytes[4..8], b"ftyp");
        assert_eq!(&box_bytes[8..], payload);
    }

    #[test]
    fn parse_empty_boxes() {
        let boxes = parse_boxes(&[], 0, 0);
        assert!(boxes.is_empty());
    }

    #[test]
    fn parse_single_box() {
        // ftyp box: size=12, type="ftyp", payload=[0,0,0,0]
        let mut data = Vec::new();
        write_u32be(12, &mut data);
        data.extend_from_slice(b"ftyp");
        data.extend_from_slice(&[0u8; 4]);
        let boxes = parse_boxes(&data, 0, data.len());
        assert_eq!(boxes.len(), 1);
        assert_eq!(&boxes[0].btype, b"ftyp");
        assert_eq!(boxes[0].size, 12);
    }

    #[test]
    fn iloc_v1_one_entry() {
        let entry = IlocEntry {
            item_id: 1,
            construction_method: 0,
            data_reference_index: 0,
            extents: vec![(0, 100)],
        };
        let iloc = make_iloc_box(&[entry]);
        // Parse it back
        let boxes = parse_boxes(&iloc, 0, iloc.len());
        assert_eq!(boxes.len(), 1);
        let parsed = parse_iloc(&iloc, &boxes[0]).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].item_id, 1);
        assert_eq!(parsed[0].extents.len(), 1);
        assert_eq!(parsed[0].extents[0], (0, 100));
    }

    #[test]
    fn ipma_entry_roundtrip() {
        let assocs = vec![(1, true), (2, false)];
        let entry = make_ipma_entry(1, &assocs, 0);
        // 16-bit item_id (2 bytes) + count(1) + 2 associations * 1 byte each
        assert!(entry.len() > 4);
    }

    #[test]
    fn infe_hvc1_roundtrip() {
        let infe = make_infe_box(5, "hvc1", 1);
        // Should be a valid box
        assert!(infe.len() >= 8);
        assert_eq!(&infe[4..8], b"infe");

        // Verify it contains "hvc1"
        let hvc1_pos = infe.windows(4).position(|w| w == b"hvc1");
        assert!(hvc1_pos.is_some(), "infe should contain 'hvc1'");
    }

    #[test]
    fn iref_entry_roundtrip() {
        let entry = make_iref_entry("dimg", 1, &[2, 3], false);
        // Should be a valid box
        assert!(entry.len() >= 8);
        assert_eq!(&entry[4..8], b"dimg");
    }

    #[test]
    fn auxc_box_constant() {
        assert_eq!(AUX_C_BOX.len(), 40);
        assert_eq!(&AUX_C_BOX[4..8], b"auxC");
        // Check URN substring exists
        let urn = b"urn:iso:std:iso:ts:21496:-1";
        assert!(AUX_C_BOX.windows(urn.len()).any(|w| w == urn));
    }

    #[test]
    fn dinf_box_present() {
        assert_eq!(&DINF_BOX[4..8], b"dinf");
        assert!(DINF_BOX.len() >= 36);
    }

    #[test]
    fn static_boxes_correct_type() {
        assert_eq!(&IROT_BOX[4..8], b"irot");
        assert_eq!(&COLR_SRGB_BOX[4..8], b"colr");
        assert_eq!(&COLR_BT2020_PQ_BOX[4..8], b"colr");
        assert_eq!(&PIXI_RGB8_BOX[4..8], b"pixi");
        assert_eq!(&PIXI_RGB10_BOX[4..8], b"pixi");
    }

    #[test]
    fn make_ftyp_appends_brands() {
        // Original ftyp payload: major="heic", minor=0, brands=["heic","mif1"]
        let mut original = Vec::new();
        original.extend_from_slice(b"heic"); // major brand
        write_u32be(0, &mut original); // minor version
        original.extend_from_slice(b"heic");
        original.extend_from_slice(b"mif1");

        let new_ftyp = make_ftyp_box(&original);
        // Should contain tmap, MiHE, miaf, MiHB
        let new_str = String::from_utf8_lossy(&new_ftyp);
        assert!(new_str.contains("tmap"));
        assert!(new_str.contains("MiHE"));
        assert!(new_str.contains("MiHB"));
    }

    #[test]
    fn ispe_box_dimensions() {
        let ispe = make_ispe_box(512, 1024);
        let boxes = parse_boxes(&ispe, 0, ispe.len());
        assert_eq!(boxes.len(), 1);
        assert_eq!(&boxes[0].btype, b"ispe");
        // Payload should be 12 bytes: version(4) + width(4) + height(4)
        assert_eq!(boxes[0].data_end - boxes[0].data_start, 12);
        let w = read_u32be(&ispe, boxes[0].data_start + 4);
        let h = read_u32be(&ispe, boxes[0].data_start + 8);
        assert_eq!(w, 512);
        assert_eq!(h, 1024);
    }

    #[test]
    fn grpl_altr_box() {
        let grpl = make_grpl_altr_box(100, 50, 1);
        assert!(grpl.len() > 8);
        assert_eq!(&grpl[4..8], b"grpl");
        // Should contain "altr" child
        assert!(grpl.windows(4).any(|w| w == b"altr"));
    }

    #[test]
    fn parse_multiple_boxes() {
        let mut data = Vec::new();
        // Box 1: ftyp
        write_u32be(12, &mut data);
        data.extend_from_slice(b"ftyp");
        data.extend_from_slice(b"xxxx");
        // Box 2: mdat (empty)
        write_u32be(8, &mut data);
        data.extend_from_slice(b"mdat");
        // Box 3: free
        write_u32be(16, &mut data);
        data.extend_from_slice(b"free");
        data.extend_from_slice(&[0u8; 8]);

        let boxes = parse_boxes(&data, 0, data.len());
        assert_eq!(boxes.len(), 3);
        assert_eq!(&boxes[0].btype, b"ftyp");
        assert_eq!(&boxes[1].btype, b"mdat");
        assert_eq!(&boxes[2].btype, b"free");
    }

    #[test]
    fn read_write_u32be() {
        let mut buf = Vec::new();
        write_u32be(0xDEAD_BEEF, &mut buf);
        assert_eq!(buf.len(), 4);
        assert_eq!(read_u32be(&buf, 0), 0xDEAD_BEEF);
    }

    #[test]
    fn read_write_u16be() {
        let mut buf = Vec::new();
        write_u16be(0xABCD, &mut buf);
        assert_eq!(buf.len(), 2);
        assert_eq!(read_u16be(&buf, 0), 0xABCD);
    }

    #[test]
    fn parse_pitm_v0() {
        // Version 0 pitm: version(1) flags(3) item_id(2)
        let mut payload = vec![0u8, 0, 0, 0];
        write_u16be(42, &mut payload);
        let box_bytes = make_box(b"pitm", &payload);
        let boxes = parse_boxes(&box_bytes, 0, box_bytes.len());
        let id = parse_pitm(&box_bytes, &boxes[0]);
        assert_eq!(id, 42);
    }

    #[test]
    fn parse_pitm_v1() {
        // Version 1 pitm: version(1) flags(3) item_id(4)
        let mut payload = vec![1u8, 0, 0, 0];
        write_u32be(4242, &mut payload);
        let box_bytes = make_box(b"pitm", &payload);
        let boxes = parse_boxes(&box_bytes, 0, box_bytes.len());
        let id = parse_pitm(&box_bytes, &boxes[0]);
        assert_eq!(id, 4242);
    }

    #[test]
    fn grid_box_structure() {
        let grid = make_grid_box(512, 512, 2, 2, 1024, 1024);
        assert!(&grid[4..8] == b"grid");
        // Compact payload: version(1)+flags(1)+rows_m1(1)+cols_m1(1)+w(2)+h(2) = 8 bytes
        let boxes = parse_boxes(&grid, 0, grid.len());
        assert_eq!(boxes[0].data_end - boxes[0].data_start, 8);
    }

    #[test]
    fn make_infe_contains_type() {
        let infe = make_infe_box(10, "tmap", 0);
        assert!(infe.windows(4).any(|w| w == b"tmap"));

        let infe = make_infe_box(11, "grid", 1);
        assert!(infe.windows(4).any(|w| w == b"grid"));
    }

    #[test]
    fn make_mime_infe() {
        let infe = make_mime_infe_box(20, 1);
        assert!(infe.windows(4).any(|w| w == b"mime"));
        assert!(infe.windows(9).any(|w| w == b"hdrgm-xmp"));
    }
}
