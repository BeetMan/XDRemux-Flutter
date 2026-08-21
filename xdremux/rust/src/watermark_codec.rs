//! Pure-Rust visible watermark restoration for returned HEIF photos.
//!
//! The primary image is decoded with heif-oxide, the donor's reserved OPPO
//! canvas is copied over the returned raster, and a new primary ImageGrid is
//! appended while the returned gain-map graph and metadata remain intact.

use crate::container;
use crate::hevc;
use crate::isobmff::{self, BoxHeader, IlocEntry, IpmaEntry, IrefEntry};

const TILE_SIZE: u32 = 512;

/// Remove the returned file's existing ISO gain-map rendition while keeping
/// its primary edited image and metadata. The OPPO-compatible writer then
/// builds the 142-byte tmap rendition from the untouched donor metadata.
pub fn strip_existing_gain_map_graph(source: &[u8]) -> Result<Vec<u8>, String> {
    let parsed = isobmff::parse_source_meta(source)?;
    let top = isobmff::parse_boxes(source, 0, source.len());
    let meta = find(&top, b"meta")?;
    let primary = parsed.primary_id;
    let mut dropped = std::collections::HashSet::new();
    for item in &parsed.items {
        if item.itype == "tmap" {
            dropped.insert(item.item_id);
        }
    }
    let tmap_ids: std::collections::HashSet<u32> = parsed
        .items
        .iter()
        .filter(|item| item.itype == "tmap")
        .map(|item| item.item_id)
        .collect();
    for reference in &parsed.refs {
        if reference.rtype == "dimg"
            && reference.from != primary
            && !tmap_ids.contains(&reference.from)
        {
            dropped.insert(reference.from);
            dropped.extend(reference.to.iter().copied());
        }
    }
    if dropped.is_empty() {
        return Ok(source.to_vec());
    }
    let keep_item = |id: u32| !dropped.contains(&id);
    let items: Vec<Vec<u8>> = parsed
        .items
        .iter()
        .filter(|item| keep_item(item.item_id))
        .map(|item| item.raw_infe.clone())
        .collect();
    let iinf_box = find_meta_child(source, &meta, b"iinf")?;
    let iinf = isobmff::make_iinf_box(source[iinf_box.data_start], &items);
    let iloc_entries: Vec<IlocEntry> = parsed
        .iloc_entries
        .iter()
        .filter(|entry| keep_item(entry.item_id))
        .cloned()
        .collect();
    let iloc = isobmff::make_iloc_box(&iloc_entries);
    let ipma_entries: Vec<IpmaEntry> = parsed
        .ipma_entries
        .iter()
        .filter(|entry| keep_item(entry.item_id))
        .cloned()
        .collect();
    let ipma = make_ipma_box(source, &meta, &ipma_entries, parsed.ipma_flags)?;
    let properties: Vec<Vec<u8>> = parsed
        .props
        .iter()
        .map(|property| property.raw.clone())
        .collect();
    let iprp = make_iprp_box(&properties, &ipma);
    let refs: Vec<IrefEntry> = parsed
        .refs
        .iter()
        .filter_map(|reference| {
            if dropped.contains(&reference.from) {
                return None;
            }
            let to: Vec<u32> = reference
                .to
                .iter()
                .copied()
                .filter(|id| keep_item(*id))
                .collect();
            if reference.rtype == "dimg" && to.is_empty() {
                None
            } else {
                Some(IrefEntry {
                    rtype: reference.rtype.clone(),
                    from: reference.from,
                    to,
                })
            }
        })
        .collect();
    let iref = find_meta_child(source, &meta, b"iref")
        .map(|box_| isobmff::make_iref_full_box(source[box_.data_start], &refs))
        .ok();
    let children = isobmff::parse_boxes(source, meta.data_start + 4, meta.data_end);
    let mut payload = source[meta.data_start..meta.data_start + 4].to_vec();
    for child in children {
        let replacement: Option<&[u8]> = match &child.btype {
            b"iinf" => Some(&iinf),
            b"iloc" => Some(&iloc),
            b"iprp" => Some(&iprp),
            b"iref" => iref.as_deref(),
            b"grpl" => None,
            _ => Some(&source[child.box_start..child.data_end]),
        };
        if let Some(bytes) = replacement {
            payload.extend_from_slice(bytes);
        }
    }
    let new_size = 8 + payload.len();
    if new_size > meta.size {
        return Err("cannot strip gain-map graph without growing meta".into());
    }
    let spare = meta.size - new_size;
    if spare >= 8 {
        payload.extend_from_slice(&isobmff::make_box(b"free", &vec![0; spare - 8]));
    } else if spare != 0 {
        return Err("meta padding is too small after stripping gain-map graph".into());
    }
    let new_meta = isobmff::make_box(b"meta", &payload);
    let meta_start = meta.box_start;
    let mut output = Vec::with_capacity(source.len());
    for box_ in top {
        if box_.box_start == meta_start {
            output.extend_from_slice(&new_meta);
        } else {
            output.extend_from_slice(&source[box_.box_start..box_.data_end]);
        }
    }
    Ok(output)
}

/// Restore the complete donor watermark canvas for the OPPO graph path.
/// OPPO's private renderer depends on the whole reserved canvas, not only the
/// glyph pixels, so this is intentionally different from the Apple-output
/// local mask below.
fn restore_watermark_canvas(
    donor: &[u8],
    donor_rgba: &[u8],
    returned_rgba: &mut [u8],
    image_width: u32,
    image_height: u32,
) -> Result<(), String> {
    let stride = image_width as usize * 4;
    match container::watermark_canvas_rect(donor, image_width, image_height) {
        Ok((x, y, width, height)) => {
            for row in y..y + height {
                let start = row as usize * stride + x as usize * 4;
                let end = start + width as usize * 4;
                returned_rgba[start..end].copy_from_slice(&donor_rgba[start..end]);
            }
        }
        Err(payload_error) => {
            let bands = detect_frame_bands(donor_rgba, image_width, image_height)
                .map_err(|band_error| format!("{payload_error}; {band_error}"))?;
            for (y0, y1) in bands {
                for row in y0..y1 {
                    let start = row as usize * stride;
                    let end = start + stride;
                    returned_rgba[start..end].copy_from_slice(&donor_rgba[start..end]);
                }
            }
        }
    }
    Ok(())
}

