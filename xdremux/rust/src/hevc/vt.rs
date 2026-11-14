//! VideoToolbox backend (Apple platforms): `src/vt_hevc.c` drives a
//! `VTCompressionSession` through the public C API.
//!
//! Differences from the x265 backend that callers can observe:
//!
//! - There is no public 8-bit 4:4:4 profile, so a 4:4:4 request is coded
//!   4:2:0 and reported as such in [`EncodedTiles::layout`].
//! - Rate control is a 0..1 `Quality`, picked per [`HevcContent`].
//! - Output is not reproducible across OS versions or chips; tests check
//!   structure and decode error, never bytes.
//! - Main10 is always available and has no minimum picture size.
//!
//! Colour conversion happens here with the shared helpers, exactly like the
//! x265 backend, so both backends are handed the same samples.

use std::os::raw::c_void;

use super::{
    codes16_to_yuv420_10bit, rgb_to_yuv420, rgb_to_yuv420_limited601, EncodeRequest,
    EncodedTiles, HevcBitDepth, HevcColor, HevcContent, HevcLayout, SourcePictures,
};

/// Keep in sync with `xdremux_vt_config` in `vt_hevc.c`.
#[repr(C)]
struct VtConfig {
    width: i32,
    height: i32,
    monochrome: i32,
    bit_depth: i32,
    full_range: i32,
    primaries: i32,
    transfer: i32,
    matrix: i32,
    force_software: i32,
    quality: f32,
}

// Internal link-time dependencies (vt_hevc.c), not part of the public C ABI.
extern "C" {
    fn xdremux_vt_open(
        config: *const VtConfig,
        stage: *mut i32,
        status: *mut i32,
        using_hardware: *mut i32,
    ) -> *mut c_void;
    fn xdremux_vt_encode(
        session: *mut c_void,
        p0: *const c_void,
        p1: *const c_void,
        p2: *const c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
        parameter_len: *mut usize,
        status: *mut i32,
    ) -> i32;
    fn xdremux_vt_close(session: *mut c_void);
    fn xdremux_vt_free(stream: *mut u8);
}

/// `Quality` per content class, calibrated on the hardware encoder (Apple
/// M-series) against the static encoder's output for the same source
/// pictures. The pictures were captured from real conversions of ten sample
/// photos; every stream was decoded with ffmpeg and compared with its source
/// on luma:
///
/// | class                    | Quality | size vs static | luma PSNR vs static |
/// |--------------------------|---------|----------------|---------------------|
/// | primary                  | 0.92    | 100%           | +0.1 dB             |
/// | gain map, gray           | 0.87    | 96%            | +1.1 dB             |
/// | gain map, colour (4:2:0) | 0.93    | 98% of 4:4:4   | +1.1 dB             |
/// | matte                    | 0.90    | 45%            | +5.5 dB             |
/// | disparity                | 0.88    | 96%            | +2.8 dB             |
/// | linear thumbnail (10-bit)| 0.70    | 112%           | +0.9 dB             |
///
/// The primary and the linear thumbnail are matched on decoded quality; the
/// auxiliary classes take the highest value that stays within the static
/// encoder's size. The software encoder maps the same values to somewhat
/// lower quality and size.
///
/// `XDREMUX_VT_QUALITY_<CLASS>` (PRIMARY, GAINMAP, MATTE, DISPARITY, LINEAR)
/// overrides one class for calibration runs.
fn quality_for(content: HevcContent, colour: bool) -> f32 {
    let (name, default) = match content {
        HevcContent::Primary => ("PRIMARY", 0.92),
        HevcContent::GainMap => ("GAINMAP", if colour { 0.93 } else { 0.87 }),
        HevcContent::Matte => ("MATTE", 0.90),
        HevcContent::Disparity => ("DISPARITY", 0.88),
        HevcContent::LinearThumbnail => ("LINEAR", 0.70),
    };
    std::env::var(format!("XDREMUX_VT_QUALITY_{name}"))
        .ok()
        .and_then(|v| v.parse::<f32>().ok())
        .filter(|q| (0.0..=1.0).contains(q))
        .unwrap_or(default)
}

