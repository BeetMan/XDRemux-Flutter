//! Minimal HEIC container builder — encode RGB frames into a single-item
//! HEVC HEIC. Foundation of the full re-encode path (Phase 2a): any input
//! (JPEG, foreign HEIC) is decoded to frames and rebuilt into a container
//! in our proven format, after which the styles contract attaches cleanly.
//!
//! v1 layout:
//!   ftyp(heic/mif1/miaf) + meta{hdlr(pict), pitm, iinf(hvc1 + Exif),
//!   iref(Exif cdsc→primary), iprp{ipco(ispe,hvcC,pixi,colr), ipma}, iloc}
//!   + mdat(image + Exif payload)

use crate::hevc::{
    drop_parameter_nals, extract_hvcc_config_with_chroma, hevc_byte_stream_to_length_prefixed,
    x265_encode_tiles,
};
use crate::isobmff;

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
    let mut payload = vec![0u8; 4]; // version + flags
    payload.extend_from_slice(&0u32.to_be_bytes()); // pre_defined
    payload.extend_from_slice(b"pict");
    payload.extend_from_slice(&[0u8; 12]); // reserved
    payload.push(0); // name (empty)
    make_box(b"hdlr", &payload)
}

fn make_pitm(primary: u16) -> Vec<u8> {
    let mut payload = vec![0u8, 0, 0, 0];
    payload.extend_from_slice(&primary.to_be_bytes());
    make_box(b"pitm", &payload)
}

fn make_colr_sdr() -> Vec<u8> {
    // nclx: BT.709 primaries, sRGB transfer, BT.601 matrix, limited range
    let mut payload = Vec::new();
    payload.extend_from_slice(b"nclx");
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&13u16.to_be_bytes());
    payload.extend_from_slice(&6u16.to_be_bytes());
    payload.push(0x00);
    make_box(b"colr", &payload)
}

/// Minimal Exif item payload: [u32=6]["Exif\0\0"][TIFF: IFD0 → empty ExifIFD].
/// The styles attach merges the Apple maker note into it afterwards.
fn make_exif_payload() -> Vec<u8> {
    let mut p: Vec<u8> = 6u32.to_be_bytes().to_vec();
    p.extend_from_slice(b"Exif\0\0");
    let mut tiff: Vec<u8> = Vec::new();
    tiff.extend_from_slice(b"MM\0*\0\0\0\x08"); // MM, magic 42, IFD0@8
    tiff.extend_from_slice(&1u16.to_be_bytes()); // IFD0: 1 entry
    tiff.extend_from_slice(&0x8769u16.to_be_bytes()); // ExifIFD pointer
    tiff.extend_from_slice(&4u16.to_be_bytes()); // LONG
    tiff.extend_from_slice(&1u32.to_be_bytes()); // count 1
    tiff.extend_from_slice(&26u32.to_be_bytes()); // ExifIFD at 26
    tiff.extend_from_slice(&0u32.to_be_bytes()); // IFD0 next
    tiff.extend_from_slice(&0u16.to_be_bytes()); // ExifIFD: 0 entries
    tiff.extend_from_slice(&0u32.to_be_bytes()); // ExifIFD next
    p.extend_from_slice(&tiff);
    p
}

