use super::*;

#[test]
fn normalize_primary_orientation_preserves_every_other_byte() {
    for bo in [Bo(false), Bo(true)] {
        let absent = exif_fixture(bo);
        assert_eq!(normalize_primary_orientation(&absent).unwrap(), absent);
        for typ in [3, 4] {
            for orientation in 1..=8 {
                let mut input = absent.clone();
                // Replace the first IFD0 field with Orientation, leaving the
                // other directories and opaque payloads untouched.
                let e = 10 + 8 + 2;
                bo.put_u16(&mut input[e..e + 2], 0x0112);
                bo.put_u16(&mut input[e + 2..e + 4], typ);
                bo.put_u32(&mut input[e + 4..e + 8], 1);
                if typ == 3 {
                    bo.put_u16(&mut input[e + 8..e + 10], orientation);
                } else {
                    bo.put_u32(&mut input[e + 8..e + 12], orientation as u32);
                }
                let mut expected = input.clone();
                if typ == 3 {
                    bo.put_u16(&mut expected[e + 8..e + 10], 1);
                } else {
                    bo.put_u32(&mut expected[e + 8..e + 12], 1);
                }
                let output = normalize_primary_orientation(&input).unwrap();
                assert_eq!(output, expected);
                assert_eq!(crate::exif::parse_exif_orientation(&output).unwrap(), crate::exif::ExifOrientation::Normal);
                assert_eq!(normalize_primary_orientation(&output).unwrap(), output);
                bo.put_u32(&mut input[e + 4..e + 8], 2);
                assert!(normalize_primary_orientation(&input).is_err());
            }
        }
    }
}

#[test]
fn restore_capture_exif_keeps_capture_gps_and_replaces_render_fields() {
    for bo in [Bo(false), Bo(true)] {
        let original = exif_fixture(bo);
        let mut rendered_color = [0; 2];
        bo.put_u16(&mut rendered_color, 65535);
        let rendered = upsert_exif_field(&original, 0xa001, 3, 1, &rendered_color).unwrap();
        let restored = restore_capture_exif(&original, &rendered, 3072, 4096).unwrap();
        assert_exif_preserved(&original, &restored);
        let prefix = exif_prefix_len(&restored).unwrap();
        let tiff = &restored[prefix..];
        let (_, ifd0) = tiff_header(tiff).unwrap();
        assert_eq!(read_ifd(tiff, bo, ifd0).unwrap().1, 0, "no stale thumbnail");
        let (_, entries, _) = exif_directory(tiff, bo, ifd0).unwrap();
        for (tag, expected) in [(0xa002, 3072), (0xa003, 4096)] {
            let e = entries.iter().find(|e| e.tag == tag).unwrap();
            assert_eq!(bo.u32(entry_bytes(tiff, e).unwrap()), expected);
        }
        let color = entries.iter().find(|e| e.tag == 0xa001).unwrap();
        assert_eq!(bo.u16(entry_bytes(tiff, color).unwrap()), 65535);
        // Portrait marking after restoration must retain the capture fields.
        let marked = set_portrait_custom_rendered(&restored).unwrap();
        let marked = inject_maker_note(&marked, b"Apple test note").unwrap();
        assert_exif_preserved(&original, &marked);
    }
}

fn exif_fixture(bo: Bo) -> Vec<u8> {
    let mut tiff = vec![0; 212];
    tiff[..2].copy_from_slice(if bo.0 { b"MM" } else { b"II" });
    bo.put_u16(&mut tiff[2..4], 42);
    bo.put_u32(&mut tiff[4..8], 8);
    let mut directory = |offset: usize, records: &[(u16, u16, u32, u32)], next| {
        bo.put_u16(&mut tiff[offset..offset + 2], records.len() as u16);
        for (i, &(tag, typ, count, value)) in records.iter().enumerate() {
            let e = offset + 2 + 12 * i;
            bo.put_u16(&mut tiff[e..e + 2], tag);
            bo.put_u16(&mut tiff[e + 2..e + 4], typ);
            bo.put_u32(&mut tiff[e + 4..e + 8], count);
            bo.put_u32(&mut tiff[e + 8..e + 12], value);
        }
        let end = offset + 2 + records.len() * 12;
        bo.put_u32(&mut tiff[end..end + 4], next);
    };
    directory(
        8,
        &[(0x010e, 2, 6, 180), (0x8769, 4, 1, 50), (0x8825, 4, 1, 128)],
        152,
    );
    directory(50, &[(0xa404, 5, 1, 188), (0xcafe, 7, 6, 196)], 0);
    directory(128, &[(0, 1, 4, 0)], 0);
    directory(152, &[(0x0201, 4, 1, 204)], 0);
    tiff[180..186].copy_from_slice(b"hello\0");
    bo.put_u32(&mut tiff[188..192], 3);
    bo.put_u32(&mut tiff[192..196], 2);
    tiff[196..202].copy_from_slice(b"opaque");
    tiff[204..212].copy_from_slice(b"jpegdata");
    let mut exif = b"\0\0\0\x06Exif\0\0".to_vec();
    exif.extend(tiff);
    exif
}

