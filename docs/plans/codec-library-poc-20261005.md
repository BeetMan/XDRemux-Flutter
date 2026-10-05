# libheif / libultrahdr 小验证（2026-10-05）

最初先验证第三方库收益；用户随后授权实现兼容改进。本文保留 PoC 历史结果，
并在后半记录 Rust 核心实现与验收。未改发布版本、未推送或发版。

## 目标与范围

1. libheif：检查 Windows 本地 HEIC 解码覆盖，对照现有 Rust 路径，重点寻找 4:2:2 / 4:4:4 输入。
2. libultrahdr：以参考 codec 对照现有 Ultra HDR JPEG 的识别、gain map 元数据与 HDR 解码。
3. 产物放在仓库外 `C:/Users/Beet/Documents/XDRemux-Flutter-logs/codec-poc-20261005/`；原始照片不修改、不提交、不上传。
4. Windows 验证不等于其他平台适配完成；结构/像素对照不等于 Apple Photos 真机验收。

## 队列

- [x] 确认可用工具链与本地样片。
- [x] 固定第三方版本，记录库版本、依赖与构建方式。
- [x] libheif 解码及 Rust 路径对照（真实 4:2:0 + 合成 4:2:2 / 4:4:4）。
- [x] libultrahdr 解码、元数据及 Rust 路径对照。
- [x] 汇总结论、失败样片与下一步准入门槛。

## 验收约束

- 不将“读取成功”写成完整 HDR / 人像 / 动态资源保留。
- 记录源文件哈希与执行结果，确认测试前后原图一致。
- 无真实失败截图样片时，该项明确待验证，不用相机照片冒充覆盖率证据。
- 先比较库调用，再考虑 FFI、包体、性能、安全更新和许可审查。

## 首轮 PoC 结果（实现前快照）

以下为实现前结果，不代表后续代码当前状态；实现进展见文末。

当前仓库基线：`integrate/huawei-portrait-live`，`3d4bc0d8`，Rust core `0.4.3`。
仅新增 research 工具与 read-only Rust example，未改生产解析、转换、构建或平台签名配置。

### 固定环境

| 项目 | 本次实际使用 |
|---|---|
| libheif | `1.23.4`，来自 `pillow-heif 1.8.0` Windows CPython 3.12 wheel |
| libheif HEVC decoder | `libde265 1.1.3` |
| 合成 HEIC encoder | wheel 内 `x265 4.3+1-e9b8812` |
| Pillow | `12.3.0` |
| libultrahdr | `v2.0.2`，`e5f5a022fe96fc4dc2ee35c19f733a50df807abe` |
| libjpeg-turbo | `3.1.0`，`20ade4dea9589515a69793e447a6c6220b464535` |
| C++ 工具链 | CMake + Visual Studio 18 2026，MSVC `14.51.36231`，Windows x64 Release |
| libultrahdr 编译选项 | `UHDR_BUILD_DEPS=ON`、`UHDR_ENABLE_HEIF=OFF`、`UHDR_WRITE_ISO=ON`、`UHDR_WRITE_XMP=OFF` |

libheif 本次使用 wheel 内的原生库，**没有完成 Rust FFI 或自行交叉编译**。
libultrahdr 在 MSVC + BUILD_DEPS 配置下实际构建静态库；未向系统安装库。

补充前面的调研结论：libultrahdr 2.0.2 已有借助 libheif 的 HEIF / AVIF 构建路径。
本次主动关闭该选项，只验证 JPEG，不代表其 HEIF / AVIF 能力不存在，也不代表已经验收。

### HEIC：8 个输入

| 输入 | 已观察的 hvcC | Rust 生产 SDR 解码 | libheif 解码 |
|---|---|---|---|
| `IMG_7868.HEIC` | 4:2:0 8-bit，另有单色记录 | 成功，4032×3024 | 成功，同尺寸 |
| `IMG_0330.HEIC` | 4:2:0 8-bit，另有单色记录 | 成功，3024×4032 | 成功，同尺寸 |
| `IMG_0325.HEIC` | 4:2:0 8-bit，另有单色记录 | 成功，4284×4284 | 成功，同尺寸 |
| `IMG20260802135928.heic` | 4:2:0 10-bit | 成功，4096×3072 | 成功，同尺寸 |
| `IMG_fresh_oppo.heic` | 4:2:0 8/10-bit | 成功，4096×3072 | 成功，同尺寸 |
| `synthetic-420.heic` | 4:2:0 8-bit | 成功，128×96 | 成功，同尺寸 |
| `synthetic-422.heic` | 4:2:2 8-bit | 失败：only 4:2:0 supported | 成功，128×96 |
| `synthetic-444.heic` | 4:4:4 8-bit | 失败：only 4:2:0 supported | 成功，128×96 |

