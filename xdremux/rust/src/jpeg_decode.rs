//! JPEG decode via the `jpeg-decoder` crate (pure Rust, no subprocess).
//!
//! Decodes a JPEG byte buffer to raw pixels. Works on all platforms
//! including Android where subprocess execution is restricted by SELinux.

use std::io::Cursor;

/// Decode a JPEG byte buffer to raw RGB pixels (3 bytes per pixel, R-G-B).
///
/// Returns `(pixels, width, height)` where `pixels` is row-major
/// with stride = width * 3.
pub fn decode_jpeg_to_rgb(jpeg_data: &[u8]) -> std::io::Result<(Vec<u8>, u32, u32)> {
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(jpeg_data));
    let pixels = decoder.decode().map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, format!("JPEG decode error: {e}"))
    })?;
    let info = decoder.info().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "failed to read JPEG info")
    })?;

    let width = info.width as u32;
    let height = info.height as u32;

    // jpeg-decoder always outputs RGB (3 components) for color images,
    // or grayscale (1 component) for gray images.
    let rgb = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => pixels,
        jpeg_decoder::PixelFormat::L8 | jpeg_decoder::PixelFormat::L16 => {
            // Convert grayscale to RGB
            pixels.iter().flat_map(|&g| [g, g, g]).collect()
        }
        jpeg_decoder::PixelFormat::CMYK32 => {
            // Convert CMYK to RGB
            pixels.chunks_exact(4).flat_map(|cmyk| {
                let (c, m, y, k) = (cmyk[0] as u16, cmyk[1] as u16, cmyk[2] as u16, cmyk[3] as u16);
                let r = ((255 - c) * (255 - k) / 255) as u8;
                let g = ((255 - m) * (255 - k) / 255) as u8;
                let b = ((255 - y) * (255 - k) / 255) as u8;
                [r, g, b]
            }).collect()
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                format!("unsupported JPEG pixel format: {:?}", info.pixel_format),
            ));
        }
    };

    let expected = (width * height * 3) as usize;
    if rgb.len() < expected {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            format!("decoded {} bytes, expected {expected} ({}x{}x3)", rgb.len(), width, height),
        ));
    }

    Ok((rgb[..expected].to_vec(), width, height))
}

/// Decode a JPEG byte buffer to raw 8-bit grayscale pixels.
///
/// Returns `(pixels, width, height)` where `pixels` is row-major
/// with stride = width (tightly packed).
pub fn decode_jpeg_to_gray(jpeg_data: &[u8]) -> std::io::Result<(Vec<u8>, u32, u32)> {
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(jpeg_data));
    let pixels = decoder.decode().map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, format!("JPEG decode error: {e}"))
    })?;
    let info = decoder.info().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "failed to read JPEG info")
    })?;

    let width = info.width as u32;
    let height = info.height as u32;

    let gray = match info.pixel_format {
        jpeg_decoder::PixelFormat::L8 | jpeg_decoder::PixelFormat::L16 => pixels,
        jpeg_decoder::PixelFormat::RGB24 => {
            // Convert RGB to grayscale using BT.601 luminance
            pixels.chunks_exact(3).map(|rgb| {
                ((rgb[0] as u32 * 77 + rgb[1] as u32 * 150 + rgb[2] as u32 * 29) >> 8) as u8
            }).collect()
        }
        jpeg_decoder::PixelFormat::CMYK32 => {
            // Convert CMYK to grayscale via RGB
            pixels.chunks_exact(4).map(|cmyk| {
                let (c, m, y, k) = (cmyk[0] as u16, cmyk[1] as u16, cmyk[2] as u16, cmyk[3] as u16);
                let r = (255 - c) * (255 - k) / 255;
                let g = (255 - m) * (255 - k) / 255;
                let b = (255 - y) * (255 - k) / 255;
                ((r * 77 + g * 150 + b * 29) >> 8) as u8
            }).collect()
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                format!("unsupported JPEG pixel format: {:?}", info.pixel_format),
            ));
        }
    };

    let expected = (width * height) as usize;
    if gray.len() < expected {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            format!("decoded {} bytes, expected {expected} ({}x{})", gray.len(), width, height),
        ));
    }

    Ok((gray[..expected].to_vec(), width, height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_empty_jpeg_errors() {
        let result = decode_jpeg_to_gray(&[]);
        assert!(result.is_err());
    }

    #[test]
    fn decode_junk_data_errors() {
        let result = decode_jpeg_to_gray(&[0u8; 100]);
        assert!(result.is_err());
    }

    #[test]
    fn decode_rgb_junk_errors() {
        let result = decode_jpeg_to_rgb(&[]);
        assert!(result.is_err());
        let result = decode_jpeg_to_rgb(&[0u8; 100]);
        assert!(result.is_err());
    }
}
