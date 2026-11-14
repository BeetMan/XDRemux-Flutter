//! HEVC still-picture encoding.
//!
//! This module owns everything that does not depend on the encoder: colour
//! conversion, NAL utilities, `hvcC` construction and the public entry points.
//! The encoder itself is a backend in a submodule:
//!
//! - [`x265`] (`cfg(xdremux_hevc_x265)`): static-linked x265, the default on
//!   every platform.
//! - [`ffmpeg`] (`cfg(xdremux_ffmpeg_fallback)`): `ffmpeg` subprocess, a
//!   desktop smoke build selected with `XDREMUX_HEVC_BACKEND=ffmpeg` (or the
//!   older `XDREMUX_USE_FFMPEG=1`).
//! - [`vt`] (`cfg(xdremux_hevc_vt)`): VideoToolbox, Apple targets only,
//!   `XDREMUX_HEVC_BACKEND=videotoolbox`. `videotoolbox+x265` compiles it
//!   next to the static encoder.
//!
//! Every backend implements the same `encode(&EncodeRequest,
//! SourcePictures)` function. [`HevcBackend::COMPILED`] lists the ones in
//! this binary and [`encode`] dispatches on [`HevcBackend::active`] at run
//! time: a per-conversion choice ([`HevcBackend::scoped`]), else a
//! process-wide one ([`HevcBackend::set_process_choice`]), else the build's
//! preferred backend.
//!
//! The entry points translate their arguments into an [`EncodeRequest`] and
//! return the streams together with the chroma format the backend actually
//! produced, which callers must use for `hvcC` instead of assuming the one
//! they asked for.
//!
//! A VideoToolbox-only build must not contain the name of the static encoder
//! anywhere in the binary (release checks grep for it), which is why nothing
//! outside its `cfg` spells that name in an identifier or string literal.

#[cfg(xdremux_ffmpeg_fallback)]
mod ffmpeg;
#[cfg(xdremux_hevc_vt)]
mod vt;
#[cfg(xdremux_hevc_x265)]
mod x265;

use std::cell::Cell;
use std::sync::atomic::{AtomicU8, Ordering};

// ===========================================================================
// Backend request / response
// ===========================================================================

/// An HEVC encoder implementation compiled into this binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HevcBackend {
    /// VideoToolbox (Apple platforms).
    #[cfg(xdremux_hevc_vt)]
    VideoToolbox,
    /// Static-linked x265.
    #[cfg(xdremux_hevc_x265)]
    X265,
    /// `ffmpeg` subprocess (desktop smoke build).
    #[cfg(xdremux_ffmpeg_fallback)]
    Ffmpeg,
}

thread_local! {
    /// Per-conversion choice, set by [`HevcBackend::scoped`].
    static SCOPED_CHOICE: Cell<Option<HevcBackend>> = const { Cell::new(None) };
}
/// Process-wide choice: 0 = none, otherwise index into `COMPILED` plus one.
static PROCESS_CHOICE: AtomicU8 = AtomicU8::new(0);

impl HevcBackend {
    /// Every backend compiled into this binary, most preferred first.
    pub const COMPILED: &'static [HevcBackend] = &[
        #[cfg(xdremux_hevc_vt)]
        HevcBackend::VideoToolbox,
        #[cfg(xdremux_hevc_x265)]
        HevcBackend::X265,
        #[cfg(xdremux_ffmpeg_fallback)]
        HevcBackend::Ffmpeg,
    ];

    /// Name used in configuration, the capability report and the C ABI.
    pub fn name(self) -> &'static str {
        match self {
            #[cfg(xdremux_hevc_vt)]
            HevcBackend::VideoToolbox => "videotoolbox",
            #[cfg(xdremux_hevc_x265)]
            HevcBackend::X265 => "x265",
            #[cfg(xdremux_ffmpeg_fallback)]
            HevcBackend::Ffmpeg => "ffmpeg",
        }
    }

    /// The compiled backend called `name`, if this binary has it.
    pub fn from_name(name: &str) -> Option<HevcBackend> {
        Self::COMPILED.iter().copied().find(|b| b.name() == name)
    }

    /// The backend this build prefers when nothing chose one.
    pub fn build_default() -> HevcBackend {
        Self::COMPILED[0]
    }

    /// The backend the current encode uses: the choice scoped to this
    /// thread's conversion, else the process-wide choice, else the
    /// `XDREMUX_HEVC_ENCODER` environment variable (diagnostics and tests),
    /// else [`HevcBackend::build_default`].
    pub fn active() -> HevcBackend {
        if let Some(choice) = SCOPED_CHOICE.with(Cell::get) {
            return choice;
        }
        let index = PROCESS_CHOICE.load(Ordering::Relaxed) as usize;
        if index != 0 {
            if let Some(choice) = Self::COMPILED.get(index - 1) {
                return *choice;
            }
        }
        if Self::COMPILED.len() > 1 {
            if let Some(choice) = std::env::var("XDREMUX_HEVC_ENCODER")
                .ok()
                .and_then(|name| Self::from_name(&name))
            {
                return choice;
            }
        }
        Self::build_default()
    }

    /// Run `f` with `choice` as this thread's backend (`None` leaves the
    /// selection alone). Encodes are dispatched on the calling thread, so
    /// this covers everything a conversion does.
    pub fn scoped<R>(choice: Option<HevcBackend>, f: impl FnOnce() -> R) -> R {
        struct Restore(Option<HevcBackend>);
        impl Drop for Restore {
            fn drop(&mut self) {
                SCOPED_CHOICE.with(|cell| cell.set(self.0));
            }
        }
        let Some(choice) = choice else { return f() };
        let _restore = Restore(SCOPED_CHOICE.with(|cell| cell.replace(Some(choice))));
        f()
    }

    /// Set (or with `None` clear) the process-wide choice used by entry
    /// points that take no per-conversion configuration.
    pub fn set_process_choice(choice: Option<HevcBackend>) {
        let index = choice
            .and_then(|c| Self::COMPILED.iter().position(|b| *b == c))
            .map_or(0, |i| i as u8 + 1);
        PROCESS_CHOICE.store(index, Ordering::Relaxed);
    }

    /// Whether Main10 pictures of this size can be encoded.
    #[cfg_attr(not(any(xdremux_hevc_vt, xdremux_hevc_x265)), allow(unused_variables))]
    fn supports_10bit(self, width: u32, height: u32) -> bool {
        match self {
            #[cfg(xdremux_hevc_vt)]
            HevcBackend::VideoToolbox => width > 0 && height > 0,
            // Needs the optional 10-bit archive, and refuses pictures smaller
            // than one CTU (64x64 with the default maxCUSize).
            #[cfg(xdremux_hevc_x265)]
            HevcBackend::X265 => cfg!(xdremux_main10) && width >= 64 && height >= 64,
            #[cfg(xdremux_ffmpeg_fallback)]
            HevcBackend::Ffmpeg => false,
        }
    }

    /// The ffmpeg smoke backend's container tiles have always kept their
    /// in-stream parameter sets; every other backend's are stripped.
    fn keeps_parameter_sets_in_tiles(self) -> bool {
        #[cfg(xdremux_ffmpeg_fallback)]
        if self == HevcBackend::Ffmpeg {
            return true;
        }
        false
    }

    /// Timing label for the encode phase of the watermark writeback.
    pub(crate) fn encode_phase_name(self) -> &'static str {
        #[cfg(xdremux_hevc_vt)]
        if self == HevcBackend::VideoToolbox {
            return "videotoolbox_encode";
        }
        legacy_encode_phase_name()
    }
}