fn io_err(msg: String) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, msg)
}

fn unsupported(what: &str) -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        format!("VideoToolbox backend does not encode {what}"),
    )
}

fn stage_name(stage: i32) -> &'static str {
    match stage {
        1 => "bad argument",
        2 => "session create",
        3 => "profile",
        4 => "session property",
        5 => "prepare",
        6 => "pixel buffer",
        7 => "encode",
        8 => "output",
        _ => "unknown stage",
    }
}

fn debug_log(msg: &str) {
    if std::env::var_os("XDREMUX_HEVC_DEBUG").is_some() {
        eprintln!("[xdremux_vt] {msg}");
    }
}

struct Session(*mut c_void);

impl Drop for Session {
    fn drop(&mut self) {
        unsafe { xdremux_vt_close(self.0) }
    }
}

impl Session {
    fn open(config: &VtConfig) -> std::io::Result<(Session, i32)> {
        let (mut stage, mut status, mut hardware) = (0i32, 0i32, -1i32);
        let handle = unsafe { xdremux_vt_open(config, &mut stage, &mut status, &mut hardware) };
        if handle.is_null() {
            return Err(io_err(format!(
                "VideoToolbox {} failed for {}x{} (status {status})",
                stage_name(stage),
                config.width,
                config.height
            )));
        }
        Ok((Session(handle), hardware))
    }

    /// Encode one picture; returns the Annex-B stream and the length of its
    /// leading parameter sets.
    fn encode(
        &mut self,
        p0: *const c_void,
        p1: *const c_void,
        p2: *const c_void,
    ) -> std::io::Result<(Vec<u8>, usize)> {
        let mut out: *mut u8 = std::ptr::null_mut();
        let (mut len, mut params, mut status) = (0usize, 0usize, 0i32);
        let stage = unsafe {
            xdremux_vt_encode(self.0, p0, p1, p2, &mut out, &mut len, &mut params, &mut status)
        };
        if stage != 0 || out.is_null() || len == 0 || params == 0 || params >= len {
            if !out.is_null() {
                unsafe { xdremux_vt_free(out) };
            }
            return Err(io_err(format!(
                "VideoToolbox {} failed (status {status})",
                stage_name(stage)
            )));
        }
        let stream = unsafe { std::slice::from_raw_parts(out, len).to_vec() };
        unsafe { xdremux_vt_free(out) };
        Ok((stream, params))
    }
}

