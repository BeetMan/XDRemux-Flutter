//! OPPO / ColorOS Camera & Gallery Filter Ecosystem Interoperability (Direction 4).
//!
//! Provides bidirectional codecs, colour-managed LUT baking, and non-destructive
//! `FileExtendedContainer` (`\0jxrs`) tail inspection/injection for:
//! - `.MS-LUT` (`Meishe` 3D LUT binary format, 17³ / 32³) <-> Adobe `.cube` 3D LUTs
//! - OPPO Camera Display P3 (sRGB EOTF) <-> Rec.709 CSS Color 4 OkLCh gamut-mapped LUT baking
//! - ColorOS Gallery `filter.info` (v4.0 140-byte & v5.0/v5.1 228-byte binary structs)
//! - ColorOS Gallery `master.mode.preset.info` (496-byte Hasselblad Master preset struct)
//! - OPPO BasicTone `basictone.info` (8216-byte 16³ FP16 LUT + header/footer) &
//!   `basictone.vig.table` (884-byte 13×17 FP32 vignette grid)

use std::fmt::Write as _;

/// Magic header bytes of a Meishe `.MS-LUT` binary file (`".MS-LUT "`).
pub const MSLUT_MAGIC: &[u8; 8] = b".MS-LUT ";
/// Core header length before the `N` float coordinates.
pub const MSLUT_CORE_HEADER_LEN: usize = 48;

/// Size of v4.0 `filter.info` payload (ColorOS 14/15 classic & master filters).
pub const OPPO_FILTER_INFO_V4_LEN: usize = 140;
/// Size of v5.0 / v5.1 `filter.info` payload (ColorOS 16/17 with Palette & Scene Luma extension).
pub const OPPO_FILTER_INFO_V5_LEN: usize = 228;
/// Size of `master.mode.preset.info` payload (Hasselblad Master Mode preset).
pub const OPPO_MASTER_PRESET_INFO_LEN: usize = 496;
/// Size of `basictone.info` payload (`16³` FP16 + 24B header/footer).
pub const OPPO_BASICTONE_INFO_LEN: usize = 8216;
/// Size of `basictone.vig.table` payload (`13 × 17` FP32 radial vignette grid).
pub const OPPO_BASICTONE_VIG_TABLE_LEN: usize = 884;

// ---------------------------------------------------------------------------
// 1. OPPO / Hasselblad / X10 / GR Filter Catalog
// ---------------------------------------------------------------------------

/// Metadata for a known OPPO / ColorOS / Hasselblad / X10 filter token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OppoFilterCatalogEntry {
    pub filter_type: &'static str,
    pub name_zh: &'static str,
    pub name_en: &'static str,
    pub category: &'static str,
    pub default_soft_light: i32,
}

pub const OPPO_FILTER_CATALOG: &[OppoFilterCatalogEntry] = &[
    // Master Mode (大师滤镜)
    OppoFilterCatalogEntry {
        filter_type: "default",
        name_zh: "原图 / 标准",
        name_en: "Original / Standard",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "qing_tou.bin",
        name_zh: "清透",
        name_en: "Clear (Serenity)",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "tong_hua.bin",
        name_zh: "童话",
        name_en: "Fairy Tale",
        category: "master",
        default_soft_light: 2,
    },
    OppoFilterCatalogEntry {
        filter_type: " LengDiao.bin",
        name_zh: "冷调",
        name_en: "Cool Tone",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "R8.bin",
        name_zh: "复古",
        name_en: "Retro",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "G4.bin",
        name_zh: "正片",
        name_en: "Positive Film",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "B6.bin",
        name_zh: "黑白",
        name_en: "Monochrome",
        category: "master",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "mei_shi.bin",
        name_zh: "美食",
        name_en: "Food",
        category: "master",
        default_soft_light: 0,
    },
    // Find X10 / ColorOS 16+ Portrait & Film Dual-LUTs
    OppoFilterCatalogEntry {
        filter_type: "hu_po.bin",
        name_zh: "琥珀",
        name_en: "Amber",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "fuji_cc_normal_a_1.bin,fuji_cc_normal_d_1.bin",
        name_zh: "经典正片 (CC)",
        name_en: "Classic Chrome (CC)",
        category: "film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "fuji_nc_normal_a_1.bin,fuji_nc_normal_d_1.bin",
        name_zh: "经典负片 (NC)",
        name_en: "Classic Neg (NC)",
        category: "film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "fuji_provia_hdr_normal_a_1.bin,fuji_provia_hdr_normal_d_1.bin",
        name_zh: "标准正片 (Provia)",
        name_en: "Provia Standard",
        category: "film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin",
        name_zh: "Portra 400",
        name_en: "Kodak Portra 400",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "velvia100_hdr_normal_a_1.bin,velvia100_hdr_normal_d_1.bin",
        name_zh: "Velvia 100",
        name_en: "Fujifilm Velvia 100",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "cinestill_800t_hdr_normal_a_1.bin,cinestill_800t_hdr_normal_d_1.bin",
        name_zh: "CineStill 800T",
        name_en: "CineStill 800T",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "c200_hdr_normal_a_1.bin,c200_hdr_normal_d_1.bin",
        name_zh: "复古胶片 (C200)",
        name_en: "Fujicolor C200",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "gold200_2026_hdr_normal_a_1.bin,gold200_2026_hdr_normal_d_1.bin",
        name_zh: "暖金胶片 (Gold 200)",
        name_en: "Kodak Gold 200",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "ektar100_hdr_normal_a_1.bin,ektar100_hdr_normal_d_1.bin",
        name_zh: "风光胶片 (Ektar 100)",
        name_en: "Kodak Ektar 100",
        category: "x10_film",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "neon_2020_a_1.bin,neon_2020_d_1.bin",
        name_zh: "霓虹",
        name_en: "Neon",
        category: "portrait",
        default_soft_light: 1,
    },
    OppoFilterCatalogEntry {
        filter_type: "f_japan_a_1.bin,f_japan_d_1.bin",
        name_zh: "清新",
        name_en: "Fresh",
        category: "portrait",
        default_soft_light: 1,
    },
    OppoFilterCatalogEntry {
        filter_type: "f_cream_a_1.bin,f_cream_d_1.bin",
        name_zh: "元气",
        name_en: "Vitality",
        category: "portrait",
        default_soft_light: 1,
    },
    OppoFilterCatalogEntry {
        filter_type: "f_ins_a_1.bin,f_ins_d_1.bin",
        name_zh: "质感",
        name_en: "Rich / Texture",
        category: "portrait",
        default_soft_light: 0,
    },
    OppoFilterCatalogEntry {
        filter_type: "f_back_4_a_1.bin,f_back_4_d_1.bin",
        name_zh: "璀璨夜晚",
        name_en: "Dazzling Night",
        category: "portrait",
        default_soft_light: 0,
    },
];

/// Look up a filter token in `OPPO_FILTER_CATALOG`.
pub fn lookup_oppo_filter(filter_type: &str) -> Option<&'static OppoFilterCatalogEntry> {
    OPPO_FILTER_CATALOG
        .iter()
        .find(|e| e.filter_type == filter_type || e.filter_type.trim() == filter_type.trim())
}

// ---------------------------------------------------------------------------
// 2. Meishe `.MS-LUT` & Adobe `.cube` 3D LUT Codecs + OkLCh Gamut Baker
// ---------------------------------------------------------------------------

/// Colour-space transformation applied when baking a `.cube` 3D LUT into an OPPO `.MS-LUT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LutColorTransform {
    /// Direct trilinear resampling without gamut conversion (when the `.cube` is already in Display P3).
    DirectSrgb,
    /// OPPO Camera Display P3 (with sRGB EOTF) -> Rec.709 CSS Color 4 OkLCh gamut mapping -> `.cube` -> Display P3.
    /// Matches `Rec709LutBaker.java` and `bake_rec709_to_serenity_mslut.py`.
    OppoDisplayP3Rec709Oklch,
}

/// Parsed `.MS-LUT` (`Meishe` 3D LUT) binary asset.
#[derive(Debug, Clone, PartialEq)]
pub struct MsLut {
    pub version: u32,
    pub dimension: u32,
    pub reserved_10: u64,
    pub flag: u32,
    pub reserved_1c: u32,
    pub coords: Vec<f32>,
    /// `dimension³` RGB triplets in R-fastest order: `index = (b * N + g) * N + r`.
    pub rgb: Vec<[u8; 3]>,
}

impl MsLut {
    /// Creates an identity `.MS-LUT` of dimension `n` (typically 17 or 32).
    pub fn identity(n: u32) -> Result<Self, String> {
        if !(2..=128).contains(&n) {
            return Err(format!("invalid MS-LUT dimension {n} (expected 2..=128)"));
        }
        let coords: Vec<f32> = (0..n).map(|i| i as f32 / (n - 1) as f32).collect();
        let mut rgb = Vec::with_capacity((n * n * n) as usize);
        for b in 0..n {
            let bv = ((b as f32 / (n - 1) as f32) * 255.0).round() as u8;
            for g in 0..n {
                let gv = ((g as f32 / (n - 1) as f32) * 255.0).round() as u8;
                for r in 0..n {
                    let rv = ((r as f32 / (n - 1) as f32) * 255.0).round() as u8;
                    rgb.push([rv, gv, bv]);
                }
            }
        }
        Ok(Self {
            version: 1,
            dimension: n,
            reserved_10: 0,
            flag: if n == 32 { 1 } else { 0 },
            reserved_1c: 0,
            coords,
            rgb,
        })
    }