#[cfg(any(xdremux_hevc_x265, xdremux_ffmpeg_fallback))]
fn legacy_encode_phase_name() -> &'static str {
    "x265_encode"
}

#[cfg(not(any(xdremux_hevc_x265, xdremux_ffmpeg_fallback)))]
fn legacy_encode_phase_name() -> &'static str {
    unreachable!("VideoToolbox is the only backend in this build")
}

/// Diagnostic switch of the scaffold stages: encode the zero matte as 4:2:0
/// gray. Its historical variable name contains the static encoder's name, so
/// VideoToolbox-only builds do not have it.
#[cfg(any(xdremux_hevc_x265, xdremux_ffmpeg_fallback))]
pub(crate) fn scaffold_matte_420_requested() -> bool {
    std::env::var("XSCAFFOLD_X265_MATTE_420").is_ok()
}

#[cfg(not(any(xdremux_hevc_x265, xdremux_ffmpeg_fallback)))]
pub(crate) fn scaffold_matte_420_requested() -> bool {
    false
}

/// A tile stream in the form the container stores: parameter sets (and SEI)
/// removed, so the tile is a pure IDR slice and the decoder configuration
/// lives only in `hvcC`. See [`HevcBackend::keeps_parameter_sets_in_tiles`]
/// for the one exception.
pub fn tile_stream_for_container(stream: &[u8]) -> Vec<u8> {
    if HevcBackend::active().keeps_parameter_sets_in_tiles() {
        stream.to_vec()
    } else {
        drop_parameter_nals(stream)
    }
}

/// Sample layout of the coded picture (`chroma_format_idc`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HevcLayout {
    /// 4:0:0.
    Monochrome,
    /// 4:2:0.
    Yuv420,
    /// 4:4:4.
    Yuv444,
}

impl HevcLayout {
    /// The `chroma_format_idc` to record in `hvcC`.
    pub fn chroma_format_idc(self) -> u8 {
        match self {
            HevcLayout::Monochrome => 0,
            HevcLayout::Yuv420 => 1,
            HevcLayout::Yuv444 => 3,
        }
    }
}

/// Coded sample bit depth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HevcBitDepth {
    Eight,
    Ten,
}

/// How samples are derived from RGB and what the stream's VUI declares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HevcColor {
    /// BT.709 matrix, full range; primaries and transfer declared BT.709.
    /// Monochrome sources carry no colour description at all.
    Bt709Full,
    /// OPPO camera convention: BT.601 limited-range data flagged full range,
    /// matrix smpte170m, primaries bt470bg, transfer sRGB.
    OppoSdr,
    /// BT.709 matrix, full range; primaries and transfer left unspecified
    /// because the HEIF item carries an ICC profile.
    IccPrimary,
    /// BT.601 limited range with no colour description (Styles linear
    /// thumbnail, Apple Log codes).
    Bt601LimitedLinear,
}

/// What the picture is. Backends whose rate control is not content-neutral
/// use it to pick a quality target; the x265 and ffmpeg backends ignore it,
/// their parameters depend only on the source pictures and [`HevcColor`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HevcContent {
    /// The image the user sees (grid tiles of the primary item).
    Primary,
    /// ISO 21496-1 / Ultra HDR gain map tiles.
    GainMap,
    /// Sky, person, hair and other semantic mattes.
    Matte,
    /// Portrait disparity map.
    Disparity,
    /// Photographic Styles linear thumbnail (Apple Log).
    LinearThumbnail,
}

/// One batch of same-size pictures for a backend to encode.
#[derive(Debug, Clone, Copy)]
pub(crate) struct EncodeRequest {
    pub width: u32,
    pub height: u32,
    /// Requested layout. A backend that cannot produce it may substitute
    /// another one and must report that in [`EncodedTiles::layout`].
    pub layout: HevcLayout,
    pub bit_depth: HevcBitDepth,
    pub color: HevcColor,
    /// Only the VideoToolbox backend's parameters depend on it (see
    /// [`HevcContent`]).
    pub content: HevcContent,
}

/// Source pictures for an [`EncodeRequest`]. Colour conversion is the
/// backend's job (using the helpers in this module, or its own tooling) so
/// that each one keeps producing exactly the samples it always has.
#[derive(Clone, Copy)]
pub(crate) enum SourcePictures<'a> {
    /// 8-bit gray, `width * height` bytes per picture.
    Gray8(&'a [&'a [u8]]),
    /// Packed 8-bit R-G-B, `width * height * 3` bytes per picture.
    Rgb8(&'a [&'a [u8]]),
    /// One picture of packed 16-bit R-G-B Apple Log codes. Only a backend
    /// with a 10-bit encoder reads it; the ffmpeg smoke build has none.
    Rgb16(
        #[cfg_attr(not(any(xdremux_hevc_x265, xdremux_hevc_vt)), allow(dead_code))] &'a [u16],
    ),
}

