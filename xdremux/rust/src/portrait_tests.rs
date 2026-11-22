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
fn src_image_base_maps_depth_by_plain_proportional_scaling() {
    // The packed Hasselblad watermark tail describes the OPPO primary
    // (3072x4608). Against the src.image storage frame (4096x3072) it must not
    // be applied: the aux canvas is the whole storage frame, so the depth plane
    // (1024x768, the same landscape storage orientation as the JPEG) covers it
    // at exactly 2x with no rotation.
    let (tail, crop) = packed_watermark();
    assert_eq!(
        parse_watermark_rect(&tail, (4096, 3072), (4096, 3072), 6, Some(&crop)),
        None
    );
    let placement = PortraitPlacement::new((4096, 3072), None, (1024, 768));
    assert_eq!(placement.content, (0, 0, 2048, 1536));
    assert_eq!(placement.crop, (0, 0, 1024, 768));
    let (placed, w, h) = placement.place(&[7u8; 1024 * 768], 1024, 768);
    assert_eq!((w, h), (2048, 1536));
    assert!(placed.iter().all(|&v| v == 7));
    assert_eq!(placement.focus((0.5, 0.5)), (0.5, 0.5));
    assert_eq!(placement.focus((0.25, 0.75)), (0.25, 0.75));

    // Find X10 variant: 4080x3072 src.image, 1020x768 depth plane.
    let placement = PortraitPlacement::new((4080, 3072), None, (1020, 768));
    assert_eq!(placement.content, (0, 0, 2040, 1536));
    assert_eq!(placement.crop, (0, 0, 1020, 768));
}

#[test]
fn framed_watermark_tail_is_not_a_content_rect() {
    // A style id alone is not geometry. An empty hassel_style_4 tail still
    // falls back to the full frame.
    let mut tail = vec![0u8; 23487];
    tail[..4].copy_from_slice(&1f32.to_le_bytes());
    tail[4..19].copy_from_slice(b"hassel_style_4\0");
    assert_eq!(parse_watermark_rect(&tail, (3244, 5444), (4096, 3072), 6, None), None);
}

/// A framed-watermark tail whose last 56 bytes are `words`. Slot 5 is the
/// `0xffffffff` sentinel whatever the caller passes there.
fn framed_watermark(style: &str, len: usize, words: [f32; 14]) -> Vec<u8> {
    let mut tail = vec![0u8; len];
    tail[..4].copy_from_slice(&1f32.to_le_bytes());
    tail[4..4 + style.len()].copy_from_slice(style.as_bytes());
    let origin = len - 56;
    for (i, v) in words.iter().enumerate() {
        tail[origin + i * 4..origin + i * 4 + 4].copy_from_slice(&v.to_le_bytes());
    }
    tail[origin + 20..origin + 24].copy_from_slice(&[0xff; 4]);
    tail
}

// End block of IMG20260807144352.heic (hassel_style_master_mode_1, 3244x5444).
const FRAMED_3244: [f32; 14] = [
    4770., 3157., 5444., 0., 0., 0., 86., 674., 3158., 4770., 86., 674., 4182., 3746.,
];

#[test]
fn hassel_style_4_end_rect_is_the_content_frame() {
    // The first ten words as read from IMG20261011120934.heic. The quad holds
    // corners: the picture is 4928x6560, centred, not 5064x7642.
    let tail = framed_watermark(
        "hassel_style_4",
        23487,
        [7642., 5064., 8724., 0., 0., 0., 136., 1082., 5064., 7642., 0., 0., 0., 0.],
    );
    assert_eq!(
        parse_watermark_rect(&tail, (5200, 8724), (3280, 2464), 1, None),
        Some((136, 1082, 4928, 6560))
    );
    assert_eq!(
        parse_watermark_rect(&tail, (3244, 5444), (3280, 2464), 1, None),
        None
    );
}

