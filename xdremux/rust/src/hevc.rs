//! HEVC tile encoder.
//!
//! - Default (all platforms): x265 static-linked, C API called directly.
//! - Optional fallback: `XDREMUX_USE_FFMPEG=1` at build time compiles out the
//!   x265 path and calls `ffmpeg` as a subprocess instead (desktop only).

#[cfg(xdremux_ffmpeg_fallback)]
use std::io::{Read, Write};
#[cfg(xdremux_ffmpeg_fallback)]
use std::path::PathBuf;
#[cfg(xdremux_ffmpeg_fallback)]
use std::process::{Command, Stdio};
#[cfg(xdremux_ffmpeg_fallback)]
use std::thread;

/// `CREATE_NO_WINDOW` — suppresses the console window flash for every ffmpeg
/// subprocess on Windows (const 0x08000000, from winbase.h).
#[cfg(all(windows, xdremux_ffmpeg_fallback))]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[cfg(all(windows, xdremux_ffmpeg_fallback))]
use std::os::windows::process::CommandExt;

/// ffmpeg-fallback batch encoder: loops the single-tile subprocess path.
/// Only used by the `XDREMUX_USE_FFMPEG=1` desktop smoke build, so per-tile
/// parameter sets (which the production x265 loop deliberately avoids) are
/// acceptable here. `use_420` is ignored — the fallback always encodes the
/// tile's native pixel layout.
#[cfg(xdremux_ffmpeg_fallback)]
pub fn x265_encode_tiles(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    _use_420: bool,
) -> std::io::Result<Vec<Vec<u8>>> {
    let format = match pixel_bytes {
        1 => "gray",
        3 => "rgb24",
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("unsupported pixel_bytes {pixel_bytes}"),
            ))
        }
    };
    tiles
        .iter()
        .map(|t| encode_raw_tile(t, format, width, height))
        .collect()
}

/// Feature flag: encode single-tile gain maps as 4:2:0 instead of 4:4:4.
///
/// The batch/production path (`x265_encode_tiles`) decides 4:2:0 vs 4:4:4 from
/// the OPPO compat mode (OPPO output requires 4:2:0 for Gallery recognition).
/// This flag only drives the standalone single-tile helpers used in tests /
/// fallbacks, defaulting to 4:4:4 for best chroma precision. Set
/// `XDREMUX_GM_420=1` to force 4:2:0 here too.
fn gain_map_420_enabled() -> bool {
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
// Public API
// ===========================================================================

/// Encode `width × height` raw 8-bit grayscale pixels as a single-frame HEVC
/// elementary stream. `pixels` must be `width * height` bytes, row-major.
pub fn encode_hevc_tile_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height);
    #[cfg(not(xdremux_ffmpeg_fallback))]
    {
        return x265_encode_gray(pixels, width, height);
    }
    #[cfg(xdremux_ffmpeg_fallback)]
    {
        encode_raw_tile(pixels, "gray", width, height)
    }
}

/// Encode `width × height` raw 8-bit RGB pixels (3 bytes per pixel, packed
/// R-G-B) as a single-frame HEVC elementary stream using YUV 4:4:4 so chroma
/// resolution is preserved.
pub fn encode_hevc_tile_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height * 3);
    #[cfg(not(xdremux_ffmpeg_fallback))]
    {
        return x265_encode_rgb(pixels, width, height);
    }
    #[cfg(xdremux_ffmpeg_fallback)]
    {
        encode_raw_tile(pixels, "rgb24", width, height)
    }
}

// ===========================================================================
// x265 static-linked encoder (default on all platforms)
// ===========================================================================