    /// Parses a `.MS-LUT` binary blob.
    pub fn from_mslut_bytes(data: &[u8]) -> Result<Self, String> {
        if data.len() < MSLUT_CORE_HEADER_LEN {
            return Err(format!(
                "MS-LUT too short ({} bytes, need at least {})",
                data.len(),
                MSLUT_CORE_HEADER_LEN
            ));
        }
        if &data[0..8] != MSLUT_MAGIC {
            return Err("invalid MS-LUT magic (expected \".MS-LUT \")".into());
        }
        let version = u32::from_le_bytes(data[8..12].try_into().unwrap());
        let dimension = u32::from_le_bytes(data[12..16].try_into().unwrap());
        if !(2..=128).contains(&dimension) {
            return Err(format!("unsupported MS-LUT dimension {dimension}"));
        }
        let reserved_10 = u64::from_le_bytes(data[16..24].try_into().unwrap());
        let flag = u32::from_le_bytes(data[24..28].try_into().unwrap());
        let reserved_1c = u32::from_le_bytes(data[28..32].try_into().unwrap());
        let coord_offset = u64::from_le_bytes(data[32..40].try_into().unwrap()) as usize;
        let data_offset = u64::from_le_bytes(data[40..48].try_into().unwrap()) as usize;

        let n = dimension as usize;
        let coord_bytes = n * 4;
        let lut_points = n * n * n;
        let lut_bytes = lut_points * 3;

        if coord_offset < MSLUT_CORE_HEADER_LEN || coord_offset + coord_bytes > data.len() {
            return Err(format!(
                "invalid MS-LUT coord_offset {coord_offset} for N={dimension}"
            ));
        }
        if data_offset < coord_offset + coord_bytes || data_offset + lut_bytes > data.len() {
            return Err(format!(
                "invalid MS-LUT data_offset {data_offset} for N={dimension} (len={})",
                data.len()
            ));
        }

        let mut coords = Vec::with_capacity(n);
        for i in 0..n {
            let off = coord_offset + i * 4;
            coords.push(f32::from_le_bytes(data[off..off + 4].try_into().unwrap()));
        }

        let mut rgb = Vec::with_capacity(lut_points);
        for i in 0..lut_points {
            let off = data_offset + i * 3;
            rgb.push([data[off], data[off + 1], data[off + 2]]);
        }

        Ok(Self {
            version,
            dimension,
            reserved_10,
            flag,
            reserved_1c,
            coords,
            rgb,
        })
    }

    /// Encodes this `MsLut` into the exact `.MS-LUT` binary format.
    pub fn to_mslut_bytes(&self) -> Vec<u8> {
        let n = self.dimension as usize;
        let coord_offset = MSLUT_CORE_HEADER_LEN as u64;
        let data_offset = (MSLUT_CORE_HEADER_LEN + n * 4) as u64;
        let total_len = data_offset as usize + n * n * n * 3;
        let mut out = Vec::with_capacity(total_len);

        out.extend_from_slice(MSLUT_MAGIC);
        out.extend_from_slice(&self.version.to_le_bytes());
        out.extend_from_slice(&self.dimension.to_le_bytes());
        out.extend_from_slice(&self.reserved_10.to_le_bytes());
        out.extend_from_slice(&self.flag.to_le_bytes());
        out.extend_from_slice(&self.reserved_1c.to_le_bytes());
        out.extend_from_slice(&coord_offset.to_le_bytes());
        out.extend_from_slice(&data_offset.to_le_bytes());

        for i in 0..n {
            let c = self
                .coords
                .get(i)
                .copied()
                .unwrap_or_else(|| i as f32 / (n.saturating_sub(1).max(1)) as f32);
            out.extend_from_slice(&c.to_le_bytes());
        }

        for &[r, g, b] in &self.rgb {
            out.push(r);
            out.push(g);
            out.push(b);
        }

        out
    }

    /// Exports this `.MS-LUT` to an Adobe `.cube` 3D LUT string.
    pub fn to_cube_string(&self, title: Option<&str>) -> String {
        let n = self.dimension as usize;
        let mut s = String::with_capacity(n * n * n * 28 + 128);
        let title_str = title.unwrap_or("Exported_from_OPPO_MS_LUT");
        let _ = writeln!(s, "TITLE \"{title_str}\"");
        let _ = writeln!(s, "LUT_3D_SIZE {}", self.dimension);
        let _ = writeln!(s, "DOMAIN_MIN 0.0 0.0 0.0");
        let _ = writeln!(s, "DOMAIN_MAX 1.0 1.0 1.0");
        for &[r, g, b] in &self.rgb {
            let _ = writeln!(
                s,
                "{:.6} {:.6} {:.6}",
                r as f64 / 255.0,
                g as f64 / 255.0,
                b as f64 / 255.0
            );
        }
        s
    }

    /// Trilinearly samples the `.MS-LUT` at normalized `r, g, b` in `[0.0, 1.0]`, returning `[0.0, 1.0]` RGB.
    pub fn sample_normalized(&self, r: f32, g: f32, b: f32) -> [f32; 3] {
        let n = self.dimension as usize;
        if n < 2 || self.rgb.len() < n * n * n {
            return [r, g, b];
        }
        let scale = (n - 1) as f32;
        let pr = r.clamp(0.0, 1.0) * scale;
        let pg = g.clamp(0.0, 1.0) * scale;
        let pb = b.clamp(0.0, 1.0) * scale;

        let r0 = (pr.floor() as usize).min(n - 2);
        let g0 = (pg.floor() as usize).min(n - 2);
        let b0 = (pb.floor() as usize).min(n - 2);

        let fr = pr - r0 as f32;
        let fg = pg - g0 as f32;
        let fb = pb - b0 as f32;

        let mut out = [0.0f32; 3];
        for db in 0..2 {
            let wb = if db == 1 { fb } else { 1.0 - fb };
            for dg in 0..2 {
                let wg = if dg == 1 { fg } else { 1.0 - fg };
                for dr in 0..2 {
                    let wr = if dr == 1 { fr } else { 1.0 - fr };
                    let w = wr * wg * wb;
                    let idx = ((b0 + db) * n + (g0 + dg)) * n + (r0 + dr);
                    let px = self.rgb[idx];
                    out[0] += w * (px[0] as f32 / 255.0);
                    out[1] += w * (px[1] as f32 / 255.0);
                    out[2] += w * (px[2] as f32 / 255.0);
                }
            }
        }
        out
    }