同时对照了直接 `heif_oxide::decode_bytes` 和生产 `sdr_source::decode_to_rgb`；
本次输入两条 Rust 路径的成功/失败结果一致，不能把生产路径已有的 clli/mdcv essential-bit 处理遗漏掉。
hvcC 扫描包含 auxiliary image 的配置，并非只测 primary；不能仅凭其中一个配置断言主图格式。

三张合成图由确定性 RGB 图案生成，不来自用户照片，不是手机真实截图。
两个 4096×3072 输入的 libheif 解码像素哈希相同，不能把它们视作两个独立画面来宣称覆盖率。
本次证明了非 4:2:0 的解码覆盖收益，但没有证明像素颜色、方向、辅助图、HDR 元数据和资源保留全部正确。

### JPEG：6 个输入

| 输入 | 当前 Rust parse | libultrahdr probe / HDR 解码 | 结论 |
|---|---|---|---|
| 项目 `motion1.jpg` | 接受，gain map 221343 bytes | 接受；输出 linear RGBA FP16 113246208 bytes | 7 组比较字段一致 |
| 官方 `apple_gainmap_old.jpg` | 拒绝：缺少 `HDRCapacityMax` | 接受；输出 FP16 1572864 bytes | Apple JPEG 元数据兼容缺口 |
| 官方 `apple_gainmap_new.jpg` | 同上 | 接受；输出 FP16 1572864 bytes | Apple JPEG 元数据兼容缺口 |
| 官方 `minnie-320x240-yuv.jpg` | 接受，合成 identity gain map | 拒绝：不含 gain map | 预期 SDR 兜底，不是 HDR 误识别 |
| 合成 `sdr.jpg` | 接受，合成 identity gain map | 拒绝：不含 gain map | 预期 SDR 兜底 |
| 合成 `iso-only.jpg` | 拒绝：缺少 hdrgm XMP | 接受；输出 FP16 614400 bytes | ISO-only JPEG 兼容缺口 |

`parseAccepted` 表示可以交给本项目后续合成管线，**不是原文件一定带 HDR gain map**。
Rust 的 `parse` 故意为普通 JPEG 生成 identity gain map，因此不能与参考库的 HDR 检测布尔值直接比较。

`motion1.jpg` 比较的是 min/max content boost、gamma、SDR/HDR offset、HDR capacity min/max，
共 7 组字段（17 个 Rust 标量）。CLI 打印精度有限，使用 `rel=2e-5, abs=2e-6`。
未对照颜色空间标记、全部 ISO 元数据、gain-map 像素或最终 HDR 渲染像素。
四次参考 HDR 解码退出码均为 0，产出了非空 RAW；未把这当成色彩准确性或真机 HDR 显示验收。

`iso-only.jpg` 用官方 SDR / gain-map JPEG 和 research 配置组合，输出只带 ISO 元数据。
这验证了当前 Rust 强依赖 hdrgm XMP 的具体限制，没有修改生产解析器以掩盖失败。

### 可追溯产物与验证

- 最终统一结果：仓库外 `codec-poc-20261005/run-04/report.json`，14 个输入全部 `sourceUnchanged=true`。
- 报告含输入前后 SHA-256、解码像素/RAW 哈希、hvcC、版本、退出码和完整错误。
- Rust probe SHA-256：`bd6040d00a8be2ba66fe8c9877c1d658fef69b4d9c67d4d6d86583764aeb6e82`。
- ultrahdr_app SHA-256：`97cc143413257942dee25a979c6329646f2787a231bb30c7eb6b9518fff4e454`。
- `cargo build --release -p xdremux-core --example codec_poc`：通过；已有 core 的 61 个 warning 保留未修。
- Rust example 的 rustfmt 检查通过；research 对照逻辑的 5 个单元测试通过。
- `git diff --check` 通过；没有设备安装、生产转换回归、提交、推送或发版。