/// Debug log helper — logcat on Android, stderr elsewhere.
#[cfg(not(xdremux_ffmpeg_fallback))]
fn xlog(msg: &str) {
    #[cfg(target_os = "android")]
    {
        use std::ffi::CString;
        use std::os::raw::c_char;
        extern "C" {
            fn __android_log_print(prio: i32, tag: *const c_char, fmt: *const c_char, ...) -> i32;
        }
        let tag = CString::new("xdremux_x265").unwrap();
        let fmt = CString::new("%s").unwrap();
        let m = CString::new(msg).unwrap_or_else(|_| CString::new("(bad utf8)").unwrap());
        unsafe {
            __android_log_print(4, tag.as_ptr(), fmt.as_ptr(), m.as_ptr()); // 4=INFO
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        if std::env::var_os("XDREMUX_X265_DEBUG").is_some() {
            eprintln!("[xdremux_x265] {msg}");
        }
    }
}

#[cfg(not(xdremux_ffmpeg_fallback))]
fn x265_encode_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    use crate::x265_ffi::*;
    use std::ffi::CString;
    use std::os::raw::c_void;

    xlog(&format!("x265 gray {}x{}", width, height));

    let use_420 = gain_map_420_enabled();

    // Gray → YUV. 4:4:4: full-res U/V = 128 (iOS expects chroma_format_idc=3).
    // 4:2:0: Y is the gray, chroma is half-res 128.
    let plane_size = (width * height) as usize;
    let y_plane = pixels.to_vec();
    let (u_plane, v_plane, chroma_stride) = if use_420 {
        let cw = ((width + 1) / 2) as usize;
        let ch = ((height + 1) / 2) as usize;
        (
            vec![128u8; cw * ch],
            vec![128u8; cw * ch],
            ((width + 1) / 2) as i32,
        )
    } else {
        (vec![128u8; plane_size], vec![128u8; plane_size], width as i32)
    };

    unsafe {
        let param = x265_param_alloc();
        if param.is_null() {
            return Err(io_err("x265_param_alloc failed"));
        }

        let preset = CString::new("ultrafast").unwrap();
        if x265_param_default_preset(param, preset.as_ptr(), std::ptr::null()) != 0 {
            x265_param_free(param);
            return Err(io_err("x265_param_default_preset failed"));
        }

        set_param(param, "input-csp", if use_420 { "i420" } else { "i444" });
        xdremux_param_set_basic(param, width as i32, height as i32, 8, 1);
        set_param(param, "fps", "1");
        set_param(param, "crf", "18");
        set_param(param, "range", "full");
        set_param(param, "repeat-headers", "1");
        set_param(param, "keyint", "1");
        let prof = CString::new(if use_420 {
            // Single-frame gain-map tiles: Main Still Picture, matching the
            // Swift/ImageIO reference. "main" emits a Main-profile SPS that
            // hvcC extraction then mislabels, which ImageIO rejects.
            "mainstillpicture"
        } else {
            "main444-8"
        })
        .unwrap();
        x265_param_apply_profile(param, prof.as_ptr());
        set_param(param, "frame-threads", "1");
        set_param(param, "pools", "1");

        xlog("opening encoder");
        let encoder = x265_encoder_open_216(param);
        if encoder.is_null() {
            xlog("encoder open FAILED");
            x265_param_free(param);
            return Err(io_err("x265_encoder_open failed"));
        }
        xlog("encoder opened OK");

        let pic = x265_picture_alloc();
        x265_picture_init(param, pic);
        xdremux_pic_set_planes(
            pic,
            y_plane.as_ptr() as *mut c_void,
            u_plane.as_ptr() as *mut c_void,
            v_plane.as_ptr() as *mut c_void,
            width as i32,
            chroma_stride,
            chroma_stride,
        );
        xdremux_pic_set_pts(pic, 0);

        let result = do_encode(encoder, pic);

        x265_picture_free(pic);
        x265_encoder_close(encoder);
        x265_param_free(param);

        result
    }
}

