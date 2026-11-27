//! Compare what the watermark restore would copy from a donor with where the
//! frame really is. For each donor: the PNG canvas rect, the detected bands,
//! the picture rect stored in `watermark.master.params`, the picture edges
//! measured from the pixels, and how much of the frame each method covers.
//!
//! cargo run --release --example wm_frame_probe -- <donor.heic>...
//! cargo run --release --example wm_frame_probe -- --verify <donor> <returned> <output>

use xdremux_core::{container, watermark_codec};

/// `--verify <donor> <returned> <output>`: how far the written-back output is
/// from the donor and from the returned edit, in the top and bottom bands, in
/// the side borders and in the picture. All three are decoded the same way.
fn verify(donor_path: &str, returned_path: &str, output_path: &str) {
    let decode = |path: &str| {
        let bytes = std::fs::read(path).expect("read");
        let image = heif_oxide::decode_bytes(&bytes).expect("decode");
        (bytes, image.width, image.height, image.to_rgba8())
    };
    let (donor, width, height, donor_rgba) = decode(donor_path);
    let (_, returned_w, returned_h, returned_rgba) = decode(returned_path);
    let (_, output_w, output_h, output_rgba) = decode(output_path);
    println!("donor {width}x{height} returned {returned_w}x{returned_h} output {output_w}x{output_h}");
    if (returned_w, returned_h) != (width, height) || (output_w, output_h) != (width, height) {
        println!("sizes differ");
        return;
    }
    let Some((x, y, w, h)) = container::watermark_frame_picture_rect(&donor, width, height) else {
        println!("donor stores no picture rect");
        return;
    };
    // Regions: 0 top and bottom bands, 1 side borders, 2 picture (three
    // pixels inside its edges left out).
    let mut sums = [[0u64; 2]; 3];
    let mut counts = [0u64; 3];
    let mut worst = [0u32; 3];
    for row in (0..height).step_by(2) {
        for column in (0..width).step_by(2) {
            let in_rows = row >= y && row < y + h;
            let in_columns = column >= x && column < x + w;
            let region = if !in_rows {
                0
            } else if !in_columns {
                1
            } else if row >= y + 3 && row < y + h - 3 && column >= x + 3 && column < x + w - 3 {
                2
            } else {
                continue;
            };
            let at = (row as usize * width as usize + column as usize) * 4;
            let distance = |other: &[u8]| -> u32 {
                (0..3).map(|c| output_rgba[at + c].abs_diff(other[at + c]) as u32).max().unwrap_or(0)
            };
            let (to_donor, to_returned) = (distance(&donor_rgba), distance(&returned_rgba));
            sums[region][0] += to_donor as u64;
            sums[region][1] += to_returned as u64;
            counts[region] += 1;
            worst[region] = worst[region].max(if region == 2 { to_returned } else { to_donor });
        }
    }
    for (region, name) in ["top/bottom bands", "side borders", "picture"].iter().enumerate() {
        if counts[region] == 0 {
            continue;
        }
        println!(
            "  {name}: output vs donor {:.2}, output vs returned edit {:.2}, worst pixel vs {} {}",
            sums[region][0] as f64 / counts[region] as f64,
            sums[region][1] as f64 / counts[region] as f64,
            if region == 2 { "edit" } else { "donor" },
            worst[region]
        );
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--verify") && args.len() == 5 {
        verify(&args[2], &args[3], &args[4]);
        return;
    }
    for path in std::env::args().skip(1) {
        let name = path.rsplit('/').next().unwrap_or(&path).to_string();
        let donor = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                println!("{name}: read failed: {error}");
                continue;
            }
        };
        let image = match heif_oxide::decode_bytes(&donor) {
            Ok(image) => image,
            Err(error) => {
                println!("{name}: decode failed: {error:?}");
                continue;
            }
        };
        let (width, height) = (image.width, image.height);
        let rgba = image.to_rgba8();
        let stride = width as usize * 4;
        let params = container::extract_tail_entry(&donor, "watermark.master.params");
        let style = params
            .as_deref()
            .and_then(|raw| raw.get(4..68))
            .and_then(|field| field.split(|&byte| byte == 0).next())
            .map(|style| String::from_utf8_lossy(style).into_owned())
            .unwrap_or_default();
        let words: Vec<f32> = params
            .as_deref()
            .filter(|raw| raw.len() >= 80)
            .map(|raw| {
                raw[raw.len() - 56..]
                    .chunks_exact(4)
                    .map(|word| f32::from_le_bytes([word[0], word[1], word[2], word[3]]))
                    .collect()
            })
            .unwrap_or_default();
        println!("{name}: {width}x{height} style={style} words={words:?}");
        println!(
            "  png canvas: {:?}",
            container::watermark_canvas_rect(&donor, width, height)
        );
        let bands = watermark_codec::detect_frame_bands(&rgba, width, height);
        println!("  bands: {bands:?}");
        let stored = container::watermark_frame_picture_rect(&donor, width, height);
        println!("  stored picture rect: {stored:?}");
        println!(
            "  stored rect confirmed by the pixels: {:?}",
            watermark_codec::stored_frame_picture_rect(&donor, &rgba, width, height)
        );

        // Frame colour from the bottom-left corner, the one margin every
        // sampled style has.
        let pixel = |x: u32, y: u32| -> [u8; 3] {
            let base = y as usize * stride + x as usize * 4;
            [rgba[base], rgba[base + 1], rgba[base + 2]]
        };
        let frame = pixel(8, height - 9);
        let is_frame =
            |x: u32, y: u32| (0..3).all(|c| pixel(x, y)[c].abs_diff(frame[c]) <= 6);
        let row_share = |y: u32, x0: u32, x1: u32| -> f64 {
            let (mut hit, mut all) = (0u32, 0u32);
            let mut x = x0;
            while x < x1 {
                all += 1;
                hit += is_frame(x, y) as u32;
                x += 16;
            }
            hit as f64 / all.max(1) as f64
        };
        let column_share = |x: u32, y0: u32, y1: u32| -> f64 {
            let (mut hit, mut all) = (0u32, 0u32);
            let mut y = y0;
            while y < y1 {
                all += 1;
                hit += is_frame(x, y) as u32;
                y += 16;
            }
            hit as f64 / all.max(1) as f64
        };
        // Picture edges measured from the pixels: walk inwards from each side
        // of the middle third until a line stops being frame.
        let (third_w, third_h) = (width / 3, height / 3);
        let mut top = 0;
        while top < height / 2 && row_share(top, third_w, 2 * third_w) >= 0.6 {
            top += 1;
        }
        let mut bottom = height - 8;
        while bottom > height / 2 && row_share(bottom - 1, third_w, 2 * third_w) >= 0.6 {
            bottom -= 1;
        }
        let mut left = 0;
        while left < width / 2 && column_share(left, third_h, 2 * third_h) >= 0.6 {
            left += 1;
        }
        let mut right = width;
        while right > width / 2 && column_share(right - 1, third_h, 2 * third_h) >= 0.6 {
            right -= 1;
        }
        println!(
            "  frame colour {frame:?}; measured picture edges: left={left} top={top} right={right} bottom={bottom}"
        );
        let Some((x, y, w, h)) = stored else { continue };
        // Pixels across each edge of the stored rect, three lines either side.
        let (mid_x, mid_y) = (x + w / 2, y + h / 2);
        let across = |horizontal: bool, edge: u32| -> Vec<[u8; 3]> {
            (edge.saturating_sub(3)..(edge + 3).min(if horizontal { width } else { height }))
                .map(|at| if horizontal { pixel(at, mid_y) } else { pixel(mid_x, at) })
                .collect()
        };
        if x > 0 {
            println!("  across left edge x={x}: {:?}", across(true, x));
        }
        if x + w < width {
            println!("  across right edge x={}: {:?}", x + w, across(true, x + w));
        }
        if y > 0 {
            println!("  across top edge y={y}: {:?}", across(false, y));
        }
        if y + h < height {
            println!("  across bottom edge y={}: {:?}", y + h, across(false, y + h));
        }
        // Share of the frame (everything outside the stored rect) that the
        // detected bands cover, and how uniform that frame is.
        let (mut frame_px, mut covered, mut uniform) = (0u64, 0u64, 0u64);
        let band_rows: Vec<(u32, u32)> = bands.clone().unwrap_or_default();
        let mut row = 0;
        while row < height {
            let in_band = band_rows.iter().any(|&(y0, y1)| row >= y0 && row < y1);
            let mut col = 0;
            while col < width {
                let inside = col >= x && col < x + w && row >= y && row < y + h;
                if !inside {
                    frame_px += 1;
                    covered += in_band as u64;
                    uniform += is_frame(col, row) as u64;
                }
                col += 4;
            }
            row += 4;
        }
        println!(
            "  frame outside the stored rect: bands cover {:.1}%, {:.1}% is the frame colour",
            covered as f64 * 100.0 / frame_px.max(1) as f64,
            uniform as f64 * 100.0 / frame_px.max(1) as f64
        );
    }
}