/// Restore only the visible watermark pixels from the untouched donor.
///
/// The returned raster remains the source of truth everywhere else, including
/// any photographic-style adjustment. The donor PNG alpha is used as a mask
/// and the donor's already-composited raster is used for the color.
fn restore_watermark_pixels(
    donor: &[u8],
    donor_rgba: &[u8],
    returned_rgba: &mut [u8],
    image_width: u32,
    image_height: u32,
) -> Result<(), String> {
    let stride = image_width as usize * 4;
    let watermark = container::extract_tail_entry(donor, "watermark");
    let mask_result = watermark
        .as_deref()
        .map(decode_watermark_png)
        .unwrap_or_else(|| Err("OPPO watermark PNG payload is missing".into()));
    let geometry = container::watermark_overlay_rect(donor, image_width, image_height);
    match (mask_result, geometry) {
        (Ok((mask, mask_width, mask_height)), Ok((x, y, width, height))) => {
            if mask_width != width || mask_height != height {
                return Err("OPPO watermark PNG and config dimensions differ".into());
            }
            let expected = mask_width as usize * mask_height as usize * 4;
            if mask.len() != expected {
                return Err("OPPO watermark PNG mask has an invalid size".into());
            }
            for mask_y in 0..mask_height as usize {
                let image_y = y as usize + mask_y;
                let mask_row = mask_y * mask_width as usize * 4;
                let image_row = image_y * stride + x as usize * 4;
                for mask_x in 0..mask_width as usize {
                    let mask_index = mask_row + mask_x * 4;
                    let alpha = mask[mask_index + 3] as u32;
                    if alpha == 0 {
                        continue;
                    }
                    let image_index = image_row + mask_x * 4;
                    for channel in 0..3 {
                        let clean = donor_rgba[image_index + channel] as u32;
                        let edited = returned_rgba[image_index + channel] as u32;
                        returned_rgba[image_index + channel] =
                            ((clean * alpha + edited * (255 - alpha) + 127) / 255) as u8;
                    }
                }
            }
            Ok(())
        }
        (mask_result, geometry_result) => {
            // Frame-style watermarks may not have a usable alpha PNG. Keep a
            // conservative fallback for those files, limited to uniform frame
            // bands rather than replacing the whole photograph.
            let payload_error = mask_result
                .err()
                .or_else(|| geometry_result.err())
                .unwrap_or_else(|| "watermark mask unavailable".into());
            let bands = detect_frame_bands(donor_rgba, image_width, image_height)
                .map_err(|band_error| format!("{payload_error}; {band_error}"))?;
            restore_frame_watermark_pixels(
                donor_rgba,
                returned_rgba,
                image_width,
                &bands,
            );
            Ok(())
        }
    }
}

/// Frame-style OPPO watermarks have no separate PNG entry. Estimate the
/// uniform frame color and copy only pixels that differ from that background
/// (the Hasselblad text and camera-setting glyphs), leaving the edited frame
/// background untouched.
fn restore_frame_watermark_pixels(
    donor_rgba: &[u8],
    returned_rgba: &mut [u8],
    image_width: u32,
    bands: &[(u32, u32)],
) {
    let width = image_width as usize;
    let mut bins: std::collections::HashMap<(u8, u8, u8), (u64, u64, u64, u64)> =
        std::collections::HashMap::new();
    for &(y0, y1) in bands {
        for y in (y0 as usize..y1 as usize).step_by(8) {
            for x in (0..width).step_by(8) {
                let index = (y * width + x) * 4;
                let key = (
                    donor_rgba[index] / 4,
                    donor_rgba[index + 1] / 4,
                    donor_rgba[index + 2] / 4,
                );
                let bin = bins.entry(key).or_insert((0, 0, 0, 0));
                bin.0 += 1;
                bin.1 += donor_rgba[index] as u64;
                bin.2 += donor_rgba[index + 1] as u64;
                bin.3 += donor_rgba[index + 2] as u64;
            }
        }
    }
    let Some((_, (count, red, green, blue))) = bins.into_iter().max_by_key(|(_, bin)| bin.0)
    else {
        return;
    };
    let background = [
        (red / count.max(1)) as i32,
        (green / count.max(1)) as i32,
        (blue / count.max(1)) as i32,
    ];
    for &(y0, y1) in bands {
        for y in y0 as usize..y1 as usize {
            for x in 0..width {
                let index = (y * width + x) * 4;
                let distance = (0..3)
                    .map(|channel| {
                        (donor_rgba[index + channel] as i32 - background[channel]).abs()
                    })
                    .max()
                    .unwrap_or(0);
                if distance <= 4 {
                    continue;
                }
                let alpha = ((distance - 4) * 255 / 24).clamp(0, 255) as u32;
                for channel in 0..3 {
                    let clean = donor_rgba[index + channel] as u32;
                    let edited = returned_rgba[index + channel] as u32;
                    returned_rgba[index + channel] =
                        ((clean * alpha + edited * (255 - alpha) + 127) / 255) as u8;
                }
            }
        }
    }
}

