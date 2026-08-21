//! Pure-Rust visible watermark restoration for returned HEIF photos.
//!
//! The primary image is decoded with heif-oxide, the donor's reserved OPPO
//! canvas is copied over the returned raster, and a new primary ImageGrid is
//! appended while the returned gain-map graph and metadata remain intact.

use crate::container;
use crate::hevc;
use crate::isobmff::{self, BoxHeader, IlocEntry, IpmaEntry, IrefEntry};

const TILE_SIZE: u32 = 512;

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
    let stride = returned_image.width as usize * 4;
    match container::watermark_canvas_rect(donor, donor_image.width, donor_image.height) {
        Ok((x, y, width, height)) => {
            for row in y..y + height {
                let start = row as usize * stride + x as usize * 4;
                let end = start + width as usize * 4;
                returned_rgba[start..end].copy_from_slice(&donor_rgba[start..end]);
            }
        }
        Err(payload_error) => {
            // Frame-style watermarks (e.g. Hasselblad master-mode borders)
            // carry no separate PNG payload: the frame is baked into the
            // donor raster. Detect the uniform frame bands and copy them.
            let bands = detect_frame_bands(
                &donor_rgba,
                donor_image.width,
                donor_image.height,
            )
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
    let rgb: Vec<u8> = returned_rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().copied())
        .collect();
    rewrite_primary_grid(returned, &rgb, returned_image.width, returned_image.height)
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
            b"grpl" => continue,
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