#[cfg(not(xdremux_ffmpeg_fallback))]
fn x265_encode_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    use crate::x265_ffi::*;
    use std::ffi::CString;
    use std::os::raw::c_void;

    xlog(&format!("x265 rgb {}x{}", width, height));

    let use_420 = gain_map_420_enabled();

    // Convert RGB24 → planar YUV (BT.709, full range). 4:4:4 keeps full-res
    // chroma; 4:2:0 downsamples chroma 2x2 (for the MediaCodec path test).
    let (y_plane, u_plane, v_plane, chroma_stride);
    if use_420 {
        let (y, u, v) = rgb_to_yuv420(pixels, width, height);
        y_plane = y;
        u_plane = u;
        v_plane = v;
        chroma_stride = ((width + 1) / 2) as i32;
    } else {
        let (y, u, v) = rgb_to_yuv444(pixels, width, height);
        y_plane = y;
        u_plane = u;
        v_plane = v;
        chroma_stride = width as i32;
    }

    unsafe {
        let param = x265_param_alloc();
        if param.is_null() {
            return Err(io_err("x265_param_alloc failed"));
        }

        let preset = CString::new("medium").unwrap();
        if x265_param_default_preset(param, preset.as_ptr(), std::ptr::null()) != 0 {
            x265_param_free(param);
            return Err(io_err("x265_param_default_preset failed"));
        }

        set_param(param, "input-csp", if use_420 { "i420" } else { "i444" });
        xdremux_param_set_basic(param, width as i32, height as i32, 8, 1);
        set_param(param, "fps", "1");
        set_param(param, "crf", "14");
        set_param(param, "range", "full");
        set_param(param, "repeat-headers", "1");
        set_param(param, "keyint", "1");
        let prof = CString::new(if use_420 {
            // Single-frame gain-map tiles: Main Still Picture, matching the
            // Swift/ImageIO reference. "main" emits a Main-profile SPS that
            // hvcC extraction then mislabels, which ImageIO rejects.
            "mainstillpicture"
        } else {
            "main444-8"
        })
        .unwrap();
        x265_param_apply_profile(param, prof.as_ptr());
        set_param(param, "colormatrix", "bt709");
        set_param(param, "colorprim", "bt709");
        set_param(param, "transfer", "bt709");
        set_param(param, "psy-rd", "0");
        set_param(param, "aq-mode", "1");
        set_param(param, "frame-threads", "1");
        set_param(param, "pools", "1");

        xlog("opening encoder");
        let encoder = x265_encoder_open_216(param);
        if encoder.is_null() {
            xlog("encoder open FAILED");
            x265_param_free(param);
            return Err(io_err("x265_encoder_open failed"));
        }
        xlog("encoder opened OK");

        let pic = x265_picture_alloc();
        x265_picture_init(param, pic);
        xdremux_pic_set_planes(
            pic,
            y_plane.as_ptr() as *mut c_void,
            u_plane.as_ptr() as *mut c_void,
            v_plane.as_ptr() as *mut c_void,
            width as i32,
            chroma_stride,
            chroma_stride,
        );
        xdremux_pic_set_pts(pic, 0);

        let result = do_encode(encoder, pic);

        x265_picture_free(pic);
        x265_encoder_close(encoder);
        x265_param_free(param);

        result
    }
}

/// Convert one tile's pixel buffer to planar YUV and set it on `pic`.
/// `pixel_bytes` selects gray (1) or RGB24 (3). 4:2:0 mode (xdremux_gm_420)
/// downsamples chroma 2x2; otherwise full-res 4:4:4 with U/V=128 for gray.
#[cfg(not(xdremux_ffmpeg_fallback))]
unsafe fn setup_pic_planes(
    pic: *mut crate::x265_ffi::x265_picture,
    param: *mut crate::x265_ffi::x265_param,
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
) -> (Vec<u8>, Vec<u8>, Vec<u8>, i32) {
    use crate::x265_ffi::*;
    use std::os::raw::c_void;

    // Must match the encoder's configured input-csp: the batch caller passes
    // the same flag it gave open_encoder. Reading gain_map_420_enabled() here
    // used to diverge from the encoder config (i420 param + 4:4:4 planes),
    // which scrambled chroma and produced per-tile colour shifts.
    let (y_plane, u_plane, v_plane, chroma_stride) = if pixel_bytes == 3 {
        let (y, u, v) = if use_420 {
            rgb_to_yuv420(pixels, width, height)
        } else {
            rgb_to_yuv444(pixels, width, height)
        };
        let stride = if use_420 { ((width + 1) / 2) as i32 } else { width as i32 };
        (y, u, v, stride)
    } else {
        // gray: Y = pixels, U/V = 128 (full-res for 4:4:4, half-res for 4:2:0)
        let plane_size = (width * height) as usize;
        let y_plane = pixels.to_vec();
        let (u_plane, v_plane, stride) = if use_420 {
            let cw = ((width + 1) / 2) as usize;
            let ch = ((height + 1) / 2) as usize;
            (vec![128u8; cw * ch], vec![128u8; cw * ch], ((width + 1) / 2) as i32)
        } else {
            (vec![128u8; plane_size], vec![128u8; plane_size], width as i32)
        };
        (y_plane, u_plane, v_plane, stride)
    };

    x265_picture_init(param, pic);
    xdremux_pic_set_planes(
        pic,
        y_plane.as_ptr() as *mut c_void,
        u_plane.as_ptr() as *mut c_void,
        v_plane.as_ptr() as *mut c_void,
        width as i32,
        chroma_stride,
        chroma_stride,
    );
    (y_plane, u_plane, v_plane, chroma_stride)
}

