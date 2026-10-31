use super::*;

const CID: &str = "01234567-89AB-4DEF-8DEF-0123456789AB";

fn styles(texture: bool) -> StillStyles {
    StillStyles {
        tone_curve: (0..516u32).map(|i| i as u8).collect(),
        baseline_exposure: 4.0,
        key5: 2,
        h: 0.5,
        texture: texture.then(|| StillTexture {
            preset: "Standard".into(),
            port_type: "PortTypeBack".into(),
            hardware_model: "iPhone 18 Pro".into(),
            people_data_version: 3,
        }),
    }
}

/// Paired MOV with an audio-less 3-frame portrait (90° matrix) video track.
fn paired_movie() -> Vec<u8> {
    let mut mvhd = Vec::new();
    for v in [0u32, 0, 600, 60, 0x0001_0000] {
        mvhd.extend_from_slice(&v.to_be_bytes());
    }
    mvhd.extend_from_slice(&[0u8; 76]); // volume..next_track_id
    let mvhd = full_box(b"mvhd", 0, 0, &mvhd);

    let mut tkhd = Vec::new();
    for v in [0u32, 0, 1, 0, 60] {
        tkhd.extend_from_slice(&v.to_be_bytes());
    }
    tkhd.extend_from_slice(&[0u8; 16]);
    for v in [0i32, 0x10000, 0, -0x10000, 0, 0, 0, 0, 0x4000_0000] {
        tkhd.extend_from_slice(&v.to_be_bytes());
    }
    tkhd.extend_from_slice(&(1728u32 << 16).to_be_bytes());
    tkhd.extend_from_slice(&(1296u32 << 16).to_be_bytes());
    let tkhd = full_box(b"tkhd", 0, 0x0f, &tkhd);
    let mut mdhd = Vec::new();
    for v in [0u32, 0, 90_000, 9_000] {
        mdhd.extend_from_slice(&v.to_be_bytes());
    }
    mdhd.extend_from_slice(&[0x55, 0xC4, 0, 0]);
    let mdhd = full_box(b"mdhd", 0, 0, &mdhd);
    let hdlr = handler_box(b"mhlr", b"vide", 0, b"VideoHandle");
    let entry = hvc1_entry(1728, 1296, &[1, 2, 3], (9, 18, 9), None);
    let mut stts = 1u32.to_be_bytes().to_vec();
    stts.extend_from_slice(&3u32.to_be_bytes());
    stts.extend_from_slice(&3000u32.to_be_bytes());
    let mut stsd = 1u32.to_be_bytes().to_vec();
    stsd.extend_from_slice(&entry);
    let stbl = make_box(
        b"stbl",
        &[full_box(b"stsd", 0, 0, &stsd), full_box(b"stts", 0, 0, &stts)].concat(),
    );
    let minf = make_box(b"minf", &stbl);
    let mdia = make_box(b"mdia", &[mdhd, hdlr, minf].concat());
    let trak = make_box(b"trak", &[tkhd, mdia].concat());
    let moov = make_box(b"moov", &[mvhd, trak].concat());
    let mut source = make_box(b"ftyp", b"qt  \0\0\0\0qt  ");
    source.extend_from_slice(&make_box(b"mdat", b"VIDEO-SAMPLES"));
    source.extend_from_slice(&moov);
    crate::live_photo::write_live_photo_movie(&source, CID, 0.05, None).expect("pair")
}

fn fake_thumbnail(
    seen: &std::cell::Cell<Option<(u32, u32, u32)>>,
) -> impl FnOnce(u32, u32, u32) -> Result<MovieLinearThumbnail, String> + '_ {
    move |turns, width, height| {
        seen.set(Some((turns, width, height)));
        Ok(MovieLinearThumbnail {
            sample: b"\0\0\0\x04THMB".to_vec(),
            hvcc: vec![1, 2, 3],
            width,
            height,
            bit_depth: 10,
        })
    }
}

fn moov_of(mov: &[u8]) -> &[u8] {
    let top = scan_boxes(mov, 0, mov.len()).unwrap();
    let b = top.iter().find(|b| &b.kind == b"moov").unwrap();
    &mov[b.offset..b.end()]
}

