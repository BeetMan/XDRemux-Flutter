//! Xiaomi 17 Ultra "Leica Moment M9" neural network stage (`StyleTransNet` + `ColorFixNet`).
//!
//! Reimplements `com.xiaomi.plugin.legendST` (`libmialgo_styletrans.so`) in pure Rust using
//! the bit-exact weights recovered from the Qualcomm QNN HTP context binaries (`low.m9w.zst`,
//! `high.m9w.zst`, `colorfix.m9w.zst`).
//!
//! Pipeline (`styletrans_pipeline.cpp` `run()` @ `0x449518`):
//! 1. Rotate portrait images to sensor (landscape) orientation.
//! 2. Center-pad to `4096×3072` using `BORDER_REFLECT_101`.
//! 3. Downsample `4×` (`INTER_AREA`) to `1024×768`, pad `48` px (`BORDER_REFLECT` on RGB, `0` on mask)
//!    to `1120×864×4`, and normalize via `(u8 - 128.0) / 127.5`.
//! 4. Select `low` (`lux_index > 260 && cct < 4692`) or `high` `StyleTransNet` (20 triple-RDB blocks),
//!    run inference at `280×216` internal resolution, upsample `4×` to `1120×864`, and crop center `1024×768`.
//! 5. Upsample styled `1024×768` back to `4096×3072` (`INTER_AREA`) and run `ColorFixNet` (12-layer U-Net)
//!    on `544×544×6` tiles (`step = 512, margin = 16`) overlapping the active image region.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::OnceLock;

const LOW_M9W_ZST: &[u8] = include_bytes!("../assets/m9/low.m9w.zst");
const HIGH_M9W_ZST: &[u8] = include_bytes!("../assets/m9/high.m9w.zst");
const COLORFIX_M9W_ZST: &[u8] = include_bytes!("../assets/m9/colorfix.m9w.zst");

const W4K: usize = 4096;
const H4K: usize = 3072;
const NW: usize = 1024;
const NH: usize = 768;
const PAD: usize = 48;
const TILE: usize = 544;
const STEP: usize = 512;
const MARGIN: usize = 16;

/// Decoded convolution layer from a `.m9w` weight archive.
pub struct ConvLayer {
    pub cout: usize,
    pub cin: usize,
    pub kh: usize,
    pub kw: usize,
    pub lo: f32,
    pub hi: f32,
    pub weights: Vec<f32>,
    pub bias: Vec<f32>,
}

/// Decoded `.m9w` weight archive.
pub struct WeightArchive {
    pub up1_gain: f32,
    pub up2_gain: f32,
    pub layers: HashMap<String, ConvLayer>,
}

impl WeightArchive {
    pub fn from_zst_bytes(zst_bytes: &[u8]) -> Result<Self, String> {
        let raw = zstd::stream::decode_all(Cursor::new(zst_bytes))
            .map_err(|e| format!("m9w zstd decode failed: {e}"))?;
        Self::from_bytes(&raw)
    }

    pub fn from_bytes(buf: &[u8]) -> Result<Self, String> {
        if buf.len() < 20 || &buf[0..4] != b"M9WT" {
            return Err("invalid .m9w header magic".into());
        }
        let ver = u32::from_le_bytes(buf[4..8].try_into().unwrap());
        if ver != 1 {
            return Err(format!("unsupported .m9w version {ver}"));
        }
        let up1_gain = f32::from_le_bytes(buf[8..12].try_into().unwrap());
        let up2_gain = f32::from_le_bytes(buf[12..16].try_into().unwrap());
        let n_layers = u32::from_le_bytes(buf[16..20].try_into().unwrap()) as usize;

        let mut pos = 20usize;
        let mut layers = HashMap::with_capacity(n_layers);
        for _ in 0..n_layers {
            if pos + 2 > buf.len() {
                return Err("truncated .m9w layer name length".into());
            }
            let name_len = u16::from_le_bytes(buf[pos..pos + 2].try_into().unwrap()) as usize;
            pos += 2;
            if pos + name_len + 14 > buf.len() {
                return Err("truncated .m9w layer header".into());
            }
            let name = std::str::from_utf8(&buf[pos..pos + name_len])
                .map_err(|_| "invalid UTF-8 layer name in .m9w")?
                .to_string();
            pos += name_len;

            let cout = u16::from_le_bytes(buf[pos..pos + 2].try_into().unwrap()) as usize;
            let cin = u16::from_le_bytes(buf[pos + 2..pos + 4].try_into().unwrap()) as usize;
            let kh = buf[pos + 4] as usize;
            let kw = buf[pos + 5] as usize;
            let lo = f32::from_le_bytes(buf[pos + 6..pos + 10].try_into().unwrap());
            let hi = f32::from_le_bytes(buf[pos + 10..pos + 14].try_into().unwrap());
            pos += 14;

            let sc_bytes = cout * 8;
            let b_bytes = cout * 4;
            let q_len = cout * cin * kh * kw;
            if pos + sc_bytes + b_bytes + q_len > buf.len() {
                return Err(format!("truncated .m9w payload for layer {name}"));
            }

            let mut sc64 = Vec::with_capacity(cout);
            for i in 0..cout {
                let off = pos + i * 8;
                sc64.push(f64::from_le_bytes(buf[off..off + 8].try_into().unwrap()));
            }
            pos += sc_bytes;

            let mut bias = Vec::with_capacity(cout);
            for i in 0..cout {
                let off = pos + i * 4;
                bias.push(f32::from_le_bytes(buf[off..off + 4].try_into().unwrap()));
            }
            pos += b_bytes;

            let q_slice = &buf[pos..pos + q_len];
            pos += q_len;

            let inner = cin * kh * kw;
            let mut weights = vec![0.0f32; q_len];
            for co in 0..cout {
                let scale = sc64[co];
                let w_row = &mut weights[co * inner..(co + 1) * inner];
                let q_row = &q_slice[co * inner..(co + 1) * inner];
                for j in 0..inner {
                    w_row[j] = ((q_row[j] as i8 as f64) * scale) as f32;
                }
            }

            layers.insert(
                name,
                ConvLayer {
                    cout,
                    cin,
                    kh,
                    kw,
                    lo,
                    hi,
                    weights,
                    bias,
                },
            );
        }

        Ok(Self {
            up1_gain,
            up2_gain,
            layers,
        })
    }