fn decode_watermark_png(data: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    let decoder = png::Decoder::new(std::io::Cursor::new(data));
    let mut reader = decoder
        .read_info()
        .map_err(|error| format!("decode OPPO watermark PNG: {error}"))?;
    let mut buffer = vec![0; reader.output_buffer_size()];
    let info = reader
        .next_frame(&mut buffer)
        .map_err(|error| format!("read OPPO watermark PNG: {error}"))?;
    let bytes = &buffer[..info.buffer_size()];
    let mut rgba = Vec::with_capacity(info.width as usize * info.height as usize * 4);
    match info.color_type {
        png::ColorType::Rgba => rgba.extend_from_slice(bytes),
        png::ColorType::Rgb => {
            for pixel in bytes.chunks_exact(3) {
                rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for pixel in bytes.chunks_exact(2) {
                rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]);
            }
        }
        png::ColorType::Grayscale => {
            for &value in bytes {
                rgba.extend_from_slice(&[value, value, value, 255]);
            }
        }
        other => return Err(format!("unsupported OPPO watermark PNG color type: {other:?}")),
    }
    Ok((rgba, info.width, info.height))
}

/// Restore donor watermark pixels into a separate Apple Styles/HDR template
/// while taking all non-watermark pixels from the actual returned edit.
pub fn restore_watermark_into_template(
    donor: &[u8],
    returned: &[u8],
    template: &[u8],
) -> Result<Vec<u8>, String> {
    let donor_image =
        heif_oxide::decode_bytes(donor).map_err(|error| format!("decode donor HEIF: {error:?}"))?;
    let returned_image = heif_oxide::decode_bytes(returned)
        .map_err(|error| format!("decode returned HEIF: {error:?}"))?;
    let template_image = heif_oxide::decode_bytes(template)
        .map_err(|error| format!("decode Apple template HEIF: {error:?}"))?;
    if donor_image.width != returned_image.width
        || donor_image.height != returned_image.height
        || template_image.width != returned_image.width
        || template_image.height != returned_image.height
    {
        return Err("donor, returned, and Apple template dimensions differ".into());
    }
    let donor_rgba = donor_image.to_rgba8();
    let mut returned_rgba = returned_image.to_rgba8();
    restore_watermark_pixels(
        donor,
        &donor_rgba,
        &mut returned_rgba,
        returned_image.width,
        returned_image.height,
    )?;
    let rgb: Vec<u8> = returned_rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().copied())
        .collect();
    rewrite_primary_grid_in_place(
        template,
        &rgb,
        template_image.width,
        template_image.height,
        false,
    )
}

/// Variant used for OPPO-style full-canvas watermarks. It replaces the
/// reserved canvas rather than alpha-compositing a local mask.
pub fn restore_watermark_canvas_into_template(
    donor: &[u8],
    returned: &[u8],
    template: &[u8],
) -> Result<Vec<u8>, String> {
    let donor_image =
        heif_oxide::decode_bytes(donor).map_err(|error| format!("decode donor HEIF: {error:?}"))?;
    let returned_image = heif_oxide::decode_bytes(returned)
        .map_err(|error| format!("decode returned HEIF: {error:?}"))?;
    let template_image = heif_oxide::decode_bytes(template)
        .map_err(|error| format!("decode Apple template HEIF: {error:?}"))?;
    if donor_image.width != returned_image.width
        || donor_image.height != returned_image.height
        || template_image.width != returned_image.width
        || template_image.height != returned_image.height
    {
        return Err("donor, returned, and Apple template dimensions differ".into());
    }
    let donor_rgba = donor_image.to_rgba8();
    let mut returned_rgba = returned_image.to_rgba8();
    restore_watermark_canvas(
        donor,
        &donor_rgba,
        &mut returned_rgba,
        returned_image.width,
        returned_image.height,
    )?;
    let rgb: Vec<u8> = returned_rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().copied())
        .collect();
    rewrite_primary_grid_in_place(
        template,
        &rgb,
        template_image.width,
        template_image.height,
        false,
    )
}

pub fn restore_visible_watermark(donor: &[u8], returned: &[u8]) -> Result<Vec<u8>, String> {
    let donor_image =
        heif_oxide::decode_bytes(donor).map_err(|error| format!("decode donor HEIF: {error:?}"))?;
    let returned_image = heif_oxide::decode_bytes(returned)
        .map_err(|error| format!("decode returned HEIF: {error:?}"))?;
    if donor_image.width != returned_image.width || donor_image.height != returned_image.height {
        return Err(format!(
            "donor/returned dimensions differ: {}x{} vs {}x{}",
            donor_image.width, donor_image.height, returned_image.width, returned_image.height
        ));
    }
    let donor_rgba = donor_image.to_rgba8();
    let mut returned_rgba = returned_image.to_rgba8();
    restore_watermark_pixels(
        donor,
        &donor_rgba,
        &mut returned_rgba,
        returned_image.width,
        returned_image.height,
    )?;
    let rgb: Vec<u8> = returned_rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().copied())
        .collect();
    // Keep the returned container graph in place. Auxiliary edit metadata can
    // reference the original primary item; appending a new primary grid would
    // detach those edits. Never rewrite the returned edit recipe here.
    let output = rewrite_primary_grid_in_place(
        returned,
        &rgb,
        returned_image.width,
        returned_image.height,
        false,
    )?;
    Ok(output)
}

