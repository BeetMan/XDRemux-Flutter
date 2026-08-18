//! One-shot diagnostic: times x265 tile encodes and a full conversion.
//! Build:  cargo build --release --example x265_diag
//! Run:    target/release/examples/x265_diag.exe list [preset]
//!         target/release/examples/x265_diag.exe <input.heic>
//!
//! `list` skips the full conversion and only times 512x512 tile encodes.
//! [preset] applies to the RGB (OPPO-compat/UHDR) path only; the gray path
//! stays at its production ultrafast preset.

use std::ffi::CString;
use std::time::Instant;

#[cfg(not(xdremux_ffmpeg_fallback))]
mod imp {
    use super::*;
    use xdremux_core::x265_ffi::*;

    // Defined in x265_helper.c (same staticlib crate the example links).
    extern "C" {
        fn xdremux_param_set_basic(
            p: *mut x265_param,
            width: i32,
            height: i32,
            bit_depth: i32,
            total_frames: i32,
        );
        fn xdremux_pic_set_planes(
            pic: *mut x265_picture,
            p0: *mut u8,
            p1: *mut u8,
            p2: *mut u8,
            s0: i32,
            s1: i32,
            s2: i32,
        );
        fn xdremux_pic_set_pts(pic: *mut x265_picture, pts: i64);
    }

    fn set_param(param: *mut x265_param, name: &str, value: &str) {
        let n = CString::new(name).unwrap();
        let v = CString::new(value).unwrap();
        let ret = unsafe { x265_param_parse(param, n.as_ptr(), v.as_ptr()) };
        if ret != 0 {
            println!("  param_parse {name}={value} -> {ret}");
        }
    }

    /// Time one gray 512x512 tile encode (production config) and one RGB
    /// 512x512 tile encode with the given preset.
    pub fn time_tiles(rgb_preset: &str) {
        let size = 512usize;
        // Deterministic non-trivial pattern so the encoder does real work.
        let gray: Vec<u8> = (0..size * size)
            .map(|i| ((i.wrapping_mul(2654435761)) >> 13) as u8)
            .collect();
        let rgb: Vec<u8> = (0..size * size * 3)
            .map(|i| ((i.wrapping_mul(2246822519)) >> 11) as u8)
            .collect();

        let t = Instant::now();
        let out = encode_tile(&gray, 1, "ultrafast", "18", size as u32, false);
        println!(
            "gray 512x512 ultrafast crf18: {:?} ({} bytes)",
            t.elapsed(),
            out.map(|v| v.len()).unwrap_or(0)
        );

        let t = Instant::now();
        let out = encode_tile(&rgb, 3, rgb_preset, "14", size as u32, true);
        println!(
            "rgb  512x512 {rgb_preset} crf14: {:?} ({} bytes)",
            t.elapsed(),
            out.map(|v| v.len()).unwrap_or(0)
        );
    }

