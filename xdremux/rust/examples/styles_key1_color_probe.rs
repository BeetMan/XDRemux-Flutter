//! Replay the key 1 payload a converted file carries on that file's own
//! displayed primary and measure how far the colour moves (upstream PR #88
//! "colour grid" check for the Standard style).
//!
//! Usage:
//! `cargo run --release -p xdremux-core --example styles_key1_color_probe -- <out_dir> <converted.heic>...`
//!
//! For every converted file: read the `styleMetadata` bplist back, pull the
//! 51 840-byte key 1 Data object, decode the primary at Linear Thumbnail
//! geometry in display order (the raster the fit saw), evaluate key 1 on it
//! with the fit's own consumer model (`styles_fit::apply_style_data`) and
//! report ΔE76 / chromaticity statistics plus the 12×9 cell map of the mean
//! chroma shift. Writes `<stem>-before.png`, `<stem>-after.png`,
//! `<stem>-deltae.png` (ΔE76 / 40 as grey) and `<stem>-chroma.png` (Δa* on
//! red↔green, Δb* on yellow↔blue, ×8 around mid grey) into `out_dir`. The "exposure-only" row refits key 1
//! with no gain map (thumbnail = primary × h / key 4) to separate the
//! baseline-exposure ratio from the gain-map ratio.
//!
//! Since the writer stopped emitting the fitted key 1 (Standard key 1 is the
//! identity lattice), the "file key1" row reads 0 on new outputs and the
//! "exposure-only" row shows what the fit would have painted.
//!
//! Diagnostic model only: Photos is the real consumer and still has to be
//! checked by eye (slider screenshots).

use std::path::Path;

use xdremux_core::styles_fit::{
    apply_style_data, fit_style_state, mean_abs_chroma_delta, StyleFitRaster, GRID_HEIGHT,
    GRID_WIDTH, STYLE_DATA_BYTE_COUNT,
};
use xdremux_core::styles_native::StyleStateOverride;
use xdremux_core::{exif, isobmff, linear_thumbnail};

fn style_metadata_item(data: &[u8]) -> Result<Vec<u8>, String> {
    let meta = isobmff::parse_source_meta(data)?;
    let item = meta
        .items
        .iter()
        .find(|i| i.itype == "uri " && i.raw_infe.windows(13).any(|w| w == b"styleMetadata"))
        .ok_or("no styleMetadata item")?;
    let entry = meta
        .iloc_entries
        .iter()
        .find(|e| e.item_id == item.item_id)
        .ok_or("styleMetadata has no iloc entry")?;
    let base = match entry.construction_method {
        0 => 0usize,
        1 => isobmff::find_idat_box(data)
            .map(|b| b.data_start)
            .ok_or("idat construction without idat box")?,
        m => return Err(format!("unsupported construction method {m}")),
    };
    let mut out = Vec::new();
    for &(offset, length) in &entry.extents {
        let start = base + offset as usize;
        let end = start + length as usize;
        out.extend_from_slice(
            data.get(start..end)
                .ok_or("styleMetadata extent out of range")?,
        );
    }
    Ok(out)
}

/// Locate a bplist Data object of exactly `len` bytes (marker 0x4F + int).
fn bplist_data_object(plist: &[u8], len: usize) -> Option<&[u8]> {
    let candidates: [Vec<u8>; 2] = [
        [vec![0x4F, 0x11], (len as u16).to_be_bytes().to_vec()].concat(),
        [vec![0x4F, 0x12], (len as u32).to_be_bytes().to_vec()].concat(),
    ];
    for needle in &candidates {
        if let Some(pos) = plist
            .windows(needle.len())
            .position(|w| w == needle.as_slice())
        {
            let start = pos + needle.len();
            return plist.get(start..start + len);
        }
    }
    None
}

fn primary_raster(data: &[u8]) -> Result<StyleFitRaster, String> {
    let meta = isobmff::parse_source_meta(data)?;
    let irot = meta
        .ipma_entries
        .iter()
        .find(|e| e.item_id == meta.primary_id)
        .and_then(|e| {
            e.associations.iter().find_map(|(idx, _)| {
                meta.props
                    .iter()
                    .find(|p| p.index == *idx && p.ptype == "irot")
            })
        })
        .and_then(|p| isobmff::irot_quarter_turns(&p.raw).ok())
        .unwrap_or(0) as u32;
    let orientation = exif::read_heif_exif_orientation(data, &meta.items, &meta.iloc_entries, None)
        .map(|o| o.to_u16())
        .unwrap_or(1);
    let out = linear_thumbnail::generate_linear_thumbnail_and_light_maps(
        data,
        irot,
        orientation,
        StyleStateOverride::identity().tag4 as f32,
    )?;
    Ok(out.fit_raster)
}