    #[inline]
    pub fn get(&self, name: &str) -> Result<&ConvLayer, String> {
        self.layers
            .get(name)
            .ok_or_else(|| format!("missing M9 network layer '{name}'"))
    }
}

static LOW_ARCHIVE: OnceLock<Result<WeightArchive, String>> = OnceLock::new();
static HIGH_ARCHIVE: OnceLock<Result<WeightArchive, String>> = OnceLock::new();
static COLORFIX_ARCHIVE: OnceLock<Result<WeightArchive, String>> = OnceLock::new();

fn get_archive(model: &str) -> Result<&'static WeightArchive, String> {
    let lock = match model {
        "low" => LOW_ARCHIVE.get_or_init(|| WeightArchive::from_zst_bytes(LOW_M9W_ZST)),
        "high" => HIGH_ARCHIVE.get_or_init(|| WeightArchive::from_zst_bytes(HIGH_M9W_ZST)),
        "colorfix" => {
            COLORFIX_ARCHIVE.get_or_init(|| WeightArchive::from_zst_bytes(COLORFIX_M9W_ZST))
        }
        _ => return Err(format!("unknown M9 model '{model}'")),
    };
    lock.as_ref().map_err(|e| e.clone())
}

/// 3D tensor `[C, H, W]` in contiguous row-major layout.
#[derive(Clone)]
pub struct Tensor3D {
    pub c: usize,
    pub h: usize,
    pub w: usize,
    pub data: Vec<f32>,
}

impl Tensor3D {
    pub fn zeros(c: usize, h: usize, w: usize) -> Self {
        Self {
            c,
            h,
            w,
            data: vec![0.0f32; c * h * w],
        }
    }

    pub fn concat(tensors: &[&Tensor3D]) -> Self {
        let h = tensors[0].h;
        let w = tensors[0].w;
        let total_c: usize = tensors.iter().map(|t| t.c).sum();
        let mut data = Vec::with_capacity(total_c * h * w);
        for t in tensors {
            debug_assert_eq!(t.h, h);
            debug_assert_eq!(t.w, w);
            data.extend_from_slice(&t.data);
        }
        Self {
            c: total_c,
            h,
            w,
            data,
        }
    }

    pub fn slice_channels(&self, c_start: usize, c_end: usize) -> Self {
        let hw = self.h * self.w;
        Self {
            c: c_end - c_start,
            h: self.h,
            w: self.w,
            data: self.data[c_start * hw..c_end * hw].to_vec(),
        }
    }
}

/// Perform 2D convolution (`padding = kw / 2`, `stride = 1`) followed by HTP `[lo, hi]` clamping.
///
/// Uses cache-blocked SGEMM (`[cout, K] x [K, H*W]`) with spatial tile blocking (`N_TILE = 128`)
/// so the accumulator rows stay in L1/SIMD registers.
pub fn conv2d_clamped(x: &Tensor3D, layer: &ConvLayer, use_threads: bool) -> Tensor3D {
    debug_assert_eq!(x.c, layer.cin);
    let h = x.h;
    let w = x.w;
    let hw = h * w;
    let cout = layer.cout;
    let cin = layer.cin;
    let kh = layer.kh;
    let kw = layer.kw;
    let k_dim = cin * kh * kw;
    let lo = layer.lo;
    let hi = layer.hi;

    // Fast path for 1x1 convolution: no im2col needed! `x.data` is already `[cin, H*W]`.
    if kh == 1 && kw == 1 {
        let mut out = vec![0.0f32; cout * hw];
        sgemm_clamped(
            cout,
            k_dim,
            hw,
            &layer.weights,
            &x.data,
            &layer.bias,
            lo,
            hi,
            &mut out,
            use_threads,
        );
        return Tensor3D {
            c: cout,
            h,
            w,
            data: out,
        };
    }

    let pad_h = kh / 2;
    let pad_w = kw / 2;

    // Build im2col matrix `col` of shape `[cin * kh * kw, H * W]` row-by-row.
    let mut col = vec![0.0f32; k_dim * hw];
    for ic in 0..cin {
        let src_ch = &x.data[ic * hw..(ic + 1) * hw];
        for ky in 0..kh {
            for kx in 0..kw {
                let k_idx = (ic * kh + ky) * kw + kx;
                let dst_row = &mut col[k_idx * hw..(k_idx + 1) * hw];
                for oh in 0..h {
                    let ih = (oh + ky) as isize - pad_h as isize;
                    if ih < 0 || ih >= h as isize {
                        continue;
                    }
                    let ih = ih as usize;
                    let dst_line = &mut dst_row[oh * w..(oh + 1) * w];
                    let src_line = &src_ch[ih * w..(ih + 1) * w];
                    let ow_start = pad_w.saturating_sub(kx);
                    let ow_end = (w + pad_w).saturating_sub(kx).min(w);
                    if ow_start < ow_end {
                        let iw_start = ow_start + kx - pad_w;
                        let len = ow_end - ow_start;
                        dst_line[ow_start..ow_end]
                            .copy_from_slice(&src_line[iw_start..iw_start + len]);
                    }
                }
            }
        }
    }

    let mut out = vec![0.0f32; cout * hw];
    sgemm_clamped(
        cout,
        k_dim,
        hw,
        &layer.weights,
        &col,
        &layer.bias,
        lo,
        hi,
        &mut out,
        use_threads,
    );
    Tensor3D {
        c: cout,
        h,
        w,
        data: out,
    }
}