fn traks(moov: &[u8]) -> Vec<MovBox> {
    scan_boxes(moov, 8, moov.len())
        .unwrap()
        .into_iter()
        .filter(|b| &b.kind == b"trak")
        .collect()
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// First chunk offset of a track (every companion uses a single chunk).
fn chunk_offset(moov: &[u8], trak: &MovBox) -> usize {
    let mdia = direct_child(moov, trak, b"mdia").unwrap();
    let minf = direct_child(moov, &mdia, b"minf").unwrap();
    let stbl = direct_child(moov, &minf, b"stbl").unwrap();
    let stco = direct_child(moov, &stbl, b"stco").unwrap();
    let at = stco.payload_offset() + 8;
    u32::from_be_bytes(moov[at..at + 4].try_into().unwrap()) as usize
}

#[test]
fn level_parsing_and_order() {
    assert_eq!(MovieStyleLevel::parse("Thumbnail"), Some(MovieStyleLevel::Thumbnail));
    assert_eq!(MovieStyleLevel::parse(" b "), Some(MovieStyleLevel::Info));
    assert_eq!(MovieStyleLevel::parse("full"), Some(MovieStyleLevel::Full));
    assert_eq!(MovieStyleLevel::parse("off"), Some(MovieStyleLevel::Off));
    assert_eq!(MovieStyleLevel::parse("bogus"), None);
    assert!(MovieStyleLevel::Off < MovieStyleLevel::Thumbnail);
    assert!(MovieStyleLevel::Info < MovieStyleLevel::Full);
}

#[test]
fn bplist_reader_round_trips_writer_output() {
    let mut w = BplistWriter::new();
    let mut entries = Vec::new();
    for (key, value) in [("0", w.add_int(16)), ("4", w.add_real(6.5))] {
        let k = w.add_str(key);
        entries.push((k, value));
    }
    let (k, v) = (w.add_str("3"), w.add_data(&[7u8; 516]));
    entries.push((k, v));
    let (k, v) = (w.add_str("2"), w.add_bool(true));
    entries.push((k, v));
    let (k, v) = (w.add_str("Preset"), w.add_str("Studio"));
    entries.push((k, v));
    let (k, v) = (w.add_str("list"), w.add_array(&[]));
    entries.push((k, v));
    let top = w.add_dict(&entries);
    let dict = parse_bplist_dict(&w.finish(top)).expect("parse");
    assert_eq!(lookup(&dict, "0"), Some(&PlistValue::Int(16)));
    assert_eq!(lookup(&dict, "4"), Some(&PlistValue::Real(6.5)));
    assert_eq!(lookup(&dict, "3"), Some(&PlistValue::Data(vec![7u8; 516])));
    assert_eq!(lookup(&dict, "2"), Some(&PlistValue::Bool(true)));
    assert_eq!(lookup(&dict, "Preset"), Some(&PlistValue::Str("Studio".into())));
    assert_eq!(lookup(&dict, "list"), Some(&PlistValue::Other));
    assert!(parse_bplist_dict(b"not a plist at all, definitely not one").is_none());
}

#[test]
fn off_level_returns_movie_unchanged() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let out = attach_with(&mov, &styles(true), MovieStyleLevel::Off, fake_thumbnail(&seen)).unwrap();
    assert_eq!(out, mov);
    assert!(seen.get().is_none());
}

#[test]
fn thumbnail_level_adds_linear_thumbnail_track_only() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let out =
        attach_with(&mov, &styles(true), MovieStyleLevel::Thumbnail, fake_thumbnail(&seen)).unwrap();
    // Coded 1728×1296 landscape shown through a 90° CW matrix: the
    // display-oriented still rotates 3 CW turns back to coded geometry.
    assert_eq!(seen.get(), Some((3, 128, 96)));
    // Source samples and pairing survive.
    assert!(out.starts_with(&mov[..mov.len() - moov_of(&mov).len()]));
    assert_eq!(crate::live_photo::read_movie_content_identifier(&out).as_deref(), Some(CID));

    let moov = moov_of(&out);
    let tracks = traks(moov);
    assert_eq!(tracks.len(), 3, "video + still-image-time + thumbnail");
    let thumb = tracks[2];
    let raw = &moov[thumb.offset..thumb.end()];
    assert!(contains(raw, THUMBNAIL_TAG));
    assert!(contains(raw, b"auxv"));
    assert!(contains(raw, b"vmap\0\0\0\x01"));
    assert!(contains(raw, b"nclc\0\x09\0\x01\0\x09"));
    assert!(contains(raw, APPLE_LOG_TRANSFER));
    // One repeated sample per video frame, pointed at by the chunk offset.
    let at = chunk_offset(moov, &thumb);
    assert_eq!(&out[at..at + 24], b"\0\0\0\x04THMB".repeat(3).as_slice());
    assert!(!contains(moov, SMARTSTYLE_INFO_KEY));
    assert!(!contains(moov, b"smartstyle.bypassed"));
    // mvhd next_track_id follows the new track.
    let mvhd = direct_child(moov, &MovBox { offset: 0, size: moov.len(), kind: *b"moov", header_size: 8 }, b"mvhd").unwrap();
    assert_eq!(&moov[mvhd.end() - 4..mvhd.end()], &4u32.to_be_bytes());
}

