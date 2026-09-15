//! Photographic Styles attach — bring the 2023 styles + PS3 (texture_styles +
//! 12 semantic part mattes + Apple maker note) contract to ANY HEIC/HEIF
//! input, not just OPPO ProXDR conversions.
//!
//! Routing semantics (see docs/research/styles-upstream-logic-comparison.md):
//! - non-Apple HEIC (no 2023 styles item): inject the styles item (identity
//!   state), texture_styles, the 12 matte placeholders, and merge the Apple
//!   maker note (the X-probe proved its absence removes every style entry).
//! - Apple HEIC with styles but no PS3 contract: add only what is missing;
//!   the native styles payload is never overwritten.
//! - files already carrying the full contract: untouched.
//!
//! SDR captures (no tmap) are handled: references degrade to [primary].

use crate::isobmff;
use crate::isobmff_write::replace_item_payload;
use crate::semantic_mattes::inject_semantic_mattes;
use crate::styles_native::{build_style_metadata_with, StyleStateOverride};
use crate::styles_scaffold::compose_styles_maker_note;
use crate::texture_styles::{inject_uri_metadata_item, texture_info_payload, TEXTURE_STYLES_URI};

pub const STYLES_URI: &str = "tag:apple.com,2023:photo:metadata:styles";
pub const MATTE_MARK_URN: &str = "tag:apple.com,2026:photo:aux:semanticnosematte";

#[derive(Debug, Clone, PartialEq)]
pub struct AttachReport {
    /// "attached" | "already-complete"
    pub status: &'static str,
    pub added: Vec<&'static str>,
}

fn has_bytes(data: &[u8], needle: &str) -> bool {
    let n = needle.as_bytes();
    data.windows(n.len()).any(|w| w == n)
}

fn find_item(parsed: &isobmff::ParsedMeta, uri: &str) -> Option<u32> {
    parsed
        .items
        .iter()
        .find(|i| i.raw_infe.windows(uri.len()).any(|w| w == uri.as_bytes()))
        .map(|i| i.item_id)
}

/// Read an item payload (construction 0 from mdat / 1 from idat).
fn item_payload_bytes(data: &[u8], parsed: &isobmff::ParsedMeta, item_id: u32) -> Option<Vec<u8>> {
    let loc = parsed.iloc_entries.iter().find(|e| e.item_id == item_id)?;
    match loc.construction_method & 0xF {
        0 => {
            let (off, len) = *loc.extents.first()?;
            Some(data.get(off as usize..(off + len) as usize)?.to_vec())
        }
        1 => {
            let top = isobmff::parse_boxes(data, 0, data.len());
            let meta = top.iter().find(|b| b.btype == *b"meta")?;
            let idat = isobmff::parse_boxes(data, meta.data_start + 4, meta.data_end)
                .into_iter()
                .find(|b| b.btype == *b"idat")?;
            let blob = &data[idat.data_start..idat.data_end];
            let (off, len) = *loc.extents.first()?;
            Some(blob.get(off as usize..(off + len) as usize)?.to_vec())
        }
        _ => None,
    }
}

const EXIF_TYPE_SIZES: [usize; 12] = [0, 1, 1, 2, 4, 8, 1, 0, 0, 4, 8, 0];

struct TiffIfd {
    entries: Vec<(u16, u16, u32, [u8; 4])>, // (tag, typ, count, value_field)
    next: u32,
    block_len: usize, // 2 + entries*12 + 4
}

fn read_tiff_ifd(tiff: &[u8], be: bool, off: usize) -> Option<TiffIfd> {
    let rd_u16 = |b: &[u8]| {
        if be {
            u16::from_be_bytes([b[0], b[1]])
        } else {
            u16::from_le_bytes([b[0], b[1]])
        }
    };
    let rd_u32 = |b: &[u8]| {
        if be {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        }
    };
    if off + 2 > tiff.len() {
        return None;
    }
    let n = rd_u16(&tiff[off..off + 2]) as usize;
    if off + 2 + n * 12 + 4 > tiff.len() {
        return None;
    }
    let mut entries = Vec::with_capacity(n);
    for i in 0..n {
        let e = off + 2 + i * 12;
        let tag = rd_u16(&tiff[e..e + 2]);
        let typ = rd_u16(&tiff[e + 2..e + 4]);
        let cnt = rd_u32(&tiff[e + 4..e + 8]);
        let mut vf = [0u8; 4];
        vf.copy_from_slice(&tiff[e + 8..e + 12]);
        entries.push((tag, typ, cnt, vf));
    }
    let next = rd_u32(&tiff[off + 2 + n * 12..off + 6 + n * 12]);
    Some(TiffIfd {
        entries,
        next,
        block_len: 2 + n * 12 + 4,
    })
}

