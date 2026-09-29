//! Grid-based HEIC container builder — encode RGB frames into a tiled HEIC
//! (primary grid + hvc1 tile items + shared hvcC/ispe + Exif item), matching
//! the structure the styles pipeline (styles_native / PS3 attach) expects.
//!
//! Two-pass: build meta with placeholder iloc offsets, measure, then patch.

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

pub struct GridContainer {
    pub data: Vec<u8>,
    pub cols: u32,
    pub rows: u32,
    pub width: u32,
    pub height: u32,
}

/// Build a tiled HEIC from an RGB frame (3 bytes/px, row-major).
pub fn build_heic_grid(rgb: &[u8], width: u32, height: u32) -> Result<GridContainer, String> {
    let cols = (width + TILE - 1) / TILE;
    let rows = (height + TILE - 1) / TILE;
    let padded_w = cols * TILE;
    let padded_h = rows * TILE;
    let tile_count = (cols * rows) as usize;

    // pad RGB
    let mut padded = vec![0u8; (padded_w * padded_h * 3) as usize];
    for y in 0..height as usize {
        let src = y * width as usize * 3;
        let dst = y * padded_w as usize * 3;
        padded[dst..dst + width as usize * 3].copy_from_slice(&rgb[src..src + width as usize * 3]);
    }

    // encode tiles
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

    // item ids: 1=grid(primary), 2=Exif, 3..=tiles
    let exif_id: u32 = 2;
    let first_tile: u32 = 3;
    let tile_ids: Vec<u32> = (0..tile_count as u32).map(|i| first_tile + i).collect();

    // grid payload
    let mut grid_payload: Vec<u8> = vec![0u8, 0, 0, 0];
    grid_payload.push((rows - 1) as u8);
    grid_payload.push((cols - 1) as u8);
    grid_payload.extend_from_slice(&width.to_be_bytes());
    grid_payload.extend_from_slice(&height.to_be_bytes());

    // mdat content: [grid_payload][tile0]...[tileN][exif_payload]
    let mut rel: usize = 0; // offsets relative to mdat content start
    let grid_rel = rel;
    rel += grid_payload.len();
    let mut tile_rels: Vec<usize> = Vec::with_capacity(tile_count);
    for t in &tile_encoded {
        tile_rels.push(rel);
        rel += t.len();
    }
    let exif_rel = rel;
    let exif_payload = {
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
    };
    let mdat_content_len = rel + exif_payload.len();

    // ---- meta children (iloc built last with real offsets) ----
    let hdlr = {
        let mut p = vec![0u8; 4];
        p.extend_from_slice(&0u32.to_be_bytes());
        p.extend_from_slice(b"pict");
        p.extend_from_slice(&[0u8; 12]);
        p.push(0);
        make_box(b"hdlr", &p)
    };
    let dinf = {
        let mut dref: Vec<u8> = vec![0u8, 0, 0, 0];
        dref.extend_from_slice(&1u32.to_be_bytes());
        let url = vec![0u8, 0, 0, 1];
        dref.extend_from_slice(&make_box(b"url ", &url));
        make_box(b"dinf", &[make_box(b"dref", &dref)].concat())
    };
    let pitm = {
        let mut p = vec![0u8, 0, 0, 0];
        p.extend_from_slice(&1u16.to_be_bytes());
        make_box(b"pitm", &p)
    };
    let iinf = {
        let mut body = vec![0u8, 0, 0, 0];
        body.extend_from_slice(&(2 + tile_count as u32).to_be_bytes()[..2]);
        body.extend_from_slice(&isobmff::make_infe_box(1, "grid", 0));
        body.extend_from_slice(&isobmff::make_infe_box(exif_id, "Exif", 1));
        for &id in &tile_ids {
            body.extend_from_slice(&isobmff::make_infe_box(id, "hvc1", 1));
        }
        make_box(b"iinf", &body)
    };
    let iref = {
        let mut payload: Vec<u8> = vec![0u8, 0, 0, 0]; // version 0 + flags 0
        let mut dimg: Vec<u8> = Vec::new();
        dimg.extend_from_slice(&1u16.to_be_bytes());
        dimg.extend_from_slice(&(tile_count as u16).to_be_bytes());
        for &id in &tile_ids {
            dimg.extend_from_slice(&(id as u16).to_be_bytes());
        }
        payload.extend_from_slice(&make_box(b"dimg", &dimg));
        let mut cdsc: Vec<u8> = Vec::new();
        cdsc.extend_from_slice(&(exif_id as u16).to_be_bytes());
        cdsc.extend_from_slice(&1u16.to_be_bytes());
        cdsc.extend_from_slice(&1u16.to_be_bytes());
        payload.extend_from_slice(&make_box(b"cdsc", &cdsc));
        make_box(b"iref", &payload)
    };
    let colr = {
        let mut p = b"nclx".to_vec();
        p.extend_from_slice(&1u16.to_be_bytes());
        p.extend_from_slice(&13u16.to_be_bytes());
        p.extend_from_slice(&6u16.to_be_bytes());
        p.push(0x00);
        make_box(b"colr", &p)
    };
    let ispe_grid = isobmff::make_ispe_box(width, height);
    let ispe_tile = isobmff::make_ispe_box(TILE, TILE);
    let pixi = isobmff::PIXI_RGB8_BOX;
    // ipco: 1=ispe_grid, 2=ispe_tile, 3=pixi, 4=colr
    let hvcc_box = make_box(b"hvcC", &hvcc);
    // ipco: 1=ispe_grid, 2=hvcC, 3=ispe_tile, 4=pixi, 5=colr
    let ipco_payload: Vec<u8> = [
        ispe_grid.as_slice(),
        hvcc_box.as_slice(),
        ispe_tile.as_slice(),
        pixi,
        colr.as_slice(),
    ].concat();
    let ipco = make_box(b"ipco", &ipco_payload);
    let mut ipma_payload = vec![0u8, 0, 0, 0];
    ipma_payload.extend_from_slice(&(2 + tile_count as u32).to_be_bytes());
    // ImageIO pattern: ALL items share ALL properties
    let all_assocs: Vec<(u32, bool)> = vec![
        (1, true),  // ispe_grid
        (2, true),  // hvcC
        (3, true),  // ispe_tile
        (4, false), // pixi
        (5, false), // colr
    ];
    ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(1, &all_assocs, 0));
    ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(exif_id, &all_assocs, 0));
    for &id in &tile_ids {
        ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(id, &all_assocs, 0));
    }
    let ipma = make_box(b"ipma", &ipma_payload);
    let idat = make_box(b"idat", &[]);

    // ---- two-pass layout ----
    // mdat content: grid_payload | tile_encoded[0..n] | exif_payload
    // iloc entry offsets = absolute file offsets into mdat
    // meta children order: hdlr, dinf, pitm, iinf, iref, iprp, idat, iloc
    let iloc_size = 8 + 4 + 2 + 2 + (2 + tile_count) * 16;
    let iprp = make_box(b"iprp", &[ipco.as_slice(), ipma.as_slice()].concat());
    let mk_meta = |iloc_box: &Vec<u8>| -> Vec<u8> {
        let mut body = vec![0u8, 0, 0, 0];
        body.extend_from_slice(&hdlr);
        body.extend_from_slice(&dinf);
        body.extend_from_slice(&pitm);
        body.extend_from_slice(&iinf);
        body.extend_from_slice(&iref);
        body.extend_from_slice(&iprp);
        body.extend_from_slice(&idat);
        body.extend_from_slice(iloc_box);
        make_box(b"meta", &body)
    };

    // grid_payload is at mdat content start
    let grid_payload_len = grid_payload.len();
    let mk_iloc = |grid_abs: usize, tile_abs: &[usize], exif_abs: usize| -> Vec<u8> {
        let mut p: Vec<u8> = vec![1u8, 0, 0, 0, 0x44, 0x00];
        p.extend_from_slice(&(2 + tile_count as u16).to_be_bytes());
        // grid
        p.extend_from_slice(&1u16.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&1u16.to_be_bytes());
        p.extend_from_slice(&(grid_abs as u32).to_be_bytes());
        p.extend_from_slice(&(grid_payload_len as u32).to_be_bytes());
        // Exif
        p.extend_from_slice(&(exif_id as u16).to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&1u16.to_be_bytes());
        p.extend_from_slice(&(exif_abs as u32).to_be_bytes());
        p.extend_from_slice(&(exif_payload.len() as u32).to_be_bytes());
        // tiles
        for (i, t) in tile_encoded.iter().enumerate() {
            p.extend_from_slice(&(tile_ids[i] as u16).to_be_bytes());
            p.extend_from_slice(&0u16.to_be_bytes());
            p.extend_from_slice(&0u16.to_be_bytes());
            p.extend_from_slice(&1u16.to_be_bytes());
            p.extend_from_slice(&(tile_abs[i] as u32).to_be_bytes());
            p.extend_from_slice(&(t.len() as u32).to_be_bytes());
        }
        make_box(b"iloc", &p)
    };

    // pass 1: meta with dummy iloc offsets → measure size
    let iloc_p1 = mk_iloc(0, &[0usize; 40], 0);
    let meta_p1 = mk_meta(&iloc_p1);
    let ftyp_len = 28usize; // fixed: 4+4+4+4+4+4+4 = 28
    let meta_size = meta_p1.len();
    let mdat_off = ftyp_len + meta_size;
    let mdat_content = mdat_off + 8; // after mdat header
    let grid_abs = mdat_content;
    let mut tile_abs: Vec<usize> = Vec::with_capacity(tile_count);
    let mut cur = grid_abs + grid_payload_len;
    for t in &tile_encoded {
        tile_abs.push(cur);
        cur += t.len();
    }
    let exif_abs = cur;

    // pass 2: real iloc
    let iloc = mk_iloc(grid_abs, &tile_abs, exif_abs);
    let meta = mk_meta(&iloc);
    eprintln!("DBG meta_size={} actual={} iloc_size={} iloc_actual={} grid_payload={}",
        meta_size, meta.len(), iloc_size, iloc.len(), grid_payload.len());

    // ---- mdat ----
    let mut mdat: Vec<u8> = Vec::new();
    let mdat_size = 8 + mdat_content_len;
    mdat.extend_from_slice(&(mdat_size as u32).to_be_bytes());
    mdat.extend_from_slice(b"mdat");
    mdat.extend_from_slice(&grid_payload);
    for t in &tile_encoded {
        mdat.extend_from_slice(t);
    }
    mdat.extend_from_slice(&exif_payload);

    // ---- ftyp ----
    let mut ftyp_payload: Vec<u8> = Vec::new();
    ftyp_payload.extend_from_slice(b"heic");
    ftyp_payload.extend_from_slice(&0u32.to_be_bytes());
    for b in [b"mif1", b"heic", b"miaf"] {
        ftyp_payload.extend_from_slice(b);
    }
    let ftyp = make_box(b"ftyp", &ftyp_payload);

    // ---- assemble ----
    let mut out: Vec<u8> = Vec::with_capacity(ftyp.len() + meta.len() + mdat.len());
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&meta);
    out.extend_from_slice(&mdat);

    Ok(GridContainer {
        data: out,
        cols,
        rows,
        width,
        height,
    })
}
