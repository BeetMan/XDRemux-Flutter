//! HEVC tile encoder.
//!
//! - Desktop (Windows/macOS): calls `ffmpeg` as a subprocess (zero link-time deps).
//! - Android: links x265 statically and calls the C API directly (SELinux
//!   prohibits executing files from the app data directory).

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// `CREATE_NO_WINDOW` — suppresses the console window flash for every ffmpeg
/// subprocess on Windows (const 0x08000000, from winbase.h).
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

// ===========================================================================
// Public API
// ===========================================================================

/// Encode `width × height` raw 8-bit grayscale pixels as a single-frame HEVC
/// elementary stream. `pixels` must be `width * height` bytes, row-major.
pub fn encode_hevc_tile_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height);
    #[cfg(target_os = "android")]
    {
        return x265_encode_gray(pixels, width, height);
    }
    #[cfg(not(target_os = "android"))]
    {
        encode_raw_tile(pixels, "gray", width, height)
    }
}

/// Encode `width × height` raw 8-bit RGB pixels (3 bytes per pixel, packed
/// R-G-B) as a single-frame HEVC elementary stream using YUV 4:4:4 so chroma
/// resolution is preserved.
pub fn encode_hevc_tile_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height * 3);
    #[cfg(target_os = "android")]
    {
        return x265_encode_rgb(pixels, width, height);
    }
    #[cfg(not(target_os = "android"))]
    {
        encode_raw_tile(pixels, "rgb24", width, height)
    }
}

// ===========================================================================
// Android: x265 static-linked encoder
// ===========================================================================

/// Android log helper — writes to logcat with tag "xdremux_x265".
#[cfg(target_os = "android")]
fn alog(msg: &str) {
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

#[cfg(target_os = "android")]
fn x265_encode_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    use crate::x265_ffi::*;
    use std::ffi::CString;
    use std::os::raw::c_void;

    alog(&format!("x265 gray {}x{}", width, height));

    // Expand gray to YUV444: Y=pixel, U=128, V=128 (iOS expects chroma_format_idc=3)
    let plane_size = (width * height) as usize;
    let y_plane = pixels.to_vec();
    let u_plane = vec![128u8; plane_size];
    let v_plane = vec![128u8; plane_size];

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

        set_param(param, "input-csp", "i444");
        xdremux_param_set_basic(param, width as i32, height as i32, 8, 1);
        set_param(param, "fps", "1");
        set_param(param, "crf", "18");
        set_param(param, "range", "full");
        set_param(param, "repeat-headers", "1");
        set_param(param, "keyint", "1");
        let prof = CString::new("main444-8").unwrap();
        x265_param_apply_profile(param, prof.as_ptr());
        set_param(param, "frame-threads", "1");
        set_param(param, "pools", "1");

        alog("opening encoder");
        let encoder = x265_encoder_open_216(param);
        if encoder.is_null() {
            alog("encoder open FAILED");
            x265_param_free(param);
            return Err(io_err("x265_encoder_open failed"));
        }
        alog("encoder opened OK");

        let pic = x265_picture_alloc();
        x265_picture_init(param, pic);
        xdremux_pic_set_planes(
            pic,
            y_plane.as_ptr() as *mut c_void,
            u_plane.as_ptr() as *mut c_void,
            v_plane.as_ptr() as *mut c_void,
            width as i32,
            width as i32,
            width as i32,
        );
        xdremux_pic_set_pts(pic, 0);

        let result = do_encode(encoder, pic);

        x265_picture_free(pic);
        x265_encoder_close(encoder);
        x265_param_free(param);

        result
    }
}