#[test]
fn master_mode_end_rect_matches_the_observed_frames() {
    // Complete end blocks from five camera originals: rear portrait, plain
    // master mode, front portrait, and two landscape frames, where the second
    // float sits 28 and 58 columns right of the picture.
    for (len, primary, words, expected) in [
        (6492, (3244, 5444), FRAMED_3244, (86, 674, 3072, 4096)),
        (
            45117,
            (6484, 10888),
            [9540., 6315., 10888., 0., 0., 0., 170., 1348., 6314., 9540., 170., 1348., 8362., 7492.],
            (170, 1348, 6144, 8192),
        ),
        (
            6492,
            (5200, 8724),
            [7642., 5065., 8724., 0., 0., 0., 136., 1082., 5064., 7642., 136., 1082., 6696., 6010.],
            (136, 1082, 4928, 6560),
        ),
        (
            45117,
            (4268, 4420),
            [3746., 4210., 4420., 0., 0., 0., 86., 674., 4182., 3746., 86., 674., 4182., 3746.],
            (86, 674, 4096, 3072),
        ),
        (
            45117,
            (8532, 8840),
            [7492., 8420., 8840., 0., 0., 0., 170., 1348., 8362., 7492., 170., 1348., 8362., 7492.],
            (170, 1348, 8192, 6144),
        ),
    ] {
        let tail = framed_watermark("hassel_style_master_mode_1", len, words);
        assert_eq!(
            parse_watermark_rect(&tail, primary, (4096, 3072), 6, None),
            Some(expected),
            "{primary:?}"
        );
    }
}

#[test]
fn landscape_master_mode_end_rect_places_auxiliaries_inside_picture() {
    let tail = framed_watermark(
        "hassel_style_master_mode_1",
        45117,
        [3746., 4210., 4420., 0., 0., 0., 86., 674., 4182., 3746., 86., 674., 4182., 3746.],
    );
    let rect = parse_watermark_rect(&tail, (4268, 4420), (4096, 3072), 1, None);
    assert_eq!(rect, Some((86, 674, 4096, 3072)));
    let placement = PortraitPlacement::new((4268, 4420), rect, (1024, 768));
    assert_eq!(placement.content, (43, 337, 2048, 1536));
}

#[test]
fn framed_content_rect_keeps_auxiliaries_off_the_frame() {
    let tail = framed_watermark("hassel_style_master_mode_1", 6492, FRAMED_3244);
    let rect = parse_watermark_rect(&tail, (3244, 5444), (4096, 3072), 6, None);
    // Depth is 1024x768 in sensor orientation, 768x1024 once rotated.
    let placement = PortraitPlacement::new((3244, 5444), rect, (768, 1024));
    assert_eq!(placement.canvas, (1622, 2722));
    assert_eq!(placement.content, (43, 337, 1536, 2048));
    assert_eq!(placement.crop, (0, 0, 768, 1024));
    let (matte, w, h) = placement.place(&vec![255; 768 * 1024], 768, 1024);
    assert_eq!((w, h), (1622, 2722));
    for (y, row) in matte.chunks_exact(1622).enumerate() {
        let inside = (337..337 + 2048).contains(&y);
        for (x, &v) in row.iter().enumerate() {
            let expected = if inside && (43..43 + 1536).contains(&x) { 255 } else { 0 };
            assert_eq!(v, expected, "({x}, {y})");
        }
    }
}