fn tiff_entry_value<'a>(
    tiff: &'a [u8],
    typ: u16,
    count: u32,
    value_field: &'a [u8; 4],
) -> Option<&'a [u8]> {
    let size = *EXIF_TYPE_SIZES.get(typ as usize)?;
    let len = size.checked_mul(count as usize)?;
    if len <= 4 {
        Some(&value_field[..len])
    } else {
        let off = u32::from_be_bytes(*value_field) as usize;
        tiff.get(off..off.checked_add(len)?)
    }
}

fn wr_u16(out: &mut Vec<u8>, be: bool, v: u16) {
    if be {
        out.extend_from_slice(&v.to_be_bytes());
    } else {
        out.extend_from_slice(&v.to_le_bytes());
    }
}

fn wr_u32(out: &mut Vec<u8>, be: bool, v: u32) {
    if be {
        out.extend_from_slice(&v.to_be_bytes());
    } else {
        out.extend_from_slice(&v.to_le_bytes());
    }
}

/// Insert or update the MakerNote (0x927c) entry in the Exif TIFF with
/// `note`, rebuilding the TIFF (IFD0 + chained IFDs + ExifIFD + data area).
fn upsert_maker_note_in_tiff(exif_payload: &[u8], note: &[u8]) -> Result<Vec<u8>, String> {
    let prefix = 10usize; // 4-byte length word + "Exif\0\0"
    if exif_payload.len() < prefix + 8 {
        return Err("Exif payload too short".into());
    }
    let tiff = &exif_payload[prefix..];
    let be = tiff[0] == b'M';
    if tiff[2..4] != [0, 42] {
        return Err("bad TIFF magic".into());
    }
    let ifd0_off = if be {
        u32::from_be_bytes(tiff[4..8].try_into().unwrap()) as usize
    } else {
        u32::from_le_bytes(tiff[4..8].try_into().unwrap()) as usize
    };
    let ifd0 = read_tiff_ifd(tiff, be, ifd0_off).ok_or("IFD0 out of bounds")?;
    let exif_ptr = ifd0
        .entries
        .iter()
        .find(|e| e.0 == 0x8769)
        .ok_or("no ExifIFD pointer")?;
    let exif_off = if be {
        u32::from_be_bytes(exif_ptr.3) as usize
    } else {
        u32::from_le_bytes(exif_ptr.3) as usize
    };
    let exif_ifd = read_tiff_ifd(tiff, be, exif_off).ok_or("ExifIFD out of bounds")?;

    let mut chain: Vec<TiffIfd> = Vec::new();
    let mut next = ifd0.next;
    let mut guard = 0;
    while next != 0 {
        guard += 1;
        if guard > 8 {
            return Err("TIFF IFD chain too long".into());
        }
        let ifd = read_tiff_ifd(tiff, be, next as usize).ok_or("chained IFD out of bounds")?;
        next = ifd.next;
        chain.push(ifd);
    }

    // ExifIFD entries with the MakerNote upserted
    let mut exif_entries: Vec<(u16, u16, u32, Vec<u8>)> = exif_ifd
        .entries
        .iter()
        .map(|(t, ty, c, vf)| (*t, *ty, *c, vf.to_vec()))
        .collect();
    if note.is_empty() {
        // empty note => remove the MakerNote entry entirely
        exif_entries.retain(|e| e.0 != 0x927c);
    } else if let Some(e) = exif_entries.iter_mut().find(|e| e.0 == 0x927c) {
        e.2 = note.len() as u32;
        e.3 = note.to_vec();
    } else {
        exif_entries.push((0x927c, 7, note.len() as u32, note.to_vec()));
    }

    // layout: header(8) + IFD0 + chain... + ExifIFD + data
    let ifd0_block = 2 + ifd0.entries.len() * 12 + 4;
    let mut chain_offs: Vec<u32> = Vec::new();
    let mut cur = 8 + ifd0_block;
    for ifd in &chain {
        chain_offs.push(cur as u32);
        cur += ifd.block_len;
    }
    let exif_new_off = cur as u32;
    cur += 2 + exif_entries.len() * 12 + 4;
    let data_start = cur;

    let mut out: Vec<u8> = Vec::new();
    let mut data_area: Vec<u8> = Vec::new();
    out.extend_from_slice(&tiff[..8]); // endian + magic + IFD0 offset

    // IFD0 (ExifIFD pointer re-pointed to the new ExifIFD offset)
    wr_u16(&mut out, be, ifd0.entries.len() as u16);
    for (t, ty, c, vf) in &ifd0.entries {
        let mut rec: Vec<u8> = Vec::new();
        wr_u16(&mut rec, be, *t);
        wr_u16(&mut rec, be, *ty);
        wr_u32(&mut rec, be, *c);
        if *t == 0x8769 {
            wr_u32(&mut rec, be, exif_new_off);
        } else {
            let value = tiff_entry_value(tiff, *ty, *c, vf).map(|s| s.to_vec()).unwrap_or_default();
            if value.len() <= 4 {
                let mut field = [0u8; 4];
                field[..value.len()].copy_from_slice(&value);
                rec.extend_from_slice(&field);
            } else {
                wr_u32(&mut rec, be, (data_start + data_area.len()) as u32);
                data_area.extend_from_slice(&value);
                if data_area.len() % 2 == 1 {
                    data_area.push(0);
                }
            }
        }
        out.extend_from_slice(&rec);
    }
    out.extend_from_slice(&0u32.to_be_bytes()); // IFD0 next → chain[0], patched below

    let mut chain_ptrs: Vec<usize> = Vec::new();
    for ifd in &chain {
        chain_ptrs.push(out.len() + 2 + ifd.entries.len() * 12);
        wr_u16(&mut out, be, ifd.entries.len() as u16);
        for (t, ty, c, vf) in &ifd.entries {
            let mut rec: Vec<u8> = Vec::new();
            wr_u16(&mut rec, be, *t);
            wr_u16(&mut rec, be, *ty);
            wr_u32(&mut rec, be, *c);
            let value = tiff_entry_value(tiff, *ty, *c, vf).map(|s| s.to_vec()).unwrap_or_default();
            if value.len() <= 4 {
                let mut field = [0u8; 4];
                field[..value.len()].copy_from_slice(&value);
                rec.extend_from_slice(&field);
            } else {
                wr_u32(&mut rec, be, (data_start + data_area.len()) as u32);
                data_area.extend_from_slice(&value);
                if data_area.len() % 2 == 1 {
                    data_area.push(0);
                }
            }
            out.extend_from_slice(&rec);
        }
        out.extend_from_slice(&0u32.to_be_bytes());
    }
    // patch chain next-pointers
    let mut prev_next = 8 + ifd0_block - 4; // IFD0 next field position
    for (i, off) in chain_offs.iter().enumerate() {
        if be {
            out[prev_next..prev_next + 4].copy_from_slice(&off.to_be_bytes());
        } else {
            out[prev_next..prev_next + 4].copy_from_slice(&off.to_le_bytes());
        }
        prev_next = chain_ptrs[i];
    }

    // ExifIFD
    wr_u16(&mut out, be, exif_entries.len() as u16);
    for (t, ty, c, value) in &exif_entries {
        let mut rec: Vec<u8> = Vec::new();
        wr_u16(&mut rec, be, *t);
        wr_u16(&mut rec, be, *ty);
        wr_u32(&mut rec, be, *c);
        if value.len() <= 4 {
            let mut field = [0u8; 4];
            field[..value.len()].copy_from_slice(value);
            rec.extend_from_slice(&field);
        } else {
            wr_u32(&mut rec, be, (data_start + data_area.len()) as u32);
            data_area.extend_from_slice(value);
            if data_area.len() % 2 == 1 {
                data_area.push(0);
            }
        }
        out.extend_from_slice(&rec);
    }
    out.extend_from_slice(&0u32.to_be_bytes());
    out.extend_from_slice(&data_area);

    let mut payload: Vec<u8> = exif_payload[..prefix].to_vec();
    payload.extend_from_slice(&out);
    Ok(payload)
}