fn assert_exif_preserved(before: &[u8], after: &[u8]) {
    let a = tiff_slice(before).unwrap();
    let b = tiff_slice(after).unwrap();
    let (bo, ifd0) = tiff_header(&a).unwrap();
    let (_, ae, _) = exif_directory(&a, bo, ifd0).unwrap();
    let (_, be, _) = exif_directory(&b, bo, ifd0).unwrap();
    for old in ae.iter().filter(|e| e.tag != 0xa401 && e.tag != 0x927c) {
        let new = be.iter().find(|e| e.tag == old.tag).unwrap();
        assert_eq!(
            (old.typ, old.count, old.payload_offset),
            (new.typ, new.count, new.payload_offset)
        );
        assert_eq!(entry_bytes(&a, old), entry_bytes(&b, new));
    }
    // GPS, thumbnail directory, ASCII, rational, unknown bytes and JPEG data
    // all remain at the same TIFF-relative offsets.
    assert_eq!(&a[128..], &b[128..a.len()]);
    assert_eq!(
        find_ascii_tag(&b, bo, ifd0, 0x010e).as_deref(),
        Some("hello")
    );
}

#[test]
fn custom_rendered_insert_update_le_be_preserves_digital_zoom_and_offsets() {
    for bo in [Bo(false), Bo(true)] {
        let original = exif_fixture(bo);
        let inserted = set_portrait_custom_rendered(&original).unwrap();
        assert_exif_preserved(&original, &inserted);
        let prefix = exif_prefix_len(&inserted).unwrap();
        let (_, entries, _) = exif_directory(&inserted[prefix..], bo, 8).unwrap();
        let e = entries.iter().find(|e| e.tag == 0xa401).unwrap();
        assert_eq!((e.typ, e.count), (3, 1));
        assert_eq!(bo.u16(entry_bytes(&inserted[prefix..], e).unwrap()), 9);
        assert_eq!(set_portrait_custom_rendered(&inserted).unwrap(), inserted);
        // Existing incorrectly typed CustomRendered must be replaced, not duplicated.
        let mut wrong = inserted.clone();
        bo.put_u16(
            &mut wrong[prefix + e.value_field_pos - 6..prefix + e.value_field_pos - 4],
            4,
        );
        bo.put_u32(
            &mut wrong[prefix + e.value_field_pos..prefix + e.value_field_pos + 4],
            1,
        );
        assert_eq!(set_portrait_custom_rendered(&wrong).unwrap(), inserted);
    }
}