/// Backend entry: encode one batch described by `request` with one session.
/// The first stream keeps the parameter sets; later ones are the bare
/// picture, after checking that the session still reports the same sets
/// (callers build one `hvcC` for the whole batch).
pub(super) fn encode(
    request: &EncodeRequest,
    pictures: SourcePictures<'_>,
) -> std::io::Result<EncodedTiles> {
    let EncodeRequest { width, height, layout, bit_depth, color, content } = *request;
    if width == 0 || height == 0 {
        return Err(io_err("VideoToolbox: zero picture extent".into()));
    }
    let pixels = (width as usize) * (height as usize);
    let force_software = std::env::var_os("XDREMUX_VT_SOFTWARE").is_some_and(|v| v != "0") as i32;
    let mut config = VtConfig {
        width: width as i32,
        height: height as i32,
        monochrome: 0,
        bit_depth: 8,
        full_range: 1,
        primaries: 0,
        transfer: 0,
        matrix: 0,
        force_software,
        quality: quality_for(content, matches!(pictures, SourcePictures::Rgb8(_))),
    };

    // What each source picture turns into, and the layout actually coded.
    enum Source<'a> {
        Gray(&'a [&'a [u8]]),
        GrayAs420(&'a [&'a [u8]]),
        Rgb { tiles: &'a [&'a [u8]], limited601: bool },
        Codes16(&'a [u16]),
    }
    let (source, coded) = match (pictures, bit_depth) {
        (SourcePictures::Gray8(tiles), HevcBitDepth::Eight) => match layout {
            HevcLayout::Monochrome => {
                config.monochrome = 1;
                (Source::Gray(tiles), HevcLayout::Monochrome)
            }
            // Neutral chroma; like x265, gray carries no colour description.
            HevcLayout::Yuv420 | HevcLayout::Yuv444 => (Source::GrayAs420(tiles), HevcLayout::Yuv420),
        },
        (SourcePictures::Rgb8(tiles), HevcBitDepth::Eight) => {
            if layout == HevcLayout::Monochrome {
                return Err(unsupported("RGB tiles as monochrome"));
            }
            // 4:4:4 has no public profile: code 4:2:0 and say so.
            let limited601 = match color {
                HevcColor::Bt709Full => {
                    (config.primaries, config.transfer, config.matrix) = (1, 1, 1);
                    false
                }
                HevcColor::OppoSdr => {
                    // Limited-range BT.601 samples in a buffer flagged full
                    // range: the OPPO camera convention, written as-is.
                    (config.primaries, config.transfer, config.matrix) = (2, 2, 2);
                    true
                }
                HevcColor::IccPrimary => {
                    config.matrix = 1;
                    false
                }
                HevcColor::Bt601LimitedLinear => {
                    return Err(unsupported("8-bit BT.601 limited RGB tiles"))
                }
            };
            (Source::Rgb { tiles, limited601 }, HevcLayout::Yuv420)
        }
        (SourcePictures::Rgb16(codes16), HevcBitDepth::Ten) => {
            if layout != HevcLayout::Yuv420 || color != HevcColor::Bt601LimitedLinear {
                return Err(unsupported("10-bit pictures other than 4:2:0 BT.601 limited"));
            }
            if codes16.len() != pixels * 3 {
                return Err(io_err("10-bit thumbnail: raster size mismatch".into()));
            }
            config.bit_depth = 10;
            config.full_range = 0;
            (Source::Codes16(codes16), HevcLayout::Yuv420)
        }
        _ => return Err(unsupported("source sample depth that differs from the coded bit depth")),
    };

    let count = match &source {
        Source::Gray(t) | Source::GrayAs420(t) => t.len(),
        Source::Rgb { tiles, .. } => tiles.len(),
        Source::Codes16(_) => 1,
    };
    if count == 0 {
        return Ok(EncodedTiles { streams: Vec::new(), layout: coded });
    }
    let expected = match &source {
        Source::Gray(_) | Source::GrayAs420(_) => pixels,
        _ => pixels * 3,
    };
    if let Source::Gray(tiles) | Source::GrayAs420(tiles) | Source::Rgb { tiles, .. } = &source {
        if tiles.iter().any(|t| t.len() != expected) {
            return Err(io_err("tile size mismatch in batch encode".into()));
        }
    }

    let (mut session, hardware) = Session::open(&config)?;
    debug_log(&format!(
        "{width}x{height} {coded:?} {}-bit {content:?} q={} n={count} encoder={}",
        config.bit_depth,
        config.quality,
        match hardware {
            1 => "hardware",
            0 => "software",
            // The macOS software encoder does not publish the property, and
            // iOS before 17.4 cannot read it.
            _ => "unreported",
        }
    ));

    let chroma_len = ((width as usize + 1) / 2) * ((height as usize + 1) / 2);
    let neutral = vec![128u8; chroma_len];
    let mut streams: Vec<Vec<u8>> = Vec::with_capacity(count);
    let mut first_parameters: Vec<u8> = Vec::new();
    for index in 0..count {
        if crate::progress::is_cancelled() {
            return Err(io_err(crate::progress::CANCELLED_MESSAGE.into()));
        }
        let (stream, params) = match &source {
            Source::Gray(tiles) => {
                session.encode(tiles[index].as_ptr().cast(), std::ptr::null(), std::ptr::null())?
            }
            Source::GrayAs420(tiles) => session.encode(
                tiles[index].as_ptr().cast(),
                neutral.as_ptr().cast(),
                neutral.as_ptr().cast(),
            )?,
            Source::Rgb { tiles, limited601 } => {
                let (y, u, v) = if *limited601 {
                    rgb_to_yuv420_limited601(tiles[index], width, height)
                } else {
                    rgb_to_yuv420(tiles[index], width, height)
                };
                session.encode(y.as_ptr().cast(), u.as_ptr().cast(), v.as_ptr().cast())?
            }
            Source::Codes16(codes16) => {
                let (y, u, v) = codes16_to_yuv420_10bit(codes16, width, height);
                session.encode(y.as_ptr().cast(), u.as_ptr().cast(), v.as_ptr().cast())?
            }
        };
        if index == 0 {
            first_parameters = stream[..params].to_vec();
            streams.push(stream);
        } else {
            if stream[..params] != first_parameters[..] {
                return Err(io_err(format!(
                    "VideoToolbox changed parameter sets at picture {index} of {count}"
                )));
            }
            streams.push(stream[params..].to_vec());
        }
    }
    Ok(EncodedTiles { streams, layout: coded })
}