    /// Applies the `.MS-LUT` to an 8-bit RGB image buffer in-place, with optional intensity (`0.0..=1.0`)
    /// and Orton Soft Light blend (`soft_light_alpha` in `0.0..=1.0`, matching OPPO Meishe filter pipeline).
    pub fn apply_to_rgb8(
        &self,
        rgb: &mut [u8],
        width: usize,
        height: usize,
        intensity: f32,
        soft_light_alpha: f32,
    ) {
        let strength = intensity.clamp(0.0, 1.0);
        if strength <= 0.0 || rgb.len() < width * height * 3 {
            return;
        }
        let mut graded = vec![0.0f32; width * height * 3];
        for i in 0..(width * height) {
            let off = i * 3;
            let r0 = rgb[off] as f32 / 255.0;
            let g0 = rgb[off + 1] as f32 / 255.0;
            let b0 = rgb[off + 2] as f32 / 255.0;
            let [mr, mg, mb] = self.sample_normalized(r0, g0, b0);
            graded[off] = r0 + strength * (mr - r0);
            graded[off + 1] = g0 + strength * (mg - g0);
            graded[off + 2] = b0 + strength * (mb - b0);
        }

        let alpha = soft_light_alpha.clamp(0.0, 1.0);
        if alpha > 0.0 && width >= 3 && height >= 3 {
            let blurred = box_blur_rgb(&graded, width, height, 4);
            for i in 0..(width * height * 3) {
                let x = graded[i].clamp(0.0, 1.0);
                let b = blurred[i].clamp(0.0, 1.0);
                // Pegtop / Orton soft-light formula from OPPO filter pipeline:
                // B(x, b) = (1 - 2b) * x^2 + 2 * b * x
                let orton = (1.0 - 2.0 * b) * x * x + 2.0 * b * x;
                graded[i] = x + alpha * (orton - x);
            }
        }

        for i in 0..(width * height * 3) {
            rgb[i] = (graded[i].clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
}

fn box_blur_rgb(src: &[f32], width: usize, height: usize, radius: usize) -> Vec<f32> {
    let mut temp = vec![0.0f32; src.len()];
    let mut dst = vec![0.0f32; src.len()];
    let r = radius as isize;
    // Horizontal pass
    for y in 0..height {
        for x in 0..width {
            let mut acc = [0.0f32; 3];
            let mut count = 0.0f32;
            for dx in -r..=r {
                let sx = (x as isize + dx).clamp(0, width as isize - 1) as usize;
                let off = (y * width + sx) * 3;
                acc[0] += src[off];
                acc[1] += src[off + 1];
                acc[2] += src[off + 2];
                count += 1.0;
            }
            let out_off = (y * width + x) * 3;
            temp[out_off] = acc[0] / count;
            temp[out_off + 1] = acc[1] / count;
            temp[out_off + 2] = acc[2] / count;
        }
    }
    // Vertical pass
    for y in 0..height {
        for x in 0..width {
            let mut acc = [0.0f32; 3];
            let mut count = 0.0f32;
            for dy in -r..=r {
                let sy = (y as isize + dy).clamp(0, height as isize - 1) as usize;
                let off = (sy * width + x) * 3;
                acc[0] += temp[off];
                acc[1] += temp[off + 1];
                acc[2] += temp[off + 2];
                count += 1.0;
            }
            let out_off = (y * width + x) * 3;
            dst[out_off] = acc[0] / count;
            dst[out_off + 1] = acc[1] / count;
            dst[out_off + 2] = acc[2] / count;
        }
    }
    dst
}

/// Parsed Adobe `.cube` 3D LUT.
#[derive(Debug, Clone)]
pub struct Cube3dLut {
    pub title: Option<String>,
    pub dimension: usize,
    pub domain_min: [f64; 3],
    pub domain_max: [f64; 3],
    /// `dimension³` RGB triplets in R-fastest order `[b][g][r]`.
    pub table: Vec<[f64; 3]>,
}

impl Cube3dLut {
    /// Parses an Adobe `.cube` 3D LUT text file.
    pub fn from_cube_str(cube_text: &str) -> Result<Self, String> {
        let mut title = None;
        let mut dimension: Option<usize> = None;
        let mut domain_min = [0.0f64; 3];
        let mut domain_max = [1.0f64; 3];
        let mut table = Vec::new();

        for (line_no, raw_line) in cube_text.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let upper = line.to_ascii_uppercase();
            if upper.starts_with("TITLE") {
                let rest = line[5..].trim().trim_matches('"').to_string();
                title = Some(rest);
                continue;
            }
            if upper.starts_with("LUT_1D_SIZE") {
                return Err("1D .cube LUTs are not supported; expected LUT_3D_SIZE".into());
            }
            if upper.starts_with("LUT_3D_SIZE") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() < 2 {
                    return Err(format!("line {}: malformed LUT_3D_SIZE", line_no + 1));
                }
                let n: usize = parts[1]
                    .parse()
                    .map_err(|_| format!("line {}: invalid LUT_3D_SIZE", line_no + 1))?;
                if !(2..=256).contains(&n) {
                    return Err(format!("line {}: LUT_3D_SIZE {n} out of range", line_no + 1));
                }
                dimension = Some(n);
                table.reserve(n * n * n);
                continue;
            }
            if upper.starts_with("DOMAIN_MIN") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let (Ok(r), Ok(g), Ok(b)) = (
                        parts[1].parse::<f64>(),
                        parts[2].parse::<f64>(),
                        parts[3].parse::<f64>(),
                    ) {
                        domain_min = [r, g, b];
                    }
                }
                continue;
            }
            if upper.starts_with("DOMAIN_MAX") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let (Ok(r), Ok(g), Ok(b)) = (
                        parts[1].parse::<f64>(),
                        parts[2].parse::<f64>(),
                        parts[3].parse::<f64>(),
                    ) {
                        domain_max = [r, g, b];
                    }
                }
                continue;
            }
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                if let (Ok(r), Ok(g), Ok(b)) = (
                    parts[0].parse::<f64>(),
                    parts[1].parse::<f64>(),
                    parts[2].parse::<f64>(),
                ) {
                    table.push([r, g, b]);
                }
            }
        }

        let n = dimension.ok_or_else(|| "missing LUT_3D_SIZE in .cube file".to_string())?;
        let expected = n * n * n;
        if table.len() != expected {
            return Err(format!(
                ".cube LUT expected {expected} lattice rows for N={n}, got {}",
                table.len()
            ));
        }

        Ok(Self {
            title,
            dimension: n,
            domain_min,
            domain_max,
            table,
        })
    }

    /// Trilinearly interpolates the `.cube` LUT at `(r, g, b)`.
    pub fn sample(&self, r: f64, g: f64, b: f64) -> [f64; 3] {
        let n = self.dimension;
        let norm = |v: f64, c: usize| -> f64 {
            let span = self.domain_max[c] - self.domain_min[c];
            if span.abs() > 1e-12 {
                ((v - self.domain_min[c]) / span).clamp(0.0, 1.0)
            } else {
                v.clamp(0.0, 1.0)
            }
        };
        let scale = (n - 1) as f64;
        let pr = norm(r, 0) * scale;
        let pg = norm(g, 1) * scale;
        let pb = norm(b, 2) * scale;

        let r0 = (pr.floor() as usize).min(n - 2);
        let g0 = (pg.floor() as usize).min(n - 2);
        let b0 = (pb.floor() as usize).min(n - 2);

        let fr = pr - r0 as f64;
        let fg = pg - g0 as f64;
        let fb = pb - b0 as f64;

        let idx = |ir: usize, ig: usize, ib: usize| -> usize { (ib * n + ig) * n + ir };

        let c000 = self.table[idx(r0, g0, b0)];
        let c100 = self.table[idx(r0 + 1, g0, b0)];
        let c010 = self.table[idx(r0, g0 + 1, b0)];
        let c110 = self.table[idx(r0 + 1, g0 + 1, b0)];
        let c001 = self.table[idx(r0, g0, b0 + 1)];
        let c101 = self.table[idx(r0 + 1, g0, b0 + 1)];
        let c011 = self.table[idx(r0, g0 + 1, b0 + 1)];
        let c111 = self.table[idx(r0 + 1, g0 + 1, b0 + 1)];

        let mut out = [0.0f64; 3];
        for c in 0..3 {
            let c00 = c000[c] * (1.0 - fr) + c100[c] * fr;
            let c10 = c010[c] * (1.0 - fr) + c110[c] * fr;
            let c01 = c001[c] * (1.0 - fr) + c101[c] * fr;
            let c11 = c011[c] * (1.0 - fr) + c111[c] * fr;
            let c0 = c00 * (1.0 - fg) + c10 * fg;
            let c1 = c01 * (1.0 - fg) + c11 * fg;
            out[c] = (c0 * (1.0 - fb) + c1 * fb).clamp(0.0, 1.0);
        }
        out
    }

    /// Bakes this `.cube` 3D LUT into a Meishe `.MS-LUT` of dimension `target_dim` (e.g. 32 or 17).
    pub fn bake_to_mslut(&self, target_dim: u32, transform: LutColorTransform) -> Result<MsLut, String> {
        if !(2..=128).contains(&target_dim) {
            return Err(format!("invalid target MS-LUT dimension {target_dim}"));
        }
        let n = target_dim as usize;
        let coords: Vec<f32> = (0..n).map(|i| i as f32 / (n - 1) as f32).collect();
        let mut rgb = Vec::with_capacity(n * n * n);

        for ib in 0..n {
            let b_in = ib as f64 / (n - 1) as f64;
            for ig in 0..n {
                let g_in = ig as f64 / (n - 1) as f64;
                for ir in 0..n {
                    let r_in = ir as f64 / (n - 1) as f64;
                    let [ro, go, bo] = match transform {
                        LutColorTransform::DirectSrgb => self.sample(r_in, g_in, b_in),
                        LutColorTransform::OppoDisplayP3Rec709Oklch => {
                            // 1. Display P3 code (sRGB EOTF) -> linear Display P3
                            let p3_lin = [
                                srgb_eotf(r_in),
                                srgb_eotf(g_in),
                                srgb_eotf(b_in),
                            ];
                            // 2. Linear Display P3 -> Linear Rec.709 (may be out of [0,1] gamut)
                            let rec709_lin = mat3_mul(&M_P3_TO_709, p3_lin);
                            // 3. CSS Color 4 OkLCh gamut mapping into Rec.709 [0,1]
                            let rec709_mapped = gamut_map_oklch_rec709(rec709_lin);
                            // 4. Linear Rec.709 -> sRGB OETF -> sample Rec.709 .cube LUT
                            let srgb_in = [
                                srgb_oetf(rec709_mapped[0]),
                                srgb_oetf(rec709_mapped[1]),
                                srgb_oetf(rec709_mapped[2]),
                            ];
                            let srgb_out = self.sample(srgb_in[0], srgb_in[1], srgb_in[2]);
                            // 5. LUT output (sRGB) -> Linear Rec.709 -> Linear Display P3 -> Display P3 code
                            let rec709_out_lin = [
                                srgb_eotf(srgb_out[0]),
                                srgb_eotf(srgb_out[1]),
                                srgb_eotf(srgb_out[2]),
                            ];
                            let p3_out_lin = mat3_mul(&M_709_TO_P3, rec709_out_lin);
                            [
                                srgb_oetf(p3_out_lin[0].clamp(0.0, 1.0)),
                                srgb_oetf(p3_out_lin[1].clamp(0.0, 1.0)),
                                srgb_oetf(p3_out_lin[2].clamp(0.0, 1.0)),
                            ]
                        }
                    };
                    rgb.push([
                        (ro.clamp(0.0, 1.0) * 255.0).round() as u8,
                        (go.clamp(0.0, 1.0) * 255.0).round() as u8,
                        (bo.clamp(0.0, 1.0) * 255.0).round() as u8,
                    ]);
                }
            }
        }

        Ok(MsLut {
            version: 1,
            dimension: target_dim,
            reserved_10: 0,
            flag: if target_dim == 32 { 1 } else { 0 },
            reserved_1c: 0,
            coords,
            rgb,
        })
    }
}