#[test]
fn portrait_then_styles_preserves_complete_live_maker_note_byte_exact() {
    for bo in [Bo(false), Bo(true)] {
        let source = exif_fixture(bo);
        let marked = set_portrait_custom_rendered(&source).unwrap();
        let portrait =
            inject_maker_note(&marked, crate::portrait_consts::PORTRAIT_MAKER_NOTE).unwrap();
        let composed = compose_styles_maker_note(&portrait).unwrap();
        assert_eq!(composed, crate::portrait_consts::PORTRAIT_MAKER_NOTE);
        // A complete valid directory need not be sorted to remain byte-exact.
        let mut unsorted = composed.clone();
        let first = unsorted[16..28].to_vec();
        let last = unsorted[700..712].to_vec();
        unsorted[16..28].copy_from_slice(&last);
        unsorted[700..712].copy_from_slice(&first);
        assert_eq!(
            merge_styles_note(&unsorted, &build_maker_note()).unwrap(),
            unsorted
        );
        let output = inject_maker_note(&portrait, &composed).unwrap();
        assert_exif_preserved(&source, &output);
        let tiff = tiff_slice(&output).unwrap();
        let (_, entries, _) = exif_directory(&tiff, bo, 8).unwrap();
        let note = entry_bytes(&tiff, entries.iter().find(|e| e.tag == 0x927c).unwrap()).unwrap();
        assert_eq!(note, crate::portrait_consts::PORTRAIT_MAKER_NOTE);
        assert_eq!(read_ifd(note, Bo(true), 14).unwrap().0.len(), 58);
        let custom = entries.iter().find(|e| e.tag == 0xa401).unwrap();
        assert_eq!(bo.u16(entry_bytes(&tiff, custom).unwrap()), 9);
    }
}

fn incomplete_note(bo: Bo) -> Vec<u8> {
    let mut note = b"Apple iOS\0\0\x01".to_vec();
    note.extend(if bo.0 { b"MM" } else { b"II" });
    note.resize(68, 0); // count + four entries + next pointer
    bo.put_u16(&mut note[14..16], 4);
    let fields: &[(u16, u16, &[u8])] = &[
        (43, 2, b"12345678-1234-4234-8234-123456789ABC\0"),
        (0xbeef, 2, b"unknown ASCII payload\0"),
        (0xcafe, 16, b"12345678"), // Apple LONG8, not inline in this classic IFD
        (0xcaff, 10, b"12345678"), // signed rational; bytes retain the original byte order
    ];
    for (i, &(tag, typ, bytes)) in fields.iter().enumerate() {
        let p = 16 + i * 12;
        bo.put_u16(&mut note[p..p + 2], tag);
        bo.put_u16(&mut note[p + 2..p + 4], typ);
        bo.put_u32(
            &mut note[p + 4..p + 8],
            bytes.len() as u32 / type_size(typ).unwrap() as u32,
        );
        let offset = note.len() as u32;
        bo.put_u32(&mut note[p + 8..p + 12], offset);
        note.extend(bytes);
    }
    note
}

#[test]
fn incomplete_apple_note_merge_le_be_preserves_uuid_and_note_relative_payloads() {
    for bo in [Bo(false), Bo(true)] {
        let note = incomplete_note(bo);
        let out = merge_styles_note(&note, &build_maker_note()).unwrap();
        let (old, _) = read_ifd(&note, bo, 14).unwrap();
        let (new, _) = read_ifd(&out, bo, 14).unwrap();
        assert_eq!(new.len(), 5);
        for e in old {
            let merged = new.iter().find(|n| n.tag == e.tag).unwrap();
            assert_eq!(entry_bytes(&note, &e), entry_bytes(&out, merged));
            assert_eq!(merged.payload_offset, e.payload_offset.map(|o| o + 12));
        }
        assert!(new
            .iter()
            .any(|e| e.tag == 84 && e.typ == 7 && e.count == 91));
        assert_eq!(merge_styles_note(&out, &build_maker_note()).unwrap(), out);
    }
}

#[test]
fn apple_merge_adds_missing_uuid_and_updates_flags_without_moving_other_payloads() {
    for bo in [Bo(false), Bo(true)] {
        let mut note = incomplete_note(bo);
        bo.put_u16(&mut note[16..18], 44); // no existing UUID
        let out = merge_styles_note(&note, &build_maker_note()).unwrap();
        let (entries, _) = read_ifd(&out, bo, 14).unwrap();
        assert_eq!(entries.len(), 6);
        assert!(entries
            .iter()
            .any(|e| e.tag == 43 && e.typ == 2 && e.count == 37));
        let flags = entries.iter().find(|e| e.tag == 84).unwrap();
        let mut wrong_flags = out.clone();
        wrong_flags[flags.payload_offset.unwrap() as usize + 8] ^= 1;
        let fixed = merge_styles_note(&wrong_flags, &build_maker_note()).unwrap();
        let (new, _) = read_ifd(&fixed, bo, 14).unwrap();
        for old in entries.iter().filter(|e| e.tag != 84) {
            let e = new.iter().find(|e| e.tag == old.tag).unwrap();
            assert_eq!(old.payload_offset, e.payload_offset);
            assert_eq!(entry_bytes(&out, old), entry_bytes(&fixed, e));
        }
        let flag = new.iter().find(|e| e.tag == 84).unwrap();
        assert_eq!(entry_bytes(&out, flags), entry_bytes(&fixed, flag));
    }
}

