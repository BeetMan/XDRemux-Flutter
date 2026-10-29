//! Bounded SDR primary previews. Never scan for gain-map JPEG fragments.
use std::io::Read;
use std::sync::Mutex;
const MAX_BYTES: u64 = 256 * 1024 * 1024;
const MAX_PIXELS: u64 = 64 * 1024 * 1024;
static DECODE: Mutex<()> = Mutex::new(());
fn extent(w: u32, h: u32) -> Result<(), String> {
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err("preview resource limit: invalid or excessive extent".into());
    }
    Ok(())
}
fn preflight(data: &[u8]) -> Result<(), String> {
    if data.starts_with(&[0xff, 0xd8]) {
        let mut decoder = jpeg_decoder::Decoder::new(std::io::Cursor::new(data));
        decoder.read_info().map_err(|e| e.to_string())?;
        let info = decoder.info().ok_or("missing JPEG dimensions")?;
        return extent(info.width as u32, info.height as u32);
    }
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        let reader = png::Decoder::new(std::io::Cursor::new(data))
            .read_info()
            .map_err(|e| e.to_string())?;
        return extent(reader.info().width, reader.info().height);
    }
    let meta = crate::isobmff::parse_source_meta(data)?;
    if meta.items.len() > 4096 {
        return Err("preview resource limit: too many items".into());
    }
    let mut primary = false;
    for p in &meta.props {
        if p.ptype == "ispe" {
            let (w, h) = crate::isobmff::ispe_dimensions(&p.raw)?;
            extent(w, h)?;
            primary |= meta.ipma_entries.iter().any(|e| {
                e.item_id == meta.primary_id && e.associations.iter().any(|(i, _)| *i == p.index)
            });
        }
    }
    if !primary {
        return Err("preview missing primary extent".into());
    }
    Ok(())
}
pub fn render(path: &str, size: u32) -> Result<Vec<u8>, String> {
    if !(1..=2048).contains(&size) {
        return Err("preview size must be 1..2048".into());
    }
    // One full-resolution allocation at a time across all Dart isolates.
    let _guard = DECODE.lock().map_err(|_| "preview lock poisoned")?;
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > MAX_BYTES {
        return Err("preview input exceeds 256 MiB".into());
    }
    let mut data = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > MAX_BYTES {
        return Err("preview input grew past limit".into());
    }
    preflight(&data)?;
    let (mut rgb, mut w, mut h, oriented) = crate::sdr_source::decode_to_rgb(&data)?;
    extent(w, h)?;
    if !oriented {
        let orientation = crate::uhdr_jpeg::extract_exif_tiff(&data)
            .as_deref()
            .map(crate::exif::parse_exif_orientation)
            .transpose()?
            .unwrap_or(crate::exif::ExifOrientation::Normal);
        (rgb, w, h) = crate::isobmff_write::orient_gainmap_pixels(
            &rgb,
            w,
            h,
            3,
            w as usize * 3,
            orientation,
        )?;
    }
    let scale = w.max(h).max(size);
    let tw = (u64::from(w) * u64::from(size) / u64::from(scale)).max(1) as u32;
    let th = (u64::from(h) * u64::from(size) / u64::from(scale)).max(1) as u32;
    let pixels = crate::linear_thumbnail::box_resize(&rgb, w, h, tw, th);
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, tw, th);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .map_err(|e| e.to_string())?
            .write_image_data(&pixels)
            .map_err(|e| e.to_string())?;
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_bad_extents_and_inputs() {
        assert!(extent(0, 1).is_err());
        assert!(extent(u32::MAX, u32::MAX).is_err());
        assert!(preflight(b"bad").is_err());
        assert!(render("missing", 0).is_err());
        assert!(render("missing", 2049).is_err());
    }
    #[test]
    fn downsamples_primary_png_without_upscaling() {
        let path = std::env::temp_dir().join(format!("xdremux-preview-{}.png", std::process::id()));
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, 20, 10);
            encoder.set_color(png::ColorType::Rgb);
            encoder
                .write_header()
                .unwrap()
                .write_image_data(&[120; 600])
                .unwrap();
        }
        std::fs::write(&path, bytes).unwrap();
        for (size, expected) in [(8, (8, 4)), (32, (20, 10))] {
            let out = render(path.to_str().unwrap(), size).unwrap();
            let reader = png::Decoder::new(std::io::Cursor::new(out))
                .read_info()
                .unwrap();
            assert_eq!((reader.info().width, reader.info().height), expected);
        }
        std::fs::remove_file(path).unwrap();
    }
}