/// Result of an encode: one Annex-B stream per source picture plus the
/// layout the backend actually used.
#[derive(Debug, Clone)]
pub struct EncodedTiles {
    /// Row-major, one per source picture. The first stream carries the
    /// parameter sets `hvcC` is built from.
    pub streams: Vec<Vec<u8>>,
    /// Layout of the coded pictures. Equal to the requested layout for the
    /// x265 backend; VideoToolbox codes 4:4:4 requests as 4:2:0 and reports
    /// that. The ffmpeg smoke backend reports the requested layout
    /// even though it codes gray and non-ICC RGB as 4:4:4: its `hvcC` has
    /// always claimed the requested value and that is kept byte-for-byte.
    pub layout: HevcLayout,
}

impl EncodedTiles {
    /// The `chroma_format_idc` callers must write into `hvcC`.
    pub fn chroma_format_idc(&self) -> u8 {
        self.layout.chroma_format_idc()
    }

    /// The first stream and its `chroma_format_idc`, for single-picture
    /// encodes. `None` when the backend produced no stream.
    pub fn into_single(self) -> Option<(Vec<u8>, u8)> {
        let chroma = self.chroma_format_idc();
        self.streams.into_iter().next().map(|stream| (stream, chroma))
    }
}

/// Run `request` on the active backend.
fn encode(request: &EncodeRequest, pictures: SourcePictures<'_>) -> std::io::Result<EncodedTiles> {
    let backend = HevcBackend::active();
    let result = encode_with(backend, request, pictures);
    // One line per batch for calibration and bug reports.
    if std::env::var_os("XDREMUX_HEVC_DEBUG").is_some() {
        if let Ok(encoded) = &result {
            eprintln!(
                "[xdremux_hevc] encoder={} content={:?} {}x{} requested={:?} coded={:?} pictures={} bytes={}",
                backend.name(),
                request.content,
                request.width,
                request.height,
                request.layout,
                encoded.layout,
                encoded.streams.len(),
                encoded.streams.iter().map(Vec::len).sum::<usize>(),
            );
        }
    }
    result
}

fn encode_with(
    backend: HevcBackend,
    request: &EncodeRequest,
    pictures: SourcePictures<'_>,
) -> std::io::Result<EncodedTiles> {
    match backend {
        #[cfg(xdremux_hevc_vt)]
        HevcBackend::VideoToolbox => vt::encode(request, pictures),
        #[cfg(xdremux_hevc_x265)]
        HevcBackend::X265 => x265::encode(request, pictures),
        #[cfg(xdremux_ffmpeg_fallback)]
        HevcBackend::Ffmpeg => ffmpeg::encode(request, pictures),
    }
}

fn invalid_input(msg: String) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidInput, msg)
}

/// Translate the historical `(pixel_bytes, use_420)` pair into a request.
fn encode_8bit_tiles(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
    color: HevcColor,
    content: HevcContent,
) -> std::io::Result<EncodedTiles> {
    let (pictures, layout) = match pixel_bytes {
        // Gray: monochrome unless the caller needs 4:2:0 with neutral chroma
        // (OPPO-compatible gain maps).
        1 => (
            SourcePictures::Gray8(tiles),
            if use_420 { HevcLayout::Yuv420 } else { HevcLayout::Monochrome },
        ),
        3 => (
            SourcePictures::Rgb8(tiles),
            if use_420 { HevcLayout::Yuv420 } else { HevcLayout::Yuv444 },
        ),
        _ => return Err(invalid_input(format!("unsupported pixel_bytes {pixel_bytes}"))),
    };
    let request = EncodeRequest {
        width,
        height,
        layout,
        bit_depth: HevcBitDepth::Eight,
        color,
        content,
    };
    encode(&request, pictures)
}

// ===========================================================================
// Entry points
// ===========================================================================

/// Encode a batch of same-size 8-bit tiles: gray (`pixel_bytes == 1`) or
/// packed RGB (`pixel_bytes == 3`), BT.709 full range. `use_420` selects
/// 4:2:0; otherwise gray is coded monochrome and RGB 4:4:4.
///
/// The first returned stream carries VPS/SPS/PPS (the `hvcC` source); with
/// the x265 backend the others are pure IDR slices. `content` says what the
/// pictures are; see [`HevcContent`].
pub fn encode_tiles(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
    content: HevcContent,
) -> std::io::Result<EncodedTiles> {
    encode_8bit_tiles(tiles, width, height, pixel_bytes, use_420, HevcColor::Bt709Full, content)
}

/// Batch-encode RGB tiles the way OPPO camera HEVC stores them: BT.601
/// limited-range data flagged as full-range, sRGB transfer. The watermark
/// writeback path uses this so the re-encoded base renders exactly like the
/// donor original in every viewer (matching shadow lift / highlight
/// compression instead of a visibly darker, harsher frame).
///
/// The ffmpeg smoke backend has no range control and encodes these like
/// [`encode_tiles`].
pub fn encode_tiles_oppo_sdr(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
) -> std::io::Result<EncodedTiles> {
    // The only caller re-encodes the primary image of an OPPO photo.
    encode_8bit_tiles(
        tiles,
        width,
        height,
        pixel_bytes,
        use_420,
        HevcColor::OppoSdr,
        HevcContent::Primary,
    )
}

/// ICC-aware JPEG primaries retain device RGB values. Only the YCbCr matrix
/// is declared here; primaries / transfer are supplied by the HEIF ICC profile.
pub(crate) fn encode_icc_primary_tiles(
    tiles: &[&[u8]], width: u32, height: u32, use_420: bool,
) -> std::io::Result<EncodedTiles> {
    encode_8bit_tiles(
        tiles,
        width,
        height,
        3,
        use_420,
        HevcColor::IccPrimary,
        HevcContent::Primary,
    )
}

/// Feature flag: encode single-tile gain maps as 4:2:0 instead of 4:4:4.
///
/// The batch/production path (`encode_tiles`) decides 4:2:0 vs 4:4:4 from
/// the OPPO compat mode (OPPO output requires 4:2:0 for Gallery recognition).
/// This flag only drives the standalone single-tile helpers used in tests /
/// fallbacks, defaulting to 4:4:4 for best chroma precision. Set
/// `XDREMUX_GM_420=1` to force 4:2:0 here too.
pub(super) fn gain_map_420_enabled() -> bool {
    #[cfg(xdremux_gm_420)]
    {
        return true;
    }
    match std::env::var_os("XDREMUX_GM_420") {
        None => false,
        Some(v) => v != "0",
    }
}

/// Convert full-resolution RGB24 to planar YUV420 (BT.709, full range).
/// Chroma is 2x2 box-filtered and subsampled to width/2 × height/2.
/// Returns (y, u, v).
pub fn rgb_to_yuv420(pixels: &[u8], width: u32, height: u32) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let (y_plane, u_plane, v_plane) = rgb_to_yuv444(pixels, width, height);
    yuv444_to_420(y_plane, u_plane, v_plane, width, height)
}