#[test]
fn incomplete_opaque_note_expansion_fails_closed_but_complete_note_stays_exact() {
    for bo in [Bo(false), Bo(true)] {
        let typed = incomplete_note(bo);
        let mut opaque = typed.clone();
        bo.put_u16(&mut opaque[30..32], 7); // unknown out-of-line UNDEFINED
        let error = merge_styles_note(&opaque, &build_maker_note()).unwrap_err();
        assert!(error.contains("unknown out-of-line UNDEFINED"));
        let mut complete = merge_styles_note(&typed, &build_maker_note()).unwrap();
        let (entries, _) = read_ifd(&complete, bo, 14).unwrap();
        let unknown = entries.iter().find(|e| e.tag == 0xbeef).unwrap();
        bo.put_u16(
            &mut complete[unknown.value_field_pos - 6..unknown.value_field_pos - 4],
            7,
        );
        assert_eq!(
            merge_styles_note(&complete, &build_maker_note()).unwrap(),
            complete
        );
    }
}

#[test]
fn apple_note_rejects_ifd8_directory_pointers_le_be() {
    for bo in [Bo(false), Bo(true)] {
        let typed = incomplete_note(bo);
        let complete = merge_styles_note(&typed, &build_maker_note()).unwrap();
        for mut note in [typed, complete] {
            let (entries, _) = read_ifd(&note, bo, 14).unwrap();
            let entry = entries.iter().find(|e| e.tag == 0xcafe).unwrap();
            let payload = entry.payload_offset.unwrap() as usize;
            let child_offset = note.len() as u64;
            let pointer = if bo.0 {
                child_offset.to_be_bytes()
            } else {
                child_offset.to_le_bytes()
            };
            note[payload..payload + 8].copy_from_slice(&pointer);
            note.extend_from_slice(&[0; 6]); // empty child IFD
            bo.put_u16(
                &mut note[entry.value_field_pos - 6..entry.value_field_pos - 4],
                18,
            );
            assert!(merge_styles_note(&note, &build_maker_note()).is_err());
        }
    }
}

#[test]
fn styles_only_non_apple_note_still_uses_two_tag_scaffold() {
    let source = inject_maker_note(&exif_fixture(Bo(false)), b"OPPO source note").unwrap();
    let note = compose_styles_maker_note(&source).unwrap();
    let (entries, _) = read_ifd(&note, Bo(true), 14).unwrap();
    assert_eq!(entries.iter().map(|e| e.tag).collect::<Vec<_>>(), [43, 84]);
    assert_eq!(entry_bytes(&note, &entries[1]).unwrap().len(), 91);
}

#[test]
fn metadata_rejects_invalid_headers_directories_and_payload_bounds() {
    for bytes in [
        vec![],
        vec![0; 3],
        vec![255; 16],
        b"\0\0\0\0XX\0\0\0\0\0\0".to_vec(),
    ] {
        assert!(set_portrait_custom_rendered(&bytes).is_err());
        assert!(inject_maker_note(&bytes, b"note").is_err());
    }
    for bo in [Bo(false), Bo(true)] {
        let source = exif_fixture(bo);
        for pos in [14, 32, 70] {
            // IFD0 count/Exif pointer, Exif payload offset
            let mut bad = source.clone();
            bad[pos..pos + 4].fill(255);
            assert!(set_portrait_custom_rendered(&bad).is_err());
        }
        let note = incomplete_note(bo);
        for pos in [14, 24, 50] {
            // count, UUID offset, unsupported next IFD
            let mut bad = note.clone();
            bad[pos..pos + 2].fill(255);
            assert!(merge_styles_note(&bad, &build_maker_note()).is_err());
        }
        let mut unsupported = note;
        bo.put_u16(&mut unsupported[42..44], 99);
        assert!(merge_styles_note(&unsupported, &build_maker_note()).is_err());
    }
}
