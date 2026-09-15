//! Grid-based HEIC container builder — encode RGB frames into a tiled HEIC
//! (primary grid + hvc1 tile items + shared hvcC/ispe + Exif item), matching
//! the structure the styles pipeline (styles_native / PS3 attach) expects.
//!
//! This is the foundation of the full re-encode path (Phase 2a): any input
//! (JPEG, foreign HEIC — decoded Dart-side) is rebuilt into a container in
//! our proven format, after which the styles contract attaches cleanly.

use crate::hevc::{
    drop_parameter_nals, extract_hvcc_config_with_chroma, hevc_byte_stream_to_length_prefixed,
    x265_encode_tiles,
};
use crate::isobmff;

const TILE: u32 = 512;

fn make_box(btype: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + payload.len());
    out.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    out.extend_from_slice(btype);
    out.extend_from_slice(payload);
    out
}

fn make_ftyp() -> Vec<u8> {
    let mut payload = Vec::new();
    payload.extend_from_slice(b"heic");
    payload.extend_from_slice(&0u32.to_be_bytes());
    for b in [b"mif1", b"heic", b"miaf"] {
        payload.extend_from_slice(b);
    }
    make_box(b"ftyp", &payload)
}

fn make_hdlr() -> Vec<u8> {
    let mut payload = vec![0u8; 4];
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(b"pict");
    payload.extend_from_slice(&[0u8; 12]);
    payload.push(0);
    make_box(b"hdlr", &payload)
}

fn make_pitm(primary: u16) -> Vec<u8> {
    let mut payload = vec![0u8, 0, 0, 0];
    payload.extend_from_slice(&primary.to_be_bytes());
    make_box(b"pitm", &payload)
}

fn make_colr_sdr() -> Vec<u8> {
    let mut payload = Vec::new();
    payload.extend_from_slice(b"nclx");
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&13u16.to_be_bytes());
    payload.extend_from_slice(&6u16.to_be_bytes());
    payload.push(0x00);
    make_box(b"colr", &payload)
}

/// Minimal Exif item payload: [u32=6]["Exif\0\0"][TIFF: IFD0 → empty ExifIFD].
pub fn make_exif_payload() -> Vec<u8> {
    let mut p: Vec<u8> = 6u32.to_be_bytes().to_vec();
    p.extend_from_slice(b"Exif\0\0");
    let mut tiff: Vec<u8> = Vec::new();
    tiff.extend_from_slice(b"MM\0*\0\0\0\x08");
    tiff.extend_from_slice(&1u16.to_be_bytes());
    tiff.extend_from_slice(&0x8769u16.to_be_bytes());
    tiff.extend_from_slice(&4u16.to_be_bytes());
    tiff.extend_from_slice(&1u32.to_be_bytes());
    tiff.extend_from_slice(&26u32.to_be_bytes());
    tiff.extend_from_slice(&0u32.to_be_bytes());
    tiff.extend_from_slice(&0u16.to_be_bytes());
    tiff.extend_from_slice(&0u32.to_be_bytes());
    p.extend_from_slice(&tiff);
    p
}

pub struct GridContainer {
    pub data: Vec<u8>,
    pub tile_streams: Vec<Vec<u8>>, // length-prefixed hvc1 tile data (for re-use)
    pub cols: u32,
    pub rows: u32,
    pub width: u32,
    pub height: u32,
}