/// Convert full-resolution RGB24 to planar YUV420 (BT.601, limited range).
pub fn rgb_to_yuv420_limited601(
    pixels: &[u8],
    width: u32,
    height: u32,
) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let (y_plane, u_plane, v_plane) = rgb_to_yuv444_limited601(pixels, width, height);
    yuv444_to_420(y_plane, u_plane, v_plane, width, height)
}

/// Convert full-resolution RGB24 to planar YUV444 using BT.601 coefficients
/// in limited (studio) range. OPPO camera HEVC tiles store limited-range data
/// while flagging the stream full-range, so decoders render them with lifted
/// shadows and compressed highlights; matching that data layout makes
/// re-encoded output render identically to the original in every viewer.
pub fn rgb_to_yuv444_limited601(
    pixels: &[u8],
    width: u32,
    height: u32,
) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let plane_size = (width * height) as usize;
    let mut y_plane = vec![0u8; plane_size];
    let mut u_plane = vec![0u8; plane_size];
    let mut v_plane = vec![0u8; plane_size];
    for i in 0..plane_size {
        let r = pixels[i * 3] as f32;
        let g = pixels[i * 3 + 1] as f32;
        let b = pixels[i * 3 + 2] as f32;
        let yy = 16.0 + (65.481 * r + 128.553 * g + 24.966 * b) / 255.0;
        let uu = 128.0 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255.0;
        let vv = 128.0 + (112.0 * r - 93.786 * g - 18.214 * b) / 255.0;
        y_plane[i] = yy.round().clamp(0.0, 255.0) as u8;
        u_plane[i] = uu.round().clamp(0.0, 255.0) as u8;
        v_plane[i] = vv.round().clamp(0.0, 255.0) as u8;
    }
    (y_plane, u_plane, v_plane)
}

fn yuv444_to_420(
    y_plane: Vec<u8>,
    u_plane: Vec<u8>,
    v_plane: Vec<u8>,
    width: u32,
    height: u32,
) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let chroma_w = ((width + 1) / 2) as usize;
    let chroma_h = ((height + 1) / 2) as usize;
    let mut u_small = Vec::with_capacity(chroma_w * chroma_h);
    let mut v_small = Vec::with_capacity(chroma_w * chroma_h);
    for cy in 0..chroma_h {
        for cx in 0..chroma_w {
            let mut usum = 0u32;
            let mut vsum = 0u32;
            let mut n = 0u32;
            for dy in 0..2 {
                let sy = (cy * 2 + dy).min(height as usize - 1);
                for dx in 0..2 {
                    let sx = (cx * 2 + dx).min(width as usize - 1);
                    let i = sy * width as usize + sx;
                    usum += u_plane[i] as u32;
                    vsum += v_plane[i] as u32;
                    n += 1;
                }
            }
            u_small.push((usum / n) as u8);
            v_small.push((vsum / n) as u8);
        }
    }
    (y_plane, u_small, v_small)
}

/// Convert full-resolution RGB24 to planar YUV444 (BT.709, full range).
/// Returns (y, u, v), each width × height.
pub fn rgb_to_yuv444(pixels: &[u8], width: u32, height: u32) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let plane_size = (width * height) as usize;
    let mut y_plane = vec![0u8; plane_size];
    let mut u_plane = vec![0u8; plane_size];
    let mut v_plane = vec![0u8; plane_size];
    for i in 0..plane_size {
        let r = pixels[i * 3] as f32;
        let g = pixels[i * 3 + 1] as f32;
        let b = pixels[i * 3 + 2] as f32;
        let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        y_plane[i] = yy.round().clamp(0.0, 255.0) as u8;
        u_plane[i] = ((b - yy) * 0.5389 + 128.0).round().clamp(0.0, 255.0) as u8;
        v_plane[i] = ((r - yy) * 0.6350 + 128.0).round().clamp(0.0, 255.0) as u8;
    }
    (y_plane, u_plane, v_plane)
}

// ===========================================================================
// Standalone single-tile helpers (tests only)
// ===========================================================================
//
// These predate the batch path and have their own encoder configuration
// (parameter sets repeated in-stream, 4:4:4 unless `XDREMUX_GM_420` is set).
// They are kept outside the `EncodeRequest` path so that configuration stays
// exactly as it was.

/// Encode `width × height` raw 8-bit grayscale pixels as a single-frame HEVC
/// elementary stream. `pixels` must be `width * height` bytes, row-major.
pub fn encode_hevc_tile_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height);
    match HevcBackend::active() {
        // No single-tile configuration of its own: one-picture batch, 4:2:0
        // gray under `XDREMUX_GM_420`, monochrome otherwise.
        #[cfg(xdremux_hevc_vt)]
        HevcBackend::VideoToolbox => {
            encode_tiles(&[pixels], width, height, 1, gain_map_420_enabled(), HevcContent::GainMap)?
                .into_single()
                .map(|(stream, _)| stream)
                .ok_or_else(|| invalid_input("no stream".into()))
        }
        #[cfg(xdremux_hevc_x265)]
        HevcBackend::X265 => x265::encode_single_gray(pixels, width, height),
        #[cfg(xdremux_ffmpeg_fallback)]
        HevcBackend::Ffmpeg => ffmpeg::encode_single(pixels, "gray", width, height),
    }
}

/// Encode `width × height` raw 8-bit RGB pixels (3 bytes per pixel, packed
/// R-G-B) as a single-frame HEVC elementary stream using YUV 4:4:4 so chroma
/// resolution is preserved.
pub fn encode_hevc_tile_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height * 3);
    match HevcBackend::active() {
        #[cfg(xdremux_hevc_vt)]
        HevcBackend::VideoToolbox => {
            encode_tiles(&[pixels], width, height, 3, true, HevcContent::GainMap)?
                .into_single()
                .map(|(stream, _)| stream)
                .ok_or_else(|| invalid_input("no stream".into()))
        }
        #[cfg(xdremux_hevc_x265)]
        HevcBackend::X265 => x265::encode_single_rgb(pixels, width, height),
        #[cfg(xdremux_ffmpeg_fallback)]
        HevcBackend::Ffmpeg => ffmpeg::encode_single(pixels, "rgb24", width, height),
    }
}

