# SDR 解码兜底：平台覆盖计划

## 背景

**2026-10-05 状态**：默认构建仍使用 heif-oxide。Rust 核心新增可选
`libheif-decoder`，Windows x64 的非 4:2:0 SDR 解码和完整转换已验证；
尚未启用到 Flutter / GitHub 默认发行包，也未完成其他平台与真实失败截图验收。
下文两阶段方案保留为原始设计，最新执行结果见文末。

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

### 2026-10-05：第三方解码库 PoC 更新

Windows 本地对照已完成，详见 [codec 小验证](codec-library-poc-20261005.md)。
5 个本地 4:2:0 输入和合成 4:2:0 基线在 Rust / libheif 上均能解码；
合成 4:2:2 / 4:4:4 8-bit 在当前 `sdr_source::decode_to_rgb` 失败，libheif 1.23.4 + libde265 1.1.3 成功。
这为阶段 2 增加了 libheif 整体接入的候选路线；尚未决定替代 libde265-only，尚未接入生产。
真实失败截图 `IMG_0008.HEIC` 本机未找到，4:4:4 10-bit 真机回归仍未完成。
8-bit 合成结果不能代替该项验收；其他平台和完整色彩/辅助图保留同样未验证。

### 原定语料清单

- iPhone 截图（4:4:4 10-bit）— `~/Downloads/IMG_0008/IMG_0008.HEIC`
- 修图软件导出的 HEIC
- 10-bit 4:2:0（heif-oxide 的 `Rgb16` 分支）
- 无 Exif 的 PNG / JPEG（已修，见 `minimal_exif_tiff`）
- 各厂商相机照片（4:2:0 基线）

## 2026-10-05：Rust 核心兼容改进已实现

用户授权后采用 libheif 整体解析/解码的可选兜底，而非本轮重写 libde265-only
的 grid / 色彩转换。仅 heif-oxide 明确的 unsupported-chroma 错误触发重试；
其他损坏输入不重试，PQ / HLG 不走这个 SDR 入口。默认 features 为空。
JPEG 改进不依赖原生库，在默认 Rust 核心构建直接生效。

### 已完成

- [x] Apple gain-map JPEG v1/v2：解析 XMP / MakerNote 33、48 的真实 headroom。
- [x] ISO-only JPEG：解析 secondary APP2 packed rationals，保留颜色空间标记、
  负 gain-map min 和不同通道值；截断、重复、无效参数明确报错。
- [x] 普通 SDR JPEG identity / 既有 hdrgm XMP 回归；损坏的 HDR 元数据不得
  因开启 Styles 被静默替换为 SDR。
- [x] JPEG 软件转换与硬件 prepare 路径传递 gain-map 颜色空间标记；C ABI 布局不变。
- [x] 可选 libheif C++ / Rust 边界、所有权、尺寸/内存/线程限制与协作式取消。
- [x] 小图 Styles 尺寸检查、无 Exif / 仅 IFD0 的 ExifIFD 补齐；保留原始数据偏移。
- [x] 修复 `iloc` 非零 base_offset 应与 extent_offset 相加而非移位的问题。
- [x] 固定版本的 Windows shared-library 构建脚本、开发文档和可复跑验证工具。

### 实际验证

- `cargo test --workspace --lib`：217 passed，2 ignored，0 failed。
- `cargo test -p xdremux-core --lib --features libheif-decoder`：218 passed，2 ignored，0 failed。
- `cargo check --workspace --all-targets` 通过；Windows feature-on release 库与示例构建通过。
- 原 14 个输入复测：源文件哈希均未改变；4 个真实 HDR JPEG 的 8 组元数据
  （含 useBaseColorSpace）与 libultrahdr 2.0.2 参考值一致。
- 新增合成 4:2:2 / 4:4:4 8/10/12-bit：hvcC 确认位深，native fallback 的
  RGB8 哈希与 libheif 参考相同；4:2:0 主路径像素仍有差异，不能泛称全库一致。
- EXIF orientation=6 的非 4:2:0 样片：96×128，哈希与独立参考旋转结果一致；
  不把 libheif 未应用 EXIF 的 raw 输出直接当成显示方向基准。
- 实际 `xdremux_convert` FFI：12/12 转换成功、输出图结构有效、原图哈希不变。
  HDR JPEG 默认关闭 Styles，SDR 样片开启 Styles；4 个 JPEG 硬件 prepare 通过。
- Windows 原生依赖脚本从新目录完整运行成功，固定 libheif 1.23.4 / libde265 1.1.3。
- 最后重新构建默认 release 库 / 示例（无 native feature / DLL 路径），4/4 JPEG
  实际转换、图结构和硬件 prepare 通过，报告确认 `nativeFeature=false`。
- Research 比较逻辑 6 个测试、Python 语法检查、新增 Rust 文件 rustfmt 检查与
  scoped `git diff --check` 通过。已有 core warnings 和 2 个 ignored 测试未清理。

