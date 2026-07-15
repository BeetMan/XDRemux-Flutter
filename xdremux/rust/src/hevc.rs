//! HEVC tile-encoder spike — proves the `ffmpeg` subprocess path works on this
//! machine without linking any GPL library into the Rust binary.
//!
//! The gain map is encoded as a single-frame HEVC elementary stream.
//! ffmpeg is called as a subprocess (platform-independent, zero link-time deps).

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;

/// Resolve `name` (e.g. "ffmpeg") to an absolute path, falling back to the bare
/// name if resolution fails.
fn resolve_exe(name: &str) -> PathBuf {
    // On Windows we need the absolute path so the DLL loader searches
    // ffmpeg's own directory rather than our application directory
    // (which contains Flutter DLLs that conflict).
    let which_cmd = if cfg!(windows) { "where" } else { "which" };
    if let Ok(output) = std::process::Command::new(which_cmd)
        .arg(name)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = stdout.lines().next() {
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                return PathBuf::from(trimmed);
            }
        }
    }
    PathBuf::from(name)
}

/// Encode `width × height` raw 8-bit grayscale pixels as a single-frame HEVC
/// elementary stream. `pixels` must be `width * height` bytes, row-major.
pub fn encode_hevc_tile_gray(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height);
    encode_raw_tile(pixels, "gray", width, height)
}

/// Encode `width × height` raw 8-bit RGB pixels (3 bytes per pixel, packed
/// R-G-B) as a single-frame HEVC elementary stream using YUV 4:4:4 so chroma
/// resolution is preserved. Used for OPPO-compat RGB-copy gain maps.
pub fn encode_hevc_tile_rgb(pixels: &[u8], width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    assert_eq!(pixels.len() as u32, width * height * 3);
    encode_raw_tile(pixels, "rgb24", width, height)
}