// --- Colour math for OPPO Display P3 <-> Rec.709 CSS Color 4 OkLCh gamut mapping ---

const M_P3_TO_709: [[f64; 3]; 3] = [
    [1.22494018, -0.22494018, 0.0],
    [-0.04205695, 1.04205695, 0.0],
    [-0.01963755, -0.07863605, 1.09827360],
];

const M_709_TO_P3: [[f64; 3]; 3] = [
    [0.82246197, 0.17753803, 0.0],
    [0.03319420, 0.96680580, 0.0],
    [0.01708263, 0.07239744, 0.91051993],
];

#[inline]
fn srgb_eotf(v: f64) -> f64 {
    let x = v.clamp(0.0, 1.0);
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
fn srgb_oetf(l: f64) -> f64 {
    let x = l.clamp(0.0, 1.0);
    if x <= 0.0031308 {
        x * 12.92
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

#[inline]
fn mat3_mul(m: &[[f64; 3]; 3], v: [f64; 3]) -> [f64; 3] {
    [
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ]
}

#[inline]
fn linear_srgb_to_oklab(rgb: [f64; 3]) -> [f64; 3] {
    let [r, g, b] = rgb;
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ]
}

#[inline]
fn oklab_to_linear_srgb(lab: [f64; 3]) -> [f64; 3] {
    let [l_val, a, b] = lab;
    let l_ = l_val + 0.3963377774 * a + 0.2158037573 * b;
    let m_ = l_val - 0.1055613458 * a - 0.0638541728 * b;
    let s_ = l_val - 0.0894841775 * a - 1.2914855480 * b;
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;
    [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]
}

#[inline]
fn in_unit_gamut(rgb: [f64; 3], eps: f64) -> bool {
    rgb[0] >= -eps
        && rgb[0] <= 1.0 + eps
        && rgb[1] >= -eps
        && rgb[1] <= 1.0 + eps
        && rgb[2] >= -eps
        && rgb[2] <= 1.0 + eps
}

#[inline]
fn delta_e_ok(lab1: [f64; 3], lab2: [f64; 3]) -> f64 {
    let dl = lab1[0] - lab2[0];
    let da = lab1[1] - lab2[1];
    let db = lab1[2] - lab2[2];
    (dl * dl + da * da + db * db).sqrt()
}

/// CSS Color 4 OkLCh gamut mapping (`JND = 0.02`) into linear Rec.709 `[0, 1]`.
pub fn gamut_map_oklch_rec709(rgb_lin: [f64; 3]) -> [f64; 3] {
    if in_unit_gamut(rgb_lin, 1e-6) {
        return [
            rgb_lin[0].clamp(0.0, 1.0),
            rgb_lin[1].clamp(0.0, 1.0),
            rgb_lin[2].clamp(0.0, 1.0),
        ];
    }
    let orig_lab = linear_srgb_to_oklab(rgb_lin);
    let l = orig_lab[0];
    if l <= 0.0 {
        return [0.0, 0.0, 0.0];
    }
    if l >= 1.0 {
        return [1.0, 1.0, 1.0];
    }
    let c = (orig_lab[1] * orig_lab[1] + orig_lab[2] * orig_lab[2]).sqrt();
    if c < 1e-9 {
        let v = oklab_to_linear_srgb([l, 0.0, 0.0]);
        return [v[0].clamp(0.0, 1.0), v[1].clamp(0.0, 1.0), v[2].clamp(0.0, 1.0)];
    }
    let ha = orig_lab[1] / c;
    let hb = orig_lab[2] / c;

    const JND: f64 = 0.02;
    const EPS: f64 = 0.0001;
    let mut lo = 0.0;
    let mut hi = c;
    let mut best_rgb = [
        rgb_lin[0].clamp(0.0, 1.0),
        rgb_lin[1].clamp(0.0, 1.0),
        rgb_lin[2].clamp(0.0, 1.0),
    ];

    while hi - lo > EPS {
        let mid = 0.5 * (lo + hi);
        let cur_lab = [l, mid * ha, mid * hb];
        let cur_rgb = oklab_to_linear_srgb(cur_lab);
        if in_unit_gamut(cur_rgb, 0.0) {
            best_rgb = [
                cur_rgb[0].clamp(0.0, 1.0),
                cur_rgb[1].clamp(0.0, 1.0),
                cur_rgb[2].clamp(0.0, 1.0),
            ];
            lo = mid;
        } else {
            let clipped = [
                cur_rgb[0].clamp(0.0, 1.0),
                cur_rgb[1].clamp(0.0, 1.0),
                cur_rgb[2].clamp(0.0, 1.0),
            ];
            let clipped_lab = linear_srgb_to_oklab(clipped);
            let de = delta_e_ok(cur_lab, clipped_lab);
            if de < JND {
                best_rgb = clipped;
                if JND - de < EPS {
                    break;
                }
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }
    best_rgb
}

// ---------------------------------------------------------------------------
// 3. ColorOS Gallery `filter.info` (v4.0 140B & v5.0/v5.1 228B) Codec
// ---------------------------------------------------------------------------

/// Decoded ColorOS Gallery `filter.info` payload (`140` bytes in v4.0, `228` bytes in v5.0/v5.1).
///
/// Verified against AArch64 `libAlgoInterface.so` (`OCamFilterMeisheV2.cpp`:
/// `seedPaletteFilterInfoSkeleton`, `fillFilterInfoBySceneV2`,
/// `updatePaletteBasicToneFilterInfoFlags`) and 29 real OPPO Find X10 captures.
#[derive(Debug, Clone, PartialEq)]
pub struct OppoFilterInfo {
    /// `+0x00`: `4.0` (`0x40800000`) for classic/master filter, `5.0` (`0x40a00000`) or `5.1` (`0x40a33333`) for Palette.
    pub version: f32,
    /// `+0x04`: Filter strength / intensity (`0..=100`, default `100`).
    pub filter_strength: i32,
    /// `+0x08`: Source capture orientation in degrees (`0`, `90`, `180`, `270`).
    pub orientation: i32,
    /// `+0x0C`: Soft light type (`0` = 朦胧 / 1/4 Black Mist or off, `1` = 柔美 / Ricoh HDF, `2` = 梦幻 / White Mist).
    pub soft_light_type: i32,
    /// `+0x10`: Whether soft light is enabled (`0` or `1`).
    pub is_soft_light: i32,
    /// `+0x14`: Reserved flag (usually `0`).
    pub reserved_14: i32,
    /// `+0x18`: Whether the filter/palette effect is enabled (`1` when active).
    pub is_filter_enable: i32,
    /// `+0x1C..+0x80` (`28..128`, 100 bytes UTF-8 NUL-padded): Filter identifier string
    /// (e.g. `"default"`, `"qing_tou.bin"`, `"hu_po.bin"`, `"portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin"`).
    pub filter_type: String,
    /// `+0x80` (`128`): Correlated Color Temperature in Kelvin (e.g. `5757.0`).
    pub color_temperature: f32,
    /// `+0x84` (`132`): Scene Lux Index (e.g. `172.734`).
    pub lux_index: f32,
    /// `+0x88` (`136`): Filter gain / HDR ratio / lux weight (e.g. `1.830`, `1.000`).
    pub filter_gain: f32,

    // --- Version 5.0 / 5.1 Palette & Scene Extension (`140..228`, 88 bytes) ---
    /// Whether this struct carries the 88-byte v5 Palette extension (`228` bytes total).
    pub has_v5_extension: bool,
    /// `+0x8C` (`140`): `1` when ColorOS AI Palette (大师调色盘 / 影调) mode is active, `0` for Master/classic filter.
    pub is_palette: i32,
    /// `+0x90` (`144`): `1` when Palette algorithm was applied at capture time, `0` otherwise.
    pub palette_algo_used: i32,
    /// `+0x94` (`148`): Palette saturation offset (`-100..=100`, default `0`).
    pub palette_saturation: i32,
    /// `+0x98` (`152`): Palette tone / contrast parameter (e.g. `89`, `38`, `0`).
    pub palette_tone: i32,
    /// `+0x9C..+0xD8` (`156..216`, 60 bytes UTF-8 NUL-padded): Capture mode string (e.g. `"common"`, `"portrait"`).
    pub capture_mode: String,
    /// `+0xD8` (`216`): Scene average luminance (e.g. `50.785`).
    pub scene_avg_luma: f32,
    /// `+0xDC` (`220`): Scene bright luminance (e.g. `234.638`).
    pub scene_bright_luma: f32,
    /// `+0xE0` (`224`): Scene dark luminance (e.g. `11.036`).
    pub scene_dark_luma: f32,
}

impl OppoFilterInfo {
    /// Creates a new 228-byte ColorOS 16/17 Master/Classic filter `OppoFilterInfo`.
    pub fn new_master_filter(
        filter_type: &str,
        strength: i32,
        orientation: i32,
        soft_light_type: i32,
        is_soft_light: bool,
    ) -> Self {
        Self {
            version: 4.0,
            filter_strength: strength.clamp(0, 100),
            orientation,
            soft_light_type,
            is_soft_light: i32::from(is_soft_light),
            reserved_14: 0,
            is_filter_enable: 1,
            filter_type: filter_type.to_string(),
            color_temperature: 5500.0,
            lux_index: 180.0,
            filter_gain: 1.0,
            has_v5_extension: true,
            is_palette: 0,
            palette_algo_used: 0,
            palette_saturation: 0,
            palette_tone: 0,
            capture_mode: "common".to_string(),
            scene_avg_luma: 60.0,
            scene_bright_luma: 280.0,
            scene_dark_luma: 10.0,
        }
    }

    /// Creates a new 228-byte ColorOS 16/17 AI Color Palette (`is_palette = 1`, `version = 5.1`) `OppoFilterInfo`.
    pub fn new_palette(
        filter_type: &str,
        strength: i32,
        orientation: i32,
        palette_saturation: i32,
        palette_tone: i32,
    ) -> Self {
        Self {
            version: 5.1,
            filter_strength: strength.clamp(0, 100),
            orientation,
            soft_light_type: 0,
            is_soft_light: 0,
            reserved_14: 0,
            is_filter_enable: 1,
            filter_type: filter_type.to_string(),
            color_temperature: 5500.0,
            lux_index: 180.0,
            filter_gain: 1.0,
            has_v5_extension: true,
            is_palette: 1,
            palette_algo_used: 1,
            palette_saturation,
            palette_tone,
            capture_mode: "common".to_string(),
            scene_avg_luma: 60.0,
            scene_bright_luma: 280.0,
            scene_dark_luma: 10.0,
        }
    }

    /// Parses a `filter.info` binary blob (supports both 140-byte v4 and 228-byte v5/v5.1 layouts).
    pub fn from_bytes(data: &[u8]) -> Result<Self, String> {
        if data.len() < OPPO_FILTER_INFO_V4_LEN {
            return Err(format!(
                "filter.info too short ({} bytes, need at least {})",
                data.len(),
                OPPO_FILTER_INFO_V4_LEN
            ));
        }
        let read_i32 = |off: usize| -> i32 {
            i32::from_le_bytes(data[off..off + 4].try_into().unwrap())
        };
        let read_f32 = |off: usize| -> f32 {
            f32::from_le_bytes(data[off..off + 4].try_into().unwrap())
        };

        let version = read_f32(0x00);
        let filter_strength = read_i32(0x04);
        let orientation = read_i32(0x08);
        let soft_light_type = read_i32(0x0C);
        let is_soft_light = read_i32(0x10);
        let reserved_14 = read_i32(0x14);
        let is_filter_enable = read_i32(0x18);
        let filter_type = read_fixed_cstr(&data[0x1C..0x80]);
        let color_temperature = read_f32(0x80);
        let lux_index = read_f32(0x84);
        let filter_gain = read_f32(0x88);

        if data.len() >= OPPO_FILTER_INFO_V5_LEN {
            let is_palette = read_i32(0x8C);
            let palette_algo_used = read_i32(0x90);
            let palette_saturation = read_i32(0x94);
            let palette_tone = read_i32(0x98);
            let capture_mode = read_fixed_cstr(&data[0x9C..0xD8]);
            let scene_avg_luma = read_f32(0xD8);
            let scene_bright_luma = read_f32(0xDC);
            let scene_dark_luma = read_f32(0xE0);
            Ok(Self {
                version,
                filter_strength,
                orientation,
                soft_light_type,
                is_soft_light,
                reserved_14,
                is_filter_enable,
                filter_type,
                color_temperature,
                lux_index,
                filter_gain,
                has_v5_extension: true,
                is_palette,
                palette_algo_used,
                palette_saturation,
                palette_tone,
                capture_mode,
                scene_avg_luma,
                scene_bright_luma,
                scene_dark_luma,
            })
        } else {
            Ok(Self {
                version,
                filter_strength,
                orientation,
                soft_light_type,
                is_soft_light,
                reserved_14,
                is_filter_enable,
                filter_type,
                color_temperature,
                lux_index,
                filter_gain,
                has_v5_extension: false,
                is_palette: 0,
                palette_algo_used: 0,
                palette_saturation: 0,
                palette_tone: 0,
                capture_mode: String::new(),
                scene_avg_luma: 0.0,
                scene_bright_luma: 0.0,
                scene_dark_luma: 0.0,
            })
        }
    }

    /// Serializes into a 140-byte v4 `filter.info` payload.
    pub fn to_bytes_v4(&self) -> Vec<u8> {
        let mut out = vec![0u8; OPPO_FILTER_INFO_V4_LEN];
        out[0x00..0x04].copy_from_slice(&self.version.to_le_bytes());
        out[0x04..0x08].copy_from_slice(&self.filter_strength.to_le_bytes());
        out[0x08..0x0C].copy_from_slice(&self.orientation.to_le_bytes());
        out[0x0C..0x10].copy_from_slice(&self.soft_light_type.to_le_bytes());
        out[0x10..0x14].copy_from_slice(&self.is_soft_light.to_le_bytes());
        out[0x14..0x18].copy_from_slice(&self.reserved_14.to_le_bytes());
        out[0x18..0x1C].copy_from_slice(&self.is_filter_enable.to_le_bytes());
        write_fixed_cstr(&mut out[0x1C..0x80], &self.filter_type);
        out[0x80..0x84].copy_from_slice(&self.color_temperature.to_le_bytes());
        out[0x84..0x88].copy_from_slice(&self.lux_index.to_le_bytes());
        out[0x88..0x8C].copy_from_slice(&self.filter_gain.to_le_bytes());
        out
    }

    /// Serializes into a 228-byte v5/v5.1 `filter.info` payload.
    pub fn to_bytes_v5(&self) -> Vec<u8> {
        let mut out = self.to_bytes_v4();
        out.resize(OPPO_FILTER_INFO_V5_LEN, 0);
        out[0x8C..0x90].copy_from_slice(&self.is_palette.to_le_bytes());
        out[0x90..0x94].copy_from_slice(&self.palette_algo_used.to_le_bytes());
        out[0x94..0x98].copy_from_slice(&self.palette_saturation.to_le_bytes());
        out[0x98..0x9C].copy_from_slice(&self.palette_tone.to_le_bytes());
        write_fixed_cstr(&mut out[0x9C..0xD8], &self.capture_mode);
        out[0xD8..0xDC].copy_from_slice(&self.scene_avg_luma.to_le_bytes());
        out[0xDC..0xE0].copy_from_slice(&self.scene_bright_luma.to_le_bytes());
        out[0xE0..0xE4].copy_from_slice(&self.scene_dark_luma.to_le_bytes());
        out
    }

    /// Serializes to 228 bytes if `has_v5_extension` is true, otherwise 140 bytes.
    pub fn to_bytes(&self) -> Vec<u8> {
        if self.has_v5_extension {
            self.to_bytes_v5()
        } else {
            self.to_bytes_v4()
        }
    }

    /// Converts this `OppoFilterInfo` to a structured JSON object, enriched with catalog names.
    pub fn to_json(&self) -> serde_json::Value {
        let catalog = lookup_oppo_filter(&self.filter_type);
        let soft_light_label = match (self.is_soft_light != 0, self.soft_light_type) {
            (false, _) => "off",
            (true, 0) => "mist_medium_blackmist",
            (true, 1) => "soft_weak_hdf",
            (true, 2) => "dreamy_strong_whitemist",
            (true, _) => "custom",
        };
        serde_json::json!({
            "version": (self.version as f64 * 100.0).round() / 100.0,
            "byteLength": if self.has_v5_extension { OPPO_FILTER_INFO_V5_LEN } else { OPPO_FILTER_INFO_V4_LEN },
            "filterType": self.filter_type,
            "filterNameZh": catalog.map(|c| c.name_zh),
            "filterNameEn": catalog.map(|c| c.name_en),
            "filterCategory": catalog.map(|c| c.category),
            "filterStrength": self.filter_strength,
            "isFilterEnable": self.is_filter_enable != 0,
            "orientation": self.orientation,
            "isSoftLight": self.is_soft_light != 0,
            "softLightType": self.soft_light_type,
            "softLightLabel": soft_light_label,
            "colorTemperature": (self.color_temperature as f64 * 10.0).round() / 10.0,
            "luxIndex": (self.lux_index as f64 * 1000.0).round() / 1000.0,
            "filterGain": (self.filter_gain as f64 * 1000.0).round() / 1000.0,
            "isPalette": self.is_palette != 0,
            "paletteAlgoUsed": self.palette_algo_used != 0,
            "paletteSaturation": self.palette_saturation,
            "paletteTone": self.palette_tone,
            "captureMode": self.capture_mode,
            "sceneAvgLuma": (self.scene_avg_luma as f64 * 1000.0).round() / 1000.0,
            "sceneBrightLuma": (self.scene_bright_luma as f64 * 1000.0).round() / 1000.0,
            "sceneDarkLuma": (self.scene_dark_luma as f64 * 1000.0).round() / 1000.0,
        })
    }
}

// ---------------------------------------------------------------------------
// 4. ColorOS Gallery `master.mode.preset.info` (496B) Codec
// ---------------------------------------------------------------------------

/// Decoded ColorOS Gallery `master.mode.preset.info` (496-byte Hasselblad Master Mode preset).
#[derive(Debug, Clone, PartialEq)]
pub struct OppoMasterPresetInfo {
    /// `+0x00` (`0`): Version (`1.0` = `0x3f800000`).
    pub version: f32,
    /// `+0x04` (`4`): Master preset intensity (`0..=100`, default `100`).
    pub intensity: i32,
    /// `+0x08` (`8`): Reserved (`0`).
    pub reserved_08: i32,
    /// `+0x0C..+0x84` (`12..132`, 120 bytes UTF-8 NUL-padded): Preset title (e.g. `"无"`).
    pub preset_title: String,
    /// `+0x84` (`132`): Preset ID (e.g. `101`).
    pub preset_id: i32,
    /// `+0x88..+0xEC` (`136..236`, 100 bytes UTF-8 NUL-padded): Filter index string (e.g. `"0"`, `"1"`).
    pub filter_index_str: String,
    /// `+0xEC..+0x150` (`236..336`, 100 bytes UTF-8 NUL-padded): Localized filter name (e.g. `"标准"`, `"清透"`, `"童话"`).
    pub filter_name: String,
    /// `+0x150..+0x1F0` (`336..496`, 160 bytes): Remaining master tuning parameters (contrast, saturation, tone, vignette, etc.).
    pub tail_params: Vec<u8>,
}

impl OppoMasterPresetInfo {
    /// Creates a standard 496-byte `master.mode.preset.info` for a Master filter.
    pub fn new(filter_index: u32, filter_name: &str, intensity: i32) -> Self {
        Self {
            version: 1.0,
            intensity: intensity.clamp(0, 100),
            reserved_08: 0,
            preset_title: "无".to_string(),
            preset_id: 101,
            filter_index_str: filter_index.to_string(),
            filter_name: filter_name.to_string(),
            tail_params: vec![0u8; 160],
        }
    }

    /// Parses a 496-byte `master.mode.preset.info` binary blob.
    pub fn from_bytes(data: &[u8]) -> Result<Self, String> {
        if data.len() < OPPO_MASTER_PRESET_INFO_LEN {
            return Err(format!(
                "master.mode.preset.info too short ({} bytes, expected {})",
                data.len(),
                OPPO_MASTER_PRESET_INFO_LEN
            ));
        }
        let version = f32::from_le_bytes(data[0x00..0x04].try_into().unwrap());
        let intensity = i32::from_le_bytes(data[0x04..0x08].try_into().unwrap());
        let reserved_08 = i32::from_le_bytes(data[0x08..0x0C].try_into().unwrap());
        let preset_title = read_fixed_cstr(&data[0x0C..0x84]);
        let preset_id = i32::from_le_bytes(data[0x84..0x88].try_into().unwrap());
        let filter_index_str = read_fixed_cstr(&data[0x88..0xEC]);
        let filter_name = read_fixed_cstr(&data[0xEC..0x150]);
        let tail_params = data[0x150..OPPO_MASTER_PRESET_INFO_LEN].to_vec();

        Ok(Self {
            version,
            intensity,
            reserved_08,
            preset_title,
            preset_id,
            filter_index_str,
            filter_name,
            tail_params,
        })
    }

    /// Serializes into a 496-byte `master.mode.preset.info` binary payload.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = vec![0u8; OPPO_MASTER_PRESET_INFO_LEN];
        out[0x00..0x04].copy_from_slice(&self.version.to_le_bytes());
        out[0x04..0x08].copy_from_slice(&self.intensity.to_le_bytes());
        out[0x08..0x0C].copy_from_slice(&self.reserved_08.to_le_bytes());
        write_fixed_cstr(&mut out[0x0C..0x84], &self.preset_title);
        out[0x84..0x88].copy_from_slice(&self.preset_id.to_le_bytes());
        write_fixed_cstr(&mut out[0x88..0xEC], &self.filter_index_str);
        write_fixed_cstr(&mut out[0xEC..0x150], &self.filter_name);
        let copy_len = self.tail_params.len().min(160);
        out[0x150..0x150 + copy_len].copy_from_slice(&self.tail_params[..copy_len]);
        out
    }

    /// Converts to a JSON summary.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "version": (self.version as f64 * 100.0).round() / 100.0,
            "intensity": self.intensity,
            "presetTitle": self.preset_title,
            "presetId": self.preset_id,
            "filterIndex": self.filter_index_str,
            "filterName": self.filter_name,
            "byteLength": OPPO_MASTER_PRESET_INFO_LEN,
        })
    }
}