/// Open an x265 encoder with the standard gain-map config.
/// `pixel_bytes` picks gray (ultrafast, CRF18) vs RGB (medium, CRF14) presets.
#[cfg(not(xdremux_ffmpeg_fallback))]
unsafe fn open_encoder(
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
) -> std::io::Result<(*mut crate::x265_ffi::x265_param, *mut crate::x265_ffi::x265_encoder)> {
    use crate::x265_ffi::*;
    use std::ffi::CString;

    let is_rgb = pixel_bytes == 3;

    let param = x265_param_alloc();
    if param.is_null() {
        return Err(io_err("x265_param_alloc failed"));
    }

    let preset = CString::new(if is_rgb { "medium" } else { "ultrafast" }).unwrap();
    if x265_param_default_preset(param, preset.as_ptr(), std::ptr::null()) != 0 {
        x265_param_free(param);
        return Err(io_err("x265_param_default_preset failed"));
    }

    set_param(param, "input-csp", if use_420 {
        "i420"
    } else if !is_rgb {
        // ISO 21496-1 gain maps are monochrome. Encoding gray through i444
        // produces a 4:4:4 "pseudo-color" stream that standard decoders
        // (e.g. Android's gain-map path) refuse to treat as a gain map.
        "i400"
    } else {
        "i444"
    });
    xdremux_param_set_basic(param, width as i32, height as i32, 8, 1);
    set_param(param, "fps", "1");
    set_param(param, "crf", if is_rgb { "14" } else { "18" });
    set_param(param, "range", "full");
    // Parameter sets are emitted once at the head of the stream (and written
    // into hvcC); each keyframe tile is then only its IDR slice. The split
    // logic below gives tile 0 the parameter sets and later tiles pure IDRs,
    // which is what ImageIO's ISO-gain-map decoder expects (it reads params
    // from hvcC). With repeat-headers=1 every tile carried VPS/SPS/PPS, which
    // ImageIO rejects (fails to decode the gain map).
    set_param(param, "repeat-headers", "0");
    set_param(param, "keyint", "1");
    let prof = CString::new(if use_420 {
            // Single-frame gain-map tiles: Main Still Picture, matching the
            // Swift/ImageIO reference. "main" emits a Main-profile SPS that
            // hvcC extraction then mislabels, which ImageIO rejects.
            "mainstillpicture"
        } else if !is_rgb {
            // Monochrome gain map: Rext/Monochrome profile.
            "main444-8"
        } else {
            "main444-8"
        })
        .unwrap();
    x265_param_apply_profile(param, prof.as_ptr());
    // Batch path: keep per-frame WPP row parallelism (default thread pool)
    // but disable B-frames / lookahead so frames are emitted strictly in
    // order with no pipeline delay — feed one frame, get one IDR back.
    // The single-tile functions keep frame-threads=1 to avoid spawning
    // threads for a lone 512x512 frame.
    set_param(param, "bframes", "0");
    set_param(param, "rc-lookahead", "0");
    set_param(param, "no-open-gop", "0"); // every IDR standalone
    if is_rgb {
        set_param(param, "colormatrix", "bt709");
        set_param(param, "colorprim", "bt709");
        set_param(param, "transfer", "bt709");
        set_param(param, "psy-rd", "0");
        set_param(param, "aq-mode", "1");
    }

    xlog(&format!("x265 opening {}x{} (rgb={})", width, height, is_rgb));
    let encoder = x265_encoder_open_216(param);
    if encoder.is_null() {
        xlog("encoder open FAILED");
        x265_param_free(param);
        return Err(io_err("x265_encoder_open failed"));
    }
    Ok((param, encoder))
}