/// Rebuild the returned raster while preserving its HDR auxiliary graph.
/// The donor tail is attached by the caller; the returned primary ID and tmap
/// graph must remain intact so HDR compatibility is not lost.
pub fn restore_on_donor_graph(donor: &[u8], returned: &[u8]) -> Result<Vec<u8>, String> {
    let donor_image =
        heif_oxide::decode_bytes(donor).map_err(|error| format!("decode donor HEIF: {error:?}"))?;
    let returned_image = heif_oxide::decode_bytes(returned)
        .map_err(|error| format!("decode returned HEIF: {error:?}"))?;
    if donor_image.width != returned_image.width || donor_image.height != returned_image.height {
        return Err(format!(
            "donor/returned dimensions differ: {}x{} vs {}x{}",
            donor_image.width, donor_image.height, returned_image.width, returned_image.height
        ));
    }
    // The returned raster already contains the watermark, but it is filtered.
    // Restore only donor watermark pixels before writing onto the donor graph;
    // preserving the graph alone is not enough when the watermark is baked in.
    let donor_rgba = donor_image.to_rgba8();
    let mut returned_rgba = returned_image.to_rgba8();
    restore_watermark_canvas(
        donor,
        &donor_rgba,
        &mut returned_rgba,
        returned_image.width,
        returned_image.height,
    )?;
    let rgb: Vec<u8> = returned_rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().copied())
        .collect();
    let returned_base = container::strip_oppo_tail(returned);
    let rewritten = rewrite_primary_grid_in_place(
        &returned_base,
        &rgb,
        returned_image.width,
        returned_image.height,
        true,
    )?;
    // Keep the returned primary ID: the returned tmap/gain-map graph is tied
    // to it. OPPO tail compatibility is supplied separately by the donor tail.
    Ok(rewritten)
}

/// Keep the returned graph (including its HDR/tmap auxiliary items) while
/// changing only the primary item's identity to the donor primary ID required
/// by the OPPO watermark renderer.
fn relabel_primary_id(data: &[u8], old_id: u32, new_id: u32) -> Result<Vec<u8>, String> {
    if old_id == new_id {
        return Ok(data.to_vec());
    }
    let top = isobmff::parse_boxes(data, 0, data.len());
    let meta = find(&top, b"meta")?;
    let parsed = isobmff::parse_source_meta(data)?;
    let iinf_box = find_meta_child(data, &meta, b"iinf")?;
    let infes: Vec<Vec<u8>> = parsed
        .items
        .iter()
        .map(|item| {
            if item.item_id == old_id {
                patch_infe_id(&item.raw_infe, new_id)
            } else {
                Ok(item.raw_infe.clone())
            }
        })
        .collect::<Result<_, _>>()?;
    let iinf = isobmff::make_iinf_box(data[iinf_box.data_start], &infes);
    let ipma_entries = parsed
        .ipma_entries
        .iter()
        .map(|entry| IpmaEntry {
            item_id: if entry.item_id == old_id {
                new_id
            } else {
                entry.item_id
            },
            associations: entry.associations.clone(),
        })
        .collect::<Vec<_>>();
    let ipma = make_ipma_box(data, &meta, &ipma_entries, parsed.ipma_flags)?;
    let properties: Vec<Vec<u8>> = parsed
        .props
        .iter()
        .map(|property| property.raw.clone())
        .collect();
    let iprp = make_iprp_box(&properties, &ipma);
    let iloc_entries = parsed
        .iloc_entries
        .iter()
        .map(|entry| IlocEntry {
            item_id: if entry.item_id == old_id {
                new_id
            } else {
                entry.item_id
            },
            construction_method: entry.construction_method,
            data_reference_index: entry.data_reference_index,
            extents: entry.extents.clone(),
        })
        .collect::<Vec<_>>();
    let refs = parsed
        .refs
        .iter()
        .map(|reference| IrefEntry {
            rtype: reference.rtype.clone(),
            from: if reference.from == old_id {
                new_id
            } else {
                reference.from
            },
            to: reference
                .to
                .iter()
                .map(|id| if *id == old_id { new_id } else { *id })
                .collect(),
        })
        .collect::<Vec<_>>();
    let iref_version = find_meta_child(data, &meta, b"iref")
        .map(|box_| data[box_.data_start])
        .unwrap_or(0);
    let iref = isobmff::make_iref_full_box(iref_version, &refs);
    let idat_box = find_meta_child(data, &meta, b"idat")?;
    let idat = data[idat_box.box_start..idat_box.data_end].to_vec();
    let final_meta = build_meta(
        data,
        &meta,
        &iinf,
        &iloc_entries,
        &iprp,
        &iref,
        &idat,
        new_id,
    )?;
    let mut output = Vec::with_capacity(data.len() + final_meta.len() - meta.size);
    for box_ in &top {
        if box_.box_start == meta.box_start {
            output.extend_from_slice(&final_meta);
        } else {
            output.extend_from_slice(&data[box_.box_start..box_.data_end]);
        }
    }
    Ok(output)
}

fn patch_infe_id(raw: &[u8], item_id: u32) -> Result<Vec<u8>, String> {
    if raw.len() < 16 {
        return Err("infe box is truncated".into());
    }
    let mut patched = raw.to_vec();
    if raw[8] >= 3 {
        patched[12..16].copy_from_slice(&item_id.to_be_bytes());
    } else if item_id > u16::MAX as u32 {
        return Err("infe item ID does not fit version 2".into());
    } else {
        patched[12..14].copy_from_slice(&(item_id as u16).to_be_bytes());
    }
    Ok(patched)
}