// ---------------------------------------------------------------------------
// 5. OPPO BasicTone `basictone.info` (8216B) & `basictone.vig.table` (884B)
// ---------------------------------------------------------------------------

/// Decoded `basictone.vig.table` (`884` bytes = `13 × 17` IEEE-754 `f32` radial vignette gain mesh).
#[derive(Debug, Clone, PartialEq)]
pub struct OppoBasicToneVigTable {
    pub rows: usize,
    pub cols: usize,
    pub grid: Vec<f32>,
}

impl OppoBasicToneVigTable {
    pub fn from_bytes(data: &[u8]) -> Result<Self, String> {
        if data.len() != OPPO_BASICTONE_VIG_TABLE_LEN {
            return Err(format!(
                "basictone.vig.table expected {} bytes (13x17 floats), got {}",
                OPPO_BASICTONE_VIG_TABLE_LEN,
                data.len()
            ));
        }
        let mut grid = Vec::with_capacity(221);
        for chunk in data.chunks_exact(4) {
            grid.push(f32::from_le_bytes(chunk.try_into().unwrap()));
        }
        Ok(Self {
            rows: 13,
            cols: 17,
            grid,
        })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.grid.len() * 4);
        for &v in &self.grid {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    pub fn to_json(&self) -> serde_json::Value {
        let min_gain = self.grid.iter().copied().fold(f32::INFINITY, f32::min);
        let max_gain = self.grid.iter().copied().fold(f32::NEG_INFINITY, f32::max);
        let center_gain = self.grid.get(6 * 17 + 8).copied().unwrap_or(1.0);
        serde_json::json!({
            "rows": self.rows,
            "cols": self.cols,
            "minGain": (min_gain as f64 * 10000.0).round() / 10000.0,
            "maxGain": (max_gain as f64 * 10000.0).round() / 10000.0,
            "centerGain": (center_gain as f64 * 10000.0).round() / 10000.0,
            "byteLength": self.grid.len() * 4,
        })
    }
}

/// Summary inspector for `basictone.info` (`8216` bytes: `16³` FP16 tone table + 24B parameters).
#[derive(Debug, Clone, PartialEq)]
pub struct OppoBasicToneInfo {
    pub version: f32,
    pub flag_04: i32,
    pub dither_strength_10bit: f32,
    pub raw_len: usize,
}

impl OppoBasicToneInfo {
    pub fn from_bytes(data: &[u8]) -> Result<Self, String> {
        if data.len() < 24 {
            return Err(format!("basictone.info too short ({} bytes)", data.len()));
        }
        let version = f32::from_le_bytes(data[0..4].try_into().unwrap());
        let flag_04 = i32::from_le_bytes(data[4..8].try_into().unwrap());
        let dither_strength_10bit = if data.len() == OPPO_BASICTONE_INFO_LEN {
            f32::from_le_bytes(data[data.len() - 4..].try_into().unwrap())
        } else {
            0.0
        };
        Ok(Self {
            version,
            flag_04,
            dither_strength_10bit,
            raw_len: data.len(),
        })
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "version": (self.version as f64 * 100.0).round() / 100.0,
            "flag04": self.flag_04,
            "ditherStrength10bit": (self.dither_strength_10bit as f64 * 100.0).round() / 100.0,
            "byteLength": self.raw_len,
        })
    }
}