const N_TILE: usize = 128;

fn sgemm_clamped(
    m: usize,
    k: usize,
    n: usize,
    a: &[f32],
    b: &[f32],
    bias: &[f32],
    lo: f32,
    hi: f32,
    c: &mut [f32],
    use_threads: bool,
) {
    let n_threads = if use_threads && m >= 16 && k * n >= 65_536 {
        std::thread::available_parallelism()
            .map(|p| p.get().min(8))
            .unwrap_or(4)
    } else {
        1
    };

    if n_threads <= 1 || m < 4 {
        sgemm_rows_range(0, m, k, n, a, b, bias, lo, hi, c);
    } else {
        let rows_per_thread = m.div_ceil(n_threads);
        std::thread::scope(|s| {
            let mut rest = c;
            let mut m0 = 0usize;
            while m0 < m && !rest.is_empty() {
                let take = rows_per_thread.min(m - m0);
                let (chunk, tail) = rest.split_at_mut(take * n);
                rest = tail;
                s.spawn(move || {
                    sgemm_rows_range(m0, m0 + take, k, n, a, b, bias, lo, hi, chunk);
                });
                m0 += take;
            }
        });
    }
}

#[inline(never)]
fn sgemm_rows_range(
    m_start: usize,
    m_end: usize,
    k: usize,
    n: usize,
    a: &[f32],
    b: &[f32],
    bias: &[f32],
    lo: f32,
    hi: f32,
    c_chunk: &mut [f32],
) {
    let rows = m_end - m_start;
    let mut m_local = 0usize;

    // Process 4 output channels at a time over spatial tiles of N_TILE = 128.
    while m_local + 4 <= rows {
        let m0 = m_start + m_local;
        let a0 = &a[m0 * k..(m0 + 1) * k];
        let a1 = &a[(m0 + 1) * k..(m0 + 2) * k];
        let a2 = &a[(m0 + 2) * k..(m0 + 3) * k];
        let a3 = &a[(m0 + 3) * k..(m0 + 4) * k];
        let b0 = bias[m0];
        let b1 = bias[m0 + 1];
        let b2 = bias[m0 + 2];
        let b3 = bias[m0 + 3];

        let (c_r01, c_r23) = c_chunk[m_local * n..(m_local + 4) * n].split_at_mut(2 * n);
        let (c0, c1) = c_r01.split_at_mut(n);
        let (c2, c3) = c_r23.split_at_mut(n);

        let mut n0 = 0usize;
        while n0 + N_TILE <= n {
            let mut acc0 = [b0; N_TILE];
            let mut acc1 = [b1; N_TILE];
            let mut acc2 = [b2; N_TILE];
            let mut acc3 = [b3; N_TILE];

            for ki in 0..k {
                let w0 = a0[ki];
                let w1 = a1[ki];
                let w2 = a2[ki];
                let w3 = a3[ki];
                let brow = &b[ki * n + n0..ki * n + n0 + N_TILE];
                for j in 0..N_TILE {
                    let bv = brow[j];
                    acc0[j] += w0 * bv;
                    acc1[j] += w1 * bv;
                    acc2[j] += w2 * bv;
                    acc3[j] += w3 * bv;
                }
            }

            let out0 = &mut c0[n0..n0 + N_TILE];
            let out1 = &mut c1[n0..n0 + N_TILE];
            let out2 = &mut c2[n0..n0 + N_TILE];
            let out3 = &mut c3[n0..n0 + N_TILE];
            for j in 0..N_TILE {
                out0[j] = acc0[j].clamp(lo, hi);
                out1[j] = acc1[j].clamp(lo, hi);
                out2[j] = acc2[j].clamp(lo, hi);
                out3[j] = acc3[j].clamp(lo, hi);
            }
            n0 += N_TILE;
        }

        if n0 < n {
            let rem = n - n0;
            for j in 0..rem {
                c0[n0 + j] = b0;
                c1[n0 + j] = b1;
                c2[n0 + j] = b2;
                c3[n0 + j] = b3;
            }
            for ki in 0..k {
                let w0 = a0[ki];
                let w1 = a1[ki];
                let w2 = a2[ki];
                let w3 = a3[ki];
                let brow = &b[ki * n + n0..ki * n + n];
                for j in 0..rem {
                    let bv = brow[j];
                    c0[n0 + j] += w0 * bv;
                    c1[n0 + j] += w1 * bv;
                    c2[n0 + j] += w2 * bv;
                    c3[n0 + j] += w3 * bv;
                }
            }
            for j in 0..rem {
                c0[n0 + j] = c0[n0 + j].clamp(lo, hi);
                c1[n0 + j] = c1[n0 + j].clamp(lo, hi);
                c2[n0 + j] = c2[n0 + j].clamp(lo, hi);
                c3[n0 + j] = c3[n0 + j].clamp(lo, hi);
            }
        }

        m_local += 4;
    }

    while m_local < rows {
        let m0 = m_start + m_local;
        let a0 = &a[m0 * k..(m0 + 1) * k];
        let b0 = bias[m0];
        let c0 = &mut c_chunk[m_local * n..(m_local + 1) * n];
        c0.fill(b0);
        for ki in 0..k {
            let w0 = a0[ki];
            let brow = &b[ki * n..(ki + 1) * n];
            for j in 0..n {
                c0[j] += w0 * brow[j];
            }
        }
        for v in c0.iter_mut() {
            *v = v.clamp(lo, hi);
        }
        m_local += 1;
    }
}

