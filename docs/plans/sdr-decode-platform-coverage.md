# SDR 解码兜底：平台覆盖计划

## 背景

`sdr_source::decode_to_rgb` 目前只用 `heif-oxide`，它底层的 `rust_h265` **只支持 4:2:0**。
iPhone 截图（1170×2532）等文件是 **HEVC Rext 4:4:4 10-bit**，直接失败：

```
Codec("Unsupported(\"only 4:2:0 (chroma_format_idc=1) supported\")")
```

用户实测文件：`/Users/beet/Downloads/IMG_0008/IMG_0008.HEIC`（1170×2532 截图）。

样本教训：42/42 的解码成功率来自**纯相机照片语料**（都是 4:2:0），
所以覆盖率评估失真。截图 / 修图软件导出 / 4:4:4 导出都要单独测。

## 平台解码能力矩阵

需要覆盖的平台（`apps/flutter/` 下存在的 runner）：
iOS / macOS / Android / Windows / ohos

| 平台 | Flutter `instantiateImageCodec` | 平台专用 API |
|---|---|---|
| iOS | ✓ 已实测（本会话 app 路径解码华为 HEIC 成功）| ImageIO（`encodeHEIC` 通道已在）|
| macOS | ✓ | ImageIO |
| Android | ✓ API 28+（Skia 委托平台 HEIF 解码器）| MediaCodec / BitmapFactory |
| ohos | 很可能 ✓（用系统解码器）| 待确认 |
| **Windows** | ✗ Skia 默认不带 HEIF | **WIC + HEIF 扩展**（Store 附加包，非默认安装）|

结论：**Windows 是唯一没有可靠平台解码器的目标平台。**

## 两阶段方案

### 阶段 1 — 平台解码兜底（覆盖 iOS/macOS/Android/ohos）

Rust 主路径失败时回退到 Flutter 引擎解码，把像素交回 Rust 重建容器。

1. **Rust 侧标记可兜底的失败**
   `sdr_fallback` 的错误信息加前缀 `DECODE_FALLBACK:`，让 Dart 能区分
   「编码不支持」与真正的错误（如 Exif/scaffold 失败），避免误重试。

2. **恢复 RGBA FFI（仅作兜底，不再作主路径）**
   `xdremux_convert_sdr_rgba(input_path, rgba, w, h, output_path, config)`
   —— 之前实现过又被删掉，`git log` 里有现成代码（commit `66ae811` 之前）。
   内部：丢 alpha → `synthesize_source_container_from_rgb`
   → 未改动的转换管线（Exif 从 `input_path` 读、剥 MakerNote、方向归一化）。

3. **Dart 侧兜底**
   `RustConversionBackend.convert`：转换失败且开风格且错误含 `DECODE_FALLBACK:`
   → `decodeImageToRgba(inputPath)` → 用 `convertSdrRgba` 再跑一次。
   解码在主 isolate（`ui.Image` 不可跨 isolate），只把 buffer 传进转换 isolate。

4. **iOS/macOS 链接器**
   `-Wl,-u,_xdremux_convert_sdr_rgba` 要加回
   `apps/flutter/ios/Runner.xcodeproj/project.pbxproj`（dead-strip 保留）。

**验收**：`IMG_0008.HEIC` 在 iOS/macOS/Android 上转换成功且风格可用。

### 阶段 2 — Windows（以及彻底移除平台依赖）

Windows 没有可靠的 HEIF 解码器，两条路：

- **WIC 平台通道**：`windows/runner` 加 C++ 通道调 WIC。
  依赖用户装了「HEIF 图像扩展」（免费但需手动安装）→ 不可靠。
- **Rust 内置解码器（推荐）**：vendor `libde265`（LGPL，支持 4:2:0/4:2:2/4:4:4
  8/10/12-bit），沿用项目已有的 C 依赖构建方式（`build.rs` + cmake，x265 已是先例）。
  容器解析用现有的 `isobmff`：取 tile + hvcC → libde265 逐 tile 解码 → 拼 grid
  → 色度上采样/位深转换 → RGB。

  这条路能同时**消除所有平台解码依赖**，让 Windows 和其他平台完全一致。

**验收**：Windows 上 `IMG_0008.HEIC` 转换成功；Rust 解码覆盖 4:2:0/4:2:2/4:4:4。

## 测试语料（必须包含，当前缺）

- iPhone 截图（4:4:4 10-bit）— `~/Downloads/IMG_0008/IMG_0008.HEIC`
- 修图软件导出的 HEIC
- 10-bit 4:2:0（heif-oxide 的 `Rgb16` 分支）
- 无 Exif 的 PNG / JPEG（已修，见 `minimal_exif_tiff`）
- 各厂商相机照片（4:2:0 基线）