#[test]
fn info_level_adds_smartstyle_track_and_movie_keys() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let out = attach_with(&mov, &styles(true), MovieStyleLevel::Info, fake_thumbnail(&seen)).unwrap();
    let moov = moov_of(&out);
    let tracks = traks(moov);
    assert_eq!(tracks.len(), 4);
    let info = tracks[3];
    let raw = &moov[info.offset..info.end()];
    assert!(contains(raw, SMARTSTYLE_INFO_KEY));
    assert!(contains(raw, b"cdsc\0\0\0\x01"));
    assert!(contains(raw, b"cdep\0\0\0\x01"));
    let at = chunk_offset(moov, &info);
    let size = u32::from_be_bytes(out[at..at + 4].try_into().unwrap()) as usize;
    assert_eq!(&out[at + 4..at + 8], &1u32.to_be_bytes());
    let dict = parse_bplist_dict(&out[at + 8..at + size]).expect("sample bplist");
    assert_eq!(lookup(&dict, "0"), Some(&PlistValue::Int(16)));
    assert_eq!(lookup(&dict, "4"), Some(&PlistValue::Real(4.0)));
    assert_eq!(lookup(&dict, "5"), Some(&PlistValue::Int(2)));
    assert_eq!(lookup(&dict, "h"), Some(&PlistValue::Real(0.5)));
    assert!(lookup(&dict, "b").is_none(), "b only rides on matte frames");
    assert!(matches!(lookup(&dict, "3"), Some(PlistValue::Data(d)) if d.len() == 516));
    for key in ["rendering-version", "tone", "color", "intensity", "bypassed", "cast"] {
        assert!(contains(moov, format!("com.apple.quicktime.smartstyle.{key}").as_bytes()), "{key}");
    }
    assert!(!contains(moov, b"texturestyle"));
    assert_eq!(crate::live_photo::read_movie_content_identifier(&out).as_deref(), Some(CID));
}

#[test]
fn full_level_adds_mattes_and_texture_style() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let out = attach_with(&mov, &styles(true), MovieStyleLevel::Full, fake_thumbnail(&seen)).unwrap();
    let moov = moov_of(&out);
    let tracks = traks(moov);
    assert_eq!(tracks.len(), 2 + 1 + 3 + 2);
    for tag in MATTE_TAGS {
        assert!(contains(moov, tag));
    }
    assert!(contains(moov, TEXTURESTYLE_INFO_KEY));
    assert!(contains(moov, b"com.apple.quicktime.texturestyle.preset"));
    let info = tracks[6];
    let at = chunk_offset(moov, &info);
    let size = u32::from_be_bytes(out[at..at + 4].try_into().unwrap()) as usize;
    let dict = parse_bplist_dict(&out[at + 8..at + size]).unwrap();
    assert_eq!(lookup(&dict, "b"), Some(&PlistValue::Real(0.0)));
    let texture = tracks[7];
    let at = chunk_offset(moov, &texture);
    let size = u32::from_be_bytes(out[at..at + 4].try_into().unwrap()) as usize;
    let dict = parse_bplist_dict(&out[at + 8..at + size]).unwrap();
    assert_eq!(lookup(&dict, "CaptureMode"), Some(&PlistValue::Str("LivePhoto".into())));
    assert_eq!(lookup(&dict, "Preset"), Some(&PlistValue::Str("Standard".into())));
}

#[test]
fn full_level_without_texture_skips_texture_track() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let out = attach_with(&mov, &styles(false), MovieStyleLevel::Full, fake_thumbnail(&seen)).unwrap();
    let moov = moov_of(&out);
    assert_eq!(traks(moov).len(), 2 + 1 + 3 + 1);
    assert!(!contains(moov, b"texturestyle"));
}

#[test]
fn second_attach_is_rejected() {
    let mov = paired_movie();
    let seen = std::cell::Cell::new(None);
    let once = attach_with(&mov, &styles(true), MovieStyleLevel::Thumbnail, fake_thumbnail(&seen)).unwrap();
    let again = attach_with(&once, &styles(true), MovieStyleLevel::Thumbnail, fake_thumbnail(&seen));
    assert!(again.is_err());
}