fn pixel_unshuffle_4(rgb: &Tensor3D) -> Tensor3D {
    let c = rgb.c;
    let oh = rgb.h / 4;
    let ow = rgb.w / 4;
    let mut out = Tensor3D::zeros(c * 16, oh, ow);
    for ch in 0..c {
        let src_ch = &rgb.data[ch * rgb.h * rgb.w..(ch + 1) * rgb.h * rgb.w];
        for dy in 0..4 {
            for dx in 0..4 {
                let oc = (ch * 4 + dy) * 4 + dx;
                let dst_ch = &mut out.data[oc * oh * ow..(oc + 1) * oh * ow];
                for y in 0..oh {
                    let sy = y * 4 + dy;
                    let src_row = &src_ch[sy * rgb.w..sy * rgb.w + rgb.w];
                    let dst_row = &mut dst_ch[y * ow..(y + 1) * ow];
                    for x in 0..ow {
                        dst_row[x] = src_row[x * 4 + dx];
                    }
                }
            }
        }
    }
    out
}

fn avg_pool2d_4(mask: &Tensor3D) -> Tensor3D {
    let c = mask.c;
    let oh = mask.h / 4;
    let ow = mask.w / 4;
    let mut out = Tensor3D::zeros(c, oh, ow);
    for ch in 0..c {
        let src_ch = &mask.data[ch * mask.h * mask.w..(ch + 1) * mask.h * mask.w];
        let dst_ch = &mut out.data[ch * oh * ow..(ch + 1) * oh * ow];
        for y in 0..oh {
            for x in 0..ow {
                let mut sum = 0.0f32;
                for dy in 0..4 {
                    let row = &src_ch[(y * 4 + dy) * mask.w..];
                    for dx in 0..4 {
                        sum += row[x * 4 + dx];
                    }
                }
                dst_ch[y * ow + x] = sum * (1.0 / 16.0);
            }
        }
    }
    out
}

fn nearest_2x_scaled(x: &Tensor3D, gain: f32) -> Tensor3D {
    let oh = x.h * 2;
    let ow = x.w * 2;
    let mut out = Tensor3D::zeros(x.c, oh, ow);
    for ch in 0..x.c {
        let src_ch = &x.data[ch * x.h * x.w..(ch + 1) * x.h * x.w];
        let dst_ch = &mut out.data[ch * oh * ow..(ch + 1) * oh * ow];
        for y in 0..x.h {
            let src_row = &src_ch[y * x.w..(y + 1) * x.w];
            let (r0, r1) = dst_ch[(y * 2) * ow..(y * 2 + 2) * ow].split_at_mut(ow);
            for x_i in 0..x.w {
                let v = src_row[x_i] * gain;
                r0[x_i * 2] = v;
                r0[x_i * 2 + 1] = v;
                r1[x_i * 2] = v;
                r1[x_i * 2 + 1] = v;
            }
        }
    }
    out
}

fn max_pool2d_2(x: &Tensor3D) -> Tensor3D {
    let oh = x.h / 2;
    let ow = x.w / 2;
    let mut out = Tensor3D::zeros(x.c, oh, ow);
    for ch in 0..x.c {
        let src_ch = &x.data[ch * x.h * x.w..(ch + 1) * x.h * x.w];
        let dst_ch = &mut out.data[ch * oh * ow..(ch + 1) * oh * ow];
        for y in 0..oh {
            let r0 = &src_ch[(y * 2) * x.w..(y * 2 + 1) * x.w];
            let r1 = &src_ch[(y * 2 + 1) * x.w..(y * 2 + 2) * x.w];
            let dst_row = &mut dst_ch[y * ow..(y + 1) * ow];
            for x_i in 0..ow {
                let v0 = r0[x_i * 2].max(r0[x_i * 2 + 1]);
                let v1 = r1[x_i * 2].max(r1[x_i * 2 + 1]);
                dst_row[x_i] = v0.max(v1);
            }
        }
    }
    out
}

/// Forward pass of `StyleTransNet` (`styletrans_net.py`).
fn run_styletrans_net(
    arch: &WeightArchive,
    rgb: &Tensor3D,
    mask: &Tensor3D,
) -> Result<Tensor3D, String> {
    let unshuf = pixel_unshuffle_4(rgb); // [48, H/4, W/4]
    let mpool = avg_pool2d_4(mask); // [1, H/4, W/4]
    let pad_zeros = Tensor3D::zeros(64 - 49, unshuf.h, unshuf.w);
    let x = Tensor3D::concat(&[&unshuf, &mpool, &pad_zeros]); // [64, 216, 280]

    let conv = |name: &str, inp: &Tensor3D| -> Result<Tensor3D, String> {
        Ok(conv2d_clamped(inp, arch.get(name)?, true))
    };

    let rdb = |pre: &str, inp: &Tensor3D| -> Result<Tensor3D, String> {
        let a = inp.slice_channels(0, 32);
        let b = inp.slice_channels(32, 64);
        let mut h = a.clone();
        for suffix in [
            "block1_conv1",
            "block1_conv2",
            "block2_conv1",
            "block2_conv2",
            "conv",
        ] {
            h = conv(&format!("{pre}_{suffix}"), &h)?;
        }
        let ha = Tensor3D::concat(&[&h, &a]);
        let f = conv(&format!("{pre}_fixed_conv_conv"), &ha)?;
        let bf = Tensor3D::concat(&[&b, &f]);
        conv(&format!("{pre}_conv_out"), &bf)
    };

    let feat = conv("conv_first", &x)?;
    let mut h = feat.clone();
    for i in 0..20 {
        let p = format!("body_{i}");
        let r1 = rdb(&format!("{p}_rdb1"), &h)?;
        let xr1 = Tensor3D::concat(&[&h, &r1]);
        let c1 = conv(&format!("{p}_conv1"), &xr1)?;
        let r2 = rdb(&format!("{p}_rdb2"), &c1)?;
        let xr1r2 = Tensor3D::concat(&[&h, &r1, &r2]);
        let c2 = conv(&format!("{p}_conv2"), &xr1r2)?;
        let r3 = rdb(&format!("{p}_rdb3"), &c2)?;
        let r3x = Tensor3D::concat(&[&r3, &h]);
        h = conv(&format!("{p}_fixed_conv_conv"), &r3x)?;
    }

    h = conv("conv_body", &h)?;
    let h_feat = Tensor3D::concat(&[&h, &feat]);
    h = conv("fixed_conv_conv", &h_feat)?;
    h = conv("tail_conv_0", &h)?;
    h = nearest_2x_scaled(&h, arch.up1_gain);
    h = conv("tail_conv_1", &h)?;
    h = nearest_2x_scaled(&h, arch.up2_gain);
    h = conv("tail_conv_2", &h)?;
    let out = conv("tail_conv_last", &h)?;
    Ok(out.slice_channels(0, 3))
}