// ---------------------------------------------------------------------------
// 6. OPPO `FileExtendedContainer` (`\0jxrs`) Tail Inspector & Modifier
// ---------------------------------------------------------------------------

/// Comprehensive inspection report of an OPPO JPEG/HEIC `FileExtendedContainer` tail.
#[derive(Debug, Clone, Default)]
pub struct OppoTailReport {
    pub has_oppo_tail: bool,
    pub base_media_end: usize,
    pub entry_names: Vec<String>,
    pub entries_json: Vec<serde_json::Value>,
    pub filter_info: Option<OppoFilterInfo>,
    pub master_preset: Option<OppoMasterPresetInfo>,
    pub basictone_info: Option<OppoBasicToneInfo>,
    pub basictone_vig_table: Option<OppoBasicToneVigTable>,
    pub has_src_image: bool,
    pub src_image_len: Option<usize>,
}

impl OppoTailReport {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "hasOppoTail": self.has_oppo_tail,
            "baseMediaEnd": self.base_media_end,
            "entryNames": self.entry_names,
            "entries": self.entries_json,
            "filterInfo": self.filter_info.as_ref().map(OppoFilterInfo::to_json),
            "masterPreset": self.master_preset.as_ref().map(OppoMasterPresetInfo::to_json),
            "basictoneInfo": self.basictone_info.as_ref().map(OppoBasicToneInfo::to_json),
            "basictoneVigTable": self.basictone_vig_table.as_ref().map(OppoBasicToneVigTable::to_json),
            "hasSrcImage": self.has_src_image,
            "srcImageLen": self.src_image_len,
        })
    }
}