/// Remove VPS/SPS/PPS NALs from a single-frame HEVC byte stream, keeping only
/// the IDR slice. Used so gain-map tiles are pure IDR slices — libheif (the
/// Python reference) writes every gain-map tile as a single IDR with no
/// parameter sets; the decoder config lives only in hvcC.
pub fn drop_parameter_nals(data: &[u8]) -> Vec<u8> {
    let nal_3b: &[u8] = &[0, 0, 1];
    let nal_4b: &[u8] = &[0, 0, 0, 1];
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let (_sc_len, nal_start) = if data[pos..].starts_with(nal_4b) {
            (4, pos + 4)
        } else if pos + 3 <= data.len() && data[pos..].starts_with(nal_3b) {
            (3, pos + 3)
        } else {
            pos += 1;
            continue;
        };
        let nal_end = if let Some(next) = data[nal_start..]
            .windows(4)
            .position(|w| w == nal_4b)
        {
            nal_start + next
        } else if let Some(next) = data[nal_start..]
            .windows(3)
            .position(|w| w == nal_3b)
        {
            nal_start + next
        } else {
            data.len()
        };
        let nal_type = (data[nal_start] >> 1) & 0x3f;
        // 32=VPS, 33=SPS, 34=PPS — drop. 39=prefix SEI also dropped.
        if nal_type != 32 && nal_type != 33 && nal_type != 34 && nal_type != 39 {
            out.extend_from_slice(&data[pos..nal_end]);
        }
        pos = nal_end;
    }
    out
}

// ===========================================================================
// NAL utilities and hvcC (backend-independent)
// ===========================================================================

/// Convert a HEVC byte-stream (with 00 00 00 01 or 00 00 01 start codes) to
/// length-prefixed format suitable for ISOBMFF mdat storage.
pub fn hevc_byte_stream_to_length_prefixed(data: &[u8]) -> Vec<u8> {
    let nal_4b: &[u8] = &[0, 0, 0, 1];
    let nal_3b: &[u8] = &[0, 0, 1];
    let mut output = Vec::with_capacity(data.len());
    let mut pos = 0;

    while pos < data.len() {
        let (_sc_len, nal_start) = if data[pos..].starts_with(nal_4b) {
            (4, pos + 4)
        } else if pos + 3 <= data.len() && data[pos..].starts_with(nal_3b) {
            (3, pos + 3)
        } else {
            pos += 1;
            continue;
        };

        let nal_end = if let Some(next) = data[nal_start..]
            .windows(4)
            .position(|w| w == nal_4b)
        {
            nal_start + next
        } else if let Some(next) = data[nal_start..]
            .windows(3)
            .position(|w| w == nal_3b)
        {
            nal_start + next
        } else {
            data.len()
        };

        let nal_size = (nal_end - nal_start) as u32;
        output.extend_from_slice(&nal_size.to_be_bytes());
        output.extend_from_slice(&data[nal_start..nal_end]);

        pos = nal_end;
    }

    output
}

/// Extract hvcC (HEVC decoder configuration record) from an HEVC elementary stream.
pub fn extract_hvcc_config(hevc_data: &[u8]) -> Option<Vec<u8>> {
    let chroma = if gain_map_420_enabled() { 1u8 } else { 3u8 };
    extract_hvcc_config_with_chroma(hevc_data, chroma)
}

/// Strip emulation-prevention bytes (`00 00 03` → `00 00`) from a NAL payload,
/// keeping the leading NAL header byte.
fn rbsp(nal: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal.len());
    let mut i = 0;
    while i < nal.len() {
        if i + 2 < nal.len() && nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] == 3 {
            out.push(0);
            out.push(0);
            i += 3;
        } else {
            out.push(nal[i]);
            i += 1;
        }
    }
    out
}

/// MSB-first bit reader over a byte slice.
struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl BitReader<'_> {
    fn read(&mut self, n: u32) -> u32 {
        let mut val = 0u32;
        for _ in 0..n {
            let byte = self.data[self.pos / 8];
            let bit = (byte >> (7 - (self.pos % 8))) & 1;
            val = (val << 1) | bit as u32;
            self.pos += 1;
        }
        val
    }
}

/// Parse profile_tier_level from an SPS (after NAL header): `sps_..._id(4)
/// max_sub_layers_minus1(3) temporal_id_nesting(1)` then profile_space(2)
/// tier(1) profile_idc(5) compat(32) constraint(48) level(8).
/// Returns (profile_byte, compat_flags, level_idc).
fn sps_ptl(sps: &[u8]) -> Option<(u8, u32, u8)> {
    let rbsp = rbsp(sps);
    if rbsp.len() < 16 {
        return None;
    }
    // HEVC NAL header is 2 bytes (forbidden_bit + type + layer_id + tid_plus1).
    let mut br = BitReader { data: &rbsp[2..], pos: 0 };
    br.read(4); // sps_video_parameter_set_id
    br.read(3); // sps_max_sub_layers_minus1
    br.read(1); // sps_temporal_id_nesting_flag
    let profile = br.read(8) as u8;
    let compat = br.read(32);
    br.read(48); // general_constraint_indicator_flags
    let level = br.read(8) as u8;
    Some((profile, compat, if level != 0 { level } else { 0x5a }))
}

/// Like [sps_ptl], but for a VPS (used as a fallback when the SPS is too
/// short): vps_id(4) base_internal(1) base_available(1) max_layers(6)
/// max_sub_layers(3) nesting(1) reserved_0xffff(16) then profile_tier_level.
fn vps_ptl(vps: &[u8]) -> Option<(u8, u32, u8)> {
    let rbsp = rbsp(vps);
    if rbsp.len() < 22 {
        return None;
    }
    // VPS NAL header is also 2 bytes.
    let mut br = BitReader { data: &rbsp[2..], pos: 0 };
    br.read(4); // vps_video_parameter_set_id
    br.read(1); // vps_base_layer_internal_flag
    br.read(1); // vps_base_layer_available_flag
    br.read(6); // vps_max_layers_minus1
    br.read(3); // vps_max_sub_layers_minus1
    br.read(1); // vps_temporal_id_nesting_flag
    br.read(16); // vps_reserved_0xffff_16bits
    let profile = br.read(8) as u8;
    let compat = br.read(32);
    br.read(48);
    let level = br.read(8) as u8;
    Some((profile, compat, if level != 0 { level } else { 0x5a }))
}