/// Forward pass of `ColorFixNet` (`colorfix_net.py`) on a single `544×544×6` tile.
fn run_colorfix_tile(arch: &WeightArchive, x6: &Tensor3D) -> Result<Tensor3D, String> {
    let pad2 = Tensor3D::zeros(2, x6.h, x6.w);
    let x8 = Tensor3D::concat(&[x6, &pad2]);

    let conv = |name: &str, inp: &Tensor3D| -> Result<Tensor3D, String> {
        Ok(conv2d_clamped(inp, arch.get(name)?, false))
    };

    let up_dcr = |name: &str, inp: &Tensor3D| -> Result<Tensor3D, String> {
        let y = conv(name, inp)?; // [4*C, h, w]
        let c = y.c / 4;
        let h = y.h;
        let w = y.w;
        let oh = h * 2;
        let ow = w * 2;
        let mut out = Tensor3D::zeros(c, oh, ow);
        // DCR phase: channel = (ay * 2 + bx) * C + ch
        for ch in 0..c {
            let dst_ch = &mut out.data[ch * oh * ow..(ch + 1) * oh * ow];
            for ay in 0..2 {
                for bx in 0..2 {
                    let ic = (ay * 2 + bx) * c + ch;
                    let src_ch = &y.data[ic * h * w..(ic + 1) * h * w];
                    for iy in 0..h {
                        let src_row = &src_ch[iy * w..(iy + 1) * w];
                        let dst_row = &mut dst_ch[(iy * 2 + ay) * ow..(iy * 2 + ay + 1) * ow];
                        for ix in 0..w {
                            dst_row[ix * 2 + bx] = src_row[ix];
                        }
                    }
                }
            }
        }
        Ok(out)
    };

    let s1 = conv("layer1_net_3", &conv("layer1_net_0", &x8)?)?;
    let mut skips = vec![s1.clone()];
    let mut h = s1;
    for l in [2, 3, 4, 5] {
        h = max_pool2d_2(&h);
        let h0 = conv(&format!("layer{l}_net_1_net_0"), &h)?;
        h = conv(&format!("layer{l}_net_1_net_3"), &h0)?;
        skips.push(h.clone());
    }

    for (l, sk_idx) in [(6, 3), (7, 2), (8, 1), (9, 0)] {
        let u = up_dcr(&format!("layer{l}_upsample"), &h)?;
        let cat = Tensor3D::concat(&[&skips[sk_idx], &u]);
        let h0 = conv(&format!("layer{l}_conv_net_0"), &cat)?;
        h = conv(&format!("layer{l}_conv_net_3"), &h0)?;
    }

    let h10 = conv("layer10", &h)?;
    let h11 = conv("layer11", &h10)?;
    conv("layer12", &h11)
}

// ---------------------------------------------------------------------------
// Image geometry helpers (OpenCV-compatible BORDER_REFLECT_101, BORDER_REFLECT, INTER_AREA)
// ---------------------------------------------------------------------------

#[inline]
fn reflect_101(mut p: isize, len: usize) -> usize {
    if len <= 1 {
        return 0;
    }
    let max_idx = (len - 1) as isize;
    while p < 0 || p > max_idx {
        if p < 0 {
            p = -p;
        }
        if p > max_idx {
            p = 2 * max_idx - p;
        }
    }
    p as usize
}

#[inline]
fn reflect_border(mut p: isize, len: usize) -> usize {
    if len <= 1 {
        return 0;
    }
    let n = len as isize;
    while p < 0 || p >= n {
        if p < 0 {
            p = -p - 1;
        }
        if p >= n {
            p = 2 * n - p - 1;
        }
    }
    p as usize
}

fn pad_center_reflect_101_u8(
    img: &[u8],
    h: usize,
    w: usize,
    dst_w: usize,
    dst_h: usize,
) -> (Vec<u8>, usize, usize) {
    let dh = dst_h - h;
    let dw = dst_w - w;
    let top = dh / 2;
    let left = dw / 2;
    let mut out = vec![0u8; dst_h * dst_w * 3];
    for dy in 0..dst_h {
        let sy = reflect_101(dy as isize - top as isize, h);
        let dst_row = &mut out[dy * dst_w * 3..(dy + 1) * dst_w * 3];
        let src_row = &img[sy * w * 3..(sy + 1) * w * 3];
        for dx in 0..dst_w {
            let sx = reflect_101(dx as isize - left as isize, w);
            dst_row[dx * 3..dx * 3 + 3].copy_from_slice(&src_row[sx * 3..sx * 3 + 3]);
        }
    }
    (out, top, left)
}