#[test]
fn framed_end_rect_rejects_blocks_that_do_not_repeat_the_geometry() {
    let parse = |words: [f32; 14]| {
        let tail = framed_watermark("hassel_style_master_mode_1", 6492, words);
        parse_watermark_rect(&tail, (3244, 5444), (4096, 3072), 6, None)
    };
    assert_eq!(parse(FRAMED_3244), Some((86, 674, 3072, 4096)));
    // The second float sits anywhere from one column left of the right edge
    // to the frame width, the first up to two rows below the bottom edge.
    for (slot, value) in [(1, 3159f32), (1, 3244.), (0, 4772.)] {
        let mut loose = FRAMED_3244;
        loose[slot] = value;
        assert_eq!(parse(loose), Some((86, 674, 3072, 4096)), "slot {slot} = {value}");
    }
    for (slot, value) in [
        (0, 4768f32),  // above the bottom edge
        (0, 4773.),    // three rows below it
        (1, 3156.),    // two columns left of the right edge
        (1, 3245.),    // outside the frame
        (2, 5440.),    // not the primary height
        (3, 1.),
        (4, 1.),
        (6, 86.5),     // not an integer
        (7, f32::NAN),
        (8, 3161.),    // right edge past the second float
        (9, 4772.),    // bottom edge past the first float
    ] {
        let mut bad = FRAMED_3244;
        bad[slot] = value;
        assert_eq!(parse(bad), None, "slot {slot}");
    }
    // Edges outside the frame, or in the wrong order, are rejected even when
    // the copies agree with the quad.
    for (slots, value) in [((1, 8), 3300f32), ((0, 9), 5446.), ((1, 8), 80.)] {
        let mut bad = FRAMED_3244;
        (bad[slots.0], bad[slots.1]) = (value, value);
        assert_eq!(parse(bad), None, "slots {slots:?} = {value}");
    }
    // A picture smaller than half the frame is not a watermark frame.
    let mut small = FRAMED_3244;
    (small[0], small[9]) = (2000., 2000.);
    assert_eq!(parse(small), None);
    // Styles without a sample are not read, whatever their end block says.
    for style in ["hassel_style_2", "hassel_style_xpan_1", "hassel_style_master_mode_10"] {
        let tail = framed_watermark(style, 6492, FRAMED_3244);
        assert_eq!(
            parse_watermark_rect(&tail, (3244, 5444), (4096, 3072), 6, None),
            None,
            "{style}"
        );
    }
    // Without the sentinel the block is not this layout.
    let mut tail = framed_watermark("hassel_style_master_mode_1", 6492, FRAMED_3244);
    let origin = tail.len() - 56;
    tail[origin + 20..origin + 24].copy_from_slice(&0f32.to_le_bytes());
    assert_eq!(parse_watermark_rect(&tail, (3244, 5444), (4096, 3072), 6, None), None);
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
fn mirrored_planes_and_focus_stay_together_in_all_turns() {
    assert_eq!(orient_plane(&[1, 2, 3, 4, 5, 6], 3, 2, 0, true), (vec![3, 2, 1, 6, 5, 4], 3, 2));
    assert_eq!(orient_plane(&[1, 2, 3, 4, 5, 6], 3, 2, 0, false), (vec![1, 2, 3, 4, 5, 6], 3, 2));
    assert_eq!(orient_focus((0.25, 0.75), 0, true), (0.75, 0.75));
    assert_eq!(orient_focus((0.25, 0.75), 0, false), (0.25, 0.75));
    for turns in 0..4 {
        let (w, h) = (200, 100);
        let mut plane = vec![0; w * h];
        plane[40 * w + 75] = 255;
        let (oriented, ow, oh) = orient_plane(&plane, w, h, turns, true);
        // The flip moves the mark; an unflipped copy must not share its place.
        assert_ne!(oriented, rotate_plane(&plane, w, h, turns).0, "turns {turns}");
        let placement = PortraitPlacement::new((200, 200), None, (ow, oh));
        let (placed, cw, ch) = placement.place(&oriented, ow, oh);
        let point = placement.focus(orient_focus((75.5 / w as f64, 40.5 / h as f64), turns, true));
        let ix = (point.0 * cw as f64).floor() as usize;
        let iy = (point.1 * ch as f64).floor() as usize;
        assert_eq!(placed[iy * cw as usize + ix], 255, "turns {turns}");
    }
}

#[test]
fn mirror_flag_is_read_from_filter_info() {
    let info = |mirror: u32| {
        let mut bytes = vec![0u8; 140];
        bytes[..4].copy_from_slice(&4f32.to_le_bytes());
        bytes[12..16].copy_from_slice(&mirror.to_le_bytes());
        bytes
    };
    assert!(source_is_mirrored(&manifest_file(&[("filter.info", &info(1))])));
    assert!(!source_is_mirrored(&manifest_file(&[("filter.info", &info(0))])));
    // Anything but the observed flag value, a short entry or no entry at all
    // leaves the planes unflipped.
    assert!(!source_is_mirrored(&manifest_file(&[("filter.info", &info(2))])));
    assert!(!source_is_mirrored(&manifest_file(&[("filter.info", &info(1)[..14])])));
    assert!(!source_is_mirrored(&manifest_file(&[("capture.mode", b"portrait")])));
}

#[test]
fn mirror_flag_falls_back_to_the_front_depth_config() {
    // End of the 544-byte config of both front originals: mirrorEnable 1,
    // cameraRoll 270, f-number 4.5.
    let config = |version: f32, len: usize, mirror: u32, roll: u32| {
        let mut bytes = vec![0u8; len];
        bytes[..4].copy_from_slice(&version.to_le_bytes());
        let end = if version >= 1.1 { len - 4 } else { len };
        bytes[end - 8..end - 4].copy_from_slice(&mirror.to_le_bytes());
        bytes[end - 4..end].copy_from_slice(&roll.to_le_bytes());
        if version >= 1.1 {
            bytes[len - 4..].copy_from_slice(&4.5f32.to_le_bytes());
        }
        bytes
    };
    assert_eq!(front_config_mirror(&config(1.2, 544, 1, 270)), Some(true));
    assert_eq!(front_config_mirror(&config(1.2, 544, 0, 90)), Some(false));
    // Before version 1.1 the entry ends with the two integers.
    assert_eq!(front_config_mirror(&config(1.0, 540, 1, 0)), Some(true));
    // Not a flag, not a rotation, or too short to hold the fixed fields.
    assert_eq!(front_config_mirror(&config(1.2, 544, 2, 270)), None);
    assert_eq!(front_config_mirror(&config(1.2, 544, 1, 45)), None);
    assert_eq!(front_config_mirror(&config(1.2, 280, 1, 270)), None);

    let mirrored = config(1.2, 544, 1, 270);
    assert!(source_is_mirrored(&manifest_file(&[("front.depth.config", &mirrored)])));
    assert!(!source_is_mirrored(&manifest_file(&[(
        "front.depth.config",
        &config(1.2, 544, 0, 270)
    )])));
    // filter.info decides when it is there.
    let mut info = vec![0u8; 140];
    info[..4].copy_from_slice(&4f32.to_le_bytes());
    assert!(!source_is_mirrored(&manifest_file(&[
        ("filter.info", &info),
        ("front.depth.config", &mirrored),
    ])));
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

// --- per-photo depth curve calibration (rear.depth.config) -------------------

/// Build a minimal OPPO `rear.depth.config` with the observed layout: float 0
/// is the version, floats 38..=58 carry the per-aperture blur-strength curve.
fn depth_config_with_curve(curve: &[f32]) -> Vec<u8> {
    let mut config = vec![0u8; 59 * 4];
    config[0..4].copy_from_slice(&4.0f32.to_le_bytes());
    for (i, v) in curve.iter().enumerate() {
        let at = (38 + i) * 4;
        if at + 4 <= config.len() {
            config[at..at + 4].copy_from_slice(&v.to_le_bytes());
        }
    }
    config
}

#[test]
fn depth_curve_max_reads_the_oppo_curve() {
    let config = depth_config_with_curve(&[3.0, 5.0, 9.0, 12.0, 150.0]);
    assert_eq!(pd::depth_curve_max(&config), Some(150.0));
}

#[test]
fn depth_curve_scale_maps_the_full_scale_onto_the_reference_span() {
    let config = depth_config_with_curve(&[3.0, 150.0]);
    let scale = pd::scale_from_depth_curve(&config).expect("curve scale");
    assert!((scale * 255.0 - pd::APPLE_REFERENCE_SPAN).abs() < 1e-9);
    // Half-scale curve -> half the reference span.
    let half = depth_config_with_curve(&[3.0, pd::CURVE_FULL_SCALE as f32 / 2.0]);
    let half_scale = pd::scale_from_depth_curve(&half).expect("curve scale");
    assert!((half_scale * 255.0 - pd::APPLE_REFERENCE_SPAN / 2.0).abs() < 1e-6);
}

#[test]
fn depth_curve_is_rejected_when_absent_or_all_zero() {
    assert_eq!(pd::depth_curve_max(&[]), None);
    assert_eq!(pd::depth_curve_max(&[0u8; 40]), None);
    assert_eq!(pd::depth_curve_max(&vec![0u8; 59 * 4]), None);
    assert_eq!(pd::scale_from_depth_curve(&vec![0u8; 59 * 4]), None);
}

#[test]
fn curve_derived_scale_is_accepted_by_the_decision() {
    let decision = pd::ScaleDecision::CurveDerived(0.008);
    assert_eq!(decision.scale(), Some(0.008));
}

// --- disparity plane construction -------------------------------------------

#[test]
fn curve_derived_span_stretches_the_scene_ranks_across_the_target_span() {
    // A scene that only uses ranks 40..=200 still has to fill the declared span.
    let ranks: Vec<u8> = (40..=200).collect();
    let target = pd::APPLE_REFERENCE_SPAN;
    let (bytes, fmin, fmax, _norm) = build_disparity(&ranks, 1, target / 255.0, true);
    assert_eq!(fmin, 0.0);
    assert!((fmax - target).abs() < 1e-5, "fmax={fmax}");
    // The extreme ranks must reach both ends of the quantised range.
    assert!(bytes.contains(&0), "no zero byte");
    assert!(bytes.contains(&255), "no full-scale byte");
    // Nearer (smaller rank) must be farther (larger disparity).
    assert!(bytes[0] > bytes[ranks.len() - 1]);
}

#[test]
fn producer_scale_path_keeps_the_legacy_unstretched_mapping() {
    let ranks: Vec<u8> = (40..=200).collect();
    let span = 2.0f64;
    let (bytes, fmin, fmax, _norm) = build_disparity(&ranks, 1, span / 255.0, false);
    // Legacy mapping: values are span * (1 - pow(rank/255, exp)), so the range
    // is set by the scene's own rank coverage, not stretched to the full span.
    let expect_min = span * (1.0 - (200.0f64 / 255.0));
    let expect_max = span * (1.0 - (40.0f64 / 255.0));
    assert!((fmin - expect_min).abs() < 1e-4, "fmin={fmin} expect={expect_min}");
    assert!((fmax - expect_max).abs() < 1e-4, "fmax={fmax} expect={expect_max}");
    assert!(fmax - fmin < span - 1e-6, "legacy range must not fill the span");
    assert!(bytes.contains(&0) && bytes.contains(&255));
}

#[test]
fn constant_rank_plane_stays_finite_in_both_modes() {
    let flat = vec![128u8; 64];
    for stretch in [true, false] {
        let (bytes, fmin, fmax, _norm) = build_disparity(&flat, 1, 2.0 / 255.0, stretch);
        assert!(fmin.is_finite() && fmax.is_finite(), "stretch={stretch}");
        assert!(fmax >= fmin, "stretch={stretch}");
        assert!(bytes.iter().all(|b| *b == bytes[0]), "stretch={stretch}");
    }
}

#[test]
fn curve_scale_is_bounded_and_version_gated() {
    // Out-of-envelope curve maxima are clamped to the observed reference range.
    let huge = depth_config_with_curve(&[3.0, 100000.0]);
    let scale = pd::scale_from_depth_curve(&huge).expect("clamped scale");
    let span = scale * 255.0;
    assert!(span <= pd::MAX_REFERENCE_SPAN + 1e-9, "span={span}");
    assert!(span >= pd::MIN_REFERENCE_SPAN - 1e-9, "span={span}");
    // A config whose version is not the documented layout is not trusted.
    let mut wrong_version = depth_config_with_curve(&[3.0, 150.0]);
    wrong_version[0..4].copy_from_slice(&99.0f32.to_le_bytes());
    assert_eq!(pd::scale_from_depth_curve(&wrong_version), None);
}

fn manifest_file(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut payload = Vec::new();
    let mut starts = Vec::new();
    for (_, bytes) in entries {
        starts.push(payload.len());
        payload.extend_from_slice(bytes);
    }
    let payload_length = payload.len();
    let mut manifest = String::from("[");
    for (index, ((name, bytes), start)) in entries.iter().zip(starts).enumerate() {
        if index > 0 {
            manifest.push(',');
        }
        let offset = payload_length - start;
        manifest.push_str(&format!(
            r#"{{"length":{},"name":"{name}","offset":{offset},"version":1}}"#,
            bytes.len()
        ));
    }
    manifest.push(']');
    let manifest_bytes = manifest.into_bytes();
    payload.extend_from_slice(&manifest_bytes);
    payload.push(0);
    let footer_size = (manifest_bytes.len() + 9) as u32;
    payload.extend_from_slice(b"jxrs");
    payload.extend_from_slice(&footer_size.to_le_bytes());
    let mut file = vec![0u8; 32];
    file.extend(payload);
    file
}

#[test]
fn front_depth_inverts_near_values_and_keeps_the_person_mask() {
    let mut config = vec![0u8; 544];
    config[..4].copy_from_slice(&1.2f32.to_le_bytes());
    config[4..8].copy_from_slice(&4u32.to_le_bytes());
    config[8..12].copy_from_slice(&2u32.to_le_bytes());
    config[540..544].copy_from_slice(&4.5f32.to_le_bytes());
    let depth = [56u8, 56, 250, 250, 56, 56, 250, 250];
    let mut segment = vec![0u8; 4 * 4];
    segment[..8].copy_from_slice(&[0, 0, 254, 254, 0, 0, 254, 254]);
    let file = manifest_file(&[
        ("front.depth", &depth),
        ("front.depth.config", &config),
        ("front.segment", &segment),
    ]);
    let parsed = parse_depth(&file).expect("front depth");
    assert_eq!((parsed.width, parsed.height), (4, 2));
    assert_eq!(parsed.ranks, vec![199, 199, 5, 5, 199, 199, 5, 5]);
    assert_eq!(
        parsed.portrait.as_deref(),
        Some(&[0u8, 0, 254, 254, 0, 0, 254, 254][..])
    );
    assert!(matches!(parsed.decision, pd::ScaleDecision::FrontStretch(_)));
    assert_eq!(
        parsed.config.as_ref().and_then(|cfg| cfg.current_f_number),
        Some(4.5)
    );
    let report = pd::portrait_depth_report(&file).expect("report");
    assert_eq!(report["classification"], "front-depth");
    assert_eq!(report["available"], true);
    assert_eq!(report["safeToTransform"], true);
}

#[test]
fn front_depth_with_a_low_valued_person_keeps_its_values() {
    // Values of IMG20260807145722.heic: person about 93, the chair behind
    // about 150, the far wall above 224. Low is near, so nothing is inverted.
    let mut config = vec![0u8; 544];
    config[..4].copy_from_slice(&1.2f32.to_le_bytes());
    config[4..8].copy_from_slice(&4u32.to_le_bytes());
    config[8..12].copy_from_slice(&2u32.to_le_bytes());
    let depth = [224u8, 224, 93, 93, 224, 150, 93, 93];
    let segment = [0u8, 0, 254, 254, 0, 0, 254, 254];
    let file = manifest_file(&[
        ("front.depth", &depth),
        ("front.depth.config", &config),
        ("front.segment", &segment),
    ]);
    let parsed = parse_depth(&file).expect("front depth");
    assert_eq!(parsed.ranks, depth.to_vec());
    // Disparity then puts the person nearest, the chair between, the wall last.
    let scale = pd::APPLE_REFERENCE_SPAN / 255.0;
    let (disparity, ..) = build_disparity(&parsed.ranks, parsed.exponentiation, scale, true);
    assert!(disparity[2] > disparity[5] && disparity[5] > disparity[0], "{disparity:?}");
}

#[test]
fn front_near_side_follows_the_person_mask() {
    let depth = [10u8, 10, 200, 200];
    assert!(front_near_is_high(&depth, Some(&[0, 0, 254, 254])));
    assert!(!front_near_is_high(&depth, Some(&[254, 254, 0, 0])));
    // Low is near when the mask cannot decide: missing, wrong size, covering
    // everything or nothing, or level with the background.
    assert!(!front_near_is_high(&depth, None));
    assert!(!front_near_is_high(&depth, Some(&[254, 254, 0])));
    assert!(!front_near_is_high(&depth, Some(&[254; 4])));
    assert!(!front_near_is_high(&depth, Some(&[0; 4])));
    assert!(!front_near_is_high(&[90; 4], Some(&[254, 254, 0, 0])));
}

#[test]
fn front_depth_without_a_segment_takes_low_values_as_the_person() {
    // Values of IMG20261011120934.heic: person 56, background 232.
    let mut config = vec![0u8; 544];
    config[..4].copy_from_slice(&1.2f32.to_le_bytes());
    config[4..8].copy_from_slice(&4u32.to_le_bytes());
    config[8..12].copy_from_slice(&2u32.to_le_bytes());
    let depth = [232u8, 232, 56, 56, 232, 232, 56, 56];
    let file = manifest_file(&[("front.depth", &depth), ("front.depth.config", &config)]);
    let parsed = parse_depth(&file).expect("front depth");
    assert_eq!(parsed.ranks, depth.to_vec());
    assert_eq!(
        parsed.portrait.as_deref(),
        Some(&[0u8, 0, 254, 254, 0, 0, 254, 254][..])
    );
}
