//! Dump one HEIF item payload by id, with its decoder config prepended so the
//! stream is directly ffmpeg-decodable (research tool for matte extraction).
fn main() {
    let path = std::env::args().nth(1).expect("path");
    let id: u32 = std::env::args().nth(2).expect("item id").parse().expect("id");
    let out = std::env::args().nth(3).expect("out");
    let with_params = std::env::args().nth(4).map(|s| s != "raw").unwrap_or(true);
    let d = std::fs::read(&path).unwrap();
    let m = xdremux_core::isobmff::parse_source_meta(&d).expect("meta");
    let e = m
        .iloc_entries
        .iter()
        .find(|e| e.item_id == id)
        .unwrap_or_else(|| panic!("item {id} not found"));
    let mut blob = Vec::new();
    for (off, len) in &e.extents {
        let s = *off as usize;
        blob.extend_from_slice(&d[s..s + *len as usize]);
    }

    // hvcC for THIS item, resolved through ipma (the file's first hvcC belongs
    // to the primary tiles and would decode at the wrong geometry).
    let hvcc = m.ipma_entries.iter().find(|e| e.item_id == id).and_then(|e| {
        e.associations.iter().find_map(|(idx, _)| {
            m.props
                .iter()
                .find(|p| p.index == *idx && p.ptype == "hvcC")
                .map(|p| p.raw.clone())
        })
    });

    let mut stream = Vec::new();
    if with_params {
        if let Some(raw) = &hvcc {
            for nal in hvcc_parameter_sets(&raw[8..]) {
                stream.extend_from_slice(&[0, 0, 0, 1]);
                stream.extend_from_slice(nal);
            }
        }
    }
    // Payload is length-prefixed NALs -> byte-stream.
    let mut i = 0usize;
    while i + 4 <= blob.len() {
        let l = u32::from_be_bytes(blob[i..i + 4].try_into().unwrap()) as usize;
        i += 4;
        if l == 0 || i + l > blob.len() {
            break;
        }
        stream.extend_from_slice(&[0, 0, 0, 1]);
        stream.extend_from_slice(&blob[i..i + l]);
        i += l;
    }
    if with_params && hvcc.is_some() {
        std::fs::write(&out, &stream).unwrap();
    } else {
        std::fs::write(&out, &blob).unwrap();
    }
    println!(
        "item {id} -> {out}: payload {}B, hvcC {}",
        blob.len(),
        if hvcc.is_some() { "matched" } else { "MISSING" }
    );
}

/// VPS/SPS/PPS NAL units out of an hvcC payload.
fn hvcc_parameter_sets(p: &[u8]) -> Vec<&[u8]> {
    if p.len() < 23 {
        return Vec::new();
    }
    let arrays = p[22] as usize;
    let mut at = 23usize;
    let mut out = Vec::new();
    for _ in 0..arrays {
        if at + 3 > p.len() {
            break;
        }
        let n = u16::from_be_bytes(p[at + 1..at + 3].try_into().unwrap()) as usize;
        at += 3;
        for _ in 0..n {
            if at + 2 > p.len() {
                break;
            }
            let l = u16::from_be_bytes(p[at..at + 2].try_into().unwrap()) as usize;
            at += 2;
            if at + l > p.len() {
                break;
            }
            out.push(&p[at..at + l]);
            at += l;
        }
    }
    out
}
