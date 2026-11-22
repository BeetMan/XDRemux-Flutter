//! Apple video observations and frame resources. The linear Rec.2020 decode
//! and shared storage exposure follow 21Z121Z1/XDRemux #99 (457c955).

use std::ffi::{c_char, c_void, CStr};

use super::{
    mebx_sample, smartstyle_info_payload, MovieStyleLevel, StillStyles, StyleFrames, TrackSamples,
    VideoTrack,
};
use crate::hevc::{self, HevcColor, HevcContent};

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FrameTime {
    value: i64,
    scale: i32,
}

extern "C" {
    fn xdremux_observe_live_style_video(
        movie: *const u8,
        size: usize,
        track_id: i32,
        width: u32,
        height: u32,
        receive: extern "C" fn(*mut c_void, FrameTime, *const f32) -> bool,
        context: *mut c_void,
        end: *mut FrameTime,
        error: *mut c_char,
        error_size: usize,
    ) -> bool;
}

struct Observation {
    pixel_count: usize,
    frames: Vec<(FrameTime, Vec<f32>)>,
}

extern "C" fn receive_frame(context: *mut c_void, time: FrameTime, rgba: *const f32) -> bool {
    if crate::progress::is_cancelled() {
        return false;
    }
    // The synchronous decoder supplies one tightly packed RGBAf raster.
    let observation = unsafe { &mut *context.cast::<Observation>() };
    let rgba = unsafe { std::slice::from_raw_parts(rgba, observation.pixel_count * 4) };
    let rgb = rgba
        .chunks_exact(4)
        .flat_map(|pixel| pixel[..3].iter().map(|&v| v.max(0.0)))
        .collect();
    observation.frames.push((time, rgb));
    true
}

/// Express display timestamps and the leading edit in one exact clock.
fn set_presentation_timing(
    video: &mut VideoTrack,
    movie_scale: u32,
    frames: &[(FrameTime, Vec<f32>)],
    end: FrameTime,
) -> Result<(), String> {
    fn gcd(mut a: u32, mut b: u32) -> u32 {
        while b != 0 {
            (a, b) = (b, a % b);
        }
        a
    }

    let invalid = || "Live Photo video has an invalid presentation timeline".to_string();
    let times = frames
        .iter()
        .map(|&(time, _)| time)
        .chain(std::iter::once(end));
    let scale = times.clone().try_fold(movie_scale, |clock, time| {
        let scale = u32::try_from(time.scale)
            .ok()
            .filter(|&s| s > 0)
            .ok_or_else(invalid)?;
        (clock / gcd(clock, scale))
            .checked_mul(scale)
            .ok_or_else(invalid)
    })?;
    let ticks = times
        .map(|time| {
            let value = u64::try_from(time.value).map_err(|_| invalid())?;
            value
                .checked_mul(u64::from(scale / time.scale as u32))
                .ok_or_else(invalid)
        })
        .collect::<Result<Vec<_>, _>>()?;

    let leading_edit = video.start * u64::from(scale / movie_scale);
    let first = *ticks.first().ok_or_else(invalid)?;
    let offset = first.checked_sub(leading_edit).ok_or_else(invalid)?;
    let durations = ticks
        .windows(2)
        .map(|pair| {
            pair[1]
                .checked_sub(pair[0])
                .and_then(|delta| u32::try_from(delta).ok())
                .filter(|&delta| delta > 0)
                .ok_or_else(invalid)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if durations.is_empty() {
        return Err("Live Photo video decoder returned no frames".into());
    }
    video.first_frame_offset = u32::try_from(offset).map_err(|_| invalid())?;
    video.media_timescale = scale;
    video.durations = durations;
    Ok(())
}

pub(super) fn style_frames(
    mov: &[u8],
    video: &mut VideoTrack,
    movie_scale: u32,
    width: u32,
    height: u32,
    styles: &StillStyles,
    level: MovieStyleLevel,
) -> Result<StyleFrames, String> {
    let mut observation = Observation {
        pixel_count: (width * height) as usize,
        frames: Vec::with_capacity(video.durations.len()),
    };
    let mut end = FrameTime::default();
    let mut error = [0 as c_char; 512];
    let ok = unsafe {
        xdremux_observe_live_style_video(
            mov.as_ptr(),
            mov.len(),
            video.id as i32,
            width,
            height,
            receive_frame,
            (&mut observation as *mut Observation).cast(),
            &mut end,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    if !ok {
        if crate::progress::is_cancelled() {
            return Err(crate::progress::CANCELLED_MESSAGE.into());
        }
        let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy();
        return Err(format!("Live Photo video decode: {message}"));
    }
    let frames = observation.frames;
    set_presentation_timing(video, movie_scale, &frames, end)?;

    // A single exposure encodes all the frame highlights on the same scale.
    let exposure = frames
        .iter()
        .flat_map(|(_, rgb)| rgb.iter().copied())
        .fold(1.0f32, f32::max);
    let mut codes = Vec::with_capacity(frames.len());
    let mut properties = Vec::new();
    for (_, rgb) in frames {
        codes.push(crate::apple_log::thumbnail_codes(&rgb, exposure)?);
        if level >= MovieStyleLevel::Info {
            // Key 3 maps the normalized log reference onto the frame's
            // display-linear range. The full highlights stay in the thumbnail.
            let reference: Vec<f32> = rgb.iter().map(|&v| v / exposure).collect();
            let display: Vec<f32> = rgb.iter().map(|&v| v.min(1.0)).collect();
            let curve = crate::styles_fit::monotonic_global_tone_curve(&reference, &display)?;
            let payload = smartstyle_info_payload(
                &curve.data,
                f64::from(exposure),
                styles.key5,
                1.0,
                level >= MovieStyleLevel::Full,
            );
            properties.push(mebx_sample(&payload));
        }
    }
    let (encoded, depth, matrix) = if hevc::main10_supported(width, height) {
        let frames: Vec<&[u16]> = codes.iter().map(Vec::as_slice).collect();
        (
            hevc::encode_thumbnails_10bit(&frames, width, height, HevcColor::Bt2020LimitedLog),
            10,
            9,
        )
    } else {
        // Use the existing 8-bit encoder's BT.709 matrix where Main10 is unavailable.
        let quantized: Vec<Vec<u8>> = codes
            .iter()
            .map(|frame| {
                frame
                    .iter()
                    .map(|&code| ((u32::from(code) + 128) / 257) as u8)
                    .collect()
            })
            .collect();
        let frames: Vec<&[u8]> = quantized.iter().map(Vec::as_slice).collect();
        (
            hevc::encode_tiles(
                &frames,
                width,
                height,
                3,
                true,
                HevcContent::LinearThumbnail,
            ),
            8,
            1,
        )
    };
    let encoded = encoded.map_err(|e| format!("Live Photo thumbnail encode: {e}"))?;
    let hvcc = encoded
        .streams
        .first()
        .and_then(|stream| {
            hevc::extract_hvcc_config_with_chroma_and_depth(stream, encoded.chroma_format_idc(), depth)
        })
        .ok_or("Live Photo thumbnail hvcC extraction failed")?;
    let thumbnails = TrackSamples::individual(encoded.streams.iter().map(|stream| {
        hevc::hevc_byte_stream_to_length_prefixed(&hevc::drop_parameter_nals(stream))
    }));
    let info = (!properties.is_empty()).then(|| TrackSamples::individual(properties));
    Ok(StyleFrames {
        thumbnails,
        hvcc,
        matrix,
        info,
    })
}
