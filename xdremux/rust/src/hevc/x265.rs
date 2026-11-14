//! x265 backend: static-linked x265 called through its C API. The default
//! encoder on every platform.
//!
//! Every parameter below is derived from the source pictures, the requested
//! layout and [`HevcColor`] only. [`EncodeRequest::content`] is deliberately
//! not read: this backend's output must not depend on it.

use super::{
    drop_parameter_nals, gain_map_420_enabled, rgb_to_yuv420,
    rgb_to_yuv420_limited601, rgb_to_yuv444, rgb_to_yuv444_limited601, EncodeRequest,
    EncodedTiles, HevcBitDepth, HevcColor, HevcLayout, SourcePictures,
};

/// Backend entry: encode one batch described by `request`.
pub(super) fn encode(
    request: &EncodeRequest,
    pictures: SourcePictures<'_>,
) -> std::io::Result<EncodedTiles> {
    let EncodeRequest { width, height, layout, bit_depth, color, content: _ } = *request;
    let streams = match (pictures, bit_depth) {
        (SourcePictures::Gray8(tiles), HevcBitDepth::Eight) => {
            // Gray is coded 4:0:0, or 4:2:0 with neutral chroma. It carries
            // no colour description, so `color` does not apply.
            let use_420 = match layout {
                HevcLayout::Monochrome => false,
                HevcLayout::Yuv420 => true,
                HevcLayout::Yuv444 => return Err(unsupported("gray tiles as 4:4:4")),
            };
            encode_8bit_tiles(tiles, width, height, 1, use_420, false, false)?
        }
        (SourcePictures::Rgb8(tiles), HevcBitDepth::Eight) => {
            let use_420 = match layout {
                HevcLayout::Yuv420 => true,
                HevcLayout::Yuv444 => false,
                HevcLayout::Monochrome => return Err(unsupported("RGB tiles as monochrome")),
            };
            let (oppo_sdr, icc_rgb) = match color {
                HevcColor::Bt709Full => (false, false),
                HevcColor::OppoSdr => (true, false),
                HevcColor::IccPrimary => (false, true),
                HevcColor::Bt601LimitedLinear => {
                    return Err(unsupported("8-bit BT.601 limited RGB tiles"))
                }
            };
            encode_8bit_tiles(tiles, width, height, 3, use_420, oppo_sdr, icc_rgb)?
        }
        (SourcePictures::Rgb16(codes16), HevcBitDepth::Ten) => {
            if layout != HevcLayout::Yuv420 || color != HevcColor::Bt601LimitedLinear {
                return Err(unsupported("10-bit pictures other than 4:2:0 BT.601 limited"));
            }
            vec![encode_10bit(codes16, width, height)?]
        }
        _ => return Err(unsupported("source sample depth does not match the coded bit depth")),
    };
    // x265 always codes the layout it was asked for.
    Ok(EncodedTiles { streams, layout })
}

fn unsupported(what: &str) -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        format!("x265 backend does not encode {what}"),
    )
}

/// Debug log helper — logcat on Android, stderr elsewhere.
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

pub(super) fn encode_single_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
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