/// Remove the MakerNote entry entirely (empty 0x927c). Used before attaching
/// when the source carries a native camera maker note whose signature would
/// gate the style editor.
pub fn strip_makernote(data: &mut Vec<u8>) -> Result<(), String> {
    let parsed = isobmff::parse_source_meta(data)?;
    let exif_id = parsed
        .items
        .iter()
        .find(|i| i.itype == "Exif")
        .map(|i| i.item_id)
        .ok_or("no Exif item")?;
    let payload = item_payload_bytes(data, &parsed, exif_id).ok_or("unreadable Exif payload")?;
    let stripped = upsert_maker_note_in_tiff(&payload, b"")?;
    if stripped != payload {
        replace_item_payload(data, exif_id, None, &stripped)?;
    }
    Ok(())
}

fn merge_maker_note(data: &mut Vec<u8>) -> Result<bool, String> {
    // Re-parse: callers may have injected items (shifting iloc offsets) before
    // this merge, so a stale parse would read the wrong extents.
    let parsed = isobmff::parse_source_meta(data)?;
    let exif_id = parsed
        .items
        .iter()
        .find(|i| i.itype == "Exif")
        .map(|i| i.item_id)
        .ok_or("no Exif item — cannot attach Apple maker note")?;
    let payload = item_payload_bytes(data, &parsed, exif_id).ok_or("unreadable Exif payload")?;

    // If an Apple-format maker note is already present (native captures,
    // Apple-edited exports, previous attaches), leave it untouched: it is
    // complete for Photos' purposes and expanding it is not always possible
    // (unknown out-of-line UNDEFINED blobs).
    if let Some(tiff_off) = find_makernote_offset(&payload) {
        let starts_apple = payload[tiff_off..].starts_with(b"Apple iOS");
        if starts_apple {
            return Ok(false);
        }
    }

    let note = compose_styles_maker_note(&payload)?;
    let merged = upsert_maker_note_in_tiff(&payload, &note)?;
    if merged != payload {
        replace_item_payload(data, exif_id, None, &merged)?;
    }
    Ok(true)
}

