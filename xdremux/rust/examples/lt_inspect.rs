// Inspect the Styles linear thumbnail item of a converted HEIC.
//
// Prints the item geometry and hvcC bit-depth fields, and optionally writes an
// Annex-B stream (hvcC parameter sets + the item's slice NAL) so ffprobe can
// confirm the profile:
//
//   lt_inspect <converted.heic> [thumbnail.hevc]
//
// Expected for the Main10 path: profile_idc=2, bitDepthLuma/Chroma=10.
use xdremux_core::isobmff;

/// Append one NAL unit as Annex-B (4-byte start code).
fn push_annex_b(out: &mut Vec<u8>, nal: &[u8]) {
    out.extend_from_slice(&[0, 0, 0, 1]);
    out.extend_from_slice(nal);
}

/// Expand the hvcC VPS/SPS/PPS arrays into Annex-B. `payload` is the hvcC
/// payload without the box header.
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
        position += 1; // array_completeness + NAL unit type
        let count = u16::from_be_bytes([payload[position], payload[position + 1]]) as usize;
        position += 2;
        for _ in 0..count {
            if position + 2 > payload.len() {
                break;
            }
            let length =
                u16::from_be_bytes([payload[position], payload[position + 1]]) as usize;
            position += 2;
            if position + length > payload.len() {
                break;
            }
            push_annex_b(out, &payload[position..position + length]);
            position += length;
            nals += 1;
        }
    }
    nals
}

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: lt_inspect <converted.heic> [out.hevc]");
    let out_path = args.next();
    let data = std::fs::read(&path).expect("read input");
    let meta = isobmff::parse_source_meta(&data).expect("parse meta");

    for item in &meta.items {
        let Some(associations) = meta
            .ipma_entries
            .iter()
            .find(|entry| entry.item_id == item.item_id)
        else {
            continue;
        };
        let mut is_linear_thumbnail = false;
        let mut hvcc_box: Option<&[u8]> = None;
        let mut dims: Option<(u32, u32)> = None;
        for (index, _) in &associations.associations {
            let Some(property) = meta.props.iter().find(|p| p.index == *index) else {
                continue;
            };
            match property.ptype.as_str() {
                "auxC" => {
                    if property
                        .raw
                        .windows(b"linearthumbnail".len())
                        .any(|window| window == b"linearthumbnail")
                    {
                        is_linear_thumbnail = true;
                    }
                }
                "hvcC" => hvcc_box = Some(&property.raw),
                "ispe" => dims = isobmff::ispe_dimensions(&property.raw).ok(),
                _ => {}
            }
        }
        if !is_linear_thumbnail {
            continue;
        }

        println!(
            "item={} type={} dims={:?} hvcC_box={}B",
            item.item_id,
            item.itype,
            dims,
            hvcc_box.map(|b| b.len()).unwrap_or(0)
        );

        let mut annex_b = Vec::new();
        if let Some(box_bytes) = hvcc_box {
            // PropertyInfo::raw includes the 8-byte box header.
            if box_bytes.len() > 8 && &box_bytes[4..8] == b"hvcC" {
                let payload = &box_bytes[8..];
                if payload.len() > 21 {
                    println!(
                        "  hvcC profile_idc={} bitDepthLuma={} bitDepthChroma={} \
                         chromaFormat={} lengthSize={}",
                        payload[1] & 0x1f,
                        payload[17] & 0x07,
                        payload[18] & 0x07,
                        payload[16] & 0x03,
                        (payload[21] & 0x03) + 1
                    );
                }
                let nals = push_hvcc_arrays(&mut annex_b, payload);
                println!("  hvcC parameter-set NALs={nals}");
            }
        }

        let extent = meta
            .iloc_entries
            .iter()
            .find(|entry| entry.item_id == item.item_id)
            .and_then(|entry| entry.extents.first().copied());
        let Some((offset, length)) = extent else {
            println!("  no iloc extent");
            continue;
        };
        let start = offset as usize;
        let end = start + length as usize;
        if end > data.len() {
            println!("  extent out of bounds");
            continue;
        }
        let payload = &data[start..end];
        let mut position = 0usize;
        let mut slice_nals = 0usize;
        while position + 4 <= payload.len() {
            let nal_length = u32::from_be_bytes(
                payload[position..position + 4].try_into().unwrap(),
            ) as usize;
            position += 4;
            if position + nal_length > payload.len() {
                println!("  truncated NAL at {position}");
                break;
            }
            push_annex_b(&mut annex_b, &payload[position..position + nal_length]);
            position += nal_length;
            slice_nals += 1;
        }
        println!(
            "  item_payload={}B slice_nals={} annexb={}B",
            payload.len(),
            slice_nals,
            annex_b.len()
        );
        if let Some(out_path) = &out_path {
            std::fs::write(out_path, &annex_b).expect("write annex-b");
            println!("  wrote {out_path}");
        }
    }
}