/// Parsed entry in an OPPO `FileExtendedContainer` (`\0jxrs`) tail.
#[derive(Debug, Clone)]
struct ParsedOppoTailEntry {
    name: String,
    offset: usize,
    length: usize,
    version: i64,
    abs_start: usize,
}

struct ParsedOppoTail {
    base_end: usize,
    entries: Vec<ParsedOppoTailEntry>,
}

/// Parses the OPPO `FileExtendedContainer` (`\0jxrs` / `\0jxrsq`) manifest at the end of `data`.
///
/// In OPPO's `FileExtendedContainer` format, each entry's `offset` is measured
/// **backwards** from `json_start` (`abs_start = json_start - entry.offset`).
fn parse_oppo_tail_entries(data: &[u8]) -> Option<ParsedOppoTail> {
    let footer_pos = data
        .windows(6)
        .rposition(|w| w == b"\x00jxrsq")
        .or_else(|| data.windows(5).rposition(|w| w == b"\x00jxrs"))?;
    let scan_start = footer_pos.saturating_sub(16384);
    let json_end = data[scan_start..footer_pos]
        .iter()
        .rposition(|&b| b == b']')
        .map(|p| scan_start + p)?;
    let json_start = data[scan_start..=json_end]
        .windows(2)
        .rposition(|w| w == b"[{")
        .map(|p| scan_start + p)?;

    let raw_entries: Vec<serde_json::Value> =
        serde_json::from_slice(&data[json_start..=json_end]).ok()?;
    if raw_entries.is_empty() {
        return None;
    }

    let mut entries = Vec::with_capacity(raw_entries.len());
    let mut min_start = json_start;
    for item in raw_entries {
        let name = item.get("name")?.as_str()?.to_string();
        let offset = item.get("offset")?.as_u64()? as usize;
        let length = item.get("length")?.as_u64()? as usize;
        let version = item.get("version").and_then(|v| v.as_i64()).unwrap_or(1);
        let abs_start = json_start.checked_sub(offset)?;
        if abs_start.checked_add(length)? > json_start {
            return None;
        }
        if abs_start < min_start {
            min_start = abs_start;
        }
        entries.push(ParsedOppoTailEntry {
            name,
            offset,
            length,
            version,
            abs_start,
        });
    }
    // Sort in physical file order (earliest abs_start first)
    entries.sort_by_key(|e| e.abs_start);
    Some(ParsedOppoTail {
        base_end: min_start,
        entries,
    })
}

/// Inspects an in-memory JPEG or HEIC buffer for OPPO `FileExtendedContainer` (`\0jxrs`) tail metadata.
pub fn inspect_oppo_tail(data: &[u8]) -> OppoTailReport {
    let parsed = match parse_oppo_tail_entries(data) {
        Some(p) => p,
        None => {
            return OppoTailReport {
                has_oppo_tail: false,
                base_media_end: data.len(),
                ..Default::default()
            }
        }
    };

    let mut report = OppoTailReport {
        has_oppo_tail: true,
        base_media_end: parsed.base_end,
        ..Default::default()
    };

    for entry in &parsed.entries {
        report.entry_names.push(entry.name.clone());
        report.entries_json.push(serde_json::json!({
            "name": entry.name,
            "offset": entry.offset,
            "length": entry.length,
            "version": entry.version,
        }));
        let start = entry.abs_start;
        let end = start.saturating_add(entry.length);
        if end > data.len() {
            continue;
        }
        let slice = &data[start..end];
        match entry.name.as_str() {
            "filter.info" => {
                if let Ok(fi) = OppoFilterInfo::from_bytes(slice) {
                    report.filter_info = Some(fi);
                }
            }
            "master.mode.preset.info" => {
                if let Ok(mp) = OppoMasterPresetInfo::from_bytes(slice) {
                    report.master_preset = Some(mp);
                }
            }
            "basictone.info" => {
                if let Ok(bt) = OppoBasicToneInfo::from_bytes(slice) {
                    report.basictone_info = Some(bt);
                }
            }
            "basictone.vig.table" => {
                if let Ok(vt) = OppoBasicToneVigTable::from_bytes(slice) {
                    report.basictone_vig_table = Some(vt);
                }
            }
            "src.image" => {
                report.has_src_image = true;
                report.src_image_len = Some(slice.len());
            }
            _ => {}
        }
    }

    report
}

/// Non-destructively inserts, updates, or removes entries in an OPPO JPEG or HEIC
/// `FileExtendedContainer` (`\0jxrs`) tail.
///
/// - Each element in `updates` is `(entry_name, Some(payload_bytes))` to insert/replace,
///   or `(entry_name, None)` to remove that entry.
/// - If the file already has an OPPO tail, existing entries not mentioned in `updates`
///   are preserved in their original order.
/// - If the file does not yet have an OPPO tail, a new valid `\0jxrs` tail is appended!
pub fn upsert_oppo_tail_entries(
    data: &[u8],
    updates: &[(&str, Option<&[u8]>)],
) -> Result<Vec<u8>, String> {
    if data.len() < 16 {
        return Err("input media buffer is too short".into());
    }
    let mut ordered_entries: Vec<(String, i64, Vec<u8>)> = Vec::new();
    let base_end = if let Some(parsed) = parse_oppo_tail_entries(data) {
        for e in &parsed.entries {
            let start = e.abs_start;
            let end = start.saturating_add(e.length);
            if end <= data.len() {
                ordered_entries.push((e.name.clone(), e.version, data[start..end].to_vec()));
            }
        }
        parsed.base_end
    } else {
        data.len()
    };

    for &(name, maybe_payload) in updates {
        if let Some(pos) = ordered_entries.iter().position(|(n, _, _)| n == name) {
            match maybe_payload {
                Some(bytes) => {
                    ordered_entries[pos].2 = bytes.to_vec();
                }
                None => {
                    ordered_entries.remove(pos);
                }
            }
        } else if let Some(bytes) = maybe_payload {
            ordered_entries.push((name.to_string(), 1, bytes.to_vec()));
        }
    }

    let mut out = data[..base_end].to_vec();
    if ordered_entries.is_empty() {
        return Ok(out);
    }

    let mut starts_in_payload = Vec::with_capacity(ordered_entries.len());
    let mut payload_length = 0usize;
    for (_name, _version, payload) in &ordered_entries {
        starts_in_payload.push(payload_length);
        out.extend_from_slice(payload);
        payload_length += payload.len();
    }

    // OPPO manifest offset is measured backwards from `json_start` (`payload_length - start_in_payload`).
    let mut manifest = String::from("[");
    for (i, ((name, version, payload), start_in_payload)) in
        ordered_entries.iter().zip(&starts_in_payload).enumerate()
    {
        if i > 0 {
            manifest.push(',');
        }
        let offset = payload_length - *start_in_payload;
        let _ = write!(
            manifest,
            r#"{{"length":{},"name":"{}","offset":{},"version":{}}}"#,
            payload.len(),
            name,
            offset,
            version
        );
    }
    manifest.push(']');
    let manifest_bytes = manifest.as_bytes();
    let footer_size = (manifest_bytes.len() + 9) as u32;
    out.extend_from_slice(manifest_bytes);
    out.extend_from_slice(b"\x00jxrs");
    out.extend_from_slice(&footer_size.to_le_bytes());

    Ok(out)
}