fn pad_reflect_u8(img: &[u8], h: usize, w: usize, pad: usize) -> Vec<u8> {
    let oh = h + 2 * pad;
    let ow = w + 2 * pad;
    let mut out = vec![0u8; oh * ow * 3];
    for dy in 0..oh {
        let sy = reflect_border(dy as isize - pad as isize, h);
        let dst_row = &mut out[dy * ow * 3..(dy + 1) * ow * 3];
        let src_row = &img[sy * w * 3..(sy + 1) * w * 3];
        for dx in 0..ow {
            let sx = reflect_border(dx as isize - pad as isize, w);
            dst_row[dx * 3..dx * 3 + 3].copy_from_slice(&src_row[sx * 3..sx * 3 + 3]);
        }
    }
    out
}

/// Resize 3-channel `u8` image using area averaging for downsampling and OpenCV `INTER_AREA`
/// (which equals bilinear with pixel-box overlap) for upsampling.
fn resize_area_u8(src: &[u8], sh: usize, sw: usize, dh: usize, dw: usize) -> Vec<u8> {
    if sh == dh && sw == dw {
        return src.to_vec();
    }
    // Exact 4x downsample fast path (`4096x3072 -> 1024x768`)
    if sh == dh * 4 && sw == dw * 4 {
        let mut out = vec![0u8; dh * dw * 3];
        for dy in 0..dh {
            for dx in 0..dw {
                let mut r = 0u32;
                let mut g = 0u32;
                let mut b = 0u32;
                for ky in 0..4 {
                    let row = &src[((dy * 4 + ky) * sw + dx * 4) * 3..];
                    for kx in 0..4 {
                        r += row[kx * 3] as u32;
                        g += row[kx * 3 + 1] as u32;
                        b += row[kx * 3 + 2] as u32;
                    }
                }
                let idx = (dy * dw + dx) * 3;
                out[idx] = ((r + 8) >> 4) as u8;
                out[idx + 1] = ((g + 8) >> 4) as u8;
                out[idx + 2] = ((b + 8) >> 4) as u8;
            }
        }
        return out;
    }

    // General box-filter / INTER_AREA resize
    let scale_y = sh as f32 / dh as f32;
    let scale_x = sw as f32 / dw as f32;
    let mut out = vec![0u8; dh * dw * 3];

    if scale_x <= 1.0 && scale_y <= 1.0 {
        // Upsampling: OpenCV INTER_AREA maps destination pixel [dy, dy+1] to source cell edge
        let inv_scale_y = 1.0 / scale_y;
        let inv_scale_x = 1.0 / scale_x;
        for dy in 0..dh {
            let sy = (dy / (inv_scale_y as usize)).min(sh - 1);
            let fy = {
                let rem = (dy as f32 + 1.0) - (sy as f32 + 1.0) * inv_scale_y;
                if rem <= 0.0 {
                    0.0
                } else {
                    rem.min(1.0)
                }
            };
            let sy1 = (sy + 1).min(sh - 1);
            for dx in 0..dw {
                let sx = (dx / (inv_scale_x as usize)).min(sw - 1);
                let fx = {
                    let rem = (dx as f32 + 1.0) - (sx as f32 + 1.0) * inv_scale_x;
                    if rem <= 0.0 {
                        0.0
                    } else {
                        rem.min(1.0)
                    }
                };
                let sx1 = (sx + 1).min(sw - 1);
                let w00 = (1.0 - fx) * (1.0 - fy);
                let w01 = fx * (1.0 - fy);
                let w10 = (1.0 - fx) * fy;
                let w11 = fx * fy;
                let p00 = &src[(sy * sw + sx) * 3..];
                let p01 = &src[(sy * sw + sx1) * 3..];
                let p10 = &src[(sy1 * sw + sx) * 3..];
                let p11 = &src[(sy1 * sw + sx1) * 3..];
                let dst = &mut out[(dy * dw + dx) * 3..];
                for c in 0..3 {
                    let v = w00 * p00[c] as f32
                        + w01 * p01[c] as f32
                        + w10 * p10[c] as f32
                        + w11 * p11[c] as f32;
                    dst[c] = (v + 0.5).clamp(0.0, 255.0) as u8;
                }
            }
        }
        return out;
    }

    // General area-averaging downsample
    for dy in 0..dh {
        let fs_y1 = dy as f32 * scale_y;
        let fs_y2 = fs_y1 + scale_y;
        let sy1 = fs_y1.ceil() as usize;
        let sy2 = fs_y2.floor() as usize;
        for dx in 0..dw {
            let fs_x1 = dx as f32 * scale_x;
            let fs_x2 = fs_x1 + scale_x;
            let sx1 = fs_x1.ceil() as usize;
            let sx2 = fs_x2.floor() as usize;
            let mut acc = [0.0f32; 3];
            let mut wsum = 0.0f32;

            let y_start = fs_y1.floor() as usize;
            let y_end = (fs_y2.ceil() as usize).min(sh);
            let x_start = fs_x1.floor() as usize;
            let x_end = (fs_x2.ceil() as usize).min(sw);

            for y in y_start..y_end {
                let wy = if y < sy1 {
                    sy1 as f32 - fs_y1
                } else if y >= sy2 {
                    fs_y2 - sy2 as f32
                } else {
                    1.0
                };
                for x in x_start..x_end {
                    let wx = if x < sx1 {
                        sx1 as f32 - fs_x1
                    } else if x >= sx2 {
                        fs_x2 - sx2 as f32
                    } else {
                        1.0
                    };
                    let w = wy * wx;
                    let p = &src[(y * sw + x) * 3..];
                    acc[0] += p[0] as f32 * w;
                    acc[1] += p[1] as f32 * w;
                    acc[2] += p[2] as f32 * w;
                    wsum += w;
                }
            }
            let inv = if wsum > 0.0 { 1.0 / wsum } else { 0.0 };
            let dst = &mut out[(dy * dw + dx) * 3..];
            dst[0] = (acc[0] * inv + 0.5).clamp(0.0, 255.0) as u8;
            dst[1] = (acc[1] * inv + 0.5).clamp(0.0, 255.0) as u8;
            dst[2] = (acc[2] * inv + 0.5).clamp(0.0, 255.0) as u8;
        }
    }
    out
}

