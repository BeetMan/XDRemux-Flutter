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
    // Find X10 framed/irregular watermark layout (hassel_style_4, 23487 bytes)
    // has no supported geometry: the caller falls back to the full frame.
    let mut tail = vec![0u8; 23487];
    tail[..4].copy_from_slice(&1f32.to_le_bytes());
    tail[4..19].copy_from_slice(b"hassel_style_4\0");
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