/// Encode a batch of same-size tiles with ONE x265 encoder instance.
/// With `keyint=1` every tile is an independent keyframe whose NALs are
/// contiguous in the output, so the stream is split per-tile after the fact.
/// Reusing the encoder + default multi-frame pipeline avoids per-tile
/// open/close and parallelizes the WPP rows (measured ~5x faster than one
/// encoder per tile on a 48-tile UHDR gain map).
#[cfg(not(xdremux_ffmpeg_fallback))]
pub fn x265_encode_tiles(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
) -> std::io::Result<Vec<Vec<u8>>> {
    use crate::x265_ffi::*;

    if tiles.is_empty() {
        return Ok(Vec::new());
    }
    let expected = (width * height * pixel_bytes as u32) as usize;
    for t in tiles {
        if t.len() != expected {
            return Err(io_err("tile size mismatch in batch encode"));
        }
    }

    unsafe {
        // Encode each tile with its own single-frame encoder session. This is
        // deterministic (no multi-frame pipeline reordering to split), and lets
        // us emit tile 0 with its parameter sets (VPS/SPS/PPS, needed for hvcC
        // extraction) while every other tile is a pure IDR slice — the shape
        // ImageIO's ISO 21496-1 gain-map decoder expects (it reads the decoder
        // config from hvcC, not from each tile).
        let mut results: Vec<Vec<u8>> = Vec::with_capacity(tiles.len());
        for (idx, tile) in tiles.iter().enumerate() {
            let (param, encoder) = open_encoder(width, height, pixel_bytes, use_420)?;
            let pic = x265_picture_alloc();
            let (y, u, v, _stride) =
                setup_pic_planes(pic, param, tile, width, height, pixel_bytes, use_420);
            let pic_out = x265_picture_alloc();
            let mut nals: *mut x265_nal = std::ptr::null_mut();
            let mut nal_count: u32 = 0;
            xdremux_pic_set_pts(pic, 0);
            let ret = x265_encoder_encode(encoder, &mut nals, &mut nal_count, pic, pic_out);
            drop(y);
            drop(u);
            drop(v);
            x265_picture_free(pic);
            if ret < 0 {
                x265_picture_free(pic_out);
                x265_encoder_close(encoder);
                x265_param_free(param);
                return Err(io_err("x265_encoder_encode failed"));
            }

            // Flush the tail of the pipeline.
            let mut chunk = Vec::new();
            if ret > 0 {
                append_nals(&mut chunk, nals, nal_count);
            }
            loop {
                let r = x265_encoder_encode(
                    encoder,
                    &mut nals,
                    &mut nal_count,
                    std::ptr::null_mut(),
                    pic_out,
                );
                if r < 0 {
                    break;
                }
                if r > 0 {
                    append_nals(&mut chunk, nals, nal_count);
                } else {
                    break;
                }
            }
            x265_picture_free(pic_out);
            x265_encoder_close(encoder);
            x265_param_free(param);

            if idx == 0 {
                // Tile 0 keeps its parameter sets (hvcC extraction source).
                results.push(chunk);
            } else {
                // Later tiles: keep only the IDR slice, drop VPS/SPS/PPS.
                results.push(drop_parameter_nals(&chunk));
            }
        }
        Ok(results)
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

/// Run the encoder: feed one frame, then flush. Collect all output NALs.
#[cfg(not(xdremux_ffmpeg_fallback))]
unsafe fn do_encode(
    encoder: *mut crate::x265_ffi::x265_encoder,
    pic_in: *mut crate::x265_ffi::x265_picture,
) -> std::io::Result<Vec<u8>> {
    use crate::x265_ffi::*;

    let mut nals: *mut x265_nal = std::ptr::null_mut();
    let mut nal_count: u32 = 0;
    let pic_out = x265_picture_alloc();
    let mut output = Vec::new();

    // Encode the input frame
    let ret = x265_encoder_encode(encoder, &mut nals, &mut nal_count, pic_in, pic_out);
    if ret < 0 {
        x265_picture_free(pic_out);
        return Err(io_err("x265_encoder_encode failed (input frame)"));
    }
    if ret > 0 {
        append_nals(&mut output, nals, nal_count);
    }

    // Flush (pass null input to get any buffered output)
    let ret = x265_encoder_encode(encoder, &mut nals, &mut nal_count, std::ptr::null_mut(), pic_out);
    if ret > 0 {
        append_nals(&mut output, nals, nal_count);
    }

    x265_picture_free(pic_out);

    if output.is_empty() {
        return Err(io_err("x265 produced no output"));
    }
    Ok(output)
}

/// Copy NAL payloads into the output buffer (they include start codes already).
#[cfg(not(xdremux_ffmpeg_fallback))]
unsafe fn append_nals(output: &mut Vec<u8>, nals: *mut crate::x265_ffi::x265_nal, count: u32) {
    for i in 0..count as usize {
        let nal = &*nals.add(i);
        let slice = std::slice::from_raw_parts(nal.payload, nal.size_bytes as usize);
        output.extend_from_slice(slice);
    }
}

/// Set a param by name/value strings (with logging on failure).
#[cfg(not(xdremux_ffmpeg_fallback))]
unsafe fn set_param(
    param: *mut crate::x265_ffi::x265_param,
    name: &str,
    value: &str,
) {
    let n = std::ffi::CString::new(name).unwrap();
    let v = std::ffi::CString::new(value).unwrap();
    let ret = crate::x265_ffi::x265_param_parse(param, n.as_ptr(), v.as_ptr());
    if ret != 0 {
        xlog(&format!("param_parse FAILED: {}={} ret={}", name, value, ret));
    }
}

#[cfg(not(xdremux_ffmpeg_fallback))]
fn io_err(msg: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, msg.to_string())
}

// ===========================================================================
// Optional fallback: ffmpeg subprocess encoder (build with XDREMUX_USE_FFMPEG=1)
// ===========================================================================

#[cfg(xdremux_ffmpeg_fallback)]
fn encode_raw_tile(pixels: &[u8], pix_fmt_in: &str, width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    let pix_fmt_out = match pix_fmt_in {
        "gray" => "yuv444p",
        "rgb24" => "yuv444p",
        other => other,
    };

    let crf: u32 = match pix_fmt_in {
        "gray" => 18,
        "rgb24" => 14,
        _ => 18,
    };

    let x265_params = if pix_fmt_in == "gray" {
        "range=full"
    } else {
        "range=full:colormatrix=bt709:colorprim=bt709:transfer=bt709:psy-rd=0:aq-mode=1"
    };

    let preset = if pix_fmt_in == "gray" { "ultrafast" } else { "medium" };

    let ffmpeg = resolve_exe("ffmpeg");
    let mut cmd = Command::new(&ffmpeg);
    cmd.args([
        "-y",
        "-f", "rawvideo",
        "-pixel_format", pix_fmt_in,
        "-video_size", &format!("{}x{}", width, height),
        "-framerate", "1",
        "-i", "pipe:0",
        "-c:v", "libx265",
        "-preset", preset,
        "-crf", &crf.to_string(),
    ]);
    cmd.args(["-profile:v", "main444-8"]);
    cmd.args([
        "-colorspace", "bt709",
        "-color_primaries", "bt709",
        "-color_trc", "bt709",
        "-color_range", "2",
    ]);
    cmd.args([
        "-x265-params", x265_params,
        "-pix_fmt", pix_fmt_out,
        "-frames:v", "1",
        "-f", "hevc",
        "pipe:1",
    ]);

    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    { cmd.creation_flags(CREATE_NO_WINDOW); }
    let mut child = cmd.spawn()?;

    let mut stdin = child.stdin.take().unwrap();
    let owned_pixels = pixels.to_vec();
    let stdin_thread = thread::spawn(move || {
        let _ = stdin.write_all(&owned_pixels);
    });

    let mut stdout = child.stdout.take().unwrap();
    let mut buf = Vec::new();
    stdout.read_to_end(&mut buf)?;

    let _ = stdin_thread.join();

    let status = child.wait()?;
    if !status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("ffmpeg exited with {}", status),
        ));
    }
    Ok(buf)
}