fn encode_raw_tile(pixels: &[u8], pix_fmt_in: &str, width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    let pix_fmt_out = match pix_fmt_in {
        "gray" => "yuv444p",  // Always 4:4:4 — iOS expects chroma_format_idc=3 matching Python libheif chroma=444
        "rgb24" => "yuv444p",
        other => other,
    };

    // CRF: lower for RGB (14, higher quality to match pillow-heif quality=90);
    // keep gray at 18 since LHDR gain maps are inherently lower-complexity.
    let crf: u32 = match pix_fmt_in {
        "gray" => 18,
        "rgb24" => 14,
        _ => 18,
    };

    let x265_params = if pix_fmt_in == "gray" {
        "range=full"
    } else {
        // RGB → YUV 4:4:4 with BT.709 color matrix for accurate SDR→HDR mapping.
        // Disable psy-rd and use PSNR-optimized AQ: the gain map encodes
        // mathematical ratios, not a photograph — perceptual optimization
        // (psy-rd) systematically shifts luminance in the wrong direction.
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

    // Set profile at ffmpeg level — always main444-8 since we always output yuv444p
    cmd.args(["-profile:v", "main444-8"]);

    // BT.709 colorspace for accurate RGB→YUV conversion (matching Apple ImageIO defaults)
    cmd.args([
        "-colorspace", "bt709",
        "-color_primaries", "bt709",
        "-color_trc", "bt709",
        "-color_range", "2",   // 2 = full/pc range (0-255). Without this, ffmpeg
                               // internally clamps to limited/TV range (16-235),
                               // causing a +9 systematic Y offset in the gain map.
    ]);

    cmd.args([
        "-x265-params", x265_params,
        "-pix_fmt", pix_fmt_out,
        "-frames:v", "1",
        "-f", "hevc",
        "pipe:1",
    ]);

    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;

    // Pump stdin on a background thread while reading stdout on the main
    // thread, so neither pipe deadlocks on Windows' 64 KiB buffer.
    let mut stdin = child.stdin.take().unwrap();
    let owned_pixels = pixels.to_vec();
    let stdin_thread = thread::spawn(move || {
        let _ = stdin.write_all(&owned_pixels);
        // stdin dropped here → pipe closes
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

/// Convert a HEVC byte-stream (with 00 00 00 01 or 00 00 01 start codes) to
/// length-prefixed format suitable for ISOBMFF mdat storage.
/// Each NAL unit is prefixed with a 4-byte big-endian length.
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
            // Not at a start code — skip one byte (shouldn't happen but be safe)
            pos += 1;
            continue;
        };

        // Find next start code to determine NAL unit end
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
///
/// Parses the HEVC byte stream for VPS, SPS, PPS NAL units and constructs the
/// ISO 14496-15 hvcC box payload. The returned bytes are the hvcC box payload
/// (without the 8-byte ISOBMFF box header).
pub fn extract_hvcc_config(hevc_data: &[u8]) -> Option<Vec<u8>> {
    // Find all NAL unit start code positions.
    // HEVC uses both 4-byte (0x00 0x00 0x00 0x01) and 3-byte (0x00 0x00 0x01)
    // start codes. VPS/SPS/PPS use 4-byte, VCL NALs and SEI use 3-byte.
    // We must find ALL start codes to correctly determine each NAL's boundary.
    let nal_3b: &[u8] = &[0, 0, 1];
    let nal_4b: &[u8] = &[0, 0, 0, 1];
    let mut nal_positions: Vec<usize> = Vec::new();
    let mut search = 0;
    while search < hevc_data.len() {
        // Check for 4-byte first (longer match takes priority)
        if hevc_data[search..].starts_with(nal_4b) {
            nal_positions.push(search); // position of the start code
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
    let chroma_format_idc: u8 = 0;
    let bit_depth_luma: u8 = 8;
    let bit_depth_chroma: u8 = 8;

    for i in 0..nal_positions.len() {
        // Determine start code length at this position
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
            32 => {
                // VPS — extract general_profile_idc, etc.
                vps_nal = Some(payload);
                if payload.len() >= 16 {
                    // NAL header = 2 bytes, VPS prefix fields = 4 bytes
                    // (vps_video_parameter_set_id(4) + flags(8) +
                    //  vps_max_layers_minus1(6) + vps_max_sub_layers_minus1(3) +
                    //  vps_temporal_id_nesting_flag(1) + reserved_ffff(16))
                    // PTL starts at byte 6 of the NAL payload.
                    // Profile/compat/level are parsed below from the VPS directly.
                }
            }
            33 => {
                // SPS — extract chroma_format_idc and bit depths
                sps_nal = Some(payload);
                if payload.len() >= 8 {
                    // SPS structure: NAL header(2) + sps_video_parameter_set_id(4)
                    // + sps_max_sub_layers_minus1(3) + sps_temporal_id_nesting_flag(1)
                    // + profile_tier_level(...) — variable, skip known fields
                    // We skip to chroma_format_idc which sits after conformance
                    // window and before bit_depth_luma_minus8.
                    // For x265, the fixed-size header before chroma includes PTL (~12 bytes)
                    // + sps_seq_parameter_set_id + chroma_format_idc is at a known offset.
                    // Strategy: scan from byte 2..12 to find the profile_tier_level end,
                    // then read chroma_format_idc.
                    // Simpler: for x265 output with general_profile_idc=4 (Rext) and
                    // vps_max_sub_layers_minus1=1, chroma_format_idc is always at payload[6]
                    // after NAL header(2) + sps fields + PTL.
                    // Use the known offset: look for the byte after PTL by reading
                    // ptl_present_flag at payload[2] bit 6, then skip PTL accordingly.
                }
            }
            34 => {
                // PPS
                pps_nal = Some(payload);
            }
            _ => {}
        }
    }

    let vps = vps_nal?;
    let sps = sps_nal?;
    let pps = pps_nal?;

    // Determine encoder defaults from profile
    // For x265 ultrafast gray: profile=1 (Main), level=whatever
    // For x265 ultrafast rgb: profile=4 (Rext), yuv444

    // Build hvcC record per ISO 14496-15
    let mut hvcc = Vec::new();

    // configurationVersion
    hvcc.push(1);

    // chromaFormatIdc: We always encode yuv444p (Main 4:4:4 Rext), so chroma = 3.
    let chroma = 3u8; // 4:4:4 — matches Python libheif chroma="444"

    // Profile / compat / level: parse from VPS PTL with correct offset.
    // NAL header = 2 bytes, VPS prefix = 4 bytes → PTL starts at vps[6].
    let (profile_byte, compat_flags, level_idc) = if vps.len() >= 19 {
        let ptl_byte = vps[6];
        let compat = u32::from_be_bytes([vps[7], vps[8], vps[9], vps[10]]);
        // level_idc is at variable offset after constraint flags (6 bytes) +
        // optional sub-layer info. For single-layer (vps_max_sub_layers_minus1=0)
        // it's at vps[18]. x265 sometimes writes 0 here — fall back to 0x5a (90).
        let lvl = if vps[18] != 0 { vps[18] } else { 0x5a };
        (ptl_byte, compat, lvl)
    } else {
        // Fallback: hardcode sensible values
        if chroma_format_idc == 0 {
            (0x01, 0x10000000u32, 0x5a) // Main, level 3.0
        } else {
            (0x04, 0x08000000u32, 0x5a) // Main 4:4:4, level 3.0
        }
    };

    // When encoding yuv444p always claim Main 4:4:4 compatibility. x265 may
    // write Main+Main10 (0x03000000) into its VPS depending on build defaults,
    // but the actual stream is 4:4:4 — iOS libheif matches the compat flags
    // and iOS Photos treats 4:4:4 gain maps differently from 4:2:0.
    let compat_flags = if chroma == 3u8 {
        0x08000000u32 // Main 4:4:4 — matches Python pillow-heif chroma="444"
    } else {
        compat_flags
    };

    hvcc.push(profile_byte);
    hvcc.extend_from_slice(&compat_flags.to_be_bytes());

    // general_constraint_indicator_flags (6 bytes) — zeroed
    hvcc.extend_from_slice(&[0u8; 6]);

    // general_level_idc (1 byte)
    hvcc.push(level_idc);

    // min_spatial_segmentation_idc: reserved(4)=0xf + min(12)=0
    hvcc.extend_from_slice(&[0xf0, 0x00]);

    // parallelismType: reserved(6)=0x3f + type(2)=0
    hvcc.push(0xfc);

    // chromaFormatIdc: reserved(6)=0x3f + idc(2)
    hvcc.push(0xfc | (chroma & 0x03));

    // bitDepthLumaMinus8: reserved(5)=0x1f + depth(3)
    hvcc.push(0xf8 | ((bit_depth_luma - 8) & 0x07));

    // bitDepthChromaMinus8: reserved(5)=0x1f + depth(3)
    hvcc.push(0xf8 | ((bit_depth_chroma - 8) & 0x07));

    // avgFrameRate (2 bytes) — 0
    hvcc.extend_from_slice(&[0, 0]);

    // constantFrameRate(2) + numTemporalLayers(3) + temporalIdNested(1) + lengthSizeMinusOne(2)
    // numTemporalLayers=1, temporalIdNested=1, lengthSizeMinusOne=3 → 0x0f
    hvcc.push(0x0f);

    // numOfArrays: VPS(1) + SPS(1) + PPS(1) = 3
    hvcc.push(3);

    // Helper to write a NAL array entry
    fn push_nal_array(hvcc: &mut Vec<u8>, nal_type: u8, nal_data: &[u8]) {
        // array_completeness(1)=1 + reserved(1)=0 + NAL_unit_type(6)
        hvcc.push(0x80 | (nal_type & 0x3f));
        // numNalus = 1
        hvcc.extend_from_slice(&1u16.to_be_bytes());
        // nalUnitLength
        hvcc.extend_from_slice(&(nal_data.len() as u16).to_be_bytes());
        // nalUnit (raw VPS/SPS/PPS including the 2-byte header)
        hvcc.extend_from_slice(nal_data);
    }

    push_nal_array(&mut hvcc, 32, vps);   // VPS
    push_nal_array(&mut hvcc, 33, sps);   // SPS
    push_nal_array(&mut hvcc, 34, pps);   // PPS

    Some(hvcc)
}

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

        // Check HEVC NAL start codes exist
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
    fn hevc_tile_gray_empty_returns_error() {
        let err = encode_hevc_tile_gray(&[], 0, 0).unwrap_err();
        assert!(err.to_string().contains("ffmpeg"), "must mention ffmpeg");
    }
}