代码入口：`xdremux/rust/examples/codec_poc.rs`、`tools/research/codec_library_poc.py`、
`tools/research/generate_codec_controls.py`、`tools/research/uhdr-control-metadata.cfg`。

后续实现已为本文及指定 research / native 源文件添加窄范围忽略例外；
外部照片、依赖下载目录和编译产物仍不纳入仓库。开发/打包阶段未提交，
后续用户已授权将代码及本记录归档推送到 `integrate/huawei-portrait-live`。

## 复跑

在仓库根目录 PowerShell，现有依赖位于仓库外；新报告目录必须不存在：

```powershell
$pocRoot = 'C:/Users/Beet/Documents/XDRemux-Flutter-logs/codec-poc-20261005'
$pocPython = "$pocRoot/venv/Scripts/python.exe"
cargo build --release -p xdremux-core --example codec_poc
& $pocPython -m unittest discover -s tools/research -p test_codec_library_poc.py -v
$pocPrevious = Get-Content "$pocRoot/run-04/report.json" -Raw | ConvertFrom-Json
$pocArgs = @('tools/research/codec_library_poc.py',
  '--rust-probe', 'target/release/examples/codec_poc.exe',
  '--uhdr-app', "$pocRoot/uhdr-build/Release/ultrahdr_app.exe",
  '--output-dir', "$pocRoot/replay-$(Get-Date -Format yyyyMMdd-HHmmss)")
foreach ($pocCase in $pocPrevious.cases) {
  $pocArgs += @("--$($pocCase.kind)", $pocCase.path)
}
& $pocPython @pocArgs
```

C++ 构建使用 VS x64 generator，配置/编译示例：

```powershell
cmake -S "$pocRoot/libultrahdr" -B "$pocRoot/uhdr-build" -G 'Visual Studio 18 2026' -A x64 -DUHDR_BUILD_DEPS=ON -DUHDR_ENABLE_HEIF=OFF -DUHDR_BUILD_EXAMPLES=ON
cmake --build "$pocRoot/uhdr-build" --config Release --parallel 4
```

## 后续实现与验收

### 2026-10-05：核心改进已完成，发行接入待验收

当前实现分两部分：JPEG 元数据解析在纯 Rust 中默认生效；HEIC 原生解码兜底以
`libheif-decoder` 可选 Cargo feature 接入，先验证 Windows；不自动改其他平台发行构建。

- [x] Apple gain-map JPEG：按真实 XMP / MakerNote 提取 headroom，不靠填固定值掩盖错误。
- [x] ISO-only JPEG：解析 APP2 ISO 21496-1 rationals，检查版本、边界、数值和方向。
- [x] 保留 SDR identity 与既有 hdrgm XMP 行为；增加失败/畸形输入回归。
- [x] HEIC：受限、可选择的 libheif native fallback；错误、尺寸、内存与方向处理。
- [x] Windows 默认 / feature-on 单元测试、14 个输入复测及小图转换验收。
- [x] 更新开发/构建说明与验证结果，明确其他平台、真实截图和发布待办。

### 实现结果

默认构建不链接 libheif / libultrahdr；Apple JPEG / ISO-only 的解析用纯 Rust，
libultrahdr 仅作为参考工具。HEIC native fallback 需显式开启 `libheif-decoder`
并提供目标 ABI 的 `XDREMUX_LIBHEIF_PREFIX`，未改 Flutter / GitHub 发布 workflow。

原生依赖自行构建为 shared libraries：libheif v1.23.4
`4e14f5942c1732ace9611b9522cc991501445463`；libde265 v1.1.3
`ba62bf4cfb3242f3bf0a45617ff09e35236e4d82`。新脚本从零执行通过，
decoder 内置、plugin loading / encoders 关闭；Python 不是生产依赖。

- 默认单元测试 217 passed / 2 ignored；feature-on 218 passed / 2 ignored，均无失败。
- Workspace all-targets 检查与 Windows feature-on release 库 / 示例构建通过。
- `integration-01/report.json`：14 个输入原图不变；4 个 HDR JPEG 的 8 组元数据
  与 Google CLI 一致（新增 useBaseColorSpace 比较），普通 JPEG 保持 identity 兜底。
- `integration-extended-02/report.json`：新增 4:2:2 / 4:4:4 8/10/12-bit 均成功，
  hvcC 确认位深，RGB8 哈希与参考一致；4:2:0 Rust 主路径不宣称像素一致。
  EXIF-only orientation=6 在 Rust 显示方向为 96×128，独立对照旋转后的参考哈希
  `fcbc8164d1ec4006ff572964b0a033f42a2be51461101f350147b886aa09ea49` 一致。
