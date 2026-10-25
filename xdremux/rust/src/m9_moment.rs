//! Xiaomi 17 Ultra "Leica Moment M9" (`徕卡一瞬 · M9`) end-to-end rendering & Ultra HDR GainMap engine.
//!
//! Integrates Directions 1, 2, and 3 from the `OffLineM9` research into XDRemux:
//! - **Direction 1 (B2Y Frontend + IPE Color Reduction + LeicaFilter)**:
//!   - 17U Legend AE re-metering (`ae_m9.json.zst` / `ae_tele.json.zst`): 16×16 center-weighted
//!     bright-deweighted luma, bright/dark histogram dynamic range `dr_b2d`, `exp_short`, and `adrc_gain`.
//!   - TMC202 global monotone cubic Hermite tone curve (`tmc202_sw_v2`).
//!   - CC15 relative color matrix (`CC_m9 * CC_normal^-1 * cam2srgb`).
//!   - TDL13 24×16 HSV hue shift & saturation gain 2D LUT (`tdl13_ipe_v2`).
//!   - Gamma152 transfer curve (`gamma152_ipe_v2`) and CV122 asymmetric YCbCr chroma scaling (`cv122_ipe_v2`).
//!   - `LeicaFilter` (`leica_filter_param_m9_{snapshot,preview}.bin.zst`): 4-corner `lux_index × CCT`
//!     blended `17×17×17` 3D LUT trilinear interpolation + `CvStyleEffect` vignette with
//!     `LightDarkPreserve` sigmoid and 6-frequency sin-hash film grain.
//! - **Direction 2 (Full Neural `StyleTransNet` + `ColorFixNet` & Multi-Format Input)**:
//!   - Supports ProXDR HEIC (LHDR/UHDR), Ultra HDR JPEG, SDR HEIC/JPEG/PNG, and uncompressed DNG inputs.
//!   - Reconstructs scene-linear RGB (using the source HDR gain map when available, or inverse
//!     normal IPE gamma + highlight roll-off expansion for SDR inputs).
//!   - Runs `StyleTransNet` (20 triple-RDB blocks) + tiled `ColorFixNet` (12-layer U-Net) in `FullNeural` mode,
//!     or uses Xiaomi's `preview.bin` LUT fallback in `FastLut` mode.
//! - **Direction 3 (Xiaomi 17U Single-Frame Ultra HDR GainMap Synthesis)**:
//!   - `B2Y GainmapForRGB` (`function 51 UltraHdrLinearFrame`, `m9_lin` raised-black gamma + tmc,
//!     digital gain `0.3` with `normADRCKnee = 1.33`).
//!   - `DoProcessLinearYuvWithMaxRGB` integer `(max(dR,dG,dB)+ + mean(dR,dG,dB))/2` at 1/2 scale.
//!   - `GainMapPostProc` highlight share (`g8 >= 250`) -> adaptive `extra` (`100%..80%`) -> `max_boost`.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

use crate::container::ExtractedLhdr;
use crate::{container, edr, exif, gainmap, jpeg_decode, m9_net, photo_details, sdr_source, styles_attach, uhdr_jpeg};

const AE_M9_ZST: &[u8] = include_bytes!("../assets/m9/ae_m9.json.zst");
const AE_TELE_ZST: &[u8] = include_bytes!("../assets/m9/ae_tele.json.zst");
const IPE_TABLES_ZST: &[u8] = include_bytes!("../assets/m9/ipe_tables.json.zst");
const LEICA_PREVIEW_ZST: &[u8] =
    include_bytes!("../assets/m9/leica_filter_param_m9_preview.bin.zst");
const LEICA_SNAPSHOT_ZST: &[u8] =
    include_bytes!("../assets/m9/leica_filter_param_m9_snapshot.bin.zst");

/// Global M9 Moment mode:
/// - `0` = Off (normal XDRemux conversion)
/// - `1` = Fast LUT (`B2Y` + `LeicaFilter preview.bin` + 17U GainMap synthesis)
/// - `2` = Full Neural (`B2Y` + `StyleTransNet` + `ColorFixNet` + `LeicaFilter snapshot.bin` + 17U GainMap)
static M9_MODE_GLOBAL: AtomicU8 = AtomicU8::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum M9Mode {
    Off = 0,
    FastLut = 1,
    FullNeural = 2,
}

impl M9Mode {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::FastLut,
            2 => Self::FullNeural,
            _ => Self::Off,
        }
    }
}

pub fn set_m9_mode(mode: u8) {
    M9_MODE_GLOBAL.store(mode, Ordering::SeqCst);
}

pub fn current_m9_mode() -> M9Mode {
    let atomic_val = M9_MODE_GLOBAL.load(Ordering::SeqCst);
    if atomic_val != 0 {
        return M9Mode::from_u8(atomic_val);
    }
    if let Ok(env_val) = std::env::var("XDREMUX_M9_MODE") {
        match env_val.trim().to_ascii_lowercase().as_str() {
            "1" | "fast" | "lut" | "preview" => return M9Mode::FastLut,
            "2" | "full" | "nn" | "neural" | "on" | "true" => return M9Mode::FullNeural,
            _ => {}
        }
    }
    M9Mode::Off
}

// ---------------------------------------------------------------------------
// 3x3 Matrix Helpers
// ---------------------------------------------------------------------------

type Mat3 = [[f64; 3]; 3];

fn mat3_mul(a: &Mat3, b: &Mat3) -> Mat3 {
    let mut out = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
    out
}

