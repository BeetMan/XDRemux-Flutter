# XDRemux 转换逻辑

本文档描述 XDRemux 从 OPPO ProXDR HEIC 转 ISO 21496-1 HDR HEIC 的完整判断与转换逻辑。所有行为均已用真实设备样本（Ace 3 / X6 Pro / X7 Ultra / X8 Ultra）验证，并对齐最新 Swift 原版（GitHub `21Z121Z1/XDRemux`）。

## 1. LHDR / UHDR 判断

入口：`container::extract_lhdr_from_bytes`（[xdremux/rust/src/container.rs](../xdremux/rust/src/container.rs)）。根据 OPPO 私有尾部 manifest 的**条目名**决定 mode，与设备型号无关。

**Step 1 — UHDR 优先**：解析 manifest，**同时存在**以下两个条目才判定为 UHDR：
- `local.uhdr.gainmap.info`（≥20 个 float 的元数据块）
- `local.uhdr.gainmap.data`（RGB 增益图 JPEG）

→ `mode = "uhdr"`。

**Step 2 — LHDR**：无 UHDR 条目时走 LHDR：
1. **float144 扫描**：找 `144.0f32` 魔数 → 读 144 字节 → `score_lhdr_meta` 打分（须 ≥10 且 `f[5] == -1`，防止压缩数据假阳性）
2. 失败则 **manifest 偏移**：找 `local.hdr.meta.data` 条目

→ `mode = "lhdr"`。

**两者都没有** → 报 `Failed to locate LHDR metadata block`（普通 HEIC、长曝光、无 HDR 等）。

**设备格式对照**（实测）：
- **LHDR**：Ace 3 移植相机、X6 Pro 原厂、X7 Ultra（manifest 含 `local.hdr.linear.mask` + `local.hdr.meta.data`）
- **UHDR**：X8 Ultra 原厂（manifest 含 `local.uhdr.gainmap.info` + `local.uhdr.gainmap.data`）

## 2. x6 / x7 family 判断

入口：`lib.rs`（[xdremux/rust/src/lib.rs](../xdremux/rust/src/lib.rs)）。

```rust
let family = if extracted.meta_floats[0] >= 3.0 || extracted.mode == "uhdr" {
    "x7"
} else {
    "x6"
};
```

- `meta_floats[0]` = **edr_version**（OPPO 元数据版本，**不是设备型号**）
- `edr_version ≥ 3.0` 或 UHDR → **x7**
- `edr_version < 3.0` → **x6**

**实际影响**（仅 LHDR reconstruct 时）：
- **x6**（`edr_version < 3`）：走 **knee 路径**。`getKneePoint(edr_scale)` 用三段 power-chain 公式（`scale*100`、`1/scale^0.4545`、`quantizedKnee`），Reinhard 曲线压缩增益。knee 公式与 Swift `EDRScaleResolver.getKneePoint` 逐字段一致。
- **x7**（`edr_version ≥ 3`）：**knee = 0**，纯 log2 线性路径（无压缩）。
- **UHDR**：恒为 x7，但不走 reconstruct（增益图预计算）。

**注意**：family 标签与设备型号是**巧合**（如 X7 Ultra 照片 `edr_version=3.9 ≥ 3` 所以标 x7），不表示按设备分。

## 3. clean（OPPO 兼容关）输出

**目标**：标准 ISO 21496-1 HDR，保留非 HDR 厂商尾。

| 环节 | 行为 |
|------|------|
| 增益图 profile | **Rext**（4），单通道 gray（LHDR）/ 3 通道 yuv444p（UHDR），**无 VUI** |
| LHDR 增益图来源 | mask → `gainmap::reconstruct`（Reinhard knee LUT 链，对齐 Swift `GainMapReconstructor`） |
| UHDR 增益图来源 | `local.uhdr.gainmap.data` JPEG 直接解码（预计算） |
| hvcC | array flags `0x40\|type`（匹配 libheif）；tile **纯 IDR**（参数集只在 hvcC） |
| pixi | 恒声明 RGB `03080808`（即使数据单色，匹配 pyref） |
| OPPO 尾 | 去除私有 HDR 条目（`local.hdr.*` / `local.uhdr.*`），保留非 HDR（watermark、transform 等） |
| XMP | 完整 `hdrgm` 命名空间 + 参数 |
| tmap | 62 字节 Apple baseline |

## 4. oppo（OPPO 兼容开）输出

**目标**：Main Still Picture 4:2:0 增益图 + 完整 OPPO 私有尾（OPPO 相册识别）。

| 环节 | 行为 |
|------|------|
| 增益图 profile | **Main Still Picture**（3），**4:2:0**（`yuvj420p`） |
| 增益图来源 | 与 clean 相同（LHDR reconstruct / UHDR 预计算），单通道复制成 RGB 后降 4:2:0 |
| hvcC | 声明 chroma = 1（4:2:0） |
| pixi | RGB |
| OPPO 尾 | **完整保留** QTI + manifest |
| XMP | **minimal**（仅日期，无 hdrgm，避免 OPPO 相册路由混乱） |
| tmap | 142 字节 ImageIO native |

## 5. 关系总结

```
输入 HEIC
  ├─ manifest 有 local.uhdr.* ? ── yes → UHDR 链路（恒 x7 family）
  └─ no → LHDR 链路（edr_version ≥3 → x7 / <3 → x6）
              └─ 两种链路都按 oppo_compat 开关输出 clean 或 oppo
```

## 6. 关键验证记录

- LHDR 增益图**必须走 reconstruct**，不能用 mask 像素直接当增益图（会偏亮）。用 Swift CLI `--debug-dir` 验证：x6 样本 mask（mean≈46）→ reconstruct → gainmap（≈31.5 全分辨率 / ≈5 编码后），与 Rust 一致。
- `edr_scale_calculator` 与 Swift `edrScaleCalculator` 一致（含早期 LHDR 路径、sigmoid/main 双路径），输出 clamp 到 `[1.0, 7.9]`。
- pyref（Python 移植）的 5 次多项式 knee 是**过时旧版**（edr>3 溢出算 74 万，勿参考）；Rust/Swift 用 `scale*100` 三段公式。
- X6P 全部 16 张 LHDR 源（edr 1.59–7.04，x6/x7 混合）批量验证：32 个转换全成功、输出结构完整（2 grid + auxC + tmap + hdrgm）。
- 已知限制：Google Photos 对 clean 模式的识别行为非标准（只认 libheif 编码的 hvcC），连 Swift 原版都不认；不影响 OPPO 相册 / iOS。详见记忆 `gainmap-encoding-requirements`。