fn resize_bilinear_u8(src: &[u8], sh: usize, sw: usize, dh: usize, dw: usize) -> Vec<u8> {
    if sh == dh && sw == dw {
        return src.to_vec();
    }
    let scale_y = sh as f32 / dh as f32;
    let scale_x = sw as f32 / dw as f32;
    let mut out = vec![0u8; dh * dw * 3];
    for dy in 0..dh {
        let fy = ((dy as f32 + 0.5) * scale_y - 0.5).clamp(0.0, (sh - 1) as f32);
        let y0 = fy.floor() as usize;
        let y1 = (y0 + 1).min(sh - 1);
        let wy = fy - y0 as f32;
        for dx in 0..dw {
            let fx = ((dx as f32 + 0.5) * scale_x - 0.5).clamp(0.0, (sw - 1) as f32);
            let x0 = fx.floor() as usize;
            let x1 = (x0 + 1).min(sw - 1);
            let wx = fx - x0 as f32;
            let p00 = &src[(y0 * sw + x0) * 3..];
            let p01 = &src[(y0 * sw + x1) * 3..];
            let p10 = &src[(y1 * sw + x0) * 3..];
            let p11 = &src[(y1 * sw + x1) * 3..];
            let dst = &mut out[(dy * dw + dx) * 3..];
            for c in 0..3 {
                let v = (1.0 - wy) * ((1.0 - wx) * p00[c] as f32 + wx * p01[c] as f32)
                    + wy * ((1.0 - wx) * p10[c] as f32 + wx * p11[c] as f32);
                dst[c] = (v + 0.5).clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

fn rot90_cw_f32(rgb: &[f32], h: usize, w: usize) -> (Vec<f32>, usize, usize) {
    // np.rot90(rgb, -1): 90 deg clockwise -> new shape (w, h), new[x, h - 1 - y] = old[y, x]
    let mut out = vec![0.0f32; h * w * 3];
    for y in 0..h {
        for x in 0..w {
            let ny = x;
            let nx = h - 1 - y;
            let src = (y * w + x) * 3;
            let dst = (ny * h + nx) * 3;
            out[dst..dst + 3].copy_from_slice(&rgb[src..src + 3]);
        }
    }
    (out, w, h)
}

fn rot90_ccw_f32(rgb: &[f32], h: usize, w: usize) -> (Vec<f32>, usize, usize) {
    // np.rot90(rgb, 1): 90 deg counter-clockwise -> new shape (w, h), new[w - 1 - x, y] = old[y, x]
    let mut out = vec![0.0f32; h * w * 3];
    for y in 0..h {
        for x in 0..w {
            let ny = w - 1 - x;
            let nx = y;
            let src = (y * w + x) * 3;
            let dst = (ny * h + nx) * 3;
            out[dst..dst + 3].copy_from_slice(&rgb[src..src + 3]);
        }
    }
    (out, w, h)
}

/// Run the full `StyleTrans` + `ColorFix` pipeline on an image (`rgb` in `[0, 1]`, shape `H × W × 3`).
pub fn run_styletrans(
    rgb: &[f32],
    width: usize,
    height: usize,
    lux_index: f32,
    cct: f32,
) -> Result<Vec<f32>, String> {
    let portrait = height > width;
    let (x, h0, w0) = if portrait {
        rot90_cw_f32(rgb, height, width)
    } else {
        (rgb.to_vec(), height, width)
    };

    let mut x8: Vec<u8> = x
        .iter()
        .map(|&v| (v * 255.0 + 0.5).clamp(0.0, 255.0) as u8)
        .collect();

    let (h1, w1) = if h0 > H4K || w0 > W4K {
        let s = (W4K as f32 / w0 as f32).min(H4K as f32 / h0 as f32);
        let nw = ((w0 as f32 * s) as usize).max(1);
        let nh = ((h0 as f32 * s) as usize).max(1);
        x8 = resize_area_u8(&x8, h0, w0, nh, nw);
        (nh, nw)
    } else {
        (h0, w0)
    };

    let (big, top, left) = pad_center_reflect_101_u8(&x8, h1, w1, W4K, H4K);
    let small = resize_area_u8(&big, H4K, W4K, NH, NW);
    let rgbp = pad_reflect_u8(&small, NH, NW, PAD);

    let ph = NH + 2 * PAD; // 864
    let pw = NW + 2 * PAD; // 1120
    let mut rgb_tensor = Tensor3D::zeros(3, ph, pw);
    for i in 0..(ph * pw) {
        rgb_tensor.data[i] = (rgbp[i * 3] as f32 - 128.0) / 127.5;
        rgb_tensor.data[ph * pw + i] = (rgbp[i * 3 + 1] as f32 - 128.0) / 127.5;
        rgb_tensor.data[2 * ph * pw + i] = (rgbp[i * 3 + 2] as f32 - 128.0) / 127.5;
    }
    // Zero humanseg mask `(0 - 128.0) / 127.5`
    let mut mask_tensor = Tensor3D::zeros(1, ph, pw);
    mask_tensor.data.fill(-128.0 / 127.5);

    let model_name = if lux_index > 260.0 && cct < 4692.0 {
        "low"
    } else {
        "high"
    };
    let st_arch = get_archive(model_name)?;
    let out_tensor = run_styletrans_net(st_arch, &rgb_tensor, &mask_tensor)?;

    // Crop Rect(PAD, PAD, NW, NH) and requantize to u8
    let mut styled = vec![0u8; NH * NW * 3];
    for y in 0..NH {
        let sy = y + PAD;
        for x_i in 0..NW {
            let sx = x_i + PAD;
            let s_idx = sy * pw + sx;
            let d_idx = (y * NW + x_i) * 3;
            for c in 0..3 {
                let v = out_tensor.data[c * ph * pw + s_idx] * 127.5 + 128.0;
                styled[d_idx + c] = v.round().clamp(0.0, 255.0) as u8;
            }
        }
    }

    let up = resize_area_u8(&styled, NH, NW, H4K, W4K);
    let cf_arch = get_archive("colorfix")?;

    // Collect only the 512x512 tiles that overlap the active [top..top+h1, left..left+w1] crop
    let mut tile_coords = Vec::new();
    for ty in (0..H4K).step_by(STEP) {
        let th = STEP.min(H4K - ty);
        if ty + th <= top || ty >= top + h1 {
            continue;
        }
        for tx in (0..W4K).step_by(STEP) {
            let tw = STEP.min(W4K - tx);
            if tx + tw <= left || tx >= left + w1 {
                continue;
            }
            tile_coords.push((ty, tx, th, tw));
        }
    }

    // Run ColorFixNet tiles in parallel across CPU threads
    let n_threads = std::thread::available_parallelism()
        .map(|p| p.get().min(8))
        .unwrap_or(4)
        .min(tile_coords.len().max(1));
    let mut tile_outputs: Vec<Vec<u8>> = vec![Vec::new(); tile_coords.len()];
    let chunk_size = tile_coords.len().div_ceil(n_threads).max(1);

    std::thread::scope(|s| {
        for (coords_chunk, out_chunk) in tile_coords
            .chunks(chunk_size)
            .zip(tile_outputs.chunks_mut(chunk_size))
        {
            let big_ref = &big;
            let up_ref = &up;
            s.spawn(move || {
                for (&(ty, tx, th, tw), slot) in coords_chunk.iter().zip(out_chunk.iter_mut()) {
                    let ys = ty.saturating_sub(MARGIN);
                    let xs = tx.saturating_sub(MARGIN);
                    let ye = (ty + STEP + MARGIN).min(H4K);
                    let xe = (tx + STEP + MARGIN).min(W4K);
                    let oy = MARGIN - (ty - ys);
                    let ox = MARGIN - (tx - xs);

                    // Fill [6, 544, 544] in [-1, 1] (zero-padded pixels map to -128.0 / 127.5)
                    let mut x6 = Tensor3D {
                        c: 6,
                        h: TILE,
                        w: TILE,
                        data: vec![-128.0 / 127.5; 6 * TILE * TILE],
                    };
                    let plane = TILE * TILE;
                    for r in 0..(ye - ys) {
                        let sy = ys + r;
                        let dy = oy + r;
                        for c_i in 0..(xe - xs) {
                            let sx = xs + c_i;
                            let dx = ox + c_i;
                            let s_idx = (sy * W4K + sx) * 3;
                            let d_idx = dy * TILE + dx;
                            for ch in 0..3 {
                                x6.data[ch * plane + d_idx] =
                                    (up_ref[s_idx + ch] as f32 - 128.0) / 127.5;
                                x6.data[(ch + 3) * plane + d_idx] =
                                    (big_ref[s_idx + ch] as f32 - 128.0) / 127.5;
                            }
                        }
                    }

                    if let Ok(y_tile) = run_colorfix_tile(cf_arch, &x6) {
                        let mut patch = vec![0u8; th * tw * 3];
                        for r in 0..th {
                            let sy = MARGIN + r;
                            for c_i in 0..tw {
                                let sx = MARGIN + c_i;
                                let s_idx = sy * TILE + sx;
                                let d_idx = (r * tw + c_i) * 3;
                                for ch in 0..3 {
                                    let v = y_tile.data[ch * plane + s_idx] * 127.5 + 128.0;
                                    patch[d_idx + ch] = v.round().clamp(0.0, 255.0) as u8;
                                }
                            }
                        }
                        *slot = patch;
                    }
                }
            });
        }
    });

    // Assemble active crop `[top..top+h1, left..left+w1]`
    let mut fixed_crop = vec![0u8; h1 * w1 * 3];
    for (&(ty, tx, th, tw), patch) in tile_coords.iter().zip(tile_outputs.iter()) {
        if patch.is_empty() {
            continue;
        }
        let iy0 = ty.max(top);
        let iy1 = (ty + th).min(top + h1);
        let ix0 = tx.max(left);
        let ix1 = (tx + tw).min(left + w1);
        for y in iy0..iy1 {
            let py = y - ty;
            let cy = y - top;
            let src_row = &patch[(py * tw + (ix0 - tx)) * 3..(py * tw + (ix1 - tx)) * 3];
            let dst_row = &mut fixed_crop[(cy * w1 + (ix0 - left)) * 3..(cy * w1 + (ix1 - left)) * 3];
            dst_row.copy_from_slice(src_row);
        }
    }

    let res_u8 = if (h1, w1) != (h0, w0) {
        resize_bilinear_u8(&fixed_crop, h1, w1, h0, w0)
    } else {
        fixed_crop
    };

    let res_f32: Vec<f32> = res_u8.iter().map(|&v| v as f32 / 255.0).collect();
    if portrait {
        Ok(rot90_ccw_f32(&res_f32, h0, w0).0)
    } else {
        Ok(res_f32)
    }
}