/// Convert the returned Apple 62-byte tmap to the 142-byte ImageIO-native
/// form used by OPPO Gallery. The numeric HDR parameters are kept identical;
/// only the container encoding changes.
fn make_oppo_native_tmap(
    source: &[u8],
    parsed: &isobmff::ParsedMeta,
    idat_box: &BoxHeader,
) -> Result<Option<Vec<u8>>, String> {
    let Some(tmap) = parsed.items.iter().find(|item| item.itype == "tmap") else {
        return Ok(None);
    };
    let Some(entry) = parsed.iloc_entries.iter().find(|entry| entry.item_id == tmap.item_id)
    else {
        return Err("OPPO tmap iloc entry is missing".into());
    };
    if entry.construction_method != 1 || entry.extents.len() != 1 {
        return Err("OPPO tmap must use one idat extent".into());
    }
    let (offset, length) = entry.extents[0];
    if length != 62 {
        return Ok(None);
    }
    let start = idat_box
        .data_start
        .checked_add(offset as usize)
        .ok_or("OPPO tmap offset overflow")?;
    let end = start
        .checked_add(length as usize)
        .ok_or("OPPO tmap extent overflow")?;
    if end > source.len() {
        return Err("OPPO tmap extent exceeds source".into());
    }
    let payload = &source[start..end];
    let value = |index: usize| -> f32 {
        let at = 6 + index * 4;
        i32::from_be_bytes(payload[at..at + 4].try_into().unwrap()) as f32 / 100_000.0
    };
    let meta = crate::iso21496::IsoMeta {
        gain_map_min: vec![value(4); 3],
        gain_map_max: vec![value(6); 3],
        gamma: vec![value(8); 3],
        offset_sdr: vec![value(10); 3],
        offset_hdr: vec![value(12); 3],
        hdr_capacity_min: value(0),
        hdr_capacity_max: value(2),
        base_rendition_is_hdr: false,
        scale: value(2).max(1.0),
        channel_count: 3,
    };
    Ok(Some(crate::iso21496::make_imageio_native_tmap_payload(&meta)))
}

/// Replace the existing donor primary tiles without changing the primary ID
/// or the donor's iref/iinf graph. Photos' thumbnail renderer uses those
/// relationships to discover the private OPPO watermark overlay.
fn rewrite_primary_grid_in_place(
    source: &[u8],
    rgb: &[u8],
    width: u32,
    height: u32,
    oppo_native_tmap: bool,
) -> Result<Vec<u8>, String> {
    let top = isobmff::parse_boxes(source, 0, source.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;
    let parsed = isobmff::parse_source_meta(source)?;
    let (tile_payloads, hvcc) = encode_tiles(rgb, width, height)?;
    let primary = parsed.primary_id;
    let tile_ids = parsed
        .refs
        .iter()
        .find(|reference| reference.rtype == "dimg" && reference.from == primary)
        .map(|reference| reference.to.clone())
        .ok_or("donor HEIF primary is not an image grid")?;
    if tile_ids.len() != tile_payloads.len() {
        return Err(format!(
            "donor grid tile count differs: {} vs {}",
            tile_ids.len(),
            tile_payloads.len()
        ));
    }
    let tile_template = parsed
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == tile_ids[0])
        .map(|entry| entry.associations.clone())
        .ok_or("donor HEIF grid tile associations are missing")?;
    let hvcc_index = tile_template
        .iter()
        .find(|(index, _)| {
            parsed
                .props
                .get(index.saturating_sub(1) as usize)
                .map(|property| property.ptype == "hvcC")
                .unwrap_or(false)
        })
        .map(|(index, _)| *index)
        .ok_or("donor HEIF grid hvcC association is missing")?;
    let mut properties: Vec<Vec<u8>> = parsed
        .props
        .iter()
        .map(|property| property.raw.clone())
        .collect();
    properties[hvcc_index.saturating_sub(1) as usize] = isobmff::make_box(b"hvcC", &hvcc);
    let ipma = make_ipma_box(source, &meta, &parsed.ipma_entries, parsed.ipma_flags)?;
    let iprp = make_iprp_box(&properties, &ipma);
    let iinf_box = find_meta_child(source, &meta, b"iinf")?;
    let iinf = source[iinf_box.box_start..iinf_box.data_end].to_vec();
    let iref_version = find_meta_child(source, &meta, b"iref")
        .map(|box_| source[box_.data_start])
        .unwrap_or(0);
    let iref = isobmff::make_iref_full_box(iref_version, &parsed.refs);
    let idat_box = find_meta_child(source, &meta, b"idat")?;
    let mut idat = source[idat_box.box_start..idat_box.data_end].to_vec();

    let mut iloc_entries = parsed.iloc_entries.clone();
    if oppo_native_tmap {
        if let Some(native_tmap) = make_oppo_native_tmap(source, &parsed, &idat_box)? {
            let tmap_entry = iloc_entries
                .iter_mut()
                .find(|entry| {
                    parsed
                        .items
                        .iter()
                        .any(|item| item.item_id == entry.item_id && item.itype == "tmap")
                })
                .ok_or("OPPO output tmap item is missing")?;
            if tmap_entry.construction_method != 1 || tmap_entry.extents.len() != 1 {
                return Err("OPPO output tmap is not stored in idat".into());
            }
            let (offset, length) = tmap_entry.extents[0];
            if length != 62 {
                return Err(format!("OPPO output expects a 62-byte Apple tmap, got {length}"));
            }
            let start = 8usize
                .checked_add(offset as usize)
                .ok_or("OPPO tmap offset overflow")?;
            let end = start
                .checked_add(length as usize)
                .ok_or("OPPO tmap extent overflow")?;
            if end > idat.len() {
                return Err("OPPO tmap extent exceeds idat".into());
            }
            let mut idat_payload = idat[8..].to_vec();
            let payload_start = offset as usize;
            let payload_end = payload_start + length as usize;
            idat_payload.splice(payload_start..payload_end, native_tmap.iter().copied());
            idat = isobmff::make_box(b"idat", &idat_payload);
            tmap_entry.extents = vec![(offset, native_tmap.len() as u64)];
        }
    }
    for entry in &mut iloc_entries {
        if tile_ids.contains(&entry.item_id) {
            entry.extents = vec![(0, 0)];
        }
    }
    let placeholder = build_meta(
        source,
        &meta,
        &iinf,
        &iloc_entries,
        &iprp,
        &iref,
        &idat,
        primary,
    )?;
    let mdat_data_start = ftyp.size
        + top
            .iter()
            .filter(|box_| {
                box_.box_start > ftyp.box_start
                    && box_.box_start < mdat.box_start
                    && &box_.btype != b"meta"
            })
            .map(|box_| box_.size)
            .sum::<usize>()
        + placeholder.len()
        + 8;
    let offset_delta = mdat_data_start as i64 - mdat.data_start as i64;
    for entry in &mut iloc_entries {
        if !tile_ids.contains(&entry.item_id) && entry.construction_method == 0 {
            for (offset, _) in &mut entry.extents {
                *offset = (*offset as i64 + offset_delta) as u64;
            }
        }
    }
    let mut mdat_payload = source[mdat.data_start..mdat.data_end].to_vec();
    let mut tile_offset = mdat_data_start + mdat_payload.len();
    for (tile_id, payload) in tile_ids.iter().zip(&tile_payloads) {
        let offset = tile_offset as u64;
        iloc_entries
            .iter_mut()
            .find(|entry| entry.item_id == *tile_id)
            .ok_or("donor grid tile iloc is missing")?
            .extents = vec![(offset, payload.len() as u64)];
        mdat_payload.extend_from_slice(payload);
        tile_offset += payload.len();
    }
    let mdat_box = isobmff::make_box(b"mdat", &mdat_payload);
    let final_meta = build_meta(
        source,
        &meta,
        &iinf,
        &iloc_entries,
        &iprp,
        &iref,
        &idat,
        primary,
    )?;
    let mut output = Vec::with_capacity(source.len() + mdat_box.len());
    for box_ in &top {
        if box_.box_start == meta.box_start {
            output.extend_from_slice(&final_meta);
        } else if box_.box_start == mdat.box_start {
            output.extend_from_slice(&mdat_box);
        } else {
            output.extend_from_slice(&source[box_.box_start..box_.data_end]);
        }
    }
    Ok(output)
}