pub(super) fn encode_single_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
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
unsafe fn setup_pic_planes(
    pic: *mut crate::x265_ffi::x265_picture,
    param: *mut crate::x265_ffi::x265_param,
    pixels: &[u8],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
    oppo_sdr: bool,
) -> (Vec<u8>, Vec<u8>, Vec<u8>, i32) {
    use crate::x265_ffi::*;
    use std::os::raw::c_void;

    // Must match the encoder's configured input-csp: the batch caller passes
    // the same flag it gave open_encoder. Reading gain_map_420_enabled() here
    // used to diverge from the encoder config (i420 param + 4:4:4 planes),
    // which scrambled chroma and produced per-tile colour shifts.
    let (y_plane, u_plane, v_plane, chroma_stride) = if pixel_bytes == 3 {
        let (y, u, v) = match (use_420, oppo_sdr) {
            (true, true) => rgb_to_yuv420_limited601(pixels, width, height),
            (true, false) => rgb_to_yuv420(pixels, width, height),
            (false, true) => rgb_to_yuv444_limited601(pixels, width, height),
            (false, false) => rgb_to_yuv444(pixels, width, height),
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
unsafe fn open_encoder(
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
    oppo_sdr: bool,
    icc_rgb: bool,
) -> std::io::Result<(*mut crate::x265_ffi::x265_param, *mut crate::x265_ffi::x265_encoder)> {
    use crate::x265_ffi::*;
    use std::ffi::CString;

    let is_rgb = pixel_bytes == 3;

    let param = x265_param_alloc();
    if param.is_null() {
        return Err(io_err("x265_param_alloc failed"));
    }

    // OPPO writeback runs on phones: medium costs ~15s for a full 4K raster
    // (measured on a Kirin device); fast is ~2-3x quicker at CRF14 with no
    // visible quality delta. Gain maps keep ultrafast, styles keep medium.
    let preset = CString::new(if is_rgb {
        if oppo_sdr { "fast" } else { "medium" }
    } else {
        "ultrafast"
    })
    .unwrap();
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
        if icc_rgb {
            set_param(param, "colormatrix", "bt709");
            set_param(param, "colorprim", "undef");
            set_param(param, "transfer", "undef");
        } else if oppo_sdr {
            // Mimic the OPPO camera's signalling: limited-range BT.601 data
            // (converted above) with a full-range flag and sRGB transfer.
            set_param(param, "colormatrix", "smpte170m");
            set_param(param, "colorprim", "bt470bg");
            set_param(param, "transfer", "iec61966-2-1");
        } else {
            set_param(param, "colormatrix", "bt709");
            set_param(param, "colorprim", "bt709");
            set_param(param, "transfer", "bt709");
        }
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

/// Encode a batch of same-size tiles, one single-frame encoder session per
/// tile (up to four in parallel). Tile 0 keeps its parameter sets; later
/// tiles are pure IDR slices.
fn encode_8bit_tiles(
    tiles: &[&[u8]],
    width: u32,
    height: u32,
    pixel_bytes: usize,
    use_420: bool,
    oppo_sdr: bool,
    icc_rgb: bool,
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

    // Encode one tile with its own single-frame encoder session. This is
    // deterministic (no multi-frame pipeline reordering to split), and lets
    // us emit tile 0 with its parameter sets (VPS/SPS/PPS, needed for hvcC
    // extraction) while every other tile is a pure IDR slice — the shape
    // ImageIO's ISO 21496-1 gain-map decoder expects (it reads the decoder
    // config from hvcC, not from each tile).
    // Captured here: the worker threads below have no progress handle.
    let progress_handle = crate::progress::current_handle();
    let encode_tile = |idx: usize, tile: &[u8]| -> std::io::Result<Vec<u8>> {
        if crate::progress::is_cancelled_for(progress_handle) {
            return Err(io_err(crate::progress::CANCELLED_MESSAGE));
        }
        unsafe {
            let (param, encoder) = open_encoder(width, height, pixel_bytes, use_420, oppo_sdr, icc_rgb)?;
            let pic = x265_picture_alloc();
            let (y, u, v, _stride) =
                setup_pic_planes(pic, param, tile, width, height, pixel_bytes, use_420, oppo_sdr);
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

            Ok(if idx == 0 {
                // Tile 0 keeps its parameter sets (hvcC extraction source).
                chunk
            } else {
                // Later tiles: keep only the IDR slice, drop VPS/SPS/PPS.
                drop_parameter_nals(&chunk)
            })
        }
    };

    // Tiles are independent single-frame sessions, so parallelize across
    // tiles: a phone encodes a 4K raster's ~40 tiles sequentially in ~15s,
    // and ~4x faster with four workers (measured 14.9s -> 6.4s on Kirin).
    let workers = std::thread::available_parallelism()
        .map(|v| v.get())
        .unwrap_or(4)
        .min(4)
        .min(tiles.len().max(1));
    let chunk_size = tiles.len().div_ceil(workers);
    let mut results: Vec<Vec<u8>> = vec![Vec::new(); tiles.len()];
    std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for (chunk_idx, part) in tiles.chunks(chunk_size).enumerate() {
            let encode_ref = &encode_tile;
            let base = chunk_idx * chunk_size;
            handles.push(scope.spawn(move || {
                let mut out = Vec::with_capacity(part.len());
                for (i, tile) in part.iter().enumerate() {
                    out.push((base + i, encode_ref(base + i, tile)));
                }
                out
            }));
        }
        let mut first_error: Option<std::io::Error> = None;
        for handle in handles {
            for (idx, res) in handle.join().expect("tile encoder panicked") {
                match res {
                    Ok(bytes) => results[idx] = bytes,
                    Err(e) => {
                        if first_error.is_none() {
                            first_error = Some(e);
                        }
                    }
                }
            }
        }
        if let Some(e) = first_error {
            return Err(e);
        }
        Ok(())
    })?;
    Ok(results)
}

/// Run the encoder: feed one frame, then flush. Collect all output NALs.
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
unsafe fn append_nals(output: &mut Vec<u8>, nals: *mut crate::x265_ffi::x265_nal, count: u32) {
    for i in 0..count as usize {
        let nal = &*nals.add(i);
        let slice = std::slice::from_raw_parts(nal.payload, nal.size_bytes as usize);
        output.extend_from_slice(slice);
    }
}

/// Set a param by name/value strings (with logging on failure).
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

fn io_err(msg: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, msg.to_string())
}

/// Main10 4:2:0 picture from 16-bit Apple Log codes, through the optional
/// 10-bit x265 archive. Returns the Annex-B stream exactly as x265 produced
/// it (parameter sets + one picture).
#[cfg(xdremux_main10)]
fn encode_10bit(
    codes16: &[u16],
    width: u32,
    height: u32,
) -> std::io::Result<Vec<u8>> {
    use std::os::raw::c_int;
    if width == 0 || height == 0 {
        return Err(io_err("10-bit thumbnail: zero extent"));
    }
    if codes16.len() != (width as usize) * (height as usize) * 3 {
        return Err(io_err("10-bit thumbnail: raster size mismatch"));
    }
    let (y_plane, u_plane, v_plane) = super::codes16_to_yuv420_10bit(codes16, width, height);
    let mut out_ptr: *mut u8 = std::ptr::null_mut();
    let mut out_len: c_int = 0;
    let status = unsafe {
        crate::x265_ffi::xdremux_encode_10bit_planes(
            y_plane.as_ptr(),
            u_plane.as_ptr(),
            v_plane.as_ptr(),
            width as c_int,
            height as c_int,
            &mut out_ptr,
            &mut out_len,
        )
    };
    if status != 0 || out_ptr.is_null() || out_len <= 0 {
        return Err(io_err(&format!(
            "10-bit thumbnail: x265 bridge failed (status {status}, {out_len} bytes)"
        )));
    }
    let stream = unsafe {
        std::slice::from_raw_parts(out_ptr, out_len as usize).to_vec()
    };
    unsafe { crate::x265_ffi::xdremux_free_stream(out_ptr) };
    Ok(stream)
}

/// Builds without the 10-bit x265 archive: `main10_available()` is false and
/// callers take their 8-bit path instead of reaching this.
#[cfg(not(xdremux_main10))]
fn encode_10bit(_codes16: &[u16], _width: u32, _height: u32) -> std::io::Result<Vec<u8>> {
    Err(unsupported("10-bit pictures (no Main10 x265 archive linked)"))
}
