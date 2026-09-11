use super::*;

fn packed_watermark() -> (Vec<u8>, Vec<u8>) {
    let mut tail = vec![0; 14185];
    tail[..4].copy_from_slice(&1f32.to_le_bytes());
    tail[4..19].copy_from_slice(b"hassel_style_1\0");
    let geometry = [
        4096f32,
        3072.,
        4608.,
        0.,
        0.,
        f32::from_bits(u32::MAX),
        0.,
        0.,
        3072.,
        4096.,
        0.,
        0.,
        4096.,
        3072.,
    ];
    for (i, v) in geometry.iter().enumerate() {
        tail[14129 + i * 4..14133 + i * 4].copy_from_slice(&v.to_le_bytes());
    }
    let mut crop = 1f32.to_le_bytes().to_vec();
    for v in [0u32, 0, 4096, 3072] {
        crop.extend(v.to_le_bytes());
    }
    (tail, crop)
}

#[test]
fn packed_watermark_sample_zero_asymmetric_bounds_and_bottom_padding() {
    let (tail, crop) = packed_watermark();
    let rect = parse_watermark_rect(&tail, (3072, 4608), (4096, 3072), 6, Some(&crop));
    assert_eq!(rect, Some((0, 0, 3072, 4096)));
    let placement = PortraitPlacement::new((3072, 4608), rect, (768, 1024));
    assert_eq!(placement.content, (0, 0, 1536, 2048));
    assert_eq!(placement.crop, (0, 0, 768, 1024));
    let (matte, w, h) = placement.place(&vec![255; 768 * 1024], 768, 1024);
    assert_eq!((w, h), (1536, 2304));
    assert!(matte[..1536 * 2048].iter().all(|&v| v == 255));
    assert!(matte[1536 * 2048..].iter().all(|&v| v == 0));
}

#[test]
fn packed_watermark_rejects_unknown_malformed_or_inconsistent_layouts() {
    let (tail, crop) = packed_watermark();
    let parse = |t: &[u8]| parse_watermark_rect(t, (3072, 4608), (4096, 3072), 6, Some(&crop));
    for (offset, value) in [
        (0, 2f32),
        (14153, -1.),
        (14157, f32::NAN),
        (14157, 1.), // unsupported nonzero origin, even though it fits the canvas
        (14161, 3072.5),
        (14165, 4609.),
        (14177, 4000.),
        (14133, 0.),
        (14141, 1.),
    ] {
        let mut bad = tail.clone();
        bad[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert_eq!(parse(&bad), None, "offset {offset}");
    }
    let mut style = tail.clone();
    style[16] = b'2';
    assert_eq!(parse(&style), None);
    assert_eq!(parse(&tail[..14184]), None);
    assert_eq!(parse(&tail[..100]), None);
    assert_eq!(
        parse_watermark_rect(&tail, (3072, 4608), (4096, 3072), 1, Some(&crop)),
        None
    );
    assert_eq!(
        parse_watermark_rect(&tail, (3072, 4608), (4096, 3072), 6, None),
        None
    );
    let mut bad_crop = crop.clone();
    bad_crop[4] = 1;
    assert_eq!(
        parse_watermark_rect(&tail, (3072, 4608), (4096, 3072), 6, Some(&bad_crop)),
        None
    );
    assert_eq!(
        parse_watermark_rect(&tail, (3072, 4608), (4000, 3000), 6, Some(&crop)),
        None
    );
    // A plausible unaligned rectangle without the known header is not a format.
    let mut arbitrary = vec![0; 101];
    arbitrary[81..97].copy_from_slice(&tail[14153..14169]);
    assert_eq!(parse(&arbitrary), None);
}

#[test]
fn aligned_legacy_watermark_symmetric_corners_remain_supported() {
    let tail: Vec<u8> = [1f32, 100., 200., 3100., 4400., 0.]
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .collect();
    assert_eq!(
        parse_watermark_rect(&tail, (3200, 4600), (4000, 3000), 6, None),
        Some((100, 200, 3000, 4200))
    );
}

#[test]
fn sample_focus_is_normalized_once_with_watermark_placement() {
    let placement = PortraitPlacement::new((3072, 4608), Some((0, 0, 3072, 4096)), (768, 1024));
    for (x, y) in [(1801., 1724.), (1471., 1823.)] {
        let focus = placement.focus(rotate_focus((x / 4096., y / 3072.), 1));
        assert!((focus.0 - (1. - y / 3072.)).abs() < 1e-12);
        assert!((focus.1 - x / 4608.).abs() < 1e-12);
        assert!(focus.0 > 0.4 && focus.1 > 0.3);
        let xmp = merge_focus_into_xmp(
            b"<rdf:RDF></rdf:RDF>",
            focus.0,
            focus.1,
            3072,
            4608,
            "2026:09:10 19:21:13",
        )
        .unwrap();
        let text = String::from_utf8(xmp).unwrap();
        assert!(text.contains(&format!("<stArea:x>{}</stArea:x>", focus.0)));
        assert!(text.contains(&format!("<stArea:y>{}</stArea:y>", focus.1)));
        assert!(text.contains("<stDim:h>4608</stDim:h>"));
    }
}

#[test]
fn inverse_cover_crop_focus_matches_raster_in_all_turns_and_padding() {
    // Landscape -> square uses central half of width. x=0.375 maps to 0.25,
    // not 0.4375 (the old multiplication-instead-of-division bug).
    let placement = PortraitPlacement::new((200, 200), None, (200, 100));
    assert_eq!(placement.crop, (50, 0, 100, 100));
    assert_eq!(placement.focus((0.375, 0.5)), (0.25, 0.5));
    assert_eq!(placement.focus((0., 1.)), (0., 1.));
    let vertical = PortraitPlacement::new((200, 200), None, (100, 200));
    assert_eq!(vertical.focus((0.5, 0.375)), (0.5, 0.25));
    for turns in 0..4 {
        let (w, h) = (200, 100);
        let mut plane = vec![0; w * h];
        plane[40 * w + 75] = 255;
        let (rotated, rw, rh) = rotate_plane(&plane, w, h, turns);
        let placement = PortraitPlacement::new((200, 200), None, (rw, rh));
        let (placed, cw, ch) = placement.place(&rotated, rw, rh);
        let point = placement.focus(rotate_focus((75.5 / w as f64, 40.5 / h as f64), turns));
        let ix = (point.0 * cw as f64).floor() as usize;
        let iy = (point.1 * ch as f64).floor() as usize;
        assert_eq!(placed[iy * cw as usize + ix], 255, "turns {turns}");
    }
    let padded = PortraitPlacement::new((400, 300), Some((100, 50, 200, 200)), (200, 100));
    assert_eq!(padded.focus((0.375, 0.5)), (0.375, 0.5));
}

#[test]
fn depth_and_upscaled_matte_share_identical_crop_window() {
    let placement = PortraitPlacement::new((200, 200), None, (201, 100));
    let mut depth = vec![0; 201 * 100];
    for y in 0..100 {
        depth[y * 201 + 50..y * 201 + 150].fill(255);
    }
    let mut matte = vec![0; 402 * 200];
    for y in 0..200 {
        matte[y * 402 + 100..y * 402 + 300].fill(255);
    }
    assert_eq!(
        placement.place(&depth, 201, 100),
        placement.place(&matte, 402, 200)
    );
}