// VideoToolbox output differs between OS versions, chips and the hardware /
// software encoders, so these tests check stream structure and decode error
// and never compare bytes.
#[cfg(test)]
mod tests {
    use super::super::{
        encode_icc_primary_tiles, encode_thumbnail_10bit, encode_tiles, encode_tiles_oppo_sdr,
        extract_hvcc_config_with_chroma, main10_supported, HevcBackend,
    };
    use super::*;

    fn vt<R>(f: impl FnOnce() -> R) -> R {
        HevcBackend::scoped(Some(HevcBackend::VideoToolbox), f)
    }

    /// NAL payloads (start code removed) of an Annex-B stream.
    fn nals(stream: &[u8]) -> Vec<&[u8]> {
        let mut starts = Vec::new();
        let mut i = 0;
        while i + 3 <= stream.len() {
            if stream[i..].starts_with(&[0, 0, 1]) {
                starts.push((i, i + 3));
                i += 3;
            } else {
                i += 1;
            }
        }
        let mut out = Vec::new();
        for (n, &(_, begin)) in starts.iter().enumerate() {
            let mut end = starts.get(n + 1).map_or(stream.len(), |next| next.0);
            // A 4-byte start code leaves its leading zero on the previous NAL.
            if end > begin && end < stream.len() && stream[end - 1] == 0 {
                end -= 1;
            }
            out.push(&stream[begin..end]);
        }
        out
    }

    fn nal_types(stream: &[u8]) -> Vec<u8> {
        nals(stream).iter().map(|n| (n[0] >> 1) & 0x3f).collect()
    }

    struct Bits {
        data: Vec<u8>,
        pos: usize,
    }

    impl Bits {
        fn u(&mut self, n: u32) -> u32 {
            let mut value = 0;
            for _ in 0..n {
                let bit = (self.data[self.pos / 8] >> (7 - self.pos % 8)) & 1;
                value = (value << 1) | u32::from(bit);
                self.pos += 1;
            }
            value
        }
        fn ue(&mut self) -> u32 {
            let mut zeros = 0;
            while self.u(1) == 0 {
                zeros += 1;
            }
            (1 << zeros) - 1 + self.u(zeros)
        }
    }

    #[derive(Debug, PartialEq)]
    struct Colour {
        full_range: u32,
        primaries: u32,
        transfer: u32,
        matrix: u32,
    }

    #[derive(Debug)]
    struct Sps {
        profile: u32,
        chroma: u32,
        width: u32,
        height: u32,
        bit_depth: u32,
        /// `None` when the VUI has no video_signal_type; the three codes are
        /// 2 (unspecified) without a colour description.
        colour: Option<Colour>,
    }

