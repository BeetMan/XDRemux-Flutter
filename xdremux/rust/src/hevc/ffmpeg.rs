//! ffmpeg backend: runs `ffmpeg -c:v libx265` as a subprocess per tile.
//! Desktop smoke build only (`XDREMUX_HEVC_BACKEND=ffmpeg`, or the older
//! `XDREMUX_USE_FFMPEG=1`); never shipped.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;

use super::{EncodeRequest, EncodedTiles, HevcBitDepth, HevcColor, HevcLayout, SourcePictures};

/// `CREATE_NO_WINDOW` — suppresses the console window flash for every ffmpeg
/// subprocess on Windows (const 0x08000000, from winbase.h).
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// Backend entry: encode one batch described by `request`, one subprocess
/// per tile. Every tile is self-contained with its own parameter sets (which
/// the production x265 loop deliberately avoids); acceptable for a smoke
/// build.
///
/// As before the split, the requested layout only changes the encode for ICC
/// primaries (`yuv420p` + Main Still Picture); everything else is coded
/// `yuv444p`, and the OPPO convention is encoded like plain BT.709 because
/// this path has no range control. The returned layout is nevertheless the
/// requested one, because that is what callers have always written to hvcC.
pub(super) fn encode(
    request: &EncodeRequest,
    pictures: SourcePictures<'_>,
) -> std::io::Result<EncodedTiles> {
    let EncodeRequest { width, height, layout, bit_depth, color, content: _ } = *request;
    let (tiles, format) = match (pictures, bit_depth) {
        (SourcePictures::Gray8(tiles), HevcBitDepth::Eight) => (tiles, "gray"),
        (SourcePictures::Rgb8(tiles), HevcBitDepth::Eight) => (tiles, "rgb24"),
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "ffmpeg backend encodes 8-bit gray or RGB tiles only",
            ))
        }
    };
    let icc_rgb = format == "rgb24" && color == HevcColor::IccPrimary;
    let use_420 = layout == HevcLayout::Yuv420;
    let streams = tiles
        .iter()
        .map(|tile| encode_raw_tile_inner(tile, format, width, height, icc_rgb, use_420))
        .collect::<std::io::Result<Vec<_>>>()?;
    Ok(EncodedTiles { streams, layout })
}

/// Standalone single-tile encode (`pix_fmt_in` is `"gray"` or `"rgb24"`).
pub(super) fn encode_single(pixels: &[u8], pix_fmt_in: &str, width: u32, height: u32) -> std::io::Result<Vec<u8>> {
    encode_raw_tile_inner(pixels, pix_fmt_in, width, height, false, false)
}

fn encode_raw_tile_inner(pixels: &[u8], pix_fmt_in: &str, width: u32, height: u32,
    icc_rgb: bool, use_420: bool) -> std::io::Result<Vec<u8>> {
    let pix_fmt_out = if icc_rgb && use_420 { "yuv420p" } else { match pix_fmt_in {
        "gray" => "yuv444p",
        "rgb24" => "yuv444p",
        other => other,
    }};

    let crf: u32 = match pix_fmt_in {
        "gray" => 18,
        "rgb24" => 14,
        _ => 18,
    };

    let x265_params = if icc_rgb {
        "range=full:colormatrix=bt709:colorprim=undef:transfer=undef:psy-rd=0:aq-mode=1"
    } else if pix_fmt_in == "gray" {
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
    if icc_rgb {
        cmd.args(["-vf", "scale=in_range=full:out_range=full:out_color_matrix=bt709"]);
    }
    cmd.args(["-profile:v", if icc_rgb && use_420 { "mainstillpicture" } else { "main444-8" }]);
    cmd.args([
        "-colorspace", "bt709",
        "-color_primaries", if icc_rgb { "2" } else { "bt709" },
        "-color_trc", if icc_rgb { "2" } else { "bt709" },
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