/// Build a single-item HEIC from an RGB frame (3 bytes/px, row-major).
/// Item 1 = the HEVC image, item 2 = a minimal Exif payload.
pub fn build_heic_from_rgb(rgb: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    if (width as usize * height as usize * 3) != rgb.len() {
        return Err(format!("rgb size {} != {}x{}x3", rgb.len(), width, height));
    }

    // ---- encode ----------------------------------------------------------
    let refs: Vec<&[u8]> = vec![rgb];
    let stream = x265_encode_tiles(&refs, width, height, 3, true)
        .map_err(|e| format!("HEVC encode: {e}"))?
        .into_iter()
        .next()
        .ok_or("encode produced no stream")?;
    let hvcc = extract_hvcc_config_with_chroma(&stream, 1).ok_or("hvcC extraction failed")?;
    let idr = drop_parameter_nals(&stream);
    let item_data = hevc_byte_stream_to_length_prefixed(&idr);

    // ---- ipco + ipma + iprp ----------------------------------------------
    let ispe = isobmff::make_ispe_box(width, height);
    let hvcc_box = make_box(b"hvcC", &hvcc);
    let pixi = isobmff::PIXI_RGB8_BOX;
    let colr = make_colr_sdr();
    let mut ipco_payload: Vec<u8> = Vec::new();
    for p in [&ispe, &hvcc_box, pixi, &colr] {
        ipco_payload.extend_from_slice(p);
    }
    let ipco = make_box(b"ipco", &ipco_payload);
    let mut ipma_payload = vec![0u8, 0, 0, 0]; // ver0, flags0 (u16 ids, 1-byte assocs)
    ipma_payload.extend_from_slice(&1u32.to_be_bytes());
    ipma_payload.extend_from_slice(&isobmff::make_ipma_entry(
        1,
        &[(1, true), (2, true), (3, false), (4, false)],
        0,
    ));
    let ipma = make_box(b"ipma", &ipma_payload);
    let iprp = make_box(b"iprp", &[ipco, ipma].concat());

    let dinf = {
        let mut dref: Vec<u8> = vec![0u8, 0, 0, 0]; // version + flags
        dref.extend_from_slice(&1u32.to_be_bytes()); // entry count
        let mut url = vec![0u8, 0, 0, 1]; // 'url ' flags=1 → self-contained
        dref.extend_from_slice(&make_box(b"url ", &url));
        make_box(b"dinf", &[make_box(b"dref", &dref)].concat())
    };
    // ---- static meta children --------------------------------------------
    let hdlr = make_hdlr();
    let pitm = make_pitm(1);
    let iinf = {
        let mut body = vec![0u8, 0, 0, 0];
        body.extend_from_slice(&2u16.to_be_bytes());
        body.extend_from_slice(&isobmff::make_infe_box(1, "hvc1", 0));
        body.extend_from_slice(&isobmff::make_infe_box(2, "Exif", 1)); // hidden
        make_box(b"iinf", &body)
    };

    // ---- iref: Exif item cdsc → primary ----------------------------------
    let mut cdsc: Vec<u8> = Vec::new();
    cdsc.extend_from_slice(&2u16.to_be_bytes()); // from = Exif item
    cdsc.extend_from_slice(&1u16.to_be_bytes()); // to count
    cdsc.extend_from_slice(&1u16.to_be_bytes()); // to = primary
    let iref = make_box(b"iref", &[make_box(b"cdsc", &cdsc)].concat());

    let exif_payload = make_exif_payload();

    // ---- layout (offsets are absolute file offsets) -----------------------
    let ftyp = make_ftyp();
    let ftyp_len = ftyp.len();
    let iloc_box = 48usize; // 8 hdr + 4 vflags + 2 sizes + 2 count + 2×16B entries
    let meta_size = 8 + 4 + hdlr.len() + dinf.len() + pitm.len() + iinf.len() + iref.len() + iprp.len() + iloc_box;
    let mdat_off = ftyp_len + meta_size;
    let item1_off = mdat_off + 8; // after the mdat box header
    let item2_off = item1_off + item_data.len();

    // ---- iloc (2 entries, ver1) ------------------------------------------
    let mut iloc_payload: Vec<u8> = vec![1u8, 0, 0, 0, 0x44, 0x00];
    iloc_payload.extend_from_slice(&2u16.to_be_bytes());
    // entry 1
    iloc_payload.extend_from_slice(&1u16.to_be_bytes());
    iloc_payload.extend_from_slice(&0u16.to_be_bytes()); // construction method
    iloc_payload.extend_from_slice(&0u16.to_be_bytes()); // data ref index
    iloc_payload.extend_from_slice(&1u16.to_be_bytes()); // extent count
    iloc_payload.extend_from_slice(&(item1_off as u32).to_be_bytes());
    iloc_payload.extend_from_slice(&(item_data.len() as u32).to_be_bytes());
    // entry 2
    iloc_payload.extend_from_slice(&2u16.to_be_bytes());
    iloc_payload.extend_from_slice(&0u16.to_be_bytes());
    iloc_payload.extend_from_slice(&0u16.to_be_bytes());
    iloc_payload.extend_from_slice(&1u16.to_be_bytes());
    iloc_payload.extend_from_slice(&(item2_off as u32).to_be_bytes());
    iloc_payload.extend_from_slice(&(exif_payload.len() as u32).to_be_bytes());
    let iloc = make_box(b"iloc", &iloc_payload);
    eprintln!("DBG item_data={} exif={} iloc_box={} mdat_off={} item1_off={} item2_off={} meta_size={}",
        item_data.len(), exif_payload.len(), iloc_box, mdat_off, item1_off, item2_off, meta_size);

    // ---- meta --------------------------------------------------------------
    let mut meta_body: Vec<u8> = vec![0u8, 0, 0, 0];
    meta_body.extend_from_slice(&hdlr);
    meta_body.extend_from_slice(&dinf);
    meta_body.extend_from_slice(&pitm);
    meta_body.extend_from_slice(&iinf);
    meta_body.extend_from_slice(&iref);
    meta_body.extend_from_slice(&iprp);
    meta_body.extend_from_slice(&iloc);
    let meta = make_box(b"meta", &meta_body);

    // ---- mdat ---------------------------------------------------------------
    let mut mdat: Vec<u8> = Vec::new();
    let total_mdat = 8 + item_data.len() + exif_payload.len();
    mdat.extend_from_slice(&(total_mdat as u32).to_be_bytes());
    mdat.extend_from_slice(b"mdat");
    eprintln!("DBG mdat declared={} actual_payload={}", total_mdat - 8, mdat.len() - 8);
    mdat.extend_from_slice(&item_data);
    mdat.extend_from_slice(&exif_payload);

    // ---- assemble ------------------------------------------------------------
    let mut out: Vec<u8> = Vec::with_capacity(ftyp_len + meta.len() + total_mdat);
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&meta);
    out.extend_from_slice(&mdat);
    Ok(out)
}