fn mat3_inv(m: &Mat3) -> Mat3 {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if det.abs() < 1e-12 {
        return [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
    }
    let inv_det = 1.0 / det;
    [
        [
            (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * inv_det,
            (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv_det,
            (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv_det,
        ],
        [
            (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * inv_det,
            (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv_det,
            (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv_det,
        ],
        [
            (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * inv_det,
            (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv_det,
            (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv_det,
        ],
    ]
}

// ---------------------------------------------------------------------------
// 1D & 2D Interpolation Helpers
// ---------------------------------------------------------------------------

#[inline]
fn interp_1d(x: f64, xs: &[f64], ys: &[f64]) -> f64 {
    if xs.is_empty() || ys.is_empty() {
        return 0.0;
    }
    if x <= xs[0] || xs.len() == 1 {
        return ys[0];
    }
    let n = xs.len().min(ys.len());
    if x >= xs[n - 1] {
        return ys[n - 1];
    }
    for i in 0..(n - 1) {
        if x >= xs[i] && x <= xs[i + 1] {
            let den = xs[i + 1] - xs[i];
            let t = if den.abs() > 1e-12 {
                (x - xs[i]) / den
            } else {
                0.0
            };
            return ys[i] + t * (ys[i + 1] - ys[i]);
        }
    }
    ys[n - 1]
}

fn interp_2d(x: f64, y: f64, xs: &[f64], ys: &[f64], z: &[Vec<f64>]) -> f64 {
    let col: Vec<f64> = z.iter().map(|row| interp_1d(x, xs, row)).collect();
    let n = col.len().min(ys.len());
    interp_1d(y, &ys[..n], &col[..n])
}

#[inline]
fn interp_lut_f32(x: f32, lut: &[f32]) -> f32 {
    let n = lut.len();
    if n == 0 {
        return x;
    }
    let xc = x.clamp(0.0, 1.0) * (n - 1) as f32;
    let i0 = (xc.floor() as usize).min(n.saturating_sub(2));
    let f = xc - i0 as f32;
    lut[i0] * (1.0 - f) + lut[i0 + 1] * f
}

// ---------------------------------------------------------------------------
// Chromatix 7 IPE Trigger Tree (`tuning.py`)
// ---------------------------------------------------------------------------

#[derive(Clone)]
enum TriggerNode {
    Branch(Vec<(f64, f64, TriggerNode)>),
    Leaf(Vec<f64>),
}

impl TriggerNode {
    fn from_json_leaves(leaves: &serde_json::Value) -> Result<Self, String> {
        let arr = leaves.as_array().ok_or("IPE module leaves is not an array")?;
        let mut root = TriggerNode::Branch(Vec::new());
        for lf in arr {
            let path = lf
                .get("path")
                .and_then(|v| v.as_array())
                .ok_or("IPE leaf missing path")?;
            let data: Vec<f64> = lf
                .get("data")
                .and_then(|v| v.as_array())
                .ok_or("IPE leaf missing data")?
                .iter()
                .map(|x| x.as_f64().unwrap_or(0.0))
                .collect();
            Self::insert_path(&mut root, path, 0, data);
        }
        Ok(root)
    }

    fn insert_path(
        node: &mut TriggerNode,
        path: &[serde_json::Value],
        k: usize,
        data: Vec<f64>,
    ) {
        let TriggerNode::Branch(children) = node else {
            return;
        };
        let step = &path[k];
        let s = step.get(1).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let e = step.get(2).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let pos = children
            .iter()
            .position(|(cs, ce, _)| (*cs - s).abs() < 1e-9 && (*ce - e).abs() < 1e-9);
        let idx = match pos {
            Some(i) => i,
            None => {
                let child = if k + 1 < path.len() {
                    TriggerNode::Branch(Vec::new())
                } else {
                    TriggerNode::Leaf(data.clone())
                };
                children.push((s, e, child));
                children.len() - 1
            }
        };
        if k + 1 < path.len() {
            Self::insert_path(&mut children[idx].2, path, k + 1, data);
        }
    }

    fn eval(&self, vals: &[f64], k: usize) -> Vec<f64> {
        match self {
            TriggerNode::Leaf(data) => data.clone(),
            TriggerNode::Branch(children) => {
                if children.is_empty() {
                    return Vec::new();
                }
                let v = vals.get(k).copied().unwrap_or(0.5);
                let mut regs: Vec<&(f64, f64, TriggerNode)> = children.iter().collect();
                regs.sort_by(|a, b| {
                    a.0.partial_cmp(&b.0)
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then_with(|| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
                });
                for c in &regs {
                    if c.0 <= v && v <= c.1 {
                        return c.2.eval(vals, k + 1);
                    }
                }
                let lo: Vec<_> = regs.iter().copied().filter(|c| c.1 < v).collect();
                let hi: Vec<_> = regs.iter().copied().filter(|c| c.0 > v).collect();
                if lo.is_empty() {
                    return hi[0].2.eval(vals, k + 1);
                }
                if hi.is_empty() {
                    return lo.last().unwrap().2.eval(vals, k + 1);
                }
                let a = lo.last().unwrap();
                let b = hi[0];
                let t = (v - a.1) / (b.0 - a.1).max(1e-9);
                let va = a.2.eval(vals, k + 1);
                let vb = b.2.eval(vals, k + 1);
                va.iter()
                    .zip(vb.iter())
                    .map(|(&x, &y)| (1.0 - t) * x + t * y)
                    .collect()
            }
        }
    }
}

struct IpeTables {
    trees: HashMap<(String, String), TriggerNode>,
}

static IPE_TABLES: OnceLock<Result<IpeTables, String>> = OnceLock::new();

fn get_ipe_tables() -> Result<&'static IpeTables, String> {
    IPE_TABLES
        .get_or_init(|| {
            let raw = zstd::stream::decode_all(Cursor::new(IPE_TABLES_ZST))
                .map_err(|e| format!("ipe_tables.json.zst decode: {e}"))?;
            let root: serde_json::Value =
                serde_json::from_slice(&raw).map_err(|e| format!("ipe_tables.json parse: {e}"))?;
            let obj = root.as_object().ok_or("ipe_tables root not object")?;
            let mut trees = HashMap::new();
            for (tag, mods) in obj {
                if let Some(m_obj) = mods.as_object() {
                    for (m_name, leaves) in m_obj {
                        let tree = TriggerNode::from_json_leaves(leaves)?;
                        trees.insert((tag.clone(), m_name.clone()), tree);
                    }
                }
            }
            Ok(IpeTables { trees })
        })
        .as_ref()
        .map_err(|e| e.clone())
}

fn level_vars_for(tag: &str, module: &str) -> &'static [&'static str] {
    match (tag, module) {
        ("tele", "gamma152_ipe_v2") => &["drc", "gain", "one", "lux", "one"],
        ("tele", "cc15_ipe_v2") => &["one", "one", "one", "lux", "cct", "one"],
        ("tele", "cv122_ipe_v2") => &["one", "gain", "lux", "cct"],
        ("tele", "tdl13_ipe_v2") => &["one", "one", "flag", "lux", "cct", "zoom"],
        ("tele", "ltm21_ipe_v2") => &["drc", "gain", "lux", "zoom"],
        ("tele", "tmc202_sw_v2") => &["drc", "gain", "lux", "zoom"],
        ("tele_normal", "cc15_ipe_v2") => &["drc", "one", "one", "lux", "cct", "zoom"],
        (_, "gamma152_ipe_v2") => &["one", "drc", "gain", "one", "lux", "cct"],
        (_, "cc15_ipe_v2") => &["drc", "flag", "lux", "cct"],
        (_, "cv122_ipe_v2") => &["drc", "gain", "flag", "lux", "cct"],
        (_, "tdl13_ipe_v2") => &["drc", "flag", "lux", "cct"],
        (_, "ltm21_ipe_v2") => &["drc", "lux"],
        (_, "tmc202_sw_v2") => &["drc", "gain", "lux"],
        _ => &["drc", "lux"],
    }
}

fn tuning_lookup(
    tag: &str,
    module: &str,
    drc: f64,
    gain: f64,
    lux: f64,
    cct: f64,
    flag: f64,
) -> Result<Vec<f64>, String> {
    let tables = get_ipe_tables()?;
    let tree = tables
        .trees
        .get(&(tag.to_string(), module.to_string()))
        .ok_or_else(|| format!("missing IPE table ({tag}, {module})"))?;
    let lv = level_vars_for(tag, module);
    let vals: Vec<f64> = lv
        .iter()
        .map(|&name| match name {
            "drc" => drc,
            "gain" => gain,
            "lux" => lux,
            "cct" => cct,
            "flag" => flag,
            "zoom" => 4.0,
            _ => 0.5,
        })
        .collect();
    Ok(tree.eval(&vals, 0))
}

fn tuning_has_tag(tag: &str) -> bool {
    get_ipe_tables()
        .map(|t| t.trees.contains_key(&(tag.to_string(), "gamma152_ipe_v2".to_string())))
        .unwrap_or(false)
}

fn tuning_gamma_lut(tag: &str, drc: f64, lux: f64, cct: f64) -> Result<Vec<f32>, String> {
    let g = tuning_lookup(tag, "gamma152_ipe_v2", drc, 1.0, lux, cct, 0.0)?;
    Ok(g.iter().take(257).map(|&v| (v / 1023.0) as f32).collect())
}

fn tuning_cc_matrix(tag: &str, drc: f64, lux: f64, cct: f64) -> Result<Mat3, String> {
    let c = tuning_lookup(tag, "cc15_ipe_v2", drc, 1.0, lux, cct, 0.0)?;
    if c.len() < 9 {
        return Err("cc15_ipe_v2 leaf shorter than 9".into());
    }
    Ok([
        [c[0], c[1], c[2]],
        [c[3], c[4], c[5]],
        [c[6], c[7], c[8]],
    ])
}

fn tuning_cv_params(tag: &str, drc: f64, lux: f64, cct: f64) -> Result<[f32; 14], String> {
    let c = tuning_lookup(tag, "cv122_ipe_v2", drc, 1.0, lux, cct, 0.0)?;
    let mut out = [0.0f32; 14];
    for (i, &v) in c.iter().take(14).enumerate() {
        out[i] = v as f32;
    }
    Ok(out)
}

fn tuning_tdl_tables(
    tag: &str,
    drc: f64,
    lux: f64,
    cct: f64,
) -> Result<([[f32; 16]; 24], [[f32; 16]; 24]), String> {
    let d = tuning_lookup(tag, "tdl13_ipe_v2", drc, 1.0, lux, cct, 0.0)?;
    if d.len() < 768 {
        return Err("tdl13_ipe_v2 leaf shorter than 768".into());
    }
    let mut hue = [[0.0f32; 16]; 24];
    let mut sat = [[0.0f32; 16]; 24];
    for h in 0..24 {
        for s in 0..16 {
            hue[h][s] = d[h * 16 + s] as f32;
            sat[h][s] = d[384 + h * 16 + s] as f32;
        }
    }
    Ok((hue, sat))
}

// ---------------------------------------------------------------------------
// TMC202 Global Tone Curve (`tmc.py`)
// ---------------------------------------------------------------------------

const CHROMATIX_GAIN_CAP: f64 = 256.0;
const CLAMP_HI: [f64; 5] = [0.9995, 0.9996, 0.9997, 0.9998, 0.9999];

fn clamp_seq(vals: &[f64; 5]) -> [f64; 5] {
    let mut out = [0.0; 5];
    let mut prev = 0.0;
    for i in 0..5 {
        let lo = if i > 0 { prev + 0.0001 } else { 0.0001 };
        let v = if vals[i] > lo {
            vals[i].min(CLAMP_HI[i])
        } else {
            lo
        };
        out[i] = v;
        prev = v;
    }
    out
}

fn tmc_lut(gain: f64, lux: f64, n: usize, tag: &str) -> Result<Vec<f32>, String> {
    let drc = gain.max(1.0);
    let mut p = tuning_lookup(tag, "tmc202_sw_v2", drc, 1.0, lux, 5000.0, 0.0)?;
    if p.len() < 0x2b {
        return Err("tmc202_sw_v2 leaf too short".into());
    }
    p[4] = 0.0;
    for v in &mut p[12..16] {
        *v = 0.0;
    }
    let mut g = 1.0 + (drc - 1.0) * p[0x10] + p[0x11];
    g = if g > 1e-6 { g.clamp(1e-6, 1023.0) } else { 1e-6 };
    let mut gd = 1.0 + p[0x14]; // drc_dark = 1.0
    gd = if gd > 1e-6 { gd.min(1023.0) } else { 1e-6 };
    let lim = (g * gd).min(CHROMATIX_GAIN_CAP);
    let r = g - 1.0;
    let q = (p[0x2a] - p[0x26]) * 0.25;
    let g3 = 1.0 + r * p[0x27];
    let g4 = 1.0 + r * p[0x28];
    let g5 = 1.0 + r * p[0x29];

    let mut x1 = p[0x25] / lim;
    x1 = if x1 > p[0x24] + 0.0001 {
        x1.min(0.9995)
    } else {
        p[0x24] + 0.0001
    };
    let mut x2 = p[0x26] / g;
    x2 = if x2 > x1 + 0.0001 {
        x2.min(0.9996)
    } else {
        x1 + 0.0001
    };
    let mut x3 = (p[0x26] + q) / g3;
    x3 = if x3 > x2 + 0.0001 {
        x3.min(0.9997)
    } else {
        x2 + 0.0001
    };
    let mut x4 = (p[0x26] + 2.0 * q) / g4;
    x4 = if x4 > x3 + 0.0001 {
        x4.min(0.9998)
    } else {
        x3 + 0.0001
    };
    let mut x5 = (p[0x26] + 3.0 * q) / g5;
    x5 = if x5 > x4 + 0.0001 {
        x5.min(0.9999)
    } else {
        x4 + 0.0001
    };

    let xs_mid = clamp_seq(&[x1, x2, x3, x4, x5]);
    let x_knots = [
        0.0,
        xs_mid[0],
        xs_mid[1],
        xs_mid[2],
        xs_mid[3],
        xs_mid[4],
        1.0,
    ];
    let pc = p[0];
    let gains = [lim, g, g3, g4, g5];
    let mut ys_raw = [0.0; 5];
    for i in 0..5 {
        ys_raw[i] = x_knots[i + 1] * gains[i].powf(pc);
    }
    let ys_mid = clamp_seq(&ys_raw);
    let y_knots = [
        0.0,
        ys_mid[0],
        ys_mid[1],
        ys_mid[2],
        ys_mid[3],
        ys_mid[4],
        1.0,
    ];

    let mut h = [0.0; 6];
    let mut dl = [0.0; 6];
    for k in 0..6 {
        h[k] = x_knots[k + 1] - x_knots[k];
        dl[k] = (y_knots[k + 1] - y_knots[k]) / h[k];
    }
    let mut d = [0.0; 7];
    for k in 1..6 {
        let w1 = 2.0 * h[k] + h[k - 1];
        let w2 = h[k] + 2.0 * h[k - 1];
        d[k] = (w1 + w2) / (w1 / dl[k - 1] + w2 / dl[k]);
    }
    let mut e = ((h[4] + 2.0 * h[5]) * dl[5] - h[5] * dl[4]) / (h[4] + h[5]);
    if dl[4] * dl[5] >= 0.0 || e.abs() <= (3.0 * dl[5]).abs() {
        if dl[5] * e < 0.0 {
            e = 0.0;
        }
    } else {
        e = 3.0 * dl[5];
    }
    d[6] = e;

    let mut c2 = [0.0; 7];
    let mut c3 = [0.0; 7];
    for k in 1..6 {
        c2[k] = (3.0 * dl[k] - 2.0 * d[k] - d[k + 1]) / h[k];
        c3[k] = (d[k] - 2.0 * dl[k] + d[k + 1]) / (h[k] * h[k]);
    }

    let mut lut = Vec::with_capacity(n);
    let slope0 = y_knots[1] / x_knots[1];
    for i in 0..n {
        let x = i as f64 / (n - 1) as f64;
        let mut y = x * slope0;
        for k in 1..6 {
            if x >= x_knots[k] && x <= x_knots[k + 1] {
                let t = x - x_knots[k];
                y = y_knots[k] + d[k] * t + c2[k] * t * t + c3[k] * t * t * t;
                break;
            }
        }
        lut.push(y as f32);
    }
    Ok(lut)
}

// ---------------------------------------------------------------------------
// Xiaomi 17U Legend Auto Exposure Re-Metering (`ae.py`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct AeResult {
    pub lux_index: f64,
    pub luma_unit: f64,
    pub dr_b2d: f64,
    pub base_target: f64,
    pub style_scale: f64,
    pub mid_target: f64,
    pub exp_mid: f64,
    pub bright_avg_unit: f64,
    pub bright_ref: f64,
    pub exp_short: f64,
    pub adrc_gain: f64,
}

static AE_MAIN: OnceLock<Result<serde_json::Value, String>> = OnceLock::new();
static AE_TELE: OnceLock<Result<serde_json::Value, String>> = OnceLock::new();

fn get_ae_table(camera: &str) -> Result<&'static serde_json::Value, String> {
    let lock = if camera == "tele" {
        AE_TELE.get_or_init(|| {
            let raw = zstd::stream::decode_all(Cursor::new(AE_TELE_ZST))
                .map_err(|e| format!("ae_tele.json.zst decode: {e}"))?;
            serde_json::from_slice(&raw).map_err(|e| format!("ae_tele.json parse: {e}"))
        })
    } else {
        AE_MAIN.get_or_init(|| {
            let raw = zstd::stream::decode_all(Cursor::new(AE_M9_ZST))
                .map_err(|e| format!("ae_m9.json.zst decode: {e}"))?;
            serde_json::from_slice(&raw).map_err(|e| format!("ae_m9.json parse: {e}"))
        })
    };
    lock.as_ref().map_err(|e| e.clone())
}

fn json_f64_vec(v: &serde_json::Value, key: &str) -> Vec<f64> {
    v.get(key)
        .and_then(|x| x.as_array())
        .map(|arr| arr.iter().map(|e| e.as_f64().unwrap_or(0.0)).collect())
        .unwrap_or_default()
}

fn json_f64_mat(v: &serde_json::Value, key: &str) -> Vec<Vec<f64>> {
    v.get(key)
        .and_then(|x| x.as_array())
        .map(|rows| {
            rows.iter()
                .map(|r| {
                    r.as_array()
                        .map(|a| a.iter().map(|e| e.as_f64().unwrap_or(0.0)).collect())
                        .unwrap_or_default()
                })
                .collect()
        })
        .unwrap_or_default()
}

fn ae_stats(lin_wb: &[f32], width: usize, height: usize) -> ([f64; 256], Vec<f64>) {
    let mut luma = vec![0.0f32; width * height];
    for i in 0..(width * height) {
        let r = lin_wb[i * 3];
        let g = lin_wb[i * 3 + 1];
        let b = lin_wb[i * 3 + 2];
        luma[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    }

    let bh = (height / 16).max(1);
    let bw = (width / 16).max(1);
    let mut blocks = [0.0f64; 256];
    for by in 0..16 {
        for bx in 0..16 {
            let mut sum = 0.0f64;
            let mut cnt = 0usize;
            let y0 = (by * bh).min(height);
            let y1 = ((by + 1) * bh).min(height);
            let x0 = (bx * bw).min(width);
            let x1 = ((bx + 1) * bw).min(width);
            for y in y0..y1 {
                let row = &luma[y * width..y * width + width];
                for x in x0..x1 {
                    sum += row[x] as f64;
                    cnt += 1;
                }
            }
            blocks[by * 16 + bx] = if cnt > 0 {
                (sum / cnt as f64) * 255.0
            } else {
                0.0
            };
        }
    }

    let step = (((height * width) as f64 / 400_000.0).sqrt() as usize).max(1);
    let mut pix = Vec::with_capacity((height / step + 1) * (width / step + 1));
    for y in (0..height).step_by(step) {
        for x in (0..width).step_by(step) {
            pix.push(luma[y * width + x] as f64 * 255.0);
        }
    }
    pix.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    (blocks, pix)
}

fn pct_avg(pix_sorted: &[f64], lo: f64, hi: f64) -> f64 {
    let n = pix_sorted.len();
    if n == 0 {
        return 0.0;
    }
    let a = ((lo * n as f64) as usize).min(n - 1);
    let b = ((hi * n as f64) as usize).max(a + 1).min(n);
    let sum: f64 = pix_sorted[a..b].iter().sum();
    sum / (b - a) as f64
}

fn weighted_luma(blocks: &[f64; 256], exposure: f64, lux: f64, tt: &serde_json::Value) -> f64 {
    let Some(t) = tt.get("luma") else {
        return 0.0;
    };
    let w_tbl = json_f64_vec(t, "weight_luma_calculation.center_wghted_mtr_tbl");
    let ln = json_f64_vec(t, "weight_luma_calculation.lux_node");
    let bs = interp_1d(lux, &ln, &json_f64_vec(t, "weight_luma_calculation.bright_start"));
    let be = interp_1d(lux, &ln, &json_f64_vec(t, "weight_luma_calculation.bright_end"));
    let bw = interp_1d(lux, &ln, &json_f64_vec(t, "weight_luma_calculation.bright_weight"));
    let denom = (be - bs).max(1e-6);

    let mut num_sum = 0.0;
    let mut w_sum = 0.0;
    for i in 0..256 {
        let mut w = w_tbl.get(i).copied().unwrap_or(1.0);
        let b = blocks[i] * exposure;
        let ramp = ((b - bs) / denom).clamp(0.0, 1.0);
        w *= 1.0 + (bw - 1.0) * ramp;
        num_sum += w * b;
        w_sum += w;
    }
    if w_sum > 0.0 {
        num_sum / w_sum
    } else {
        0.0
    }
}

pub fn ae_meter(
    lin_wb: &[f32],
    width: usize,
    height: usize,
    lux_index: f64,
    camera: &str,
) -> Result<AeResult, String> {
    let t = get_ae_table(camera)?;
    let m = t.get("metering").ok_or("AE table missing metering")?;
    let (blocks, pix) = ae_stats(lin_wb, width, height);
    let lux = lux_index;

    let hl = json_f64_vec(
        m,
        "hist_target_by_lux.hist_short_long_adjustment.hist_lux_node",
    );
    let bt_st = interp_1d(
        lux,
        &hl,
        &json_f64_vec(
            m,
            "hist_target_by_lux.hist_short_long_adjustment.hist_base_bright_start_pct",
        ),
    );
    let dt_en = interp_1d(
        lux,
        &hl,
        &json_f64_vec(
            m,
            "hist_target_by_lux.hist_short_long_adjustment.hist_dark_tone_end_pct",
        ),
    );
    let bright_avg = pct_avg(&pix, bt_st, 1.0);
    let dark_avg = pct_avg(&pix, 0.0, dt_en);
    let dr = bright_avg / dark_avg.max(1e-3);

    let bl = json_f64_vec(m, "base_target_by_lux.base_target_lux_node");
    let bdr = json_f64_vec(m, "base_target_by_lux.base_target_dr_node");
    let bt_mat = json_f64_mat(m, "base_target_by_lux.base_target");
    let base = interp_2d(lux, dr, &bl, &bdr, &bt_mat);

    let style = if let Some(s) = t.get("stylization") {
        let enabled = s
            .get("enable_stylization.value")
            .or_else(|| s.get("enable_stylization"))
            .and_then(|v| v.as_bool().or_else(|| v.as_i64().map(|i| i != 0)))
            .unwrap_or(false);
        if enabled {
            let sln = json_f64_vec(s, "style_base.style_base_target_lux_node");
            let s_mat = json_f64_mat(s, "style_base.style_base_target_scale");
            if let Some(row0) = s_mat.first() {
                interp_1d(lux, &sln, row0)
            } else {
                1.0
            }
        } else {
            1.0
        }
    } else {
        1.0
    };
    let mid = base * style;

    let luma_1 = weighted_luma(&blocks, 1.0, lux, t);
    let mut e = mid / luma_1.max(1e-6);
    for _ in 0..20 {
        let wl = weighted_luma(&blocks, e, lux, t);
        let e_new = e * mid / wl.max(1e-6);
        if (e_new / e - 1.0).abs() < 1e-4 {
            e = e_new;
            break;
        }
        e = e_new;
    }

    let hdr_nodes = json_f64_vec(
        m,
        "hist_target_by_lux.hist_short_long_adjustment.hist_dr_node",
    );
    let ref_mat = json_f64_mat(
        m,
        "hist_target_by_lux.hist_short_long_adjustment.hist_bright_tone_ref_target",
    );
    let bright_ref = interp_2d(lux, dr, &hl, &hdr_nodes, &ref_mat);
    let mut e_short = bright_ref / bright_avg.max(1e-6);

    let d = t.get("drc").ok_or("AE table missing drc")?;
    let dln = json_f64_vec(d, "normal_drc_ctrl.nor_drc_lux_node");
    let dmat = json_f64_mat(d, "normal_drc_ctrl.max_drc_gain");
    let cap = dmat
        .first()
        .map(|r| interp_1d(lux, &dln, r))
        .unwrap_or(4.0);
    let adrc = (e / e_short.max(1e-9)).clamp(1.0, cap);
    e_short = e / adrc;

    Ok(AeResult {
        lux_index: lux,
        luma_unit: luma_1,
        dr_b2d: dr,
        base_target: base,
        style_scale: style,
        mid_target: mid,
        exp_mid: e,
        bright_avg_unit: bright_avg,
        bright_ref,
        exp_short: e_short,
        adrc_gain: adrc,
    })
}

pub fn lux_index_from_ev(ev100: f64) -> f64 {
    (474.9 - 23.45 * ev100).clamp(0.0, 999.0)
}

// ---------------------------------------------------------------------------
// B2Y IPE Pixel Operators (`frontend.py`)
// ---------------------------------------------------------------------------

fn cc_m9_matrix(cam2srgb: &Mat3, lux: f64, cct: f64, drc: f64, camera: &str) -> Result<[[f32; 3]; 3], String> {
    let (tag, ref_tag) = if camera == "tele" {
        ("tele", "tele_normal")
    } else {
        ("m9", "normal")
    };
    let drc_c = drc.max(1.0);
    let cc_tag = tuning_cc_matrix(tag, drc_c, lux, cct)?;
    let cc_ref = tuning_cc_matrix(ref_tag, drc_c, lux, cct)?;
    let rel = mat3_mul(&cc_tag, &mat3_inv(&cc_ref));
    let m = mat3_mul(&rel, cam2srgb);
    Ok([
        [m[0][0] as f32, m[0][1] as f32, m[0][2] as f32],
        [m[1][0] as f32, m[1][1] as f32, m[1][2] as f32],
        [m[2][0] as f32, m[2][1] as f32, m[2][2] as f32],
    ])
}

#[inline]
fn rgb_to_hsv_unit(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let d = max - min;
    let s = if max > 1e-6 { d / max } else { 0.0 };
    let mut h = if d <= 1e-6 {
        0.0
    } else if (max - r).abs() <= 1e-7 {
        60.0 * ((g - b) / d)
    } else if (max - g).abs() <= 1e-7 {
        60.0 * ((b - r) / d + 2.0)
    } else {
        60.0 * ((r - g) / d + 4.0)
    };
    if h < 0.0 {
        h += 360.0;
    }
    (h, s, max)
}

#[inline]
fn hsv_to_rgb_unit(h: f32, s: f32, v: f32) -> (f32, f32, f32) {
    if s <= 1e-6 {
        return (v, v, v);
    }
    let hh = (h.rem_euclid(360.0)) / 60.0;
    let i = hh.floor() as i32;
    let f = hh - i as f32;
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match i {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

#[inline]
fn tdl_pixel(
    r: f32,
    g: f32,
    b: f32,
    hue_tab: &[[f32; 16]; 24],
    sat_tab: &[[f32; 16]; 24],
) -> (f32, f32, f32) {
    let r = r.max(0.0);
    let g = g.max(0.0);
    let b = b.max(0.0);
    let v = r.max(g).max(b);
    let scale = v.max(1e-6);
    let (h, s, _) = rgb_to_hsv_unit(r / scale, g / scale, b / scale);

    let hi = h / 15.0;
    let si = s * 15.0;
    let h_floor = hi.floor();
    let h0 = (h_floor as isize).rem_euclid(24) as usize;
    let h1 = (h0 + 1) % 24;
    let fh = hi - h_floor;

    let s_floor = si.floor();
    let s0 = (s_floor as isize).clamp(0, 15) as usize;
    let s1 = (s0 + 1).min(15);
    let fs = (si - s0 as f32).clamp(0.0, 1.0);

    let bil = |t: &[[f32; 16]; 24]| -> f32 {
        (1.0 - fh) * ((1.0 - fs) * t[h0][s0] + fs * t[h0][s1])
            + fh * ((1.0 - fs) * t[h1][s0] + fs * t[h1][s1])
    };
    let h_new = (h + bil(hue_tab)).rem_euclid(360.0);
    let s_new = (s * (1.0 + bil(sat_tab))).clamp(0.0, 1.0);
    let (ro, go, bo) = hsv_to_rgb_unit(h_new, s_new, 1.0);
    (ro * scale, go * scale, bo * scale)
}

#[inline]
fn cv_yuv_pixel(r: f32, g: f32, b: f32, p: &[f32; 14]) -> (f32, f32, f32) {
    let y = p[0] * r + p[1] * g + p[2] * b;
    let bg = b - g;
    let rg = r - g;
    let cb_ = bg + (if bg >= 0.0 { p[6] } else { p[7] }) * rg;
    let cr_ = rg + (if rg >= 0.0 { p[10] } else { p[11] }) * bg;
    let cb = (if cb_ >= 0.0 { p[4] } else { p[5] }) * cb_;
    let cr = (if cr_ >= 0.0 { p[8] } else { p[9] }) * cr_;
    (y, cb, cr)
}

#[inline]
fn cv_apply_pixel(r: f32, g: f32, b: f32, p: &[f32; 14]) -> (f32, f32, f32) {
    let (y, cb, cr) = cv_yuv_pixel(r, g, b, p);
    let ro = (y + 1.402 * cr).clamp(0.0, 1.0);
    let go = (y - 0.344136 * cb - 0.714136 * cr).clamp(0.0, 1.0);
    let bo = (y + 1.772 * cb).clamp(0.0, 1.0);
    (ro, go, bo)
}

fn run_b2y_for_rgb(
    lin_wb: &[f32],
    width: usize,
    height: usize,
    ae: &AeResult,
    lux_index: f64,
    cct: f64,
    cam2srgb: &Mat3,
    camera: &str,
) -> Result<Vec<f32>, String> {
    let tag = if camera == "tele" { "tele" } else { "m9" };
    let gain = ae.exp_short as f32;
    let ccm = cc_m9_matrix(cam2srgb, lux_index, cct, ae.adrc_gain, camera)?;
    let (hue_tab, sat_tab) = tuning_tdl_tables(tag, ae.adrc_gain, lux_index, cct)?;
    let glut = tuning_gamma_lut(tag, ae.adrc_gain, lux_index, cct)?;
    let cvp = tuning_cv_params(tag, ae.adrc_gain, lux_index, cct)?;
    let gtm = tmc_lut(ae.adrc_gain, lux_index, 4096, tag)?;

    let mut out = vec![0.0f32; width * height * 3];
    let n_threads = std::thread::available_parallelism()
        .map(|p| p.get().min(16))
        .unwrap_or(4);
    let rows_per_chunk = height.div_ceil(n_threads).max(1);

    std::thread::scope(|s| {
        for (in_chunk, out_chunk) in lin_wb
            .chunks(rows_per_chunk * width * 3)
            .zip(out.chunks_mut(rows_per_chunk * width * 3))
        {
            let gtm_ref = &gtm;
            let glut_ref = &glut;
            let hue_ref = &hue_tab;
            let sat_ref = &sat_tab;
            s.spawn(move || {
                for (src_px, dst_px) in in_chunk.chunks_exact(3).zip(out_chunk.chunks_exact_mut(3)) {
                    let rx = src_px[0] * gain;
                    let gx = src_px[1] * gain;
                    let bx = src_px[2] * gain;
                    let y = 0.299 * rx + 0.587 * gx + 0.114 * bx;
                    let c = interp_lut_f32(y.clamp(0.0, 1.0), gtm_ref);
                    let g_ratio = c / y.max(1e-6);
                    let rl = rx * g_ratio;
                    let gl = gx * g_ratio;
                    let bl = bx * g_ratio;

                    let rc = (ccm[0][0] * rl + ccm[0][1] * gl + ccm[0][2] * bl).max(0.0);
                    let gc = (ccm[1][0] * rl + ccm[1][1] * gl + ccm[1][2] * bl).max(0.0);
                    let bc = (ccm[2][0] * rl + ccm[2][1] * gl + ccm[2][2] * bl).max(0.0);

                    let (rt, gt, bt) = tdl_pixel(rc, gc, bc, hue_ref, sat_ref);
                    let rg = interp_lut_f32(rt, glut_ref);
                    let gg = interp_lut_f32(gt, glut_ref);
                    let bg = interp_lut_f32(bt, glut_ref);

                    let (ro, go, bo) = cv_apply_pixel(rg, gg, bg, &cvp);
                    dst_px[0] = ro;
                    dst_px[1] = go;
                    dst_px[2] = bo;
                }
            });
        }
    });

    Ok(out)
}

// ---------------------------------------------------------------------------
// LeicaFilter 3D LUT + CvStyle Vignette (`leicafilter.py`)
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct LfBin {
    lo: i32,
    hi: i32,
    idx: usize,
    sub: Vec<LfBin>,
}

struct LeicaFilterParams {
    lut_n: usize,
    scenes: HashMap<String, Vec<LfBin>>,
    zooms: Vec<(f32, Vec<LfBin>)>,
    luts: Vec<Vec<u8>>, // each is 17*17*17*3 (B, G, R)
    shading: Vec<[f32; 8]>,
}

impl LeicaFilterParams {
    fn from_zst_bytes(zst: &[u8]) -> Result<Self, String> {
        let d = zstd::stream::decode_all(Cursor::new(zst))
            .map_err(|e| format!("leica_filter_param zstd decode: {e}"))?;
        if d.len() < 0x400 {
            return Err("leica_filter_param file too short".into());
        }
        let read_u16 = |byte_off: usize| -> u16 {
            u16::from_le_bytes(d[byte_off..byte_off + 2].try_into().unwrap())
        };
        let n_scene = read_u16(0) as usize;
        let mut scene_sizes = Vec::with_capacity(n_scene);
        for i in 0..n_scene {
            scene_sizes.push(read_u16(2 + i * 2) as usize);
        }
        let p = 1 + n_scene;
        let param_off = read_u16(p * 2) as usize;
        let lut_off = read_u16((p + 1) * 2) as usize;
        let lut_n = read_u16((p + 2) * 2) as usize;
        let n_zoom = read_u16((p + 3) * 2) as usize;
        let mut zoom_sizes = Vec::with_capacity(n_zoom);
        for i in 0..n_zoom {
            zoom_sizes.push(read_u16((p + 4 + i) * 2) as usize);
        }

        let read_tree = |slice: &[u8]| -> Vec<LfBin> {
            let u16_at = |idx: usize| -> i32 {
                u16::from_le_bytes(slice[idx * 2..idx * 2 + 2].try_into().unwrap()) as i32
            };
            let n_lux = u16_at(0) as usize;
            let mut pos = 1usize;
            let mut lux_bins = Vec::with_capacity(n_lux);
            for _ in 0..n_lux {
                let lo = u16_at(pos);
                let hi = u16_at(pos + 1);
                let n_cct = u16_at(pos + 2) as usize;
                pos += 3;
                let mut ccts = Vec::with_capacity(n_cct);
                for _ in 0..n_cct {
                    let clo = u16_at(pos);
                    let chi = u16_at(pos + 1);
                    let idx = u16_at(pos + 2) as usize;
                    pos += 3;
                    ccts.push(LfBin {
                        lo: clo,
                        hi: chi,
                        idx,
                        sub: Vec::new(),
                    });
                }
                lux_bins.push(LfBin {
                    lo,
                    hi,
                    idx: 0,
                    sub: ccts,
                });
            }
            lux_bins
        };

        let mut scenes = HashMap::new();
        let mut off = param_off;
        let mut n_lut = 0usize;
        for sz in scene_sizes {
            let name_bytes = &d[off..off + 64];
            let nul = name_bytes.iter().position(|&b| b == 0).unwrap_or(64);
            let name = String::from_utf8_lossy(&name_bytes[..nul]).to_string();
            let tree = read_tree(&d[off + 64..off + sz]);
            for b in &tree {
                for c in &b.sub {
                    n_lut = n_lut.max(c.idx + 1);
                }
            }
            scenes.insert(name, tree);
            off += sz;
        }

        let mut zooms = Vec::with_capacity(n_zoom);
        let mut n_sh = 0usize;
        for sz in zoom_sizes {
            let z = f32::from_le_bytes(d[off..off + 4].try_into().unwrap());
            let tree = read_tree(&d[off + 4..off + sz]);
            for b in &tree {
                for c in &b.sub {
                    n_sh = n_sh.max(c.idx + 1);
                }
            }
            zooms.push((z, tree));
            off += sz;
        }
        zooms.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));

        let lut_bytes = lut_n * lut_n * lut_n * 3;
        let mut luts = Vec::with_capacity(n_lut);
        for i in 0..n_lut {
            let start = lut_off + i * lut_bytes;
            luts.push(d[start..start + lut_bytes].to_vec());
        }

        let sh_base = lut_off + n_lut * lut_bytes;
        let mut shading = Vec::with_capacity(n_sh);
        for i in 0..n_sh {
            let mut arr = [0.0f32; 8];
            for j in 0..8 {
                let b_off = sh_base + (i * 8 + j) * 4;
                arr[j] = f32::from_le_bytes(d[b_off..b_off + 4].try_into().unwrap());
            }
            shading.push(arr);
        }

        Ok(Self {
            lut_n,
            scenes,
            zooms,
            luts,
            shading,
        })
    }

    fn find_bin(bins: &[LfBin], v: i32) -> (&LfBin, &LfBin) {
        for (i, b) in bins.iter().enumerate() {
            if v <= b.hi {
                if v >= b.lo || i == 0 {
                    return (b, b);
                }
                return (&bins[i - 1], b);
            }
        }
        let last = bins.last().unwrap();
        (last, last)
    }

    fn frac(v: f32, e: &LfBin, p: &LfBin) -> f32 {
        let den = p.lo as f32 - e.hi as f32;
        if den != 0.0 {
            (v - e.hi as f32) / den
        } else {
            0.0
        }
    }

    fn corners(tree: &[LfBin], lux: i32, cct: i32) -> [(usize, f32); 4] {
        let (le, lp) = Self::find_bin(tree, lux);
        let a = Self::frac(lux as f32, le, lp);
        let (ce, cp) = Self::find_bin(&le.sub, cct);
        let b = Self::frac(cct as f32, ce, cp);
        let (de, dp) = Self::find_bin(&lp.sub, cct);
        let c = Self::frac(cct as f32, de, dp);
        [
            (ce.idx, (1.0 - a) * (1.0 - b)),
            (cp.idx, (1.0 - a) * b),
            (de.idx, a * (1.0 - c)),
            (dp.idx, a * c),
        ]
    }

    fn blended_lut(&self, scene: &str, lux_index: f32, cct: f32) -> Vec<u8> {
        let tree = self
            .scenes
            .get(scene)
            .or_else(|| self.scenes.get("common"))
            .expect("common scene present");
        let corners = Self::corners(tree, lux_index as i32, cct as i32);
        let mut order: Vec<(usize, f32)> = Vec::with_capacity(4);
        for (idx, w) in corners {
            if let Some(entry) = order.iter_mut().find(|(i, _)| *i == idx) {
                entry.1 += w;
            } else {
                order.push((idx, w));
            }
        }
        if order.len() == 1 {
            return self.luts[order[0].0].clone();
        }
        let len = self.luts[0].len();
        let mut s = vec![0.0f32; len];
        for (idx, w) in order {
            let lut = &self.luts[idx];
            for j in 0..len {
                s[j] += w * (lut[j] as f32);
            }
        }
        s.into_iter().map(|v| v.trunc() as u8).collect()
    }

    fn shading_params(&self, zoom: f32, lux_index: f32, cct: f32) -> [f32; 8] {
        let mut tree = &self.zooms[0].1;
        for (z, t) in &self.zooms {
            if zoom >= *z {
                tree = t;
            }
        }
        let corners = Self::corners(tree, lux_index as i32, cct as i32);
        let mut out = [0.0f32; 8];
        for (idx, w) in corners {
            let sh = &self.shading[idx];
            for j in 0..8 {
                out[j] += w * sh[j];
            }
        }
        out
    }
}

static LEICA_PREVIEW: OnceLock<Result<LeicaFilterParams, String>> = OnceLock::new();
static LEICA_SNAPSHOT: OnceLock<Result<LeicaFilterParams, String>> = OnceLock::new();

fn get_leica_params(style_trans_on: bool) -> Result<&'static LeicaFilterParams, String> {
    let lock = if style_trans_on {
        LEICA_SNAPSHOT.get_or_init(|| LeicaFilterParams::from_zst_bytes(LEICA_SNAPSHOT_ZST))
    } else {
        LEICA_PREVIEW.get_or_init(|| LeicaFilterParams::from_zst_bytes(LEICA_PREVIEW_ZST))
    };
    lock.as_ref().map_err(|e| e.clone())
}

#[inline]
fn nrand(u: f32, v: f32) -> f32 {
    let s = (u * 12.9898 + v * 78.233).sin() * 43_758.547;
    (s - s.trunc()).rem_euclid(1.0)
}

fn apply_leica_filter(
    rgb: &[f32],
    width: usize,
    height: usize,
    lux_index: f32,
    cct: f32,
    zoom: f32,
    scene: &str,
    style_trans_on: bool,
) -> Result<Vec<f32>, String> {
    let params = get_leica_params(style_trans_on)?;
    let lut_u8 = params.blended_lut(scene, lux_index, cct);
    let n = params.lut_n;
    // Convert u8 [r][g][b] (B, G, R) to float32 (R, G, B)
    let mut lut_rgb = vec![[0.0f32; 3]; n * n * n];
    for i in 0..(n * n * n) {
        lut_rgb[i] = [
            lut_u8[i * 3 + 2] as f32 / 255.0,
            lut_u8[i * 3 + 1] as f32 / 255.0,
            lut_u8[i * 3] as f32 / 255.0,
        ];
    }
    let sh = params.shading_params(zoom, lux_index, cct);
    let (start, end, coord_scale, value_scale, k, b, v, t) =
        (sh[0], sh[1], sh[2], sh[3], sh[4], sh[5], sh[6], sh[7]);

    let mut out = vec![0.0f32; width * height * 3];
    let n_threads = std::thread::available_parallelism()
        .map(|p| p.get().min(16))
        .unwrap_or(4);
    let rows_per_chunk = height.div_ceil(n_threads).max(1);
    let wf = width as f32;
    let hf = height as f32;
    let scale_n = (n - 1) as f32;
    let max_i0 = n - 2;

    std::thread::scope(|s| {
        for (chunk_idx, (in_chunk, out_chunk)) in rgb
            .chunks(rows_per_chunk * width * 3)
            .zip(out.chunks_mut(rows_per_chunk * width * 3))
            .enumerate()
        {
            let y_base = chunk_idx * rows_per_chunk;
            let lut_ref = &lut_rgb;
            s.spawn(move || {
                let rows = in_chunk.len() / (width * 3);
                for ry in 0..rows {
                    let y = y_base + ry;
                    let uvy = (y as f32 + 0.5) / hf;
                    let uy = uvy - 0.5;
                    let ny = uy - 0.5;
                    let in_row = &in_chunk[ry * width * 3..(ry + 1) * width * 3];
                    let out_row = &mut out_chunk[ry * width * 3..(ry + 1) * width * 3];

                    for x in 0..width {
                        let px = &in_row[x * 3..x * 3 + 3];
                        let rx = px[0].clamp(0.0, 1.0) * scale_n;
                        let gx = px[1].clamp(0.0, 1.0) * scale_n;
                        let bx = px[2].clamp(0.0, 1.0) * scale_n;

                        let r0 = (rx.floor() as usize).min(max_i0);
                        let g0 = (gx.floor() as usize).min(max_i0);
                        let b0 = (bx.floor() as usize).min(max_i0);
                        let fr = rx - r0 as f32;
                        let fg = gx - g0 as f32;
                        let fb = bx - b0 as f32;

                        let mut acc = [0.0f32; 3];
                        for dr in 0..=1 {
                            let wr = if dr == 1 { fr } else { 1.0 - fr };
                            for dg in 0..=1 {
                                let wg = if dg == 1 { fg } else { 1.0 - fg };
                                let wrg = wr * wg;
                                for db in 0..=1 {
                                    let wb = if db == 1 { fb } else { 1.0 - fb };
                                    let w = wrg * wb;
                                    let idx = ((r0 + dr) * n + (g0 + dg)) * n + (b0 + db);
                                    let c = lut_ref[idx];
                                    acc[0] += w * c[0];
                                    acc[1] += w * c[1];
                                    acc[2] += w * c[2];
                                }
                            }
                        }

                        // CvStyleEffect vignette + light/dark preserve + sin-hash grain
                        let uvx = ((x as f32 + 0.5) / wf - 0.5) * wf / hf + 0.5;
                        let ux = uvx - 0.5;
                        let nx = ux - 0.5;
                        let mut dist = (ux * ux + uy * uy).sqrt();
                        let rnd = nrand(nx, ny); // current_time == 0.0 -> all 6 frequencies evaluate at (nx, ny)
                        dist += 0.004 * rnd * 10.0 * coord_scale;
                        let s_vig = ((dist - start) / (end - start)).clamp(0.0, 1.0);
                        let mut vig = s_vig * s_vig * (3.0 - 2.0 * s_vig);
                        let l_val = 0.499 * acc[0] + 0.387 * acc[1] + 0.114 * acc[2];
                        let y_val = 0.299 * acc[0] + 0.587 * acc[1] + 0.114 * acc[2];
                        let pf = v / (1.0 + (k * (-l_val + b)).exp()) + t;
                        vig = ((1.0 - pf) * vig + pf) * value_scale;
                        let delta = y_val * (vig - 1.0);

                        out_row[x * 3] = (acc[0] + delta).clamp(0.0, 1.0);
                        out_row[x * 3 + 1] = (acc[1] + delta).clamp(0.0, 1.0);
                        out_row[x * 3 + 2] = (acc[2] + delta).clamp(0.0, 1.0);
                    }
                }
            });
        }
    });

    Ok(out)
}

// ---------------------------------------------------------------------------
// Xiaomi 17U Ultra HDR GainMap Branch (`gainmap.py`)
// ---------------------------------------------------------------------------

const DG_LEGEND: f32 = 0.3;
const NORM_ADRC_KNEE: f64 = 1.33;
const NORM_ADRC_LUX: f64 = 150.0;
const GM_SCALE: usize = 2;
const MAX_BOOST: f32 = 5.0;
const HL_VAL: u8 = 250;
const HL_ANC1: f32 = 8.0;
const HL_G1: f32 = 100.0;
const HL_ANC2: f32 = 20.0;
const HL_G2: f32 = 80.0;

pub struct M9GainMap {
    pub pixels: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub max_boost: f32,
    pub hl_pct: f32,
}

fn synthesize_m9_gainmap(
    lin_wb: &[f32],
    width: usize,
    height: usize,
    ae: &AeResult,
    lux_index: f64,
    cct: f64,
    cam2srgb: &Mat3,
    camera: &str,
) -> Result<M9GainMap, String> {
    let tag = if camera == "tele" { "tele" } else { "m9" };
    let lin_tag_candidate = format!("{tag}_lin");
    let lin_tag = if tuning_has_tag(&lin_tag_candidate) {
        lin_tag_candidate.as_str()
    } else {
        tag
    };

    let mut dg = DG_LEGEND;
    if lux_index > NORM_ADRC_LUX && ae.adrc_gain < NORM_ADRC_KNEE {
        dg *= (ae.adrc_gain / NORM_ADRC_KNEE) as f32;
    }
    let gain = (ae.exp_short as f32) * dg;
    let ccm = cc_m9_matrix(cam2srgb, lux_index, cct, ae.adrc_gain, camera)?;
    let (hue_tab, sat_tab) = tuning_tdl_tables(tag, ae.adrc_gain, lux_index, cct)?;
    let cvp = tuning_cv_params(tag, ae.adrc_gain, lux_index, cct)?;
    let glut = tuning_gamma_lut(lin_tag, ae.adrc_gain, lux_index, cct)?;
    let gtm = tmc_lut(ae.adrc_gain, lux_index, 4096, lin_tag)?;

    let mut yuv = vec![0.0f32; width * height * 3];
    let n_threads = std::thread::available_parallelism()
        .map(|p| p.get().min(16))
        .unwrap_or(4);
    let rows_per_chunk = height.div_ceil(n_threads).max(1);

    std::thread::scope(|s| {
        for (in_chunk, out_chunk) in lin_wb
            .chunks(rows_per_chunk * width * 3)
            .zip(yuv.chunks_mut(rows_per_chunk * width * 3))
        {
            let gtm_ref = &gtm;
            let glut_ref = &glut;
            let hue_ref = &hue_tab;
            let sat_ref = &sat_tab;
            s.spawn(move || {
                for (src_px, dst_px) in in_chunk.chunks_exact(3).zip(out_chunk.chunks_exact_mut(3)) {
                    let rx = src_px[0] * gain;
                    let gx = src_px[1] * gain;
                    let bx = src_px[2] * gain;
                    let y = 0.299 * rx + 0.587 * gx + 0.114 * bx;
                    let c = interp_lut_f32(y.clamp(0.0, 1.0), gtm_ref);
                    let g_ratio = c / y.max(1e-6);
                    let rl = rx * g_ratio;
                    let gl = gx * g_ratio;
                    let bl = bx * g_ratio;

                    let rc = (ccm[0][0] * rl + ccm[0][1] * gl + ccm[0][2] * bl).max(0.0);
                    let gc = (ccm[1][0] * rl + ccm[1][1] * gl + ccm[1][2] * bl).max(0.0);
                    let bc = (ccm[2][0] * rl + ccm[2][1] * gl + ccm[2][2] * bl).max(0.0);

                    let (rt, gt, bt) = tdl_pixel(rc, gc, bc, hue_ref, sat_ref);
                    let rg = interp_lut_f32(rt, glut_ref);
                    let gg = interp_lut_f32(gt, glut_ref);
                    let bg = interp_lut_f32(bt, glut_ref);

                    let (yo, cbo, cro) = cv_yuv_pixel(rg, gg, bg, &cvp);
                    dst_px[0] = yo;
                    dst_px[1] = cbo;
                    dst_px[2] = cro;
                }
            });
        }
    });

    // to_nv12: 8-bit Y + 2x2-averaged Cb/Cr
    let h2 = (height & !1).max(2);
    let w2 = (width & !1).max(2);
    let ch = h2 / 2;
    let cw = w2 / 2;
    let mut y8 = vec![0u8; height * width];
    for i in 0..(height * width) {
        y8[i] = (yuv[i * 3] * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    let mut cb8 = vec![128u8; ch * cw];
    let mut cr8 = vec![128u8; ch * cw];
    for cy in 0..ch {
        for cx in 0..cw {
            let p00 = ((cy * 2) * width + (cx * 2)) * 3;
            let p01 = ((cy * 2) * width + (cx * 2 + 1)) * 3;
            let p10 = ((cy * 2 + 1) * width + (cx * 2)) * 3;
            let p11 = ((cy * 2 + 1) * width + (cx * 2 + 1)) * 3;
            let cb_mean = (yuv[p00 + 1] + yuv[p01 + 1] + yuv[p10 + 1] + yuv[p11 + 1]) * 0.25;
            let cr_mean = (yuv[p00 + 2] + yuv[p01 + 2] + yuv[p10 + 2] + yuv[p11 + 2]) * 0.25;
            cb8[cy * cw + cx] = (cb_mean * 255.0 + 128.0).round().clamp(0.0, 255.0) as u8;
            cr8[cy * cw + cx] = (cr_mean * 255.0 + 128.0).round().clamp(0.0, 255.0) as u8;
        }
    }

    // DoProcessLinearYuvWithMaxRGB (0xc320)
    let ow = (((width + GM_SCALE - 1) / GM_SCALE) + 1) & !1;
    let oh = (((height + GM_SCALE - 1) / GM_SCALE) + 1) & !1;
    let r_step = if ow > 0 { (width / ow).max(1) } else { 1 };
    let mut g8 = vec![0u8; oh * ow];
    let mut hl_count = 0usize;

    for oy in 0..oh {
        let sy = (oy * r_step).min(height - 1);
        let crow = (sy / 2).min(ch - 1);
        for ox_pair in (0..ow).step_by(2) {
            let c0 = ox_pair * r_step;
            let ccol = (c0 / 2).min(cw - 1);
            let u = cb8[crow * cw + ccol] as i32 - 128;
            let v = cr8[crow * cw + ccol] as i32 - 128;
            let d_r = v * 359;
            let d_b = u * 454;
            let d_g = u * -88 + v * -183;
            let m = d_r.max(d_g).max(d_b);
            let mx = if m < 1 { 0 } else { m >> 8 };
            let s = (d_r + d_b + d_g) >> 8;
            let mut t = (s * 0x5556) >> 16;
            t -= t >> 15;
            let add = (mx + t) >> 1;

            for dx in 0..2 {
                if ox_pair + dx < ow {
                    let sx = (c0 + dx).min(width - 1);
                    let y_val = y8[sy * width + sx] as i32;
                    let g_val = (y_val + add).clamp(0, 255) as u8;
                    if g_val >= HL_VAL {
                        hl_count += 1;
                    }
                    g8[oy * ow + ox_pair + dx] = g_val;
                }
            }
        }
    }

    let hl_pct = 100.0 * (hl_count as f32) / ((oh * ow).max(1) as f32);
    let extra = if hl_pct <= HL_ANC1 {
        HL_G1
    } else if hl_pct >= HL_ANC2 {
        HL_G2
    } else {
        (hl_pct - HL_ANC1) / (HL_ANC2 - HL_ANC1) * (HL_G2 - HL_G1) + HL_G1
    };
    let mut boost = (extra / 100.0 * MAX_BOOST).max(1.0);
    boost = (boost * 100.0).trunc() / 100.0;

    Ok(M9GainMap {
        pixels: g8,
        width: ow as u32,
        height: oh as u32,
        max_boost: boost,
        hl_pct,
    })
}

// ---------------------------------------------------------------------------
// Baseline 8-bit Grayscale JPEG Encoder (ITU-T.81 Annex K tables)
// ---------------------------------------------------------------------------

const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
    13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59,
    52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

const STD_LUMA_QUANT: [u8; 64] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113,
    92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

const BITS_DC_LUMINANCE: [u8; 16] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const VAL_DC_LUMINANCE: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const BITS_AC_LUMINANCE: [u8; 16] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const VAL_AC_LUMINANCE: [u8; 162] = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
];

fn build_huff_lut(bits: &[u8; 16], vals: &[u8]) -> [(u16, u8); 256] {
    let mut lut = [(0u16, 0u8); 256];
    let mut code = 0u16;
    let mut k = 0usize;
    for len in 1..=16u8 {
        let count = bits[(len - 1) as usize] as usize;
        for _ in 0..count {
            let sym = vals[k] as usize;
            lut[sym] = (code, len);
            code += 1;
            k += 1;
        }
        code <<= 1;
    }
    lut
}

pub fn encode_gray_jpeg(pixels: &[u8], width: u32, height: u32, quality: u8) -> Vec<u8> {
    let w = width as usize;
    let h = height as usize;
    let q = quality.clamp(1, 100) as i32;
    let scale = if q < 50 { 5000 / q } else { 200 - q * 2 };

    let mut qtable = [1u8; 64];
    for i in 0..64 {
        let v = (STD_LUMA_QUANT[ZIGZAG[i]] as i32 * scale + 50) / 100;
        qtable[i] = v.clamp(1, 255) as u8;
    }

    // Precompute 1D DCT basis table
    let mut cos_tbl = [[0.0f32; 8]; 8];
    for u in 0..8 {
        let cu = if u == 0 {
            1.0 / std::f32::consts::SQRT_2
        } else {
            1.0
        };
        for x in 0..8 {
            cos_tbl[u][x] =
                0.5 * cu * (((2 * x + 1) * u) as f32 * std::f32::consts::PI / 16.0).cos();
        }
    }

    let dc_lut = build_huff_lut(&BITS_DC_LUMINANCE, &VAL_DC_LUMINANCE);
    let ac_lut = build_huff_lut(&BITS_AC_LUMINANCE, &VAL_AC_LUMINANCE);

    let mut out = Vec::with_capacity(w * h / 2 + 512);
    // SOI + APP0 JFIF
    out.extend_from_slice(&[
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0x01, 0x01, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00,
    ]);
    // DQT
    out.extend_from_slice(&[0xFF, 0xDB, 0x00, 67, 0x00]);
    out.extend_from_slice(&qtable);
    // SOF0 (8-bit, 1 component)
    out.extend_from_slice(&[0xFF, 0xC0, 0x00, 11, 0x08]);
    out.extend_from_slice(&(height as u16).to_be_bytes());
    out.extend_from_slice(&(width as u16).to_be_bytes());
    out.extend_from_slice(&[0x01, 0x01, 0x11, 0x00]);
    // DHT DC
    out.extend_from_slice(&[0xFF, 0xC4, 0x00, 31, 0x00]);
    out.extend_from_slice(&BITS_DC_LUMINANCE);
    out.extend_from_slice(&VAL_DC_LUMINANCE);
    // DHT AC
    out.extend_from_slice(&[0xFF, 0xC4, 0x00, 181, 0x10]);
    out.extend_from_slice(&BITS_AC_LUMINANCE);
    out.extend_from_slice(&VAL_AC_LUMINANCE);
    // SOS
    out.extend_from_slice(&[0xFF, 0xDA, 0x00, 8, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);

    let mut bit_buf = 0u32;
    let mut bit_cnt = 0u8;
    fn emit_bits(
        code: u16,
        len: u8,
        bit_buf: &mut u32,
        bit_cnt: &mut u8,
        out: &mut Vec<u8>,
    ) {
        *bit_buf = (*bit_buf << len) | (code as u32 & ((1u32 << len) - 1));
        *bit_cnt += len;
        while *bit_cnt >= 8 {
            *bit_cnt -= 8;
            let b = ((*bit_buf >> *bit_cnt) & 0xFF) as u8;
            out.push(b);
            if b == 0xFF {
                out.push(0x00);
            }
        }
    }

    let mag_bits = |val: i32| -> (u8, u16) {
        if val == 0 {
            return (0, 0);
        }
        let abs_v = val.unsigned_abs();
        let nbits = (32 - abs_v.leading_zeros()) as u8;
        let bits = if val > 0 {
            abs_v as u16
        } else {
            ((1u32 << nbits) - 1 - abs_v) as u16
        };
        (nbits, bits)
    };

    let mut prev_dc = 0i32;
    let mut block = [[0.0f32; 8]; 8];
    let mut tmp = [[0.0f32; 8]; 8];
    let mut zz = [0i32; 64];

    for by in (0..h).step_by(8) {
        for bx in (0..w).step_by(8) {
            for y in 0..8 {
                let sy = (by + y).min(h - 1);
                for x in 0..8 {
                    let sx = (bx + x).min(w - 1);
                    block[y][x] = pixels[sy * w + sx] as f32 - 128.0;
                }
            }
            for y in 0..8 {
                for u in 0..8 {
                    let mut s = 0.0f32;
                    for x in 0..8 {
                        s += block[y][x] * cos_tbl[u][x];
                    }
                    tmp[y][u] = s;
                }
            }
            for i in 0..64 {
                let sp = ZIGZAG[i];
                let v = sp / 8;
                let u = sp % 8;
                let mut s = 0.0f32;
                for y in 0..8 {
                    s += tmp[y][u] * cos_tbl[v][y];
                }
                zz[i] = (s / (qtable[i] as f32)).round() as i32;
            }

            let diff = zz[0] - prev_dc;
            prev_dc = zz[0];
            let (nbits, vbits) = mag_bits(diff);
            let (hcode, hlen) = dc_lut[nbits as usize];
            emit_bits(hcode, hlen, &mut bit_buf, &mut bit_cnt, &mut out);
            if nbits > 0 {
                emit_bits(vbits, nbits, &mut bit_buf, &mut bit_cnt, &mut out);
            }

            let mut run = 0usize;
            for k in 1..64 {
                let ac = zz[k];
                if ac == 0 {
                    run += 1;
                } else {
                    while run >= 16 {
                        let (zcode, zlen) = ac_lut[0xF0];
                        emit_bits(zcode, zlen, &mut bit_buf, &mut bit_cnt, &mut out);
                        run -= 16;
                    }
                    let (nb, vb) = mag_bits(ac);
                    let sym = ((run as u8) << 4) | nb;
                    let (acode, alen) = ac_lut[sym as usize];
                    emit_bits(acode, alen, &mut bit_buf, &mut bit_cnt, &mut out);
                    emit_bits(vb, nb, &mut bit_buf, &mut bit_cnt, &mut out);
                    run = 0;
                }
            }
            if run > 0 {
                let (ecode, elen) = ac_lut[0x00];
                emit_bits(ecode, elen, &mut bit_buf, &mut bit_cnt, &mut out);
            }
        }
    }

    if bit_cnt > 0 {
        let pad_len = 8 - bit_cnt;
        let pad_code = (1u16 << pad_len) - 1;
        emit_bits(pad_code, pad_len, &mut bit_buf, &mut bit_cnt, &mut out);
    }
    out.extend_from_slice(&[0xFF, 0xD9]);
    out
}

// ---------------------------------------------------------------------------
// Scene Linear Reconstruction (ProXDR / Ultra HDR / SDR / DNG -> Linear RGB)
// ---------------------------------------------------------------------------

#[inline]
fn srgb_to_linear_f32(v: f32) -> f32 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
fn linear_to_srgb_f32(v: f32) -> f32 {
    if v <= 0.0031308 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }
}

/// Convert display-referred sRGB `[0, 1]` to Display P3 encoded values (`uhdr.py::srgb_to_p3`).
pub fn srgb_to_p3_pixels(rgb: &[f32]) -> Vec<u8> {
    let mut out = vec![0u8; rgb.len()];
    for (src, dst) in rgb.chunks_exact(3).zip(out.chunks_exact_mut(3)) {
        let rl = srgb_to_linear_f32(src[0].clamp(0.0, 1.0));
        let gl = srgb_to_linear_f32(src[1].clamp(0.0, 1.0));
        let bl = srgb_to_linear_f32(src[2].clamp(0.0, 1.0));

        let rp = (0.822462 * rl + 0.177538 * gl).clamp(0.0, 1.0);
        let gp = (0.033194 * rl + 0.966806 * gl).clamp(0.0, 1.0);
        let bp = (0.017083 * rl + 0.072397 * gl + 0.910520 * bl).clamp(0.0, 1.0);

        dst[0] = (linear_to_srgb_f32(rp) * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
        dst[1] = (linear_to_srgb_f32(gp) * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
        dst[2] = (linear_to_srgb_f32(bp) * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
    }
    out
}

/// Reconstruct linear scene RGB (`1.0` = highlight saturation) from decoded 8-bit SDR RGB
/// and an optional ProXDR / Ultra HDR gain map.
fn reconstruct_scene_linear(
    rgb_u8: &[u8],
    width: usize,
    height: usize,
    source_bytes: &[u8],
    lux_index: f64,
    cct: f64,
) -> Vec<f32> {
    let n_px = width * height;
    let mut lin = vec![0.0f32; n_px * 3];

    // Check if the input has an existing ProXDR LHDR/UHDR or Ultra HDR JPEG gain map
    let mut applied_hdr_gainmap = false;
    if let Ok(ext) = crate::extract_lhdr_or_uhdr_from_bytes(source_bytes) {
        if ext.mode == "uhdr" {
            if let Some(ref gm_jpeg) = ext.gainmap_data {
                if gm_jpeg.as_slice() != uhdr_jpeg::IDENTITY_GAINMAP_JPEG {
                    if let Ok((gm_rgb, gm_w, gm_h)) = jpeg_decode::decode_jpeg_to_rgb(gm_jpeg) {
                        let r_max = ext
                            .meta_floats
                            .get(4)
                            .copied()
                            .unwrap_or(1.0)
                            .max(1.0);
                        let gamma = ext
                            .meta_floats
                            .get(7)
                            .copied()
                            .unwrap_or(1.0)
                            .max(0.01);
                        let gw = gm_w as usize;
                        let gh = gm_h as usize;
                        if r_max > 1.05 && gw > 0 && gh > 0 {
                            for y in 0..height {
                                let gy = (y * gh / height).min(gh - 1);
                                for x in 0..width {
                                    let gx = (x * gw / width).min(gw - 1);
                                    let g_idx = (gy * gw + gx) * 3;
                                    let p_idx = (y * width + x) * 3;
                                    for c in 0..3 {
                                        let sdr_l =
                                            srgb_to_linear_f32(rgb_u8[p_idx + c] as f32 / 255.0);
                                        let g_norm = (gm_rgb[g_idx + c] as f32 / 255.0).powf(gamma);
                                        let boost = r_max.powf(g_norm);
                                        lin[p_idx + c] = sdr_l * boost;
                                    }
                                }
                            }
                            applied_hdr_gainmap = true;
                        }
                    }
                }
            }
        } else if let Some(ref mask_jpeg) = ext.mask_data {
            if let Ok((mask_gray, mw, mh)) = jpeg_decode::decode_jpeg_to_gray(mask_jpeg) {
                let edr_scale = edr::edr_scale_calculator(&ext.meta_floats).max(1.0);
                let gm_gray = gainmap::reconstruct(
                    &mask_gray,
                    mw as usize,
                    mh as usize,
                    mw as usize,
                    edr_scale,
                    ext.meta_floats.first().copied().unwrap_or(3.0),
                );
                let gw = mw as usize;
                let gh = mh as usize;
                if edr_scale > 1.05 && gw > 0 && gh > 0 {
                    for y in 0..height {
                        let gy = (y * gh / height).min(gh - 1);
                        for x in 0..width {
                            let gx = (x * gw / width).min(gw - 1);
                            let g_norm = gm_gray[gy * gw + gx] as f32 / 255.0;
                            let boost = 1.0 + (edr_scale - 1.0) * g_norm;
                            let p_idx = (y * width + x) * 3;
                            for c in 0..3 {
                                let sdr_l = srgb_to_linear_f32(rgb_u8[p_idx + c] as f32 / 255.0);
                                lin[p_idx + c] = sdr_l * boost;
                            }
                        }
                    }
                    applied_hdr_gainmap = true;
                }
            }
        }
    }

    if !applied_hdr_gainmap {
        // Plain SDR source: invert the 17U normal gamma152 LUT + soft highlight shoulder expansion
        // so M9 AE re-metering and GainMap synthesis recover natural highlight headroom.
        let normal_gamma = tuning_gamma_lut("normal", 2.0, lux_index, cct).unwrap_or_default();
        let mut inv_lut = [0.0f32; 256];
        for i in 0..256 {
            let y = i as f32 / 255.0;
            let x_lin = if normal_gamma.len() >= 2 {
                // Monotone search in normal_gamma
                let mut pos = 0usize;
                while pos + 1 < normal_gamma.len() && normal_gamma[pos + 1] < y {
                    pos += 1;
                }
                if pos + 1 >= normal_gamma.len() {
                    1.0
                } else {
                    let g0 = normal_gamma[pos];
                    let g1 = normal_gamma[pos + 1];
                    let t = if (g1 - g0).abs() > 1e-6 {
                        ((y - g0) / (g1 - g0)).clamp(0.0, 1.0)
                    } else {
                        0.0
                    };
                    (pos as f32 + t) / (normal_gamma.len() - 1) as f32
                }
            } else {
                srgb_to_linear_f32(y)
            };
            // Gentle inverse Reinhard highlight shoulder expansion for SDR highlights
            inv_lut[i] = x_lin / (1.0 - 0.55 * x_lin);
        }
        for i in 0..(n_px * 3) {
            lin[i] = inv_lut[rgb_u8[i] as usize];
        }
    }

    // Normalize so the 99.9th percentile channel value maps to 1.0 (sensor saturation)
    let step = (n_px / 100_000).max(1);
    let mut samples = Vec::with_capacity(n_px / step + 1);
    for i in (0..n_px).step_by(step) {
        let m = lin[i * 3].max(lin[i * 3 + 1]).max(lin[i * 3 + 2]);
        samples.push(m);
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p999 = samples
        .get((samples.len() * 999 / 1000).min(samples.len().saturating_sub(1)))
        .copied()
        .unwrap_or(1.0)
        .max(1e-4);
    let inv_norm = 1.0 / p999;
    for v in &mut lin {
        *v = (*v * inv_norm).clamp(0.0, 1.0);
    }
    lin
}

fn parse_leading_f64(s: &str) -> Option<f64> {
    let trimmed = s.trim().trim_start_matches("f/").trim_start_matches("F/");
    if let Some((num, den)) = trimmed.split_once('/') {
        let n: f64 = num.trim().parse().ok()?;
        let d_clean: String = den
            .trim()
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '.')
            .collect();
        let d: f64 = d_clean.parse().ok()?;
        if d > 0.0 {
            return Some(n / d);
        }
    }
    let clean: String = trimmed
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    clean.parse().ok()
}

/// Parse shooting parameters from EXIF (`input_path` or `exif_tiff`) to determine
/// `(lux_index, cct, camera, zoom)`.
fn extract_shooting_conditions(input_path: &str) -> (f64, f64, &'static str, f32) {
    let mut lux_index = 260.0f64;
    let cct = 5003.0f64;
    let mut camera = "main";
    let mut zoom = 1.0f32;

    if let Ok(details) = photo_details::inspect_photo_details(input_path) {
        let shutter = details.exposure_time.as_deref().and_then(parse_leading_f64);
        let fnum = details.f_number.as_deref().and_then(parse_leading_f64);
        let iso = details.iso.as_deref().and_then(parse_leading_f64);
        if let (Some(shutter), Some(fnum), Some(iso)) = (shutter, fnum, iso) {
            if shutter > 0.0 && fnum > 0.0 && iso > 0.0 {
                let ev100 = (fnum * fnum / shutter).log2() - (iso / 100.0).log2();
                lux_index = lux_index_from_ev(ev100);
            }
        }
        let f35 = details
            .focal_length_35mm
            .as_deref()
            .and_then(parse_leading_f64)
            .or_else(|| {
                details
                    .focal_length
                    .as_deref()
                    .and_then(parse_leading_f64)
                    .map(|v| v * 3.2)
            });
        if let Some(fl35) = f35 {
            if fl35 >= 65.0 {
                camera = "tele";
                zoom = ((fl35 / 23.0) as f32).clamp(3.2, 4.3);
            }
        }
    }
    (lux_index, cct, camera, zoom)
}

/// Build the 20-float UHDR metadata block for an M9 GainMap (`min_boost = 1.0`,
/// `max_boost = gm.max_boost`, `gamma = 1.0`, `offset_sdr = 0.0`, `offset_hdr = 0.0`).
fn m9_gainmap_meta_floats(max_boost: f32) -> Vec<f32> {
    let r_max = max_boost.max(1.0);
    vec![
        1.0, 1.0, 1.0, // ratio_min
        0.0, // pad
        r_max, r_max, r_max, // ratio_max
        1.0, 1.0, 1.0, // gamma
        0.0, 0.0, 0.0, // eps_sdr (0.0 for Xiaomi 17U GainMap)
        0.0, 0.0, 0.0, // eps_hdr (0.0 for Xiaomi 17U GainMap)
        1.0, // drs
        r_max, // drh
        r_max, // scale
        0.0, // base_is_hdr
    ]
}

/// Run the complete Xiaomi 17 Ultra "Leica Moment M9" pipeline on `source` bytes and
/// return a synthesized HEIF source container + `ExtractedLhdr` ready for XDRemux's
/// ISO 21496-1 UHDR + Photographic Styles + Portrait + OPPO output pipeline.
pub fn synthesize_m9_source(
    source: &[u8],
    input_path: &str,
    mode: M9Mode,
) -> Result<(Vec<u8>, ExtractedLhdr), String> {
    let (mut rgb_u8, mut w, mut h, oriented) = sdr_source::decode_to_rgb(source)?;

    let exif_tiff = if source.starts_with(&[0xFF, 0xD8]) {
        uhdr_jpeg::extract_exif_tiff(source)
    } else {
        styles_attach::extract_exif_tiff(source)
    }
    .map(|t| styles_attach::strip_note_from_tiff(&t));

    if !oriented {
        let orientation = exif_tiff
            .as_deref()
            .map(exif::parse_exif_orientation)
            .transpose()?
            .unwrap_or(exif::ExifOrientation::Normal);
        let (rotated, rw, rh) = crate::isobmff_write::orient_gainmap_pixels(
            &rgb_u8,
            w,
            h,
            3,
            w as usize * 3,
            orientation,
        )
        .map_err(|e| format!("M9 source orientation: {e}"))?;
        rgb_u8 = rotated;
        w = rw;
        h = rh;
    }

    let width = w as usize;
    let height = h as usize;
    let (lux_index, cct, camera, zoom) = extract_shooting_conditions(input_path);

    // 1. Reconstruct linear white-balanced RGB (`lin_wb`)
    let lin_wb = reconstruct_scene_linear(&rgb_u8, width, height, source, lux_index, cct);
    let cam2srgb: Mat3 = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

    // 2. Stage 1: B2Y ForRGB (M9 AE re-metering + TMC202 + CC15 + TDL13 + Gamma152 + CV122)
    let ae = ae_meter(&lin_wb, width, height, lux_index, camera)?;
    let mut img_rgb = run_b2y_for_rgb(
        &lin_wb,
        width,
        height,
        &ae,
        lux_index,
        cct,
        &cam2srgb,
        camera,
    )?;

    // 3. Stage 2: StyleTransNet + ColorFixNet (when FullNeural mode is selected)
    let style_trans_on = if mode == M9Mode::FullNeural {
        match m9_net::run_styletrans(&img_rgb, width, height, lux_index as f32, cct as f32) {
            Ok(styled) => {
                img_rgb = styled;
                true
            }
            Err(e) => {
                eprintln!("m9_moment: StyleTrans fallback to preview LUT ({e})");
                false
            }
        }
    } else {
        false
    };

    // 4. Stage 3: LeicaFilter (17^3 3D LUT trilinear lookup + CvStyleEffect vignette & grain)
    let filtered_rgb = apply_leica_filter(
        &img_rgb,
        width,
        height,
        lux_index as f32,
        cct as f32,
        zoom,
        "common",
        style_trans_on,
    )?;

    // Convert M9 sRGB output to Display P3 (matching Xiaomi 17U `uhdr.py::srgb_to_p3`)
    let m9_p3_u8 = srgb_to_p3_pixels(&filtered_rgb);

    // 5. Stage 4: Xiaomi 17U Single-Frame Ultra HDR GainMap Synthesis (`gainmap.py`)
    let gm = synthesize_m9_gainmap(
        &lin_wb,
        width,
        height,
        &ae,
        lux_index,
        cct,
        &cam2srgb,
        camera,
    )?;
    let gm_jpeg = encode_gray_jpeg(&gm.pixels, gm.width, gm.height, 95);

    // Normalize EXIF orientation to 1 (pixels are already in presentation orientation)
    let fallback_dt = std::fs::metadata(input_path)
        .and_then(|m| m.modified())
        .map(sdr_source::exif_datetime_from_system)
        .ok();
    let exif_tiff = Some(match exif_tiff {
        Some(mut tiff) => {
            exif::normalize_tiff_orientation(&mut tiff);
            exif::ensure_exif_ifd(&mut tiff)?;
            tiff
        }
        None => sdr_source::minimal_exif_tiff(fallback_dt.as_deref().unwrap_or("1970:01:01 00:00:00")),
    });

    let container = uhdr_jpeg::synthesize_source_container_from_rgb(&m9_p3_u8, w, h, exif_tiff, true)?;
    let extracted = ExtractedLhdr {
        mode: "uhdr".into(),
        meta_bytes: Vec::new(),
        meta_floats: m9_gainmap_meta_floats(gm.max_boost),
        gainmap_use_base_color_space: true,
        mask_data: None,
        gainmap_data: Some(gm_jpeg),
        manifest_entries: None,
    };
    Ok((container, extracted))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_m9_tables_and_ae_load() {
        let tables = get_ipe_tables().expect("ipe_tables.json.zst should load");
        assert!(tables.trees.contains_key(&("m9".into(), "gamma152_ipe_v2".into())));
        assert!(tables.trees.contains_key(&("m9_lin".into(), "gamma152_ipe_v2".into())));
        let _ = get_leica_params(false).expect("preview.bin.zst should load");
        let _ = get_leica_params(true).expect("snapshot.bin.zst should load");

        let dummy_lin = vec![0.25f32; 64 * 48 * 3];
        let ae = ae_meter(&dummy_lin, 64, 48, 250.0, "main").expect("ae_meter should succeed");
        assert!(ae.adrc_gain >= 1.0);
        assert!(ae.exp_short > 0.0);
    }

    #[test]
    fn test_gray_jpeg_roundtrip() {
        let w = 32u32;
        let h = 24u32;
        let mut orig = vec![0u8; (w * h) as usize];
        for y in 0..h {
            for x in 0..w {
                orig[(y * w + x) as usize] = ((x * 7 + y * 5) & 0xFF) as u8;
            }
        }
        let jpeg = encode_gray_jpeg(&orig, w, h, 95);
        let (dec, dw, dh) = jpeg_decode::decode_jpeg_to_rgb(&jpeg).expect("decode_jpeg_to_rgb");
        assert_eq!((dw, dh), (w, h));
        assert_eq!(dec.len(), (w * h * 3) as usize);
    }

    #[test]
    fn test_synthesize_m9_source_fast_and_neural() {
        let w = 64u32;
        let h = 48u32;
        let mut orig = vec![0u8; (w * h) as usize];
        for y in 0..h {
            for x in 0..w {
                orig[(y * w + x) as usize] = ((x * 4 + y * 3).min(255)) as u8;
            }
        }
        let jpeg = encode_gray_jpeg(&orig, w, h, 92);

        let (container_fast, ext_fast) =
            synthesize_m9_source(&jpeg, "synthetic_test.jpg", M9Mode::FastLut)
                .expect("FastLut should succeed");
        assert!(!container_fast.is_empty());
        assert_eq!(ext_fast.mode, "uhdr");
        assert!(ext_fast.gainmap_data.is_some());
        assert!(ext_fast.meta_floats[4] >= 1.0);

        let (container_neural, ext_neural) =
            synthesize_m9_source(&jpeg, "synthetic_test.jpg", M9Mode::FullNeural)
                .expect("FullNeural should succeed");
        assert!(!container_neural.is_empty());
        assert_eq!(ext_neural.mode, "uhdr");
        assert!(ext_neural.gainmap_data.is_some());
        assert!(ext_neural.meta_floats[4] >= 1.0);
    }
}