    /// Enough of ISO/IEC 23008-2 7.3.2.2 for single-layer intra streams.
    fn parse_sps(stream: &[u8]) -> Sps {
        let nal = *nals(stream)
            .iter()
            .find(|n| (n[0] >> 1) & 0x3f == 33)
            .expect("stream has an SPS");
        let mut rbsp = Vec::with_capacity(nal.len());
        let mut i = 0;
        while i < nal.len() {
            if i + 2 < nal.len() && nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] == 3 {
                rbsp.extend_from_slice(&[0, 0]);
                i += 3;
            } else {
                rbsp.push(nal[i]);
                i += 1;
            }
        }
        let mut b = Bits { data: rbsp[2..].to_vec(), pos: 0 };
        b.u(4);
        let sub_layers = b.u(3);
        assert_eq!(sub_layers, 0, "single temporal layer expected");
        b.u(1);
        b.u(3);
        let profile = b.u(5);
        b.u(32);
        b.u(32);
        b.u(16);
        b.u(8);
        b.ue();
        let chroma = b.ue();
        if chroma == 3 {
            b.u(1);
        }
        let (mut width, mut height) = (b.ue(), b.ue());
        if b.u(1) == 1 {
            let (sub_w, sub_h) = if chroma == 1 { (2, 2) } else { (1, 1) };
            let (left, right, top, bottom) = (b.ue(), b.ue(), b.ue(), b.ue());
            width -= sub_w * (left + right);
            height -= sub_h * (top + bottom);
        }
        let bit_depth = b.ue() + 8;
        b.ue();
        let poc_bits = b.ue() + 4;
        let ordering = b.u(1);
        for _ in 0..if ordering == 1 { 1 } else { 1 } {
            b.ue();
            b.ue();
            b.ue();
        }
        for _ in 0..6 {
            b.ue();
        }
        if b.u(1) == 1 {
            assert_eq!(b.u(1), 0, "explicit scaling lists are not parsed here");
        }
        b.u(2);
        if b.u(1) == 1 {
            b.u(8);
            b.ue();
            b.ue();
            b.u(1);
        }
        let short_term_sets = b.ue();
        for set in 0..short_term_sets {
            if set > 0 {
                assert_eq!(b.u(1), 0, "predicted reference picture sets are not parsed here");
            }
            let (negative, positive) = (b.ue(), b.ue());
            for _ in 0..negative + positive {
                b.ue();
                b.u(1);
            }
        }
        if b.u(1) == 1 {
            for _ in 0..b.ue() {
                b.u(poc_bits);
                b.u(1);
            }
        }
        b.u(2);
        let mut colour = None;
        if b.u(1) == 1 {
            if b.u(1) == 1 && b.u(8) == 255 {
                b.u(32);
            }
            if b.u(1) == 1 {
                b.u(1);
            }
            if b.u(1) == 1 {
                b.u(3);
                let full_range = b.u(1);
                let (primaries, transfer, matrix) =
                    if b.u(1) == 1 { (b.u(8), b.u(8), b.u(8)) } else { (2, 2, 2) };
                colour = Some(Colour { full_range, primaries, transfer, matrix });
            }
        }
        Sps { profile, chroma, width, height, bit_depth, colour }
    }

    fn gray(width: u32, height: u32, seed: u32) -> Vec<u8> {
        (0..width * height)
            .map(|i| ((i % width) * 255 / width.max(2) + (i / width) * 31 / height + seed) as u8)
            .collect()
    }

    fn rgb(width: u32, height: u32, seed: u32) -> Vec<u8> {
        let mut out = Vec::with_capacity((width * height * 3) as usize);
        for y in 0..height {
            for x in 0..width {
                out.push((x * 255 / width.max(2) + seed) as u8);
                out.push((y * 255 / height.max(2)) as u8);
                out.push(((x + y) * 127 / (width + height)) as u8);
            }
        }
        out
    }

    #[test]
    fn monochrome_is_rext_400() {
        let tile = gray(512, 512, 0);
        let out = vt(|| encode_tiles(&[&tile], 512, 512, 1, false, HevcContent::Matte)).unwrap();
        assert_eq!(out.layout, HevcLayout::Monochrome);
        let sps = parse_sps(&out.streams[0]);
        assert_eq!((sps.profile, sps.chroma, sps.bit_depth), (4, 0, 8), "{sps:?}");
        assert_eq!((sps.width, sps.height), (512, 512));
        assert_eq!(sps.colour.map(|c| c.full_range), Some(1), "full range");
        let hvcc = extract_hvcc_config_with_chroma(&out.streams[0], out.chroma_format_idc()).unwrap();
        assert_eq!(hvcc[16] & 0x03, 0, "hvcC chromaFormat follows the stream");
    }

    #[test]
    fn gray_as_420_is_main_with_neutral_chroma() {
        let tile = gray(512, 512, 3);
        let out = vt(|| encode_tiles(&[&tile], 512, 512, 1, true, HevcContent::GainMap)).unwrap();
        assert_eq!(out.layout, HevcLayout::Yuv420);
        let sps = parse_sps(&out.streams[0]);
        assert_eq!((sps.profile, sps.chroma, sps.bit_depth), (1, 1, 8), "{sps:?}");
    }

    #[test]
    fn rgb_444_request_is_coded_420_and_reported() {
        let tile = rgb(512, 512, 0);
        let out = vt(|| encode_tiles(&[&tile], 512, 512, 3, false, HevcContent::GainMap)).unwrap();
        assert_eq!(out.layout, HevcLayout::Yuv420, "no public 4:4:4 profile");
        assert_eq!(out.chroma_format_idc(), 1);
        let sps = parse_sps(&out.streams[0]);
        assert_eq!((sps.profile, sps.chroma), (1, 1), "{sps:?}");
        assert_eq!(
            sps.colour,
            Some(Colour { full_range: 1, primaries: 1, transfer: 1, matrix: 1 }),
            "BT.709 full range"
        );
    }

    #[test]
    fn oppo_convention_is_written_as_is() {
        let tile = rgb(512, 512, 7);
        let out = vt(|| encode_tiles_oppo_sdr(&[&tile], 512, 512, 3, true)).unwrap();
        // bt470bg primaries, sRGB transfer, smpte170m matrix, flagged full range.
        assert_eq!(
            parse_sps(&out.streams[0]).colour,
            Some(Colour { full_range: 1, primaries: 5, transfer: 13, matrix: 6 })
        );
    }

    #[test]
    fn icc_primary_declares_only_the_matrix() {
        let tile = rgb(512, 512, 9);
        let out = vt(|| encode_icc_primary_tiles(&[&tile], 512, 512, true)).unwrap();
        assert_eq!(
            parse_sps(&out.streams[0]).colour,
            Some(Colour { full_range: 1, primaries: 2, transfer: 2, matrix: 1 })
        );
    }

    #[test]
    fn linear_thumbnail_is_main10_limited_range_at_any_size() {
        for (w, h) in [(128u32, 96u32), (682, 1024), (32, 24)] {
            assert!(vt(|| main10_supported(w, h)));
            let codes: Vec<u16> = (0..w * h * 3).map(|i| (i * 37 % 65536) as u16).collect();
            let (stream, chroma) = vt(|| encode_thumbnail_10bit(&codes, w, h))
                .unwrap_or_else(|e| panic!("{w}x{h}: {e}"))
                .into_single()
                .unwrap();
            let sps = parse_sps(&stream);
            assert_eq!((sps.profile, sps.chroma, sps.bit_depth), (2, 1, 10), "{w}x{h}: {sps:?}");
            assert_eq!((sps.width, sps.height), (w, h), "cropped size");
            assert_eq!(chroma, 1);
            if let Some(colour) = sps.colour {
                assert_eq!(colour.full_range, 0, "limited range");
                assert_eq!((colour.primaries, colour.transfer), (2, 2), "unspecified");
            }
        }
    }

    #[test]
    fn odd_and_small_sizes_keep_their_dimensions() {
        // Hardware encoders round the coded size up and crop; the SPS must
        // still describe the requested picture.
        for (w, h) in [(2016u32, 1512u32), (1022, 766), (256, 170), (64, 64), (34, 18), (16, 16)] {
            let tile = gray(w, h, 1);
            let out = vt(|| encode_tiles(&[&tile], w, h, 1, false, HevcContent::Matte))
                .unwrap_or_else(|e| panic!("mono {w}x{h}: {e}"));
            let sps = parse_sps(&out.streams[0]);
            assert_eq!((sps.width, sps.height, sps.chroma), (w, h, 0), "mono {w}x{h}");
            let tile = rgb(w, h, 1);
            let out = vt(|| encode_tiles(&[&tile], w, h, 3, true, HevcContent::Primary))
                .unwrap_or_else(|e| panic!("4:2:0 {w}x{h}: {e}"));
            let sps = parse_sps(&out.streams[0]);
            assert_eq!((sps.width, sps.height, sps.chroma), (w, h, 1), "4:2:0 {w}x{h}");
        }
    }

    #[test]
    fn batch_shares_one_set_of_parameter_sets() {
        let tiles: Vec<Vec<u8>> = (0..5).map(|s| rgb(512, 512, s * 40)).collect();
        let refs: Vec<&[u8]> = tiles.iter().map(Vec::as_slice).collect();
        let out = vt(|| encode_tiles(&refs, 512, 512, 3, true, HevcContent::Primary)).unwrap();
        assert_eq!(out.streams.len(), 5);
        for (i, stream) in out.streams.iter().enumerate() {
            let types = nal_types(stream);
            let parameter_sets = types.iter().filter(|t| (32..=34).contains(*t)).count();
            assert_eq!(parameter_sets, if i == 0 { 3 } else { 0 }, "tile {i}: {types:?}");
            assert!(types.iter().any(|t| (16..=21).contains(t)), "tile {i} has no IRAP: {types:?}");
            assert!(types.iter().all(|t| *t < 35), "tile {i} carries SEI/AUD: {types:?}");
        }
    }

    #[test]
    fn software_and_hardware_encoders_agree_on_structure() {
        // XDREMUX_VT_SOFTWARE is process-wide, so drive the C layer directly.
        for force_software in [0, 1] {
            let config = VtConfig {
                width: 512,
                height: 512,
                monochrome: 1,
                bit_depth: 8,
                full_range: 1,
                primaries: 0,
                transfer: 0,
                matrix: 0,
                force_software,
                quality: 0.9,
            };
            let (mut session, hardware) = Session::open(&config).expect("session");
            if force_software == 1 {
                assert_ne!(hardware, 1, "software was forced");
            }
            let tile = gray(512, 512, 5);
            let (stream, params) = session
                .encode(tile.as_ptr().cast(), std::ptr::null(), std::ptr::null())
                .expect("encode");
            assert!(params > 0 && params < stream.len());
            let sps = parse_sps(&stream);
            assert_eq!((sps.profile, sps.chroma, sps.width, sps.height), (4, 0, 512, 512));
        }
    }

    #[test]
    fn cancellation_stops_a_batch() {
        let tiles: Vec<Vec<u8>> = (0..3).map(|s| gray(512, 512, s)).collect();
        let refs: Vec<&[u8]> = tiles.iter().map(Vec::as_slice).collect();
        let handle = crate::progress::begin_progress();
        assert_ne!(handle, 0, "progress registry has a free slot");
        crate::progress::cancel(handle);
        let result = vt(|| encode_tiles(&refs, 512, 512, 1, false, HevcContent::GainMap));
        crate::progress::end_progress();
        let error = result.expect_err("cancelled batch must not succeed");
        assert!(error.to_string().contains(crate::progress::CANCELLED_MESSAGE), "{error}");
    }

    /// Decode a one-picture stream with the core's own decoder and return
    /// the luma PSNR against `source_luma` (`width * height` samples).
    fn luma_psnr(stream: &[u8], source_luma: &[u16], width: u32, height: u32, peak: f64) -> f64 {
        let mut decoder = rust_h265::Decoder::new();
        let mut frame = None;
        for nal in &rust_h265::parse_annex_b(stream) {
            if let Some(decoded) = decoder.decode_nal(nal).expect("decodable NAL") {
                frame = Some(decoded);
            }
        }
        let frame = frame.or_else(|| decoder.flush()).expect("one decoded picture");
        assert!(frame.width >= width && frame.height >= height, "decoded {}x{}", frame.width, frame.height);
        let luma: Vec<u16> = match frame.y.as_u8() {
            Some(bytes) => bytes.iter().map(|v| u16::from(*v)).collect(),
            None => frame.y.as_u16().expect("16-bit luma").to_vec(),
        };
        let stride = luma.len() / frame.height as usize;
        let mut squared = 0f64;
        for y in 0..height as usize {
            for x in 0..width as usize {
                let d = f64::from(luma[y * stride + x]) - f64::from(source_luma[y * width as usize + x]);
                squared += d * d;
            }
        }
        let mse = squared / f64::from(width * height);
        10.0 * (peak * peak / mse.max(1e-9)).log10()
    }

    // Thresholds: these synthetic gradients decode at 53 dB or better on the
    // hardware and software encoders of the machine they were written on; 38
    // leaves room for other chips and OS versions while still catching a
    // wrong plane layout, stride or range (which lands below 20 dB).
    #[test]
    fn decoded_8bit_420_luma_is_close_to_the_source() {
        let (w, h) = (512u32, 512u32);
        for (content, name) in [(HevcContent::Primary, "primary"), (HevcContent::GainMap, "gain map")] {
            let source = rgb(w, h, 0);
            let out = vt(|| encode_tiles(&[&source], w, h, 3, true, content)).unwrap();
            let (y, _, _) = rgb_to_yuv420(&source, w, h);
            let luma: Vec<u16> = y.iter().map(|v| u16::from(*v)).collect();
            let psnr = luma_psnr(&out.streams[0], &luma, w, h, 255.0);
            eprintln!("{name} luma PSNR {psnr:.1} dB");
            assert!(psnr > 38.0, "{name} luma PSNR {psnr:.1} dB");
        }
    }

    #[test]
    fn decoded_10bit_luma_is_close_to_the_source() {
        // Not a multiple of 16: also proves the crop window lines up.
        let (w, h) = (128u32, 86u32);
        let mut codes = Vec::with_capacity((w * h * 3) as usize);
        for y in 0..h {
            for x in 0..w {
                let code = ((x * 3 + y * 5) % 256 * 256) as u16;
                codes.extend_from_slice(&[code, code, code]);
            }
        }
        let (stream, _) = vt(|| encode_thumbnail_10bit(&codes, w, h)).unwrap().into_single().unwrap();
        let (y, _, _) = codes16_to_yuv420_10bit(&codes, w, h);
        let psnr = luma_psnr(&stream, &y, w, h, 1023.0);
        eprintln!("10-bit luma PSNR {psnr:.1} dB");
        assert!(psnr > 38.0, "10-bit luma PSNR {psnr:.1} dB");
    }

    #[test]
    fn unsupported_requests_are_errors() {
        let tile = rgb(64, 64, 0);
        let request = EncodeRequest {
            width: 64,
            height: 64,
            layout: HevcLayout::Monochrome,
            bit_depth: HevcBitDepth::Eight,
            color: HevcColor::Bt709Full,
            content: HevcContent::Primary,
        };
        let error = encode(&request, SourcePictures::Rgb8(&[&tile])).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
        let short = vec![0u8; 10];
        assert!(vt(|| encode_tiles(&[&short], 64, 64, 1, false, HevcContent::Matte)).is_err());
    }

    #[cfg(xdremux_hevc_x265)]
    #[test]
    fn a_scoped_choice_selects_the_other_backend() {
        assert_eq!(HevcBackend::build_default(), HevcBackend::VideoToolbox);
        let tile = rgb(512, 512, 0);
        let out = HevcBackend::scoped(Some(HevcBackend::X265), || {
            assert_eq!(HevcBackend::active(), HevcBackend::X265);
            encode_tiles(&[&tile], 512, 512, 3, false, HevcContent::GainMap)
        })
        .unwrap();
        assert_eq!(out.layout, HevcLayout::Yuv444, "the static encoder keeps 4:4:4");
        assert_eq!(parse_sps(&out.streams[0]).chroma, 3);
    }
}