/// High-level helper to inject or update `filter.info` (and optionally `master.mode.preset.info`
/// and `src.image`) in an OPPO JPEG or HEIC photo so ColorOS Gallery recognizes the filter/palette
/// non-destructively.
pub fn inject_oppo_filter_tail(
    data: &[u8],
    filter_info: &OppoFilterInfo,
    master_preset: Option<&OppoMasterPresetInfo>,
    embed_src_image_if_missing: bool,
) -> Result<Vec<u8>, String> {
    let existing = inspect_oppo_tail(data);
    let base_media = &data[..existing.base_media_end];
    let filter_bytes = filter_info.to_bytes();
    let preset_bytes = master_preset.map(OppoMasterPresetInfo::to_bytes);

    let mut updates: Vec<(&str, Option<&[u8]>)> = Vec::new();
    if embed_src_image_if_missing && !existing.has_src_image {
        updates.push(("src.image", Some(base_media)));
    }
    updates.push(("filter.info", Some(filter_bytes.as_slice())));
    if let Some(ref pb) = preset_bytes {
        updates.push(("master.mode.preset.info", Some(pb.as_slice())));
    }

    upsert_oppo_tail_entries(data, &updates)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn read_fixed_cstr(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).to_string()
}

fn write_fixed_cstr(dst: &mut [u8], s: &str) {
    dst.fill(0);
    let bytes = s.as_bytes();
    let max_copy = dst.len().saturating_sub(1);
    let n = bytes.len().min(max_copy);
    dst[..n].copy_from_slice(&bytes[..n]);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mslut_identity_roundtrip_and_cube_conversion() {
        let lut17 = MsLut::identity(17).unwrap();
        let bytes17 = lut17.to_mslut_bytes();
        // 48 + 17*4 + 17^3 * 3 = 116 + 14739 = 14855 bytes
        assert_eq!(bytes17.len(), 14855);
        let parsed17 = MsLut::from_mslut_bytes(&bytes17).unwrap();
        assert_eq!(parsed17, lut17);

        let cube_str = parsed17.to_cube_string(Some("Identity17"));
        let cube = Cube3dLut::from_cube_str(&cube_str).unwrap();
        assert_eq!(cube.dimension, 17);
        assert_eq!(cube.title.as_deref(), Some("Identity17"));

        // Bake to 32^3 MS-LUT via both DirectSrgb and OppoDisplayP3Rec709Oklch
        let baked_direct = cube
            .bake_to_mslut(32, LutColorTransform::DirectSrgb)
            .unwrap();
        assert_eq!(baked_direct.to_mslut_bytes().len(), 98480);

        let baked_oklch = cube
            .bake_to_mslut(17, LutColorTransform::OppoDisplayP3Rec709Oklch)
            .unwrap();
        assert_eq!(baked_oklch.to_mslut_bytes().len(), 14855);
        // Neutral axis (0, 0, 0) and (255, 255, 255) must remain exact
        assert_eq!(baked_oklch.rgb[0], [0, 0, 0]);
        assert_eq!(*baked_oklch.rgb.last().unwrap(), [255, 255, 255]);
    }

    #[test]
    fn filter_info_v4_and_v5_roundtrip() {
        let v5 = OppoFilterInfo::new_palette(
            "portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin",
            100,
            90,
            0,
            89,
        );
        let bytes = v5.to_bytes();
        assert_eq!(bytes.len(), OPPO_FILTER_INFO_V5_LEN);
        let decoded = OppoFilterInfo::from_bytes(&bytes).unwrap();
        assert_eq!(decoded, v5);

        let v4_bytes = v5.to_bytes_v4();
        assert_eq!(v4_bytes.len(), OPPO_FILTER_INFO_V4_LEN);
        let decoded_v4 = OppoFilterInfo::from_bytes(&v4_bytes).unwrap();
        assert!(!decoded_v4.has_v5_extension);
        assert_eq!(decoded_v4.filter_type, v5.filter_type);
        assert_eq!(decoded_v4.filter_strength, 100);
        assert_eq!(decoded_v4.orientation, 90);
    }

    #[test]
    fn master_preset_info_roundtrip() {
        let preset = OppoMasterPresetInfo::new(1, "清透", 100);
        let bytes = preset.to_bytes();
        assert_eq!(bytes.len(), OPPO_MASTER_PRESET_INFO_LEN);
        let decoded = OppoMasterPresetInfo::from_bytes(&bytes).unwrap();
        assert_eq!(decoded, preset);
    }

    #[test]
    fn inject_and_inspect_oppo_tail_on_synthetic_jpeg() {
        let fake_jpeg = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9";
        let fi = OppoFilterInfo::new_master_filter("qing_tou.bin", 85, 90, 1, true);
        let mp = OppoMasterPresetInfo::new(1, "清透", 85);

        let with_tail = inject_oppo_filter_tail(fake_jpeg, &fi, Some(&mp), true).unwrap();
        let report = inspect_oppo_tail(&with_tail);
        assert!(report.has_oppo_tail);
        assert_eq!(report.base_media_end, fake_jpeg.len());
        assert!(report.has_src_image);
        assert_eq!(report.src_image_len, Some(fake_jpeg.len()));
        assert_eq!(report.filter_info.as_ref(), Some(&fi));
        assert_eq!(report.master_preset.as_ref(), Some(&mp));

        // Update filter.info non-destructively while keeping src.image and master.mode.preset.info
        let fi2 = OppoFilterInfo::new_palette("hu_po.bin", 100, 90, 12, 45);
        let updated = inject_oppo_filter_tail(&with_tail, &fi2, None, false).unwrap();
        let report2 = inspect_oppo_tail(&updated);
        assert_eq!(report2.filter_info.as_ref(), Some(&fi2));
        assert_eq!(report2.master_preset.as_ref(), Some(&mp));
        assert_eq!(report2.src_image_len, Some(fake_jpeg.len()));
    }

    #[test]
    fn inspects_real_find_x10_filter_info_if_present() {
        let sample_jpg = std::path::Path::new(r"C:\Users\Beet\Desktop\Find X10\IMG20260910130102.jpg");
        if sample_jpg.exists() {
            let data = std::fs::read(sample_jpg).unwrap();
            let report = inspect_oppo_tail(&data);
            assert!(report.has_oppo_tail);
            let fi = report.filter_info.expect("expected filter.info in IMG20260910130102.jpg");
            assert!((fi.version - 5.1).abs() < 1e-4);
            assert_eq!(fi.filter_strength, 100);
            assert_eq!(fi.filter_type, "qing_tou.bin");
            assert!(fi.has_v5_extension);
            assert_eq!(fi.is_palette, 1);
            assert_eq!(fi.palette_tone, 89);
            assert_eq!(fi.capture_mode, "common");
            // Verify byte-exact roundtrip against original slice!
            let raw_slice = crate::container::extract_tail_entry(&data, "filter.info").unwrap();
            assert_eq!(fi.to_bytes(), raw_slice);
        }

        let sample_heic = std::path::Path::new(r"C:\Users\Beet\Desktop\Find X10\IMG20260910130237.heic");
        if sample_heic.exists() {
            let data = std::fs::read(sample_heic).unwrap();
            let report = inspect_oppo_tail(&data);
            assert!(report.has_oppo_tail);
            let fi = report.filter_info.expect("expected filter.info in IMG20260910130237.heic");
            assert!((fi.version - 5.1).abs() < 1e-4);
            assert_eq!(fi.is_palette, 1);
            assert_eq!(fi.palette_algo_used, 1);
            assert_eq!(fi.palette_tone, 0);
            assert_eq!(
                fi.filter_type,
                "portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin"
            );
            let raw_slice = crate::container::extract_tail_entry(&data, "filter.info").unwrap();
            assert_eq!(fi.to_bytes(), raw_slice);
        }

        let sample_master = std::path::Path::new(r"C:\Users\Beet\Desktop\Find X10\IMG20260910130244.heic");
        if sample_master.exists() {
            let data = std::fs::read(sample_master).unwrap();
            let report = inspect_oppo_tail(&data);
            assert!(report.has_oppo_tail);
            let fi = report.filter_info.expect("expected filter.info in IMG20260910130244.heic");
            assert!((fi.version - 4.0).abs() < 1e-4);
            assert_eq!(fi.is_palette, 0);
            assert_eq!(fi.filter_type, "qing_tou.bin");
            let raw_slice = crate::container::extract_tail_entry(&data, "filter.info").unwrap();
            assert_eq!(fi.to_bytes(), raw_slice);

            let mp = report.master_preset.expect("expected master.mode.preset.info");
            assert_eq!(mp.version, 1.0);
            assert_eq!(mp.intensity, 100);
            assert_eq!(mp.filter_name, "清透");
            let raw_mp = crate::container::extract_tail_entry(&data, "master.mode.preset.info").unwrap();
            assert_eq!(mp.to_bytes(), raw_mp);
        }
    }
}