#[cfg(target_os = "android")]
fn x265_encode_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    use crate::x265_ffi::*;
    use std::ffi::CString;
    use std::os::raw::c_void;

    alog(&format!("x265 rgb {}x{}", width, height));

    // Convert RGB24 → YUV444 planar (BT.709, full range)
    let plane_size = (width * height) as usize;
    let mut y_plane = vec![0u8; plane_size];
    let mut u_plane = vec![0u8; plane_size];
    let mut v_plane = vec![0u8; plane_size];

    for i in 0..plane_size {
        let r = pixels[i * 3] as f32;
        let g = pixels[i * 3 + 1] as f32;
        let b = pixels[i * 3 + 2] as f32;
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        let u = (b - y) * 0.5389 + 128.0;
        let v = (r - y) * 0.6350 + 128.0;
        y_plane[i] = y.round().clamp(0.0, 255.0) as u8;
        u_plane[i] = u.round().clamp(0.0, 255.0) as u8;
        v_plane[i] = v.round().clamp(0.0, 255.0) as u8;
    }

    unsafe {
        let param = x265_param_alloc();
        if param.is_null() {
            return Err(io_err("x265_param_alloc failed"));
        }

        let preset = CString::new("slower").unwrap();
        if x265_param_default_preset(param, preset.as_ptr(), std::ptr::null()) != 0 {
            x265_param_free(param);
            return Err(io_err("x265_param_default_preset failed"));
        }

        set_param(param, "input-csp", "i444");
        xdremux_param_set_basic(param, width as i32, height as i32, 8, 1);
        set_param(param, "fps", "1");
        set_param(param, "crf", "14");
        set_param(param, "range", "full");
        set_param(param, "repeat-headers", "1");
        set_param(param, "keyint", "1");
        let prof = CString::new("main444-8").unwrap();
        x265_param_apply_profile(param, prof.as_ptr());
        set_param(param, "colormatrix", "bt709");
        set_param(param, "colorprim", "bt709");
        set_param(param, "transfer", "bt709");
        set_param(param, "psy-rd", "0");
        set_param(param, "aq-mode", "1");
        set_param(param, "frame-threads", "1");
        set_param(param, "pools", "1");

        alog("opening encoder");
        let encoder = x265_encoder_open_216(param);
        if encoder.is_null() {
            alog("encoder open FAILED");
            x265_param_free(param);
            return Err(io_err("x265_encoder_open failed"));
        }
        alog("encoder opened OK");

        let pic = x265_picture_alloc();
        x265_picture_init(param, pic);
        xdremux_pic_set_planes(
            pic,
            y_plane.as_ptr() as *mut c_void,
            u_plane.as_ptr() as *mut c_void,
            v_plane.as_ptr() as *mut c_void,
            width as i32,
            width as i32,
            width as i32,
        );
        xdremux_pic_set_pts(pic, 0);

        let result = do_encode(encoder, pic);

        x265_picture_free(pic);
        x265_encoder_close(encoder);
        x265_param_free(param);

        result
    }
}

/// Run the encoder: feed one frame, then flush. Collect all output NALs.
#[cfg(target_os = "android")]
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
#[cfg(target_os = "android")]
unsafe fn append_nals(output: &mut Vec<u8>, nals: *mut crate::x265_ffi::x265_nal, count: u32) {
    for i in 0..count as usize {
        let nal = &*nals.add(i);
        let slice = std::slice::from_raw_parts(nal.payload, nal.size_bytes as usize);
        output.extend_from_slice(slice);
    }
}

/// Set a param by name/value strings (with logging on failure).
#[cfg(target_os = "android")]
unsafe fn set_param(
    param: *mut crate::x265_ffi::x265_param,
    name: &str,
    value: &str,
) {
    let n = std::ffi::CString::new(name).unwrap();
    let v = std::ffi::CString::new(value).unwrap();
    let ret = crate::x265_ffi::x265_param_parse(param, n.as_ptr(), v.as_ptr());
    if ret != 0 {
        alog(&format!("param_parse FAILED: {}={} ret={}", name, value, ret));
    }
}

#[cfg(target_os = "android")]
fn io_err(msg: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, msg.to_string())
}

// ===========================================================================
// Desktop: ffmpeg subprocess encoder
// ===========================================================================

#[cfg(not(target_os = "android"))]
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

    let preset = if pix_fmt_in == "gray" { "ultrafast" } else { "slower" };

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
#[cfg(not(target_os = "android"))]
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

    let chroma = 3u8; // 4:4:4

    // Profile / compat / level from VPS PTL
    let (profile_byte, compat_flags, level_idc) = if vps.len() >= 19 {
        let ptl_byte = vps[6];
        let compat = u32::from_be_bytes([vps[7], vps[8], vps[9], vps[10]]);
        let lvl = if vps[18] != 0 { vps[18] } else { 0x5a };
        (ptl_byte, compat, lvl)
    } else {
        (0x04, 0x08000000u32, 0x5a)
    };

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
        hvcc.push(0x80 | (nal_type & 0x3f));
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
}