/// Resolve `name` (e.g. "ffmpeg") to an absolute path, falling back to the bare
/// name if resolution fails.
#[cfg(xdremux_ffmpeg_fallback)]
fn resolve_exe(name: &str) -> PathBuf {
    // 1. Check next to our own executable (bundled distribution).
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let bare = exe_dir.join(name);
            if bare.exists() {
                return bare;
            }
            if cfg!(windows) {
                let with_ext = exe_dir.join(format!("{}.exe", name));
                if with_ext.exists() {
                    return with_ext;
                }
            }
        }
    }
    // 2. Search PATH
    let which_cmd = if cfg!(windows) { "where" } else { "which" };
    let mut cmd = std::process::Command::new(which_cmd);
    cmd.arg(name).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(windows)]
    { cmd.creation_flags(CREATE_NO_WINDOW); }
    if let Ok(output) = cmd.output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = stdout.lines().next() {
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                return PathBuf::from(trimmed);
            }
        }
    }
    // 3. macOS: check homebrew paths
    if cfg!(target_os = "macos") {
        for dir in &["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = PathBuf::from(dir).join(name);
            if candidate.exists() {
                return candidate;
            }
        }
    }
    PathBuf::from(name)
}

// ===========================================================================
// Shared utilities (all platforms)
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
    let bit_depth_luma: u8 = 8;
    let bit_depth_chroma: u8 = 8;

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
// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

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

        let streams =
            x265_encode_tiles(&refs, w, h, 1, false).expect("batch encode failed");
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