/// Detects uniform frame bands at the top and bottom of a donor raster.
///
/// Frame-style watermarks fill the bands with one solid colour (corner
/// sampled) plus sparse text; a row counts as frame when at least 85% of
/// sampled pixels stay within +/-6 of the frame colour. Returns the
/// `(y0, y1)` row ranges to copy from the donor.
pub fn detect_frame_bands(
    rgba: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<(u32, u32)>, String> {
    let stride = width as usize * 4;
    if rgba.len() < stride * height as usize || width < 64 || height < 64 {
        return Err("donor raster too small for frame detection".into());
    }
    // Sample corners slightly inside: extreme edge pixels can carry HEVC
    // reconstruction artifacts (observed greenish values on OPPO frames).
    let inset = 8u32;
    let corner = |x: u32, y: u32| -> [u8; 3] {
        let base = y as usize * stride + x as usize * 4;
        [rgba[base], rgba[base + 1], rgba[base + 2]]
    };
    let frame = corner(inset, inset);
    for (x, y) in [
        (width - 1 - inset, inset),
        (inset, height - 1 - inset),
        (width - 1 - inset, height - 1 - inset),
    ] {
        let other = corner(x, y);
        if (0..3).any(|c| other[c].abs_diff(frame[c]) > 6) {
            return Err("donor corners disagree; not a frame watermark".into());
        }
    }
    let row_is_frame = |y: u32| -> bool {
        let row = &rgba[y as usize * stride..(y as usize + 1) * stride];
        let mut sampled = 0u32;
        let mut uniform = 0u32;
        let mut x = 0usize;
        while x + 2 < row.len() {
            sampled += 1;
            if (0..3).all(|c| row[x + c].abs_diff(frame[c]) <= 6) {
                uniform += 1;
            }
            x += 16 * 4;
        }
        // Band text rows still measure >=0.8 uniform (sparse glyphs on a
        // solid frame); photo content stays below ~0.35. 60% separates both.
        sampled > 0 && uniform * 100 >= sampled * 60
    };
    // Tolerate a few decoder-artifact rows at the extreme edges: the last
    // rows of HEVC-decoded frames can be garbage (observed greenish rows on
    // OPPO frames), which would otherwise stop the band scan immediately.
    let mut top_edge = 0u32;
    while top_edge < 8 && !row_is_frame(top_edge) {
        top_edge += 1;
    }
    let mut top = top_edge;
    while top < height / 4 && row_is_frame(top) {
        top += 1;
    }
    let mut bottom_edge = height;
    while bottom_edge > height - 8 && !row_is_frame(bottom_edge - 1) {
        bottom_edge -= 1;
    }
    let mut bottom = bottom_edge;
    while bottom > height * 3 / 4 && row_is_frame(bottom - 1) {
        bottom -= 1;
    }
    let mut bands = Vec::new();
    if top - top_edge >= 16 {
        bands.push((0, top));
    }
    if bottom_edge - bottom >= 16 {
        bands.push((bottom, height));
    }
    if bands.is_empty() {
        return Err("no frame watermark bands detected in donor".into());
    }
    Ok(bands)
}

fn encode_tiles(rgb: &[u8], width: u32, height: u32) -> Result<(Vec<Vec<u8>>, Vec<u8>), String> {
    let cols = (width + TILE_SIZE - 1) / TILE_SIZE;
    let rows = (height + TILE_SIZE - 1) / TILE_SIZE;
    let mut padded = Vec::with_capacity((cols * rows) as usize);
    for row in 0..rows {
        for col in 0..cols {
            let x0 = col * TILE_SIZE;
            let y0 = row * TILE_SIZE;
            let tile_width = TILE_SIZE.min(width - x0);
            let tile_height = TILE_SIZE.min(height - y0);
            let mut tile = vec![0u8; (TILE_SIZE * TILE_SIZE * 3) as usize];
            for ty in 0..TILE_SIZE {
                let source_y = y0 + ty.min(tile_height - 1);
                for tx in 0..TILE_SIZE {
                    let source_x = x0 + tx.min(tile_width - 1);
                    let source = ((source_y * width + source_x) * 3) as usize;
                    let target = ((ty * TILE_SIZE + tx) * 3) as usize;
                    tile[target..target + 3].copy_from_slice(&rgb[source..source + 3]);
                }
            }
            padded.push(tile);
        }
    }
    let refs: Vec<&[u8]> = padded.iter().map(Vec::as_slice).collect();
    let streams = hevc::x265_encode_tiles_oppo_sdr(&refs, TILE_SIZE, TILE_SIZE, 3, true)
        .map_err(|error| format!("encode watermark HEVC tiles: {error}"))?;
    let hvcc = streams
        .first()
        .and_then(|stream| hevc::extract_hvcc_config_with_chroma(stream, 1))
        .ok_or("watermark HEVC encoder did not produce hvcC")?;
    let payloads = streams
        .iter()
        .map(|stream| {
            #[cfg(not(xdremux_ffmpeg_fallback))]
            let stream = hevc::drop_parameter_nals(stream);
            #[cfg(xdremux_ffmpeg_fallback)]
            let stream = stream.to_vec();
            hevc::hevc_byte_stream_to_length_prefixed(&stream)
        })
        .collect();
    Ok((payloads, hvcc))
}

fn rewrite_primary_grid(
    source: &[u8],
    rgb: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<u8>, String> {
    let top = isobmff::parse_boxes(source, 0, source.len());
    let ftyp = find(&top, b"ftyp")?;
    let meta = find(&top, b"meta")?;
    let mdat = find(&top, b"mdat")?;
    let parsed = isobmff::parse_source_meta(source)?;
    let (tile_payloads, hvcc) = encode_tiles(rgb, width, height)?;
    let old_primary = parsed.primary_id;
    let old_dimg = parsed
        .refs
        .iter()
        .find(|reference| reference.rtype == "dimg" && reference.from == old_primary)
        .ok_or("returned HEIF primary is not an image grid")?;
    let old_first_tile = *old_dimg
        .to
        .first()
        .ok_or("returned HEIF grid has no tiles")?;
    let tile_template = parsed
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == old_first_tile)
        .map(|entry| entry.associations.clone())
        .ok_or("returned HEIF tile associations are missing")?;
    let grid_template = parsed
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == old_primary)
        .map(|entry| entry.associations.clone())
        .ok_or("returned HEIF grid associations are missing")?;

    let first_new_id = parsed
        .items
        .iter()
        .map(|item| item.item_id)
        .max()
        .unwrap_or(1)
        + 1;
    let tile_ids: Vec<u32> = (0..tile_payloads.len())
        .map(|index| first_new_id + index as u32)
        .collect();
    let grid_id = first_new_id + tile_ids.len() as u32;
    let hvcc_index = parsed.props.len() as u32 + 1;
    let mut properties: Vec<Vec<u8>> = parsed
        .props
        .iter()
        .map(|property| property.raw.clone())
        .collect();
    properties.push(isobmff::make_box(b"hvcC", &hvcc));

    let mut tile_associations = tile_template;
    tile_associations.retain(|(index, _)| {
        parsed
            .props
            .get(index.saturating_sub(1) as usize)
            .map(|property| property.ptype != "hvcC")
            .unwrap_or(true)
    });
    tile_associations.push((hvcc_index, true));

    let mut infes: Vec<Vec<u8>> = parsed
        .items
        .iter()
        .map(|item| item.raw_infe.clone())
        .collect();
    infes.extend(
        tile_ids
            .iter()
            .map(|id| isobmff::make_infe_box(*id, "hvc1", 0)),
    );
    infes.push(isobmff::make_infe_box(grid_id, "grid", 0));
    let iinf_box = find_meta_child(source, &meta, b"iinf")?;
    let iinf = isobmff::make_iinf_box(source[iinf_box.data_start], &infes);

    let mut ipma_entries = parsed.ipma_entries.clone();
    ipma_entries.extend(tile_ids.iter().map(|id| IpmaEntry {
        item_id: *id,
        associations: tile_associations.clone(),
    }));
    ipma_entries.push(IpmaEntry {
        item_id: grid_id,
        associations: grid_template,
    });
    let ipma = make_ipma_box(source, &meta, &ipma_entries, parsed.ipma_flags)?;
    let iprp = make_iprp_box(&properties, &ipma);

    let idat_box = find_meta_child(source, &meta, b"idat")?;
    let old_idat = source[idat_box.data_start..idat_box.data_end].to_vec();
    let cols = (width + TILE_SIZE - 1) / TILE_SIZE;
    let rows = (height + TILE_SIZE - 1) / TILE_SIZE;
    let grid_box = isobmff::make_grid_box(TILE_SIZE, TILE_SIZE, rows, cols, width, height);
    let grid_payload = grid_box[8..].to_vec();
    let new_idat = {
        let mut data = old_idat.clone();
        data.extend_from_slice(&grid_payload);
        data
    };
    let idat = isobmff::make_box(b"idat", &new_idat);

    let iref_version = find_meta_child(source, &meta, b"iref")
        .map(|box_| source[box_.data_start])
        .unwrap_or(0);
    let mut refs = parsed.refs.clone();
    for reference in &mut refs {
        for item in &mut reference.to {
            if *item == old_primary {
                *item = grid_id;
            }
        }
    }
    refs.push(IrefEntry {
        rtype: "dimg".into(),
        from: grid_id,
        to: tile_ids.clone(),
    });
    let iref = isobmff::make_iref_full_box(iref_version, &refs);

    let mut mdat_payload = source[mdat.data_start..mdat.data_end].to_vec();
    let source_mdat_len = mdat_payload.len();
    for payload in &tile_payloads {
        mdat_payload.extend_from_slice(payload);
    }
    let mdat_box = isobmff::make_box(b"mdat", &mdat_payload);

    let mut iloc_entries = parsed.iloc_entries.clone();
    let grid_iloc = IlocEntry {
        item_id: grid_id,
        construction_method: 1,
        data_reference_index: 0,
        extents: vec![(old_idat.len() as u64, grid_payload.len() as u64)],
    };
    iloc_entries.extend(tile_ids.iter().map(|id| IlocEntry {
        item_id: *id,
        construction_method: 0,
        data_reference_index: 0,
        extents: vec![(0, 0)],
    }));
    iloc_entries.push(grid_iloc);

    let placeholder = build_meta(
        source,
        &meta,
        &iinf,
        &iloc_entries,
        &iprp,
        &iref,
        &idat,
        grid_id,
    )?;
    let mdat_data_start = ftyp.size
        + top
            .iter()
            .filter(|box_| {
                box_.box_start > ftyp.box_start
                    && box_.box_start < mdat.box_start
                    && &box_.btype != b"meta"
            })
            .map(|box_| box_.size)
            .sum::<usize>()
        + placeholder.len()
        + 8;
    let mut tile_offset = mdat_data_start + source_mdat_len;
    for entry in &mut iloc_entries {
        if entry.item_id == grid_id {
            continue;
        }
        if let Some(payload) = tile_payloads.get(
            tile_ids
                .iter()
                .position(|id| *id == entry.item_id)
                .unwrap_or(usize::MAX),
        ) {
            entry.extents = vec![(tile_offset as u64, payload.len() as u64)];
            tile_offset += payload.len();
        } else if entry.construction_method == 0 {
            for (offset, _) in &mut entry.extents {
                *offset = mdat_data_start as u64 + offset.saturating_sub(mdat.data_start as u64);
            }
        }
    }
    let final_meta = build_meta(
        source,
        &meta,
        &iinf,
        &iloc_entries,
        &iprp,
        &iref,
        &idat,
        grid_id,
    )?;

    let mut output = Vec::with_capacity(source.len() + mdat_box.len());
    for box_ in &top {
        if box_.box_start == meta.box_start {
            output.extend_from_slice(&final_meta);
        } else if box_.box_start == mdat.box_start {
            output.extend_from_slice(&mdat_box);
        } else {
            output.extend_from_slice(&source[box_.box_start..box_.data_end]);
        }
    }
    Ok(output)
}