/// Like [extract_hvcc_config], but with an explicit chroma format idc. The
/// hardware-encoding split path always produces 4:2:0 (MediaCodec has no
/// 4:4:4 encoder), so its hvcC must claim chroma 1 even when the x265 fallback
/// default is still 4:4:4.
pub fn extract_hvcc_config_with_chroma(hevc_data: &[u8], chroma: u8) -> Option<Vec<u8>> {
    extract_hvcc_config_with_chroma_and_depth(hevc_data, chroma, 8)
}

/// Like [`extract_hvcc_config_with_chroma`] but records the bit depth in the
/// `hvcC` record. The Main10 linear thumbnail needs `bitDepthLuma/Chroma`
/// = 2 (10-bit) instead of the 8-bit default.
pub fn extract_hvcc_config_with_chroma_and_depth(
    hevc_data: &[u8],
    chroma: u8,
    bit_depth: u8,
) -> Option<Vec<u8>> {
    let nal_3b: &[u8] = &[0, 0, 1];
    let nal_4b: &[u8] = &[0, 0, 0, 1];
    let mut nal_positions: Vec<usize> = Vec::new();
    let mut search = 0;
    while search < hevc_data.len() {
        if hevc_data[search..].starts_with(nal_4b) {
            nal_positions.push(search);
            search += 4;
        } else if search + 3 <= hevc_data.len() && hevc_data[search..].starts_with(nal_3b) {
            nal_positions.push(search);
            search += 3;
        } else {
            search += 1;
        }
    }

    if nal_positions.is_empty() {
        return None;
    }

    let mut vps_nal: Option<&[u8]> = None;
    let mut sps_nal: Option<&[u8]> = None;
    let mut pps_nal: Option<&[u8]> = None;
    let bit_depth_luma: u8 = bit_depth;
    let bit_depth_chroma: u8 = bit_depth;

    for i in 0..nal_positions.len() {
        let start_code_len = if hevc_data[nal_positions[i]..].starts_with(nal_4b) { 4 } else { 3 };
        let nal_data_start = nal_positions[i] + start_code_len;
        let nal_data_end = if i + 1 < nal_positions.len() {
            nal_positions[i + 1]
        } else {
            hevc_data.len()
        };

        if nal_data_start >= nal_data_end {
            continue;
        }

        let nal_header = hevc_data[nal_data_start];
        let nal_type = (nal_header >> 1) & 0x3f;
        let payload = &hevc_data[nal_data_start..nal_data_end];

        match nal_type {
            32 => { vps_nal = Some(payload); }
            33 => { sps_nal = Some(payload); }
            34 => { pps_nal = Some(payload); }
            _ => {}
        }
    }

    let vps = vps_nal?;
    let sps = sps_nal?;
    let pps = pps_nal?;

    // Build hvcC record per ISO 14496-15
    let mut hvcc = Vec::new();
    hvcc.push(1); // configurationVersion

    // Profile / compat / level from the SPS's profile_tier_level, parsed from
    // the RBSP (after removing emulation-prevention bytes). This is reliable
    // for both x265 and MediaCodec streams, whereas reading the VPS at fixed
    // offsets only works for x265's VPS layout.
    let (profile_byte, compat_flags, level_idc) = sps_ptl(sps)
        .or_else(|| vps_ptl(vps))
        .unwrap_or((0x04, 0x08000000u32, 0x5a));

    // Always claim Main 4:4:4 compatibility for yuv444p
    let compat_flags = if chroma == 3u8 {
        0x08000000u32
    } else {
        compat_flags
    };

    hvcc.push(profile_byte);
    hvcc.extend_from_slice(&compat_flags.to_be_bytes());
    hvcc.extend_from_slice(&[0u8; 6]); // constraint flags
    hvcc.push(level_idc);
    hvcc.extend_from_slice(&[0xf0, 0x00]); // min_spatial_segmentation
    hvcc.push(0xfc); // parallelismType
    hvcc.push(0xfc | (chroma & 0x03)); // chromaFormatIdc
    hvcc.push(0xf8 | ((bit_depth_luma - 8) & 0x07)); // bitDepthLuma
    hvcc.push(0xf8 | ((bit_depth_chroma - 8) & 0x07)); // bitDepthChroma
    hvcc.extend_from_slice(&[0, 0]); // avgFrameRate
    hvcc.push(0x0f); // constantFrameRate + numTemporalLayers + lengthSizeMinusOne
    hvcc.push(3); // numOfArrays

    fn push_nal_array(hvcc: &mut Vec<u8>, nal_type: u8, nal_data: &[u8]) {
        // array_completeness=0, reserved=1 — matches the exact byte pattern
        // pillow-heif / libheif writes for gain-map hvcC arrays (0x60/0x61/0x62
        // for VPS/SPS/PPS). Google Photos' Ultra HDR detector compares the
        // gain-map hvcC arrays byte-for-byte with what its own reference
        // encoder produces; a plain 0x20 pattern (reserved=0) is rejected.
        hvcc.push(0x40 | (nal_type & 0x3f));
        hvcc.extend_from_slice(&1u16.to_be_bytes());
        hvcc.extend_from_slice(&(nal_data.len() as u16).to_be_bytes());
        hvcc.extend_from_slice(nal_data);
    }

    push_nal_array(&mut hvcc, 32, vps);
    push_nal_array(&mut hvcc, 33, sps);
    push_nal_array(&mut hvcc, 34, pps);

    Some(hvcc)
}

/// True when the active backend can encode Main10 at all: VideoToolbox
/// always, the static encoder when its optional 10-bit archive was linked.
///
/// When false the caller must fall back to the 8-bit Apple Log thumbnail; the
/// 10-bit archive is built per platform and is not required everywhere yet
/// (see `docs/research/x265-main10-feasibility-20261025.md`).
pub fn main10_available() -> bool {
    HevcBackend::active().supports_10bit(64, 64)
}

/// True when [`encode_thumbnail_10bit`] can encode a `width` x `height`
/// picture with the active backend (some have a minimum size).
pub fn main10_supported(width: u32, height: u32) -> bool {
    HevcBackend::active().supports_10bit(width, height)
}

/// Convert one 16-bit Apple Log code (`0..=65535`) to a 10-bit sample.
///
/// The 16-bit codes are the native precision of the Styles Linear Thumbnail;
/// x265's 10-bit build takes samples in `0..=1023`.
pub fn code16_to_10bit(code: u16) -> u16 {
    ((u32::from(code) * 1023 + 32_767) / 65_535) as u16
}