/// Build a tiled HEIC from an RGB frame (3 bytes/px, row-major).
/// Tiles are `TILE`-square; the image is zero-padded to tile multiples and
/// the grid's output dimensions crop back to the true size.
pub fn build_heic_grid(rgb: &[u8], width: u32, height: u32, with_exif: bool) -> Result<GridContainer, String> {
    let cols = (width + TILE - 1) / TILE;
    let rows = (height + TILE - 1) / TILE;
    let padded_w = cols * TILE;
    let padded_h = rows * TILE;
    let tile_count = (cols * rows) as usize;

    // pad RGB to padded_w × padded_h
    let mut padded = vec![0u8; (padded_w * padded_h * 3) as usize];
    for y in 0..height as usize {
        let src = y * width as usize * 3;
        let dst = y * padded_w as usize * 3;
        padded[dst..dst + width as usize * 3].copy_from_slice(&rgb[src..src + width as usize * 3]);
    }

    // ---- encode tiles ----------------------------------------------------
    let mut tile_encoded: Vec<Vec<u8>> = Vec::with_capacity(tile_count);
    let mut hvcc: Vec<u8> = Vec::new();
    for r in 0..rows {
        for c in 0..cols {
            let mut tile_rgb: Vec<u8> = Vec::with_capacity((TILE * TILE * 3) as usize);
            for y in 0..TILE {
                let sy = (r * TILE + y) as usize;
                let sx = (c * TILE) as usize;
                let base = sy * padded_w as usize * 3 + sx * 3;
                tile_rgb.extend_from_slice(&padded[base..base + TILE as usize * 3]);
            }
            let refs: Vec<&[u8]> = vec![&tile_rgb];
            let stream = x265_encode_tiles(&refs, TILE, TILE, 3, true)
                .map_err(|e| format!("tile encode: {e}"))?
                .into_iter()
                .next()
                .ok_or("tile encode produced no stream")?;
            if hvcc.is_empty() {
                hvcc = extract_hvcc_config_with_chroma(&stream, 1)
                    .ok_or("tile hvcC extraction failed")?;
            }
            let idr = drop_parameter_nals(&stream);
            tile_encoded.push(hevc_byte_stream_to_length_prefixed(&idr));
        }
    }

    // ---- item ids ----------------------------------------------------------
    // 1 = grid (primary), 2 = Exif, 3.. = tiles
    let first_tile_id: u32 = 3;
    let tile_ids: Vec<u32> = (0..tile_count as u32).map(|i| first_tile_id + i).collect();
    let exif_id: u16 = 2;

    // ---- ipco (shared props for tiles + grid props) ------------------------
    // tile props: hvcC(1), ispe(TILE,TILE)(2), pixi(3)
    // grid props: ispe(w,h)(4), colr(5), pixi(6)
    let hvcc_box = make_box(b"hvcC", &hvcc);
    let ispe_tile = isobmff::make_ispe_box(TILE, TILE);
    let ispe_grid = isobmff::make_ispe_box(width, height);
    let colr = make_colr_sdr();
    let mut ipco_payload: Vec<u8> = Vec::new();
    let mut idx = 0u32;
    let mut push_prop = |raw: &[u8], idx: &mut u32, ipco_payload: &mut Vec<u8>| -> u32 {
        let this = *idx;
        *idx += 1;
        ipco_payload.extend_from_slice(raw);
        this
    };
    let hvcc_idx = push_prop(&hvcc_box, &mut idx, &mut ipco_payload);
    let ispe_tile_idx = push_prop(&ispe_tile, &mut idx, &mut ipco_payload);
    let pixi_idx = push_prop(isobmff::PIXI_RGB8_BOX, &mut idx, &mut ipco_payload);
    let ispe_grid_idx = push_prop(&ispe_grid, &mut idx, &mut ipco_payload);
    let colr_idx = push_prop(&colr, &mut idx, &mut ipco_payload);
    let pixi_grid_idx = push_prop(isobmff::PIXI_RGB8_BOX, &mut idx, &mut ipco_payload);
    let ipco = make_box(b"ipco", &ipco_payload);

    // ---- ipma --------------------------------------------------------------
    // item 1 (grid): ispe_grid(essential), colr, pixi_grid
    // item 2 (Exif): none
    // tiles: hvcC(essential), ispe_tile(essential), pixi
    let mut ipma_payload = vec![0u8, 0, 0, 0]; // ver0, flags0
    ipma_payload.extend_from_slice(&(2 + tile_count as u32).to_be_bytes());
    // grid
    ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(
        1,
        &[(ispe_grid_idx, true), (colr_idx, false), (pixi_grid_idx, false)],
        0,
    ));
    // Exif: no associations — emit an entry with 0 assocs? spec allows count 0.
    ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(exif_id as u32, &[], 0));
    // tiles
    for &id in &tile_ids {
        ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(
            id,
            &[(hvcc_idx, true), (ispe_tile_idx, true), (pixi_idx, false)],
            0,
        ));
    }
    let ipma = make_box(b"ipma", &ipma_payload);
    let iprp = make_box(b"iprp", &[ipco, ipma].concat());

    // ---- iinf --------------------------------------------------------------
    let mut iinf_body = vec![0u8, 0, 0, 0];
    let item_total = (if with_exif { 2u32 } else { 1u32 }) + tile_count as u32;
    iinf_body.extend_from_slice(&(item_total).to_be_bytes()[..2]);
    iinf_body.extend_from_slice(&isobmff::make_infe_box(1, "grid", 0));
    if with_exif {
        iinf_body.extend_from_slice(&isobmff::make_infe_box(exif_id as u32, "Exif", 1));
    }
    for &id in &tile_ids {
        iinf_body.extend_from_slice(&isobmff::make_infe_box(id as u32, "hvc1", 1)); // hidden tile
    }
    let iinf = make_box(b"iinf", &iinf_body);

    // ---- grid item payload -------------------------------------------------
    // version(1)=0, flags(3)=0, rows_minus1(1), cols_minus1(1),
    // output_width(4), output_height(4)
    let mut grid_payload: Vec<u8> = vec![0u8, 0, 0, 0];
    grid_payload.push((rows - 1) as u8);
    grid_payload.push((cols - 1) as u8);
    grid_payload.extend_from_slice(&width.to_be_bytes());
    grid_payload.extend_from_slice(&height.to_be_bytes());

    // ---- iref: dimg grid→tiles + cdsc Exif→grid -----------------------------
    let mut iref_payload: Vec<u8> = vec![0u8]; // version 0
    {
        let mut dimg: Vec<u8> = Vec::new();
        dimg.extend_from_slice(&1u16.to_be_bytes()); // from = grid
        dimg.extend_from_slice(&(tile_count as u16).to_be_bytes());
        for &id in &tile_ids {
            dimg.extend_from_slice(&(id as u16).to_be_bytes());
        }
        iref_payload.extend_from_slice(&make_box(b"dimg", &dimg));
    }
    if with_exif {
        let mut cdsc: Vec<u8> = Vec::new();
        cdsc.extend_from_slice(&(exif_id as u16).to_be_bytes());
        cdsc.extend_from_slice(&1u16.to_be_bytes());
        cdsc.extend_from_slice(&1u16.to_be_bytes()); // to = grid (primary)
        iref_payload.extend_from_slice(&make_box(b"cdsc", &cdsc));
    }
    let iref = make_box(b"iref", &iref_payload);

    // ---- static meta children -------------------------------------------------
    let hdlr = make_hdlr();
    let pitm = make_pitm(1);
    let dinf = {
        let mut dref: Vec<u8> = vec![0u8, 0, 0, 0];
        dref.extend_from_slice(&1u32.to_be_bytes());
        let url = vec![0u8, 0, 0, 1];
        dref.extend_from_slice(&make_box(b"url ", &url));
        make_box(b"dinf", &[make_box(b"dref", &dref)].concat())
    };

    // ---- layout --------------------------------------------------------------
    let ftyp = make_ftyp();
    let ftyp_len = ftyp.len();
    let exif_payload = make_exif_payload();

    let grid_item_len = 8 + grid_payload.len();
    let tiles_data_len: usize = tile_encoded.iter().map(|t| t.len()).sum();
    let iloc_box = 8 + 4 + 2 + 2 + (2 + tile_count as usize) * 16;
    let meta_size = 8
        + 4
        + hdlr.len()
        + pitm.len()
        + iinf.len()
        + iref.len()
        + iprp.len()
        + iloc_box;
    let mdat_off = ftyp_len + meta_size;
    let mdat_hdr = 8usize;
    let grid_off = mdat_off + mdat_hdr;
    let mut cur = grid_off + grid_item_len;
    let mut tile_offs: Vec<u32> = Vec::with_capacity(tile_count);
    for t in &tile_encoded {
        tile_offs.push(cur as u32);
        cur += t.len();
    }
    let exif_off = cur as u32;
    cur += exif_payload.len();
    let _ = cur;

    // ---- iloc ------------------------------------------------------------------
    // entries: grid(cm0), Exif(cm0), tiles(cm0) — each 1 extent
    let entry_count = 2 + tile_count as u16;
    let mut iloc_payload: Vec<u8> = vec![1u8, 0, 0, 0, 0x44, 0x00];
    iloc_payload.extend_from_slice(&entry_count.to_be_bytes());
    // grid
    iloc_payload.extend_from_slice(&1u16.to_be_bytes());
    iloc_payload.extend_from_slice(&0u16.to_be_bytes());
    iloc_payload.extend_from_slice(&0u16.to_be_bytes());
    iloc_payload.extend_from_slice(&1u16.to_be_bytes());
    iloc_payload.extend_from_slice(&(grid_off as u32).to_be_bytes());
    iloc_payload.extend_from_slice(&(grid_item_len as u32).to_be_bytes());
    // Exif
    if with_exif {
        iloc_payload.extend_from_slice(&(exif_id as u16).to_be_bytes());
        iloc_payload.extend_from_slice(&0u16.to_be_bytes());
        iloc_payload.extend_from_slice(&0u16.to_be_bytes());
        iloc_payload.extend_from_slice(&1u16.to_be_bytes());
        iloc_payload.extend_from_slice(&(exif_off).to_be_bytes());
        iloc_payload.extend_from_slice(&(exif_payload.len() as u32).to_be_bytes());
    }
    // tiles
    for (i, t) in tile_encoded.iter().enumerate() {
        iloc_payload.extend_from_slice(&(tile_ids[i] as u16).to_be_bytes());
        iloc_payload.extend_from_slice(&0u16.to_be_bytes());
        iloc_payload.extend_from_slice(&0u16.to_be_bytes());
        iloc_payload.extend_from_slice(&1u16.to_be_bytes());
        iloc_payload.extend_from_slice(&(tile_offs[i]).to_be_bytes());
        iloc_payload.extend_from_slice(&(t.len() as u32).to_be_bytes());
    }
    let iloc = make_box(b"iloc", &iloc_payload);

    // ---- meta --------------------------------------------------------------------
    let mut meta_body: Vec<u8> = vec![0u8, 0, 0, 0];
    meta_body.extend_from_slice(&hdlr);
    meta_body.extend_from_slice(&dinf);
    meta_body.extend_from_slice(&pitm);
    meta_body.extend_from_slice(&iinf);
    meta_body.extend_from_slice(&iref);
    meta_body.extend_from_slice(&iprp);
    meta_body.extend_from_slice(&iloc);
    let meta = make_box(b"meta", &meta_body);

    // ---- mdat ----------------------------------------------------------------------
    let mut mdat: Vec<u8> = Vec::new();
    let mdat_content = grid_payload.len()
        + tiles_data_len
        + exif_payload.len();
    mdat.extend_from_slice(&((mdat_hdr + mdat_content) as u32).to_be_bytes());
    mdat.extend_from_slice(b"mdat");
    mdat.extend_from_slice(&grid_payload);
    for t in &tile_encoded {
        mdat.extend_from_slice(t);
    }
    mdat.extend_from_slice(&exif_payload);

    // ---- assemble ---------------------------------------------------------------------
    let mut out: Vec<u8> = Vec::with_capacity(ftyp_len + meta.len() + mdat.len());
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&meta);
    out.extend_from_slice(&mdat);

    Ok(GridContainer {
        data: out,
        tile_streams: tile_encoded,
        cols,
        rows,
        width,
        height,
    })
}