fn find<'a>(boxes: &'a [BoxHeader], kind: &[u8; 4]) -> Result<&'a BoxHeader, String> {
    boxes
        .iter()
        .find(|box_| &box_.btype == kind)
        .ok_or_else(|| format!("{} missing", String::from_utf8_lossy(kind)))
}

fn find_meta_child<'a>(
    source: &[u8],
    meta: &BoxHeader,
    kind: &[u8; 4],
) -> Result<BoxHeader, String> {
    isobmff::parse_boxes(source, meta.data_start + 4, meta.data_end)
        .into_iter()
        .find(|box_| &box_.btype == kind)
        .ok_or_else(|| format!("meta child {} missing", String::from_utf8_lossy(kind)))
}

fn make_ipma_box(
    source: &[u8],
    meta: &BoxHeader,
    entries: &[IpmaEntry],
    flags: u32,
) -> Result<Vec<u8>, String> {
    let iprp = find_meta_child(source, meta, b"iprp")?;
    let ipma = isobmff::parse_boxes(source, iprp.data_start, iprp.data_end)
        .into_iter()
        .find(|box_| &box_.btype == b"ipma")
        .ok_or("ipma missing")?;
    let version = source[ipma.data_start];
    let mut payload = vec![
        version,
        ((flags >> 16) & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
        (flags & 0xff) as u8,
    ];
    isobmff::write_u32be(entries.len() as u32, &mut payload);
    for entry in entries {
        payload.extend_from_slice(&isobmff::make_ipma_entry(
            entry.item_id,
            &entry.associations,
            flags,
        ));
    }
    Ok(isobmff::make_box(b"ipma", &payload))
}

fn make_iprp_box(properties: &[Vec<u8>], ipma: &[u8]) -> Vec<u8> {
    let ipco_payload: Vec<u8> = properties
        .iter()
        .flat_map(|property| property.clone())
        .collect();
    let ipco = isobmff::make_box(b"ipco", &ipco_payload);
    let mut payload = ipco;
    payload.extend_from_slice(ipma);
    isobmff::make_box(b"iprp", &payload)
}

fn build_meta(
    source: &[u8],
    meta: &BoxHeader,
    iinf: &[u8],
    iloc_entries: &[IlocEntry],
    iprp: &[u8],
    iref: &[u8],
    idat: &[u8],
    primary_id: u32,
) -> Result<Vec<u8>, String> {
    let kids = isobmff::parse_boxes(source, meta.data_start + 4, meta.data_end);
    let pitm = find_meta_child(source, meta, b"pitm")?;
    let iloc = isobmff::make_iloc_box(iloc_entries);
    let pitm_box = isobmff::make_pitm_box(source[pitm.data_start], primary_id);
    let mut payload = source[meta.data_start..meta.data_start + 4].to_vec();
    let mut saw_iref = false;
    let mut saw_idat = false;
    for kid in kids {
        let replacement: &[u8] = match &kid.btype {
            b"pitm" => &pitm_box,
            b"iinf" => iinf,
            b"iloc" => &iloc,
            b"iprp" => iprp,
            b"iref" => {
                saw_iref = true;
                iref
            }
            b"idat" => {
                saw_idat = true;
                idat
            }
            // The in-place primary rewrite keeps the existing item IDs;
            // dropping this group makes Photos expose the gain map separately.
            b"grpl" => &source[kid.box_start..kid.data_end],
            _ => &source[kid.box_start..kid.data_end],
        };
        payload.extend_from_slice(replacement);
    }
    if !saw_iref {
        payload.extend_from_slice(iref);
    }
    if !saw_idat {
        payload.extend_from_slice(idat);
    }
    Ok(isobmff::make_box(b"meta", &payload))
}