报告位于仓库外 `C:/Users/Beet/Documents/XDRemux-Flutter-logs/codec-poc-20261005/`：
`integration-01/report.json`、`integration-extended-02/report.json`、`e2e-06/report.json`、
`e2e-default-01/report.json`。
早期失败报告保留用于追溯，不覆盖为成功结果。构建方法见
[native 说明](../../tools/native/README.md)，详细研究记录见
[codec 实现记录](codec-library-poc-20261005.md)。

### 发布前仍待完成

- [ ] 真实 `IMG_0008.HEIC` / 截图、alpha / grid / ICC / nclx 和畸形输入扩充验收。
- [ ] Apple JPEG 强制开启 Styles：两张参考样片仍因不透明 MakerNote 扩展被拒绝；
  不能靠删除未知 Apple 数据绕过，HDR 转换成功不代表该项完成。
- [ ] macOS / iOS / Android / OHOS 的目标 ABI 构建、包内依赖、签名、加载路径与真机。
- [ ] Flutter / CI 发行打包、性能/包体与 LGPL 分发义务审查；之后才能考虑默认启用。
- [ ] HDR 像素/色彩准确性、Apple Photos 与各目标相册的人像 / Live 验收。

本轮不修改签名配置、不改变 0.4.3 版本号、不提交/推送/发版。

## 2026-10-05：Windows 本地便携测试包

用户授权先打 Windows 测试版；本轮仅生成本地 x64 ZIP，不创建 Release、
不安装/覆盖正式版。App 版本保留 `0.4.3+37`，测试身份由包名与说明标记。

### 已完成

- [x] 独立 `target/windows-libheif-test` 构建 feature-on Rust DLL，避免覆盖默认 core 产物。
- [x] Windows CMake 显式环境变量选择 DLL / prefix，复制 heif、libde265、
  原生许可文件和 app-local MSVC runtime；正式 CI 未默认启用。
- [x] JNI 仅过滤到 build 目录副本，Flutter 生成源文件保持不变，不引入桌面 JVM。
- [x] Flutter 3.44.5 / VS 2026 x64 Release 构建通过。
- [x] 包内应用 Dart FFI 回归 12/12：转换、ISO 输出、请求 Styles 的输出验证、
  原图 SHA-256 均通过；不依赖 codec-prefix / Flutter / Cargo 的 PATH。
- [x] ZIP 解压到全新仓库外目录后再跑相同 12/12 回归通过；manifest 的 34 个
  文件哈希一致，实际测试 DLL 与独立 Cargo 构建 DLL 哈希一致。
- [x] Dart 新增工具 analyze 无问题、format 与 scoped diff 检查通过。
- [x] 项目镜像与锁定版本保留；只将已有 crypto 3.0.7 声明为测试 dev dependency，
  未升级其他依赖，未改版本号或鸿蒙签名。

### 本地产物

包：`dist/XDRemux-Windows-x64-0.4.3-libheif-test-20261005-01.zip`
（17,038,426 bytes，约 16.25 MiB）。SHA-256：
`f18f3ae412ddc77db09af470feda988d374b89233fc9a1c047cc92c5e2712f69`。

解压保留整个目录，运行 `xdremux.exe`；普通 SDR HEIC 需开启 Photographic Styles
以进入当前 SDR 转换工作流。包内包含测试说明、BUILD-MANIFEST、许可文件与依赖构建脚本。
便携版可能与已安装 XDRemux 共用用户设置，并非独立用户配置沙箱。

回归报告位于仓库外 `codec-poc-20261005/windows-package-smoke-01/report.json`
和 `windows-zip-smoke-01/report.json`；没有把个人测试原图或回归输出放进 ZIP。
可复跑工具：`apps/flutter/tool/windows_package_smoke.dart`，方法见 native README。

### 本测试包仍待人工验收

- [ ] 真实界面启动、添加文件、预览、批量转换、取消与用户设置操作。
- [ ] 无开发工具的干净 Windows 环境 / 安装包验收。
- [ ] 真实失败截图、Apple JPEG + Styles / MakerNote、完整色彩和相册验收。
- [ ] 正式 CI 打包、公开分发许可审查和其他平台接入。

## 2026-10-05：提交归档范围

用户在本地测试包交付后授权提交并推送当前分支
`integrate/huawei-portrait-live`。本次归档包含 Rust JPEG 兼容、可选 HEIC
兜底、Windows 测试包支持、验证工具和任务记录；此前“未提交/推送”描述的是
开发/打包阶段的状态。默认发行 feature 与正式版本号仍未改变。

本地 `apps/flutter/ohos/build-profile.json5` 签名改动、`apps/harmony/`、
`dist/` 测试包、仓库外样片/报告和第三方构建产物均排除，不随源码推送。
没有合并 main、创建 tag 或发布 Release，人工验收队列继续保留。