/// RGB (16-bit Apple Log codes) -> planar YUV 4:2:0 at 10-bit, BT.601 limited
/// range (Y 64..=940, chroma 64..=960) which is what HEVC Main10 HEIF stills
/// conventionally use.
pub fn codes16_to_yuv420_10bit(
    codes16: &[u16],
    width: u32,
    height: u32,
) -> (Vec<u16>, Vec<u16>, Vec<u16>) {
    let (w, h) = (width as usize, height as usize);
    let plane = w * h;
    debug_assert_eq!(codes16.len(), plane * 3);
    let mut y_plane = vec![0u16; plane];
    let mut u_full = vec![0f32; plane];
    let mut v_full = vec![0f32; plane];
    for i in 0..plane {
        let r = f32::from(code16_to_10bit(codes16[i * 3])) / 1023.0;
        let g = f32::from(code16_to_10bit(codes16[i * 3 + 1])) / 1023.0;
        let b = f32::from(code16_to_10bit(codes16[i * 3 + 2])) / 1023.0;
        y_plane[i] = (64.0 + 876.0 * (0.299 * r + 0.587 * g + 0.114 * b))
            .round()
            .clamp(0.0, 1023.0) as u16;
        u_full[i] = 512.0 + 896.0 * (-0.168_736 * r - 0.331_264 * g + 0.5 * b);
        v_full[i] = 512.0 + 896.0 * (0.5 * r - 0.418_688 * g - 0.081_312 * b);
    }
    let cw = w.div_ceil(2);
    let ch = h.div_ceil(2);
    let mut u_plane = vec![0u16; cw * ch];
    let mut v_plane = vec![0u16; cw * ch];
    for cy in 0..ch {
        for cx in 0..cw {
            let (mut su, mut sv, mut count) = (0.0f32, 0.0f32, 0.0f32);
            for dy in 0..2 {
                for dx in 0..2 {
                    let (x, y) = (cx * 2 + dx, cy * 2 + dy);
                    if x < w && y < h {
                        let index = y * w + x;
                        su += u_full[index];
                        sv += v_full[index];
                        count += 1.0;
                    }
                }
            }
            let index = cy * cw + cx;
            u_plane[index] = (su / count).round().clamp(0.0, 1023.0) as u16;
            v_plane[index] = (sv / count).round().clamp(0.0, 1023.0) as u16;
        }
    }
    (y_plane, u_plane, v_plane)
}