fn srgb_encode(v: f32) -> f32 {
    let v = v.clamp(0.0, 1.0);
    if v <= 0.003_130_8 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }
}

fn lab(rgb: &[f32]) -> [f64; 3] {
    let (r, g, b) = (
        f64::from(rgb[0].clamp(0.0, 1.0)),
        f64::from(rgb[1].clamp(0.0, 1.0)),
        f64::from(rgb[2].clamp(0.0, 1.0)),
    );
    let x = (0.412_390_8 * r + 0.357_584_3 * g + 0.180_480_8 * b) / 0.950_47;
    let y = 0.212_639 * r + 0.715_169 * g + 0.072_192 * b;
    let z = (0.019_330_8 * r + 0.119_194_8 * g + 0.950_532 * b) / 1.088_83;
    let f = |t: f64| {
        if t > 216.0 / 24_389.0 {
            t.cbrt()
        } else {
            (24_389.0 / 27.0 * t + 16.0) / 116.0
        }
    };
    let (fx, fy, fz) = (f(x), f(y), f(z));
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

fn write_png(path: &Path, width: usize, height: usize, rgb8: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgb8).map_err(|e| e.to_string())
}

fn to_srgb8(linear: &[f32]) -> Vec<u8> {
    linear
        .iter()
        .map(|&v| (srgb_encode(v) * 255.0).round().clamp(0.0, 255.0) as u8)
        .collect()
}

struct Report {
    de_mean: f64,
    de_p95: f64,
    de_max: f64,
    chroma: f64,
    l_mean: f64,
    cell_chroma: Vec<f64>,
    cell_ab: Vec<[f64; 2]>,
    de_map: Vec<f64>,
    ab_map: Vec<[f64; 2]>,
}

fn measure(width: usize, height: usize, before: &[f32], after: &[f32]) -> Report {
    let mut de = Vec::with_capacity(width * height);
    let mut ab_map = Vec::with_capacity(width * height);
    let mut l_sum = 0.0;
    let mut cell_sum = vec![[0.0_f64; 2]; GRID_WIDTH * GRID_HEIGHT];
    let mut cell_count = vec![0.0_f64; GRID_WIDTH * GRID_HEIGHT];
    for y in 0..height {
        for x in 0..width {
            let o = (y * width + x) * 3;
            let a = lab(&before[o..o + 3]);
            let b = lab(&after[o..o + 3]);
            let d = ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt();
            de.push(d);
            ab_map.push([b[1] - a[1], b[2] - a[2]]);
            l_sum += b[0] - a[0];
            let cell = (x * GRID_WIDTH / width) * GRID_HEIGHT + (y * GRID_HEIGHT / height);
            cell_sum[cell][0] += b[1] - a[1];
            cell_sum[cell][1] += b[2] - a[2];
            cell_count[cell] += 1.0;
        }
    }
    let mut sorted = de.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let n = sorted.len().max(1);
    let cell_ab: Vec<[f64; 2]> = cell_sum
        .iter()
        .zip(&cell_count)
        .map(|(s, c)| [s[0] / c.max(1.0), s[1] / c.max(1.0)])
        .collect();
    Report {
        de_mean: de.iter().sum::<f64>() / n as f64,
        de_p95: sorted[(n * 95 / 100).min(n - 1)],
        de_max: sorted[n - 1],
        chroma: mean_abs_chroma_delta(before, after),
        l_mean: l_sum / n as f64,
        cell_chroma: cell_ab
            .iter()
            .map(|ab| (ab[0].powi(2) + ab[1].powi(2)).sqrt())
            .collect(),
        cell_ab,
        de_map: de,
        ab_map,
    }
}

/// Mean |difference| of the per-cell (Δa*, Δb*) between horizontally /
/// vertically adjacent cells: how "blocky" the chroma shift is.
fn cell_edge_contrast(cell_ab: &[[f64; 2]]) -> f64 {
    let mut total = 0.0_f64;
    let mut count = 0.0_f64;
    for cx in 0..GRID_WIDTH {
        for cy in 0..GRID_HEIGHT {
            let here = cell_ab[cx * GRID_HEIGHT + cy];
            if cx + 1 < GRID_WIDTH {
                let n = cell_ab[(cx + 1) * GRID_HEIGHT + cy];
                total += ((here[0] - n[0]).powi(2) + (here[1] - n[1]).powi(2)).sqrt();
                count += 1.0;
            }
            if cy + 1 < GRID_HEIGHT {
                let n = cell_ab[cx * GRID_HEIGHT + cy + 1];
                total += ((here[0] - n[0]).powi(2) + (here[1] - n[1]).powi(2)).sqrt();
                count += 1.0;
            }
        }
    }
    total / count.max(1.0)
}