- `e2e-06/report.json`：12 个实际 FFI 转换均成功、输出图结构有效、原图不变；
  4 个 JPEG 的硬件 prepare 通过且颜色空间标记保留。SDR 请求 Styles，HDR JPEG
  不请求 Styles；`--styles` 可显式测单独的 HDR + Styles 门槛。
- 修复转换入口吞掉损坏 HDR 元数据、JPEG 硬件 prepare 错误提取 OPPO tail、
  小图拒绝、缺失 ExifIFD、iloc 非零基址计算问题；C ABI 结构布局未改变。
- 默认 release 库与示例重新构建通过；`e2e-default-01/report.json` 确认
  `nativeFeature=false`，4/4 JPEG 的实际转换、图结构、硬件 prepare 和原图完整性通过。
  比较脚本 6 个单元测试、Python 语法、新增 Rust 文件 rustfmt 与 scoped diff 检查通过。
- 两张 Apple JPEG 强制 Styles 仍拒绝扩展不透明 MakerNote，详见保留的
  `e2e-03/report.json`；未删除未知 Apple 元数据绕过检查。

所有报告、样片和第三方构建留在仓库外 `codec-poc-20261005/`。
早期诊断报告（含失败）不被覆盖；未完成 Photos 真机 / HDR 色彩准确性验收。

### 原始路线建议（保留）

1. **HEIC 解码兜底**：优先做 Windows 独立后端原型，比对 libheif 与 libde265-only 的接入成本。
   主管线仍负责容器、Exif、gain map、人像和 Live 资源；不让新解码器顺手重写这些数据。
2. **JPEG 元数据补齐**：Apple JPEG 和 ISO-only JPEG 分别添加失败回归，再选择扩展 Rust parser
   或提供 libultrahdr 适配层；不把缺字段简单填常量当作兼容完成。
3. **准入门槛**：真实 `IMG_0008.HEIC`（4:4:4 10-bit）和 4:2:2 / 4:4:4 10/12-bit 语料；
   alpha、方向、grid、ICC/nclx、畸形输入、RAW 长度/数值/像素基准；性能与包体；
   原生依赖许可和发布方式审查；再安排目标平台构建与真机验收。

### 待验收队列

- [ ] Windows 真实失败截图 `IMG_0008.HEIC`，本机未找到该文件。
- [x] 合成非 4:2:0 的 8/10/12-bit、EXIF orientation 单独对照。
- [ ] 带 alpha / grid / ICC 与真实失败截图的完整语料、性能和恶意输入压力测试。
- [ ] JPEG HDR 像素/色彩、Apple JPEG + Styles 不透明 MakerNote 保留策略。
- [x] Rust FFI、错误分类与选择性 fallback，内存/线程/协作式取消限制。
- [ ] macOS / iOS / Android / OHOS / Windows 发布构建及许可评估。
- [ ] Apple Photos / 各目标相册的 HDR、人像编辑、Live 实机验收。

与现有 [SDR 平台覆盖计划](sdr-decode-platform-coverage.md) 对齐；核心可选实现已验证，
不宣称默认发行包、其他平台或所有生产样片已经修复。使用方法见
[native 构建说明](../../tools/native/README.md)。

### Windows 应用测试包补充（2026-10-05）

已按后续用户授权生成本地 Windows x64 便携 ZIP，保留 app `0.4.3+37`，
启用 libheif decoder；打包阶段未推送或发版，之后仅获授权提交推送源码。
构建环境、包哈希、完整任务状态见
[平台计划：Windows 测试包](sdr-decode-platform-coverage.md#2026-10-05windows-本地便携测试包)。

区别于此前静态链接的 Rust example，本轮通过应用现有 Dart FFI 加载包内
`xdremux_core.dll` 实际转换。包内/重新解压后的 12 个输入均通过转换、输出及
Styles 验证与原图完整性检查；PATH 仅保留 Windows 系统目录，依赖 DLL 和
MSVC runtime 从包内提供。34 个 manifest 文件哈希验证通过。
报告为 `windows-package-smoke-01/report.json`、`windows-zip-smoke-01/report.json`。
这不等于真实 UI 文件选择/预览、干净系统或 Photos 验收。