    fn encode_tile(
        pixels: &[u8],
        channels: usize,
        preset: &str,
        crf: &str,
        dim: u32,
        bt709: bool,
    ) -> std::io::Result<Vec<u8>> {
        let plane_size = (dim * dim) as usize;
        let (y_plane, u_plane, v_plane) = if channels == 1 {
            (
                pixels.to_vec(),
                vec![128u8; plane_size],
                vec![128u8; plane_size],
            )
        } else {
            let mut y = vec![0u8; plane_size];
            let mut u = vec![0u8; plane_size];
            let mut v = vec![0u8; plane_size];
            for i in 0..plane_size {
                let r = pixels[i * 3] as f32;
                let g = pixels[i * 3 + 1] as f32;
                let b = pixels[i * 3 + 2] as f32;
                let yy = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                y[i] = yy.round().clamp(0.0, 255.0) as u8;
                u[i] = ((b - yy) * 0.5389 + 128.0).round().clamp(0.0, 255.0) as u8;
                v[i] = ((r - yy) * 0.6350 + 128.0).round().clamp(0.0, 255.0) as u8;
            }
            (y, u, v)
        };

        unsafe {
            let param = x265_param_alloc();
            if param.is_null() {
                return Err(std::io::Error::other("param_alloc failed"));
            }
            let p = CString::new(preset).unwrap();
            if x265_param_default_preset(param, p.as_ptr(), std::ptr::null()) != 0 {
                x265_param_free(param);
                return Err(std::io::Error::other("preset failed"));
            }
            set_param(param, "input-csp", "i444");
            xdremux_param_set_basic(param, dim as i32, dim as i32, 8, 1);
            set_param(param, "fps", "1");
            set_param(param, "crf", crf);
            set_param(param, "range", "full");
            set_param(param, "repeat-headers", "1");
            set_param(param, "keyint", "1");
            let prof = CString::new("main444-8").unwrap();
            x265_param_apply_profile(param, prof.as_ptr());
            if bt709 {
                set_param(param, "colormatrix", "bt709");
                set_param(param, "colorprim", "bt709");
                set_param(param, "transfer", "bt709");
                set_param(param, "psy-rd", "0");
                set_param(param, "aq-mode", "1");
            }
            set_param(param, "frame-threads", "1");
            set_param(param, "pools", "1");

            let encoder = x265_encoder_open_216(param);
            if encoder.is_null() {
                x265_param_free(param);
                return Err(std::io::Error::other("encoder open failed"));
            }
            let pic = x265_picture_alloc();
            x265_picture_init(param, pic);
            xdremux_pic_set_planes(
                pic,
                y_plane.as_ptr() as *mut u8,
                u_plane.as_ptr() as *mut u8,
                v_plane.as_ptr() as *mut u8,
                dim as i32,
                dim as i32,
                dim as i32,
            );
            xdremux_pic_set_pts(pic, 0);

            let mut out = Vec::new();
            let mut nals: *mut x265_nal = std::ptr::null_mut();
            let mut nnal: u32 = 0;
            let mut ret = x265_encoder_encode(
                encoder,
                &mut nals,
                &mut nnal,
                pic,
                std::ptr::null_mut(),
            );
            if ret >= 0 {
                // flush
                ret = x265_encoder_encode(
                    encoder,
                    &mut nals,
                    &mut nnal,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
            }
            if ret >= 0 && !nals.is_null() {
                for i in 0..nnal as isize {
                    let nal = &*nals.offset(i);
                    let payload =
                        std::slice::from_raw_parts(nal.payload, nal.size_bytes as usize);
                    out.extend_from_slice(payload);
                }
            }

            x265_picture_free(pic);
            x265_encoder_close(encoder);
            x265_param_free(param);
            if ret < 0 {
                return Err(std::io::Error::other(format!("encode failed ret={ret}")));
            }
            Ok(out)
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = args.get(1).map(|s| s.as_str());
    let preset = args.get(2).map(|s| s.as_str()).unwrap_or("slower");

    #[cfg(xdremux_ffmpeg_fallback)]
    {
        eprintln!("built with XDREMUX_USE_FFMPEG=1 — x265 static path not linked");
        std::process::exit(2);
    }

    #[cfg(not(xdremux_ffmpeg_fallback))]
    {
        if input.is_none() || input == Some("list") {
            imp::time_tiles(preset);
            return;
        }

        let input = input.unwrap();
        let t = Instant::now();
        let data = std::fs::read(input).expect("read input");
        println!("read {} bytes in {:?}", data.len(), t.elapsed());

        let output = format!("{input}.diag_out.heic");
        let cin = CString::new(input).unwrap();
        let cout = CString::new(output.as_str()).unwrap();
        let t = Instant::now();
        let config = xdremux_core::ConvertConfig {
            oppo_compat: 0,
            oppo_camera_tail: 255, // compatibility-dependent default
            strict_tmap: 0,
            apple_photographic_styles: 0,
        };
        let res = xdremux_core::xdremux_convert(cin.as_ptr(), cout.as_ptr(), &config);
        let dt = t.elapsed();
        println!("xdremux_convert total: {dt:?} success={}", res.success);
        if !res.error_message.is_null() {
            let msg = unsafe { std::ffi::CStr::from_ptr(res.error_message) };
            println!("error: {}", msg.to_string_lossy());
        }
        xdremux_core::xdremux_free_result(res);
    }
}