fn print_report(label: &str, r: &Report) {
    println!(
        "  {label:<14} ΔE76 mean {:.2}  p95 {:.2}  max {:.2} | chroma {:.4} | ΔL* mean {:+.2} | cell-edge Δab {:.2}",
        r.de_mean,
        r.de_p95,
        r.de_max,
        r.chroma,
        r.l_mean,
        cell_edge_contrast(&r.cell_ab)
    );
}

fn print_cell_map(r: &Report) {
    println!("  12×9 cell map of |mean (Δa*, Δb*)| (rows = y cells, columns = x cells):");
    for cy in 0..GRID_HEIGHT {
        let row: Vec<String> = (0..GRID_WIDTH)
            .map(|cx| format!("{:5.1}", r.cell_chroma[cx * GRID_HEIGHT + cy]))
            .collect();
        println!("    {}", row.join(" "));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: styles_key1_color_probe <out_dir> <converted.heic>...");
        std::process::exit(2);
    }
    let out_dir = Path::new(&args[0]);
    std::fs::create_dir_all(out_dir).expect("create out_dir");
    let identity = StyleStateOverride::identity();
    for path in &args[1..] {
        println!("{path}");
        let data = std::fs::read(path).expect("read input");
        let plist = match style_metadata_item(&data) {
            Ok(p) => p,
            Err(e) => {
                println!("  error: {e}");
                continue;
            }
        };
        let Some(key1) = bplist_data_object(&plist, STYLE_DATA_BYTE_COUNT) else {
            println!("  error: no {STYLE_DATA_BYTE_COUNT}-byte key 1 object in styleMetadata");
            continue;
        };
        let is_identity = key1 == identity.key1.as_slice();
        let raster = match primary_raster(&data) {
            Ok(r) => r,
            Err(e) => {
                println!("  error: {e}");
                continue;
            }
        };
        let (w, h) = (raster.width, raster.height);
        let before = &raster.primary_linear;
        println!("  raster {w}x{h}, key1 identity={is_identity}");

        let after = apply_style_data(key1, w, h, before).expect("apply file key1");
        let file_report = measure(w, h, before, &after);
        print_report("file key1", &file_report);
        print_cell_map(&file_report);

        // Control: identity payload must not move anything.
        let kept = apply_style_data(&identity.key1, w, h, before).expect("apply identity");
        print_report("identity", &measure(w, h, before, &kept));

        // Exposure-only refit: no gain map, thumbnail = primary × h / key4.
        let no_gain = StyleFitRaster {
            width: w,
            height: h,
            primary_linear: before.clone(),
            scene_linear: before.clone(),
        };
        if let Ok(fitted) = fit_style_state(&no_gain, identity.tag4, identity.tag_h) {
            let applied = apply_style_data(&fitted.style_data, w, h, before).expect("apply refit");
            print_report("exposure-only", &measure(w, h, before, &applied));
        }

        let stem = Path::new(path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "sample".into());
        write_png(
            &out_dir.join(format!("{stem}-before.png")),
            w,
            h,
            &to_srgb8(before),
        )
        .unwrap();
        write_png(
            &out_dir.join(format!("{stem}-after.png")),
            w,
            h,
            &to_srgb8(&after),
        )
        .unwrap();
        let heat: Vec<u8> = file_report
            .de_map
            .iter()
            .flat_map(|&d| {
                let v = (d / 40.0 * 255.0).clamp(0.0, 255.0) as u8;
                [v, v, v]
            })
            .collect();
        write_png(&out_dir.join(format!("{stem}-deltae.png")), w, h, &heat).unwrap();
        let chroma: Vec<u8> = file_report
            .ab_map
            .iter()
            .flat_map(|ab| {
                let px = |v: f64| (128.0 + v * 8.0).round().clamp(0.0, 255.0) as u8;
                [px(ab[0]), px(-ab[0] * 0.5 + ab[1] * 0.5), px(-ab[1])]
            })
            .collect();
        write_png(&out_dir.join(format!("{stem}-chroma.png")), w, h, &chroma).unwrap();
        println!(
            "  wrote {}/{stem}-{{before,after,deltae,chroma}}.png",
            out_dir.display()
        );
    }
}