/// Encode one 16-bit Apple Log thumbnail raster as a Main10 4:2:0 HEVC
/// picture (BT.601 limited range, see [`codes16_to_yuv420_10bit`]).
///
/// Returns the Annex-B stream exactly as the backend produced it (parameter
/// sets + one picture), ready for [`extract_hvcc_config_with_chroma_and_depth`]
/// and [`drop_parameter_nals`]. Fails with `Unsupported` when
/// [`main10_available`] is false.
pub fn encode_thumbnail_10bit(
    codes16: &[u16],
    width: u32,
    height: u32,
) -> std::io::Result<EncodedTiles> {
    let request = EncodeRequest {
        width,
        height,
        layout: HevcLayout::Yuv420,
        bit_depth: HevcBitDepth::Ten,
        color: HevcColor::Bt601LimitedLinear,
        content: HevcContent::LinearThumbnail,
    };
    encode(&request, SourcePictures::Rgb16(codes16))
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code16_to_10bit_endpoints_and_monotonic() {
        assert_eq!(code16_to_10bit(0), 0);
        assert_eq!(code16_to_10bit(65535), 1023);
        assert_eq!(code16_to_10bit(32_768), 512);
        let mut previous = 0u16;
        for code in [0u16, 1024, 8192, 32768, 49152, 65535] {
            let value = code16_to_10bit(code);
            assert!(value >= previous, "not monotonic at {code}");
            previous = value;
        }
    }

    #[test]
    fn codes16_to_yuv420_10bit_maps_white_and_black() {
        let white = vec![65535u16; 4 * 4 * 3];
        let (y, u, v) = codes16_to_yuv420_10bit(&white, 4, 4);
        assert_eq!(y.len(), 16);
        assert_eq!(u.len(), 4, "chroma is half resolution");
        assert_eq!(v.len(), 4);
        assert!((i32::from(y[0]) - 940).abs() <= 1, "white Y {}", y[0]);
        assert!((i32::from(u[0]) - 512).abs() <= 1, "white U {}", u[0]);
        assert!((i32::from(v[0]) - 512).abs() <= 1, "white V {}", v[0]);

        let black = vec![0u16; 4 * 4 * 3];
        let (y_black, _, _) = codes16_to_yuv420_10bit(&black, 4, 4);
        assert!(
            (i32::from(y_black[0]) - 64).abs() <= 1,
            "black Y {}",
            y_black[0]
        );
    }

    #[cfg(xdremux_main10)]
    #[test]
    fn main10_thumbnail_encode_is_profile_2_and_10bit_hvcc() {
        assert!(main10_available(), "test only runs with xdremux_main10");
        // x265 requires at least one CTU per edge (64x64 by default).
        let (w, h) = (64u32, 64u32);
        let mut codes = Vec::with_capacity((w * h * 3) as usize);
        for y in 0..h {
            for x in 0..w {
                let code = ((x + y) * 65535 / (w + h - 2)) as u16;
                codes.extend_from_slice(&[code, code, code]);
            }
        }
        let (stream, chroma) = encode_thumbnail_10bit(&codes, w, h)
            .expect("10-bit encode")
            .into_single()
            .expect("one stream");
        assert_eq!(chroma, 1, "Main10 thumbnail is 4:2:0");
        assert!(stream.len() > 100, "stream too small: {}", stream.len());
        let hvcc = extract_hvcc_config_with_chroma_and_depth(&stream, chroma, 10).expect("hvcC");
        assert_eq!(hvcc[1] & 0x1f, 2, "SPS profile must be Main10 (2)");
        assert_eq!(hvcc[17] & 0x07, 2, "hvcC bitDepthLuma must be 10-bit");
        assert_eq!(hvcc[18] & 0x07, 2, "hvcC bitDepthChroma must be 10-bit");
    }

    #[cfg(xdremux_main10)]
    #[test]
    fn main10_thumbnail_reconstruction_matches_source_luma() {
        use std::os::raw::c_int;
        // Regression for 5512ea7: strides were passed in samples, x265 wants
        // bytes, so every row was read from half the right offset and the
        // picture came out as two squeezed copies.
        let (w, h) = (128u32, 96u32);
        let mut codes = Vec::with_capacity((w * h * 3) as usize);
        for y in 0..h {
            for x in 0..w {
                // Asymmetric in x and y so a wrong row step cannot match.
                let code = ((x * 3 + y * 5) % 256 * 256) as u16;
                codes.extend_from_slice(&[code, code, code]);
            }
        }
        let (y_plane, u_plane, v_plane) = codes16_to_yuv420_10bit(&codes, w, h);
        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: c_int = 0;
        let mut psnr = -1.0f64;
        let status = unsafe {
            crate::x265_ffi::xdremux_encode_10bit_planes_checked(
                y_plane.as_ptr(),
                u_plane.as_ptr(),
                v_plane.as_ptr(),
                w as c_int,
                h as c_int,
                &mut out_ptr,
                &mut out_len,
                &mut psnr,
            )
        };
        assert_eq!(status, 0, "10-bit encode failed");
        unsafe { crate::x265_ffi::xdremux_free_stream(out_ptr) };
        assert!(psnr > 35.0, "reconstructed luma PSNR {psnr:.1} dB: input layout is wrong");
    }

    #[test]
    fn hevc_tile_gray_512() {
        let w = 512u32;
        let h = 512u32;
        let mut pixels = vec![0u8; (w * h) as usize];
        for y in 0..h {
            for x in 0..w {
                pixels[(y * w + x) as usize] =
                    ((x as f32 / (w - 1) as f32) * 128.0 + (y as f32 / (h - 1) as f32) * 127.0) as u8;
            }
        }

        let hevc = encode_hevc_tile_gray(&pixels, w, h).expect("encode_hevc_tile_gray failed");
        assert!(hevc.len() > 100, "HEVC must be >100 bytes (got {})", hevc.len());

        let nal_count = hevc.windows(4).filter(|w| *w == b"\x00\x00\x00\x01").count();
        assert!(nal_count >= 2, "at least VPS+SPS/PPS NAL units expected");

        eprintln!("✓ hevc_tile_gray_512: {} bytes, {} NALs", hevc.len(), nal_count);
    }

    #[test]
    fn hevc_tile_rgb_256() {
        let w = 256u32;
        let h = 256u32;
        let mut pixels = vec![0u8; (w * h * 3) as usize];
        for y in 0..h {
            for x in 0..w {
                let val = ((x + y) % 256) as u8;
                let base = ((y * w + x) * 3) as usize;
                pixels[base] = val;
                pixels[base + 1] = val;
                pixels[base + 2] = val;
            }
        }

        let hevc = encode_hevc_tile_rgb(&pixels, w, h).expect("encode_hevc_tile_rgb failed");
        assert!(hevc.len() > 100);

        eprintln!("✓ hevc_tile_rgb_256: {} bytes", hevc.len());
    }

    #[test]
    fn batch_encode_matches_single_tile_headers() {
        // Single-frame loop encoding: tile 0 keeps VPS/SPS/PPS (source for
        // the hvcC config record), later tiles carry pure IDR slices. This
        // is what ImageIO's ISO gain-map decoder requires — embedded
        // parameter sets in every tile used to break macOS recognition.
        let w = 512u32;
        let h = 512u32;
        let make = |seed: u8| {
            let mut px = vec![0u8; (w * h) as usize];
            for (i, v) in px.iter_mut().enumerate() {
                *v = (i as u8).wrapping_mul(31).wrapping_add(seed);
            }
            px
        };
        let tiles: Vec<Vec<u8>> = (0..4).map(|s| make(s)).collect();
        let refs: Vec<&[u8]> = tiles.iter().map(|t| t.as_slice()).collect();

        let batch = encode_tiles(&refs, w, h, 1, false, HevcContent::GainMap)
            .expect("batch encode failed");
        assert_eq!(batch.chroma_format_idc(), 0, "gray without 4:2:0 is monochrome");
        let streams = batch.streams;
        assert_eq!(streams.len(), 4, "one stream per tile");

        for (i, s) in streams.iter().enumerate() {
            let nal_types: Vec<u8> = {
                let mut pos = 0;
                let mut types = Vec::new();
                while pos < s.len() {
                    let sc = if s[pos..].starts_with(&[0, 0, 0, 1]) { 4 }
                        else if pos + 3 <= s.len() && s[pos..].starts_with(&[0, 0, 1]) { 3 }
                        else { pos += 1; continue };
                    let start = pos + sc;
                    if start < s.len() {
                        types.push((s[start] >> 1) & 0x3f);
                    }
                    pos = start;
                }
                types
            };
            // Every tile must decode standalone → IDR present in each.
            assert!(
                nal_types.iter().any(|&t| t == 19 || t == 20 || t == 21),
                "tile {i} missing IDR: {nal_types:?}"
            );
            if cfg!(xdremux_ffmpeg_fallback) {
                // The ffmpeg fallback encodes tiles independently, so every
                // tile is self-contained with its own parameter sets.
                assert!(nal_types.contains(&32), "tile {i} missing VPS: {nal_types:?}");
                assert!(nal_types.contains(&33), "tile {i} missing SPS: {nal_types:?}");
                assert!(nal_types.contains(&34), "tile {i} missing PPS: {nal_types:?}");
            } else if i == 0 {
                assert!(nal_types.contains(&32), "tile 0 missing VPS: {nal_types:?}");
                assert!(nal_types.contains(&33), "tile 0 missing SPS: {nal_types:?}");
                assert!(nal_types.contains(&34), "tile 0 missing PPS: {nal_types:?}");
                // hvcC extracts from tile 0 (the parameter-set carrier).
                let hvcc = extract_hvcc_config(s).expect("hvcC from tile 0");
                assert!(!hvcc.is_empty(), "tile 0 hvcC empty");
            } else {
                assert!(!nal_types.contains(&32), "tile {i} has embedded VPS: {nal_types:?}");
                assert!(!nal_types.contains(&33), "tile {i} has embedded SPS: {nal_types:?}");
                assert!(!nal_types.contains(&34), "tile {i} has embedded PPS: {nal_types:?}");
            }
        }
        eprintln!("✓ batch_encode_matches_single_tile_headers: tile0 params + pure-IDR rest");
    }
}