/// Offset (within the Exif payload) of the MakerNote entry data, if any.
fn find_makernote_offset(exif_payload: &[u8]) -> Option<usize> {
    let prefix = 10usize;
    let tiff = &exif_payload[prefix..];
    let be = tiff[0] == b'M';
    let rd_u16 = |b: &[u8]| {
        if be {
            u16::from_be_bytes([b[0], b[1]])
        } else {
            u16::from_le_bytes([b[0], b[1]])
        }
    };
    let rd_u32 = |b: &[u8]| {
        if be {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        }
    };
    let ifd0_off = rd_u32(&tiff[4..8]) as usize;
    let ifd0 = read_tiff_ifd(tiff, be, ifd0_off)?;
    let exif_ptr = ifd0.entries.iter().find(|e| e.0 == 0x8769)?;
    let exif_off = rd_u32(&exif_ptr.3) as usize;
    let exif_ifd = read_tiff_ifd(tiff, be, exif_off)?;
    let mn = exif_ifd.entries.iter().find(|e| e.0 == 0x927c)?;
    let off = rd_u32(&mn.3) as usize;
    Some(prefix + off)
}

/// Attach the styles contract to `data`. Returns the patched bytes and a
/// report of what happened.
pub fn attach_styles(data: &[u8], grain_seed: u64) -> Result<(Vec<u8>, AttachReport), String> {
    let parsed = isobmff::parse_source_meta(data)?;
    let has_styles = find_item(&parsed, STYLES_URI).is_some();
    let has_texture = find_item(&parsed, TEXTURE_STYLES_URI).is_some();
    let has_mattes = has_bytes(data, MATTE_MARK_URN);

    let mut added: Vec<&'static str> = Vec::new();
    let mut out = data.to_vec();

    if has_styles && has_texture && has_mattes {
        return Ok((
            out,
            AttachReport {
                status: "already-complete",
                added,
            },
        ));
    }

    if !has_styles {
        // Non-Apple capture: inject the styles item with the identity state,
        // then make the file look like an Apple capture to Photos (maker note).
        let payload = build_style_metadata_with(&StyleStateOverride::identity());
        out = inject_uri_metadata_item(&out, STYLES_URI, &payload)?;
        if merge_maker_note(&mut out)? {
            added.push("maker-note");
        }
        added.push("styles");
    }
    if !has_texture {
        let payload = texture_info_payload(grain_seed);
        out = inject_uri_metadata_item(&out, TEXTURE_STYLES_URI, &payload)?;
        added.push("texture");
    }
    if !has_mattes {
        out = inject_semantic_mattes(&out)?;
        added.push("mattes");
    }

    Ok((
        out,
        AttachReport {
            status: "attached",
            added,
        },
    ))
}
