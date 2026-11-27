# 苹果原生版去掉 x265：改用 VideoToolbox 的开发计划

> 设计基准为 2026-11-12。到 2026-11-24，VideoToolbox 后端已合入，SwiftUI 本地默认构建只编入 VideoToolbox。发布包与 TestFlight 仍编入 VideoToolbox 和 x265，后续工作是切换分发构建并验收产物。见[当前后端配置](../operations/current-status.md#3-能力现状主线)。
> 范围：原生 SwiftUI 版 `apps/apple`（iOS / iPadOS / macOS，bundle id `io.github.beetman.xdremux.swiftui`）。
> Flutter 版、Android、Windows、Linux、鸿蒙继续用 x265，不在本计划内。

## 1. 背景与目标

原生版 0.1.1 已上传 TestFlight，准备开公开测试并上架 App Store。内核 `xdremux/rust` 静态链接了 x265（GPL-2.0-or-later），GPL 与 App Store 分发条款冲突。项目自有代码和上游代码可以另行授权，x265 不行，所以苹果平台必须彻底不链接 x265。

目标：

1. 原生版的全部 HEVC 编码改由 VideoToolbox 完成，最终的 `.app` / `.ipa` / `.dmg` 里没有任何 x265 目标代码。
2. 输出文件在苹果相册里的表现不退步：HDR、摄影风格、人像、实况都要被正确识别。
3. 其他平台的 x265 路径、现有单元测试和一致性测试不受影响。

结论先行（依据见后文）：

- VideoToolbox 的公开 API 能覆盖内核用到的全部码流形态，**唯一的例外是 8 位 4:4:4**：公开的 profile 常量只有 Main、Main10、Main42210、Monochrome、Monochrome10，没有 8 位 4:4:4。受影响的是“关闭 OPPO 兼容时的三通道（RGB）增益图”，需要改成 4:2:0。
- 摄影风格和人像用到的单色遮罩与 10 位线性缩略图，恰好是上游 macOS 版本来就用 VideoToolbox 编码的东西，换过去反而更接近 iPhone 原生文件。
- 推荐架构：在内核里加一个编译期可选的 VideoToolbox 后端（一个 C 文件直接调 VideoToolbox 的 C API），由 `build.rs` 按环境变量选择；不走 Swift 回调注入，也不把流程拆成三段。

## 2. 现状盘点

### 2.1 x265 在内核里的位置

| 位置 | 作用 |
|---|---|
| `xdremux/rust/build.rs:29-36` | 只有两种构建：静态 x265（默认），或 `XDREMUX_USE_FFMPEG=1` 时设 `xdremux_ffmpeg_fallback` 调外部 ffmpeg。没有第三种。 |
| `xdremux/rust/build.rs:40-51` | 编译 `src/x265_helper.c`。 |
| `xdremux/rust/build.rs:99-171` | 可选的 10 位 x265 归档，存在时编译 `src/x265_10bit_bridge.cpp` 并设 `xdremux_main10`。 |
| `xdremux/rust/build.rs:173-221` | 各平台的 x265 链接参数。 |
| `xdremux/rust/build_apple.sh:43-51、57-81` | 为每个切片构建 8 位与 10 位 x265，再用 `libtool` 把 `libx265.a` 并进 `libXDRemuxCore.a`。 |
| `xdremux/rust/src/x265_ffi.rs`、`x265_helper.c`、`x265_10bit_bridge.cpp` | FFI 与两个桥接文件。 |
| `xdremux/rust/src/lib.rs:64` | `pub mod x265_ffi;` 无条件导出。 |
| `apps/apple/Packages/XDRemuxKit/Package.swift:43-46`、`apps/apple/project.yml:101` | 因为 x265 是 C++，显式链接 `c++`。 |

### 2.2 编码入口（`xdremux/rust/src/hevc.rs`）

| 函数 | 行号 | 说明 |
|---|---|---|
| `x265_encode_tiles` | 613-621 | 批量编码同尺寸图块。灰度 `pixel_bytes=1`、RGB `pixel_bytes=3`，`use_420` 决定色度格式。 |
| `x265_encode_tiles_oppo_sdr` | 629-637 | OPPO 约定：BT.601 limited 数据、标记 full range、sRGB 传输函数。 |
| `x265_encode_icc_primary_tiles` | 68-75 | 带 ICC 的主图：只声明 BT.709 矩阵，原色与传输函数写 undef。 |
| `x265_encode_tiles_inner` / `open_encoder` | 640-772 / 501-604 | 真正的参数：灰度 ultrafast CRF 18，RGB medium（OPPO 写回用 fast）CRF 14，`keyint=1`、`bframes=0`、`repeat-headers=0`、`range=full`；每块一个独立会话，最多 4 线程并行。 |
| `encode_hevc_tile_gray` / `encode_hevc_tile_rgb` | 199-224 | 单块辅助函数，只有测试在用（`hevc.rs:1500、1524`，`isobmff_write.rs:2620`）。 |
| `encode_thumbnail_10bit` | 1351-1387 | Main10 4:2:0，经 `x265_10bit_bridge.cpp`；桥里把 `totalFrames` 设成 2，避免被标成 Main10 Intra（`x265_10bit_bridge.cpp:117-119`）。 |
| `main10_available` | 1283-1285 | 取决于构建时有没有 10 位归档。 |
| `drop_parameter_nals` | 778-813 | 去掉 VPS/SPS/PPS 和前缀 SEI，只留图像切片。与编码器无关。 |
| `hevc_byte_stream_to_length_prefixed` | 1028-1066 | Annex-B 转长度前缀。与编码器无关。 |
| `extract_hvcc_config_with_chroma_and_depth` | 1167-1276 | 从 Annex-B 里的参数集拼 hvcC。约束标志位写死为 0（1248 行），数组头用 `0x40 \| type`（1265 行，为了和 libheif 字节一致）。与编码器无关。 |
| `rgb_to_yuv444`、`rgb_to_yuv420`、`*_limited601`、`codes16_to_yuv420_10bit` | 98-191、1298-1343 | 色彩转换在内核里完成，编码器拿到的已经是平面 YUV。与编码器无关。 |

所有调用点对码流的共同要求（`docs/formats/hevc-hevc-conventions.md` §4.2）：

- 每张图一个独立的 IDR，不依赖其他帧。
- 参数集只出现在第一条流里，供 hvcC 提取；写进 `mdat` 的每块都是纯图像切片，长度前缀。
- 同一批图块共用一份 hvcC，所以各块的 SPS/PPS 必须完全相同。

### 2.3 调用点清单

“产品路径”一列说明原生版是否真的会走到：`是` 表示经由 `xdremux_convert_pipeline`、`xdremux_make_live_photo`、`xdremux_writeback_returned_photo` 等原生版已调用的接口可达。

| # | 调用点 | 编码内容 | 像素格式 | 尺寸 | 对码流的要求 | 产品路径 |
|---|---|---|---|---|---|---|
| 1 | `isobmff_write.rs:990`（`tile_and_encode`，947-1040） | 增益图图块，单通道 | 关 OPPO 兼容：8 位单色 4:0:0（Rext，`main444-8` + `i400`）；开 OPPO 兼容：8 位 4:2:0，色度填 128，Main Still Picture | 512×512，边缘块复制填充 | 全范围；hvcC 的色度格式须与 SPS 一致（1013-1021）；每块去参数集（1028-1037）；安卓相册不接受 4:4:4 伪彩色增益图 | 是 |
| 2 | 同上，`pixel_bytes=3` | 增益图图块，三通道（UHDR 模式恒为三通道，`isobmff_write.rs:584`） | 关 OPPO 兼容：8 位 4:4:4；开：8 位 4:2:0；BT.709 全范围 | 512×512 | 同上 | 是 |
| 3 | `isobmff_write.rs:593-621`（`assemble_prepared_tiles`） | 外部编码器交回的增益图图块 | 固定按 4:2:0 写 hvcC（609-613） | 512×512 | 现有硬件路径的装配端 | 是（现有硬件开关） |
| 4 | `uhdr_jpeg.rs:552-560` | 由 JPEG / SDR 像素合成的主图网格 | 8 位 RGB→YUV；转换路径固定 4:2:0（`lib.rs:1620、2104`，`sdr_source.rs:344`）；带 ICC 时原色与传输函数写 undef | 512×512 | 这是用户看到的主图，画质要求最高；要求 Main 4:2:0 以便各家硬件解码器能解（`lib.rs:1616-1619`） | 是 |
| 5 | `uhdr_jpeg.rs:552-560` 经 `lib.rs:2306` | 同上，但走 `xdremux_prepare_tiles` 时传的是 `use_420=false`，即 4:4:4 主图 | 8 位 4:4:4 | 512×512 | 与 #4 不一致，见 §7 开放问题 | 是（现有硬件开关 + JPEG 输入） |
| 6 | `watermark_codec.rs:983`（`encode_tiles`，958-1001） | OPPO 水印写回时重编码的主图网格 | 8 位 4:2:0；BT.601 limited 数据，标记 full range，矩阵 smpte170m、原色 bt470bg、传输函数 sRGB | 512×512 | 观感要和 OPPO 原图一致，靠的就是这组“不自洽”的标记（`hevc-hevc-conventions.md` §1、§3.2）；产物回到 OPPO 手机相册 | 是 |
| 7 | `styles_native.rs:158、170、186` | 摄影风格的天空遮罩 | 8 位单色 4:0:0 | `(主图宽/2)&!1 × (主图高/2)&!1`，例如 2016×1512、2048×1536，单张 | 作为辅助图，由 ImageIO 的辅助数据路径读取；内容通常全零 | 是 |
| 8 | `styles_scaffold.rs:112、135`（`styles_native.rs:61` 调用） | 摄影风格脚手架阶段的零遮罩 | 8 位单色；诊断开关可切 4:2:0 或内置常量 | 同 #7 | 同 #7 | 是 |
| 9 | `linear_thumbnail.rs:393`（经 `styles_native.rs:241`） | 摄影风格线性缩略图，Apple Log | 10 位 4:2:0，BT.601 limited（Y 64–940），Main10 | 长边 ≤ 1024，两边为偶数，跟随主图宽高比 | 必须是 Main10（profile 2），不能是 Main10 Intra；小于 64×64 时退回 8 位 | 是 |
| 10 | `linear_thumbnail.rs:405` | 同上，无 10 位编码器时的 8 位退路 | 8 位 4:2:0 | 同上 | — | 仅退路 |
| 11 | `styles_native.rs:262` | 线性缩略图生成失败时的黑色占位 | 8 位 4:2:0 | 同 #9 | — | 仅退路 |
| 12 | `portrait.rs:1146-1149`（`encode_mono`，897-910） | 人像：视差图、人物遮罩、头发遮罩 | 8 位单色 4:0:0 | 由 `placement` 决定，与主图同宽高比 | 相册的人像编辑（重新对焦、景深滑块）依赖这三张图 | 是 |
| 13 | `portrait.rs:2173、2233` | 华为人像转苹果人像：视差图、人物遮罩 | 8 位单色 | 例如 1536×2048（上采样 2 倍） | 同 #12 | 是 |
| 14 | `semantic_mattes.rs:54`（`encode_gray`，52-61；调用在 136、141） | 12 张语义遮罩，共用一张黑图，另可带一张人物遮罩 | 8 位单色 | 768×576 | 辅助图 | 是 |
| 15 | `live_photo_styles.rs:730`（`empty_matte`，728-739；调用在 1021） | 实况视频里的空遮罩轨样本 | 8 位单色 | 按视频编码尺寸缩到 `MATTE_MAX_EDGE` 以内，偶数边 | 作为 MOV 轨道样本：hvcC + 一个长度前缀 IDR | 是 |
| 16 | `linear_thumbnail.rs:263`（经 `live_photo_styles.rs:935`） | 实况视频的线性缩略图轨样本 | 10 位 4:2:0 Main10 | 128×96（iPhone 原生就是这个尺寸） | 同 #9，作为 MOV 轨道样本 | 是 |
| 17 | `portrait_scaffold.rs:105、123` | 人像脚手架的零遮罩 | 8 位单色 | 同 #7 | `portrait_scaffold::scaffold` 在 `src/` 内没有调用者，只有示例程序用 | 否 |
| 18 | `container_build.rs:60` | 把 RGB 帧做成网格 HEIC | 8 位 4:2:0 | 512×512 | 只有 `examples/build_test.rs` 用 | 否 |
| 19 | `hevc.rs:1432-1593`、`isobmff_write.rs:2620` | 单元测试 | — | — | 断言了 x265 特有的行为（例如 10 位流必须 ≥ 64×64） | 测试 |

不涉及编码、只是文字提到 x265 的模块：`apple_log.rs:17`（注释），`styles_consts.rs:326-329`（注释，说明内置零遮罩常量 `ZERO_MATTE_STREAM` 是 VideoToolbox 编出来的），`lib.rs:64`（模块声明）。

摄影风格的增量图块不编码：`styles_native.rs:357、488` 直接写入常量 `DELTA_TILE` / `DELTA_HVCC_BOX`（`styles_consts.rs:302-324`）。

示例程序里直接引用 x265 的有 `examples/x265_diag.rs`、`examples/tile_stream_probe.rs`、`examples/enc_test.rs`。

### 2.4 现有硬件路径

内核侧（`lib.rs:2239-2488`）：

- `xdremux_prepare_tiles`（2261-2384）：读输入，重建并旋转增益图，切成 512×512，转成紧排的 I420（Y、U、V 依次排列），连同一个不透明句柄 `PreparedOutput` 返回。
- `xdremux_assemble_tiles`（2413-2482）：收回每块的 Annex-B 流，调 `assemble_prepared_tiles` 组装。
- `xdremux_progress_report`（2486-2488）：让外部编码循环上报进度。
- 只覆盖增益图。主图合成、摄影风格、人像、实况、水印写回都不在这条路上。

Swift 侧：

- `HardwareTiles.swift:17-175`（`VideoToolboxTileEncoder`）：一个 `VTCompressionSession` 编所有块；HEVC Main、`MaxKeyFrameInterval=1`、不重排、`Quality=0.9`；像素缓冲用 `420YpCbCr8BiPlanarFullRange` 并附 BT.709 三元组；macOS 上要求硬件编码器（40-45 行）；`annexB()`（139-174）把格式描述里的参数集拼到每条流前面。
- `HardwareTiles.swift:185-188`（`hardwareTilesApplicable`）：用户开了硬件编码、摄影风格 2/3 和人像都关、且有编码器时才启用。
- `HardwareTiles.swift:204-245`：准备、编码、组装、校验；失败抛 `HardwareTilesError`。
- `Pipeline.swift:123-148`：先试硬件路径，失败回退 `xdremux_convert_pipeline`（即 x265）。

已有实测（`docs/plans/apple-native.md:445-447`）：M 系列 Mac 上 74 块 0.11 秒；ImageIO 能读出增益图；iOS 真机未验证。

### 2.5 Flutter 版 iOS 侧的 VideoToolbox 实现

`apps/flutter/ios/SwiftBackend/Sources/XDremuxAppleProviders/AppleVTHevcEncoderInProcess.swift`（863 行，移植自上游的 `apple_vt_hevc_encoder.swift`）支持五种模式（15、253-259 行）：

| 模式 | profile | 用途 | 能否照搬 |
|---|---|---|---|
| `mono8` | `kVTProfileLevel_HEVC_Monochrome_AutoLevel`（154-155 行），像素缓冲 `OneComponent8`（298-300 行） | 遮罩 | 可以，全是公开 API |
| `rgb10` | `kVTProfileLevel_HEVC_Main10_AutoLevel`（158-159 行） | 摄影风格的线性缩略图与增量图（`ApplePhotographicStylesPipeline.swift:1497`） | 可以，全是公开 API |
| `rgb4448` | 用 `dlsym` 取 `kVTProfileLevel_HEVC_Main444_AutoLevel`（157、543-559 行），并设私有键 `QuantizationScalingMatrixPreset`（179-186 行） | 8 位 4:4:4 | **不可以**：符号和键都不在公开头文件里 |
| `mono8tile`、`rgb4448tile` | 用 `dlsym` 取 `VTTileCompressionSession*` 一组函数（569-720 行附近） | 增益图分块（`DirectTiledHEVCGainMapEncoder.swift:86`） | **不可以**：整组函数是私有 API |

另一份 `apps/flutter/ios/Runner/VideoToolboxHevcEncoder.swift`（282 行，macOS 下有同名副本）只做 Main 4:2:0 图块，全是公开 API，和原生版的 `HardwareTiles.swift` 等价。

可复用的东西：

- `mono8` 与 `rgb10` 两种模式的会话配置和像素缓冲格式，这是上游在 macOS 上被苹果相册接受的做法。
- 色彩矩阵的设定方式（`kVTCompressionPropertyKey_YCbCrMatrix` 等，187-195 行）。
- 从格式描述的扩展原子里直接取 hvcC（825 行附近）这条备选路线。
- 原生版 `HardwareTiles.swift` 的 `annexB()` 逻辑和测试 `HardwareTilesTests.swift`。

不能复用的东西：一切经 `dlopen` / `dlsym` 拿的符号。原生版目前没有任何私有 API（`apps/apple` 下搜 `dlopen|dlsym|NSClassFromString|NSSelectorFromString` 无结果），这一点要保持。

## 3. VideoToolbox 可行性逐项评估

### 3.1 已核实的事实

SDK 头文件（Xcode 自带的 macOS 27.2 与 iOS 27.2 SDK，`VTCompressionProperties.h`）里公开的 HEVC profile 常量只有：

- `kVTProfileLevel_HEVC_Main_AutoLevel`（iOS 11+）
- `kVTProfileLevel_HEVC_Main10_AutoLevel`（iOS 11+）
- `kVTProfileLevel_HEVC_Main42210_AutoLevel`（iOS 15.4+）
- `kVTProfileLevel_HEVC_Monochrome_AutoLevel`（iOS 11+）
- `kVTProfileLevel_HEVC_Monochrome10_AutoLevel`（iOS 13+）

没有 8 位 4:4:4，也没有 `VTTileCompressionSession`、`QuantizationScalingMatrixPreset`。

本机探针（Apple M6，macOS 27.2.1；脚本留在共享笔记目录的 `vtprobe.swift`，每种组合编一帧并解析 SPS）：

| 组合 | 硬件编码器 | 软件编码器（macOS） | SPS 结果 |
|---|---|---|---|
| Main + `420f`（8 位 4:2:0 全范围） | 成功 | 成功 | profile 1，色度格式 1，8 位 |
| Monochrome + `L008`（8 位单色） | 成功 | 成功 | profile 4（Rext），色度格式 0，8 位，`max_monochrome` 约束位为 1 |
| Main10 + `x420`（10 位 4:2:0） | 成功 | 成功 | profile 2（Main10，不是 Main10 Intra），色度格式 1，10 位 |
| Main + `444f` 输入 | 成功 | 成功 | 被静默转成 4:2:0 |
| Main42210 + `444f` 输入 | 成功，得到 10 位 4:2:2 | 设置 profile 失败（-12902） | — |

测试尺寸：512×512、768×576、128×96、1024×768、2016×1512、64×64、1022×766，三种组合全部成功。

探针里顺带看到的差异：

- 硬件编码器输出“前缀 SEI（39）+ IDR_N_LP（20）”，软件编码器只输出 IDR_W_RADL（19）。`drop_parameter_nals` 已经会丢掉 39（`hevc.rs:806-807`），两种都能处理。
- 硬件编码器把编码尺寸向上取整：2016×1512 编成 2016×1520，64×64 编成 128×64，靠 SPS 的裁剪窗口还原。软件编码器保持 2016×1512 和 64×64。x265 现在的输出是不取整的。
- `Quality` 与体积的关系很陡：512×512 渐变图，单色，硬件编码器在 0.5 / 0.75 / 0.9 / 1.0 时分别是 4.1 / 7.1 / 14.5 / 72.3 KB。1.0 不是无损。
- 单色与 4:2:0 灰度的体积几乎一样。
- 参数集恒为 3 个（VPS、SPS、PPS），从格式描述里取，不在样本数据里。

以上只在一台 Apple Silicon Mac 上测过，iPhone 真机、Intel Mac、CI 虚拟机都**待验证**。

### 3.2 逐项结论

| 调用点（§2.3 编号） | 结论 | 做法 | 风险与依据 |
|---|---|---|---|
| 1 增益图单通道，单色 | 可直接替换 | Monochrome + `OneComponent8` | 低。探针确认色度格式 0；iPhone 原生文件和上游都用同样的形态。iPhone 硬件编码器是否支持 Monochrome **待验证**。 |
| 1 增益图单通道，4:2:0（OPPO 兼容） | 可直接替换 | Main + `420f`，色度填 128 | 低到中。profile 从 Main Still Picture（3）变成 Main（1）。ImageIO 已验证能读（`apple-native.md:446-447`）；OPPO 相册是否接受 Main profile 的增益图块**待验证**，Flutter 安卓的 MediaCodec 路径输出的也是 Main，可作旁证。 |
| 2 增益图三通道，4:4:4 | **做不到** | 改成 Main 4:2:0 | 中。公开 API 没有 8 位 4:4:4。备选：a）4:2:0，现有硬件开关和 OPPO 兼容模式已经这么做；b）Main42210，10 位 4:2:2，只有硬件编码器支持，且不是增益图的常见形态，不推荐；c）私有符号，有审核风险，排除。推荐 a。色度精度下降对增益图的实际影响**待验证**（增益图本身低频，预期很小，需要样张对比）。这会改变苹果平台上所有 UHDR 模式输出的增益图格式，需要用户确认（§7）。 |
| 2 增益图三通道，4:2:0 | 可直接替换 | Main + `420f` | 低。即现有硬件路径。 |
| 4 合成主图，4:2:0 | 可替换，需要校准 | Main + `420f`，BT.709 全范围 | 中。两点：一是画质与体积，x265 是 CRF 14 medium，VideoToolbox 只有 `Quality`，要按样张用 PSNR/SSIM 和体积定值；二是带 ICC 时要让 VUI 的原色与传输函数为“未指定”，VideoToolbox 在不设这两个属性时写什么**待验证**，不行就在内核里改写 SPS 的 VUI，或接受写 BT.709（ICC 优先，解码器一般以 ICC 为准，但需实测）。 |
| 5 合成主图，4:4:4（`prepare_tiles` 路径） | **做不到** | 统一成 4:2:0 | 低。`lib.rs:1616-1619` 的注释本来就要求主图必须 4:2:0，`lib.rs:2306` 传 `false` 更像是遗漏。 |
| 6 OPPO 水印写回主图 | 可替换，有风险 | Main + `420f`，内核照旧做 limited 601 转换，像素缓冲标成全范围；矩阵设 ITU-R 601，原色设 EBU 3213（即 bt470bg），传输函数设 sRGB | 中。要确认 VideoToolbox 原样写出 `matrix=6 / primaries=5 / transfer=13 / full_range=1`，**待验证**（用 `ffprobe -show_streams` 检查）。写不出来就在内核里改写 VUI。最终要在 OPPO 手机相册里和原图并排看。 |
| 7、8、14、15、17 各类单色遮罩 | 可直接替换 | Monochrome + `OneComponent8` | 低。内置常量 `ZERO_MATTE_STREAM` 就是 VideoToolbox 编的（`styles_consts.rs:326-329`）。一点要验证：硬件编码器把高度取整到 16 的倍数再裁剪（2016×1512 → 2016×1520），ImageIO 的辅助图路径和相册是否照常处理**待验证**；不行就对这类图强制软件编码器，或把遮罩先填充到 16 的倍数。 |
| 9、16 线性缩略图，10 位 | 可直接替换 | Main10 + `x420`，矩阵设 ITU-R 601 | 低。探针确认是 Main10（profile 2），不需要 x265 那个 `totalFrames=2` 的绕法。与上游做法一致。64×64 的下限也可以去掉。 |
| 10、11 线性缩略图 8 位退路 | 可直接替换，且基本用不到 | Main + `420f` | 低。VideoToolbox 后端下 10 位恒可用，8 位退路只在 10 位编码失败时用。 |
| 12、13 人像的视差图与遮罩 | 可替换，需要验证 | Monochrome + `OneComponent8` | 中。视差图对量化敏感，`Quality` 取值要靠相册里的人像编辑效果来定。 |
| 18 示例用的网格容器 | 可直接替换 | Main + `420f` | 无产品影响。 |

### 3.3 共性风险

1. **码率控制方式不同。** x265 用 CRF（灰度 18、RGB 14），VideoToolbox 用 0–1 的 `Quality`，硬件与软件编码器在同一个 `Quality` 下体积也不同。需要按内容类别（主图、增益图、遮罩、视差图、线性缩略图）各定一个值。头文件里还有 `kVTEncodeFrameOptionKey_BaseFrameQP`（iOS 15+，要求编码器支持，用法有约束），可以作为固定 QP 的备选，是否可用**待验证**。
2. **输出不可复现。** VideoToolbox 的输出随系统版本和芯片变化，不能做字节级的黄金样本比对。VideoToolbox 后端的测试只能查结构和解码后的误差。
3. **各块参数集必须一致。** 只有第一块的参数集进 hvcC。一个会话编完同一批图块可以保证这一点；后端里要加一条断言，发现不一致就报错。
4. **机型差异。** 部署目标是 iOS 17 / macOS 14（`build_apple.sh:35-36`）。iOS 17 支持的最老机型是 A12，都有硬件 HEVC 编码器，但 Monochrome 与 Main10 静态图在各代芯片上的表现**待验证**，至少要测一台老机型和一台新机型。
5. **macOS 与 iOS 的差异。** macOS 有软件 HEVC 编码器，探针确认它支持 Main、Monochrome、Main10。iOS 上的软件编码器：`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` 在 iOS 17.4 才公开，17.0–17.3 上能否指定或回退到软件编码器**待验证**。
6. **Intel Mac。** 现在的构建带 x86_64 切片。Intel Mac 的硬件 HEVC 编码器能力不一，Monochrome 和 Main10 很可能要靠软件编码器，**待验证**（没有 Intel 机器的话要决定是否继续支持，§7）。
7. **模拟器与 CI。** 模拟器里的 VideoToolbox 用的是宿主 Mac 的编码器，结果不代表真机。GitHub 的 macOS 虚拟机里硬件编码器可能不可用。所以后端的策略应是“优先硬件，允许软件”，不能像现在的 `HardwareTiles.swift:40-45` 那样强制硬件。
8. **hvcC 的约束标志。** `hevc.rs:1248` 把 6 字节约束标志写成 0，而 VideoToolbox 的单色 SPS 里这些位不为 0。x265 的单色流现在也是同样的处理，所以行为不变；但借这次机会可以评估是否改为如实拷贝，或直接用 VideoToolbox 给的 hvcC。

## 4. 架构方案对比与推荐

### 方案 A：编码器回调，由 Swift 注入

内核定义一张 C 函数表（编码一张图、释放输出），新增 `xdremux_set_hevc_encoder(...)`。苹果构建编译成“外部编码器”模式，`hevc.rs` 的入口把平面 YUV 交给回调；Swift 侧用 `VideoToolboxTileEncoder` 的扩展版实现回调。

- 优点：内核里 20 多个调用点不用动；能复用现有 Swift 编码器。
- 缺点：
  - 每个宿主进程都要先注册：App、分享扩展、命令行工具、Swift 测试。漏掉就只能在运行时报错。
  - Rust 的单元测试和一致性测试跑不到这条路，因为 `cargo test` 里没有 Swift。内核改动只能靠 Swift 侧间接验证。
  - 内核批量编码时用了最多 4 个工作线程（`hevc.rs:733-770`），回调要么可重入，要么内核在这个模式下改成串行。
  - C ABI 多一组需要长期维护的结构体。

### 方案 B：全部拆成“准备、编码、组装”三段，由 Swift 驱动

把现有 `prepare_tiles` / `assemble_tiles` 的做法推广到所有路径。

- 优点：没有回调；线程和会话全由 Swift 管。
- 缺点：
  - 编码步骤散在流程深处，而且一次转换里有多次、多种编码：摄影风格要先后编天空遮罩和线性缩略图（`styles_native.rs:158-271`），人像一次编三张（`portrait.rs:1146-1149`），JPEG 输入要先合成主图再编增益图，实况是往 MOV 里加轨道。每条路径都要设计自己的中间状态和一对 C 接口。
  - `xdremux_convert_pipeline` 现在是“一次调用做完转换、校验、摄影风格 3”，拆开后这套编排要在 Swift 里重写一遍，并和内核里给其他平台用的那套长期保持一致。
  - 工作量和回归风险都是三个方案里最大的。

### 方案 C：内核内置 VideoToolbox 后端（推荐）

VideoToolbox、CoreMedia、CoreVideo 都是 C API。仿照现有的 `x265_10bit_bridge.cpp`，加一个 `src/vt_hevc.c`，对内核暴露和现在 10 位桥几乎一样的接口：传入平面数据和参数，返回 `malloc` 出来的 Annex-B 流（含参数集）。`build.rs` 在选择 VideoToolbox 后端时编译它，不再编译和链接任何 x265 相关的东西。

- 优点：
  - C ABI 和头文件 `include/xdremux_core.h` 完全不变。Swift 侧、分享扩展、命令行工具都不用注册任何东西。
  - 在 macOS 上可以直接 `XDREMUX_HEVC_BACKEND=videotoolbox cargo test`，内核现有的 300 多个单元测试和一致性测试都能在新后端上跑。
  - 调用点基本不动，改动集中在 `hevc.rs` 和构建脚本。
  - 其他平台因为是编译期开关，一行代码都不会变。
  - 现有的 Swift 硬件路径和“硬件编码”开关可以整体删除，少维护一套代码。
- 缺点：
  - 要手写一段调 CoreFoundation / VideoToolbox 的 C 代码（估计 300–400 行），并处理好同步等待输出回调。
  - 内核里多了一段苹果专用代码，但它由 `cfg` 隔离，和 x265 的 FFI 是同等地位。
  - 链接：静态库不带链接参数，`XDRemuxKit` 要显式链接 VideoToolbox、CoreMedia、CoreVideo、CoreFoundation（`Package.swift` 和 `project.yml` 各加一处；`c++` 那一行可以去掉）。

### 对比

| 维度 | A 回调注入 | B 三段拆分 | C 内核内置后端 |
|---|---|---|---|
| C ABI 变化 | 新增注册接口和结构体 | 每条路径新增一对接口 | 无 |
| 内核调用点改动 | 小 | 大 | 小 |
| Swift 侧改动 | 中（实现回调、各进程注册） | 大（重写编排） | 小（删硬件路径、改链接） |
| Rust 测试能否覆盖新后端 | 不能 | 不能 | 能 |
| 对其他平台的影响 | 无（编译期开关） | 有（流程被拆） | 无（编译期开关） |
| 漏配置的失败方式 | 运行时报错 | 编译期 | 编译期 |
| 工作量 | 中 | 大 | 中偏小 |

推荐方案 C。如果第一阶段发现某项能力只能通过 Swift 才拿得到（目前没有发现这样的 API），再退到方案 A，届时内核里“后端”这层抽象可以原样保留，只是把 C 文件换成回调。

### 方案 C 的具体设计

**后端选择。** `build.rs` 读环境变量 `XDREMUX_HEVC_BACKEND`：

- 不设或 `x265`：现状，默认值。
- `ffmpeg`：等价于现有的 `XDREMUX_USE_FFMPEG=1`（旧变量继续有效）。
- `videotoolbox`：只允许在苹果目标上使用，否则 `panic!`。设 `cfg(xdremux_hevc_vt)`，编译 `src/vt_hevc.c`，输出 `cargo:rustc-link-lib=framework=VideoToolbox` 等（对 `cargo test` 和 cdylib 生效），不编译 `x265_helper.c`、不查找 `libx265.a`、不设 `xdremux_main10`。

`Cargo.toml` 的 `check-cfg` 列表加上 `xdremux_hevc_vt`。

**`hevc.rs` 的整理。** 现在 x265 代码和通用工具混在一个文件里。拆成：

- `hevc/mod.rs`：色彩转换、NAL 工具、hvcC、对外入口。入口函数名暂时保持不变（`x265_encode_tiles` 等），避免第一轮就改 20 多个调用点；改名留到收尾阶段。
- `hevc/x265.rs`：现有的 x265 实现，`cfg(not(any(xdremux_ffmpeg_fallback, xdremux_hevc_vt)))`。
- `hevc/ffmpeg.rs`：现有的 ffmpeg 退路。
- `hevc/vt.rs`：VideoToolbox 后端，`cfg(xdremux_hevc_vt)`。

`lib.rs:64` 的 `pub mod x265_ffi;` 和 `main10_available()` 相应加上 `cfg`；VideoToolbox 后端下 `main10_available()` 返回 `true`。

**后端内部的统一请求。** 三个后端实现同一个内部函数，参数描述一批同尺寸的图：

- 宽、高
- 布局：单色 / 4:2:0 / 4:4:4（VideoToolbox 后端遇到 4:4:4 时按 §3.2 的决定降为 4:2:0，并返回实际使用的色度格式，调用方据此写 hvcC）
- 位深：8 或 10
- 色彩标记：BT.709 全范围 / OPPO 约定 / 带 ICC（原色与传输函数未指定）/ BT.601 limited（线性缩略图）
- 内容类别：主图、增益图、遮罩、视差图、线性缩略图，用来查 `Quality`

调用点里目前写死的 hvcC 色度值（例如 `uhdr_jpeg.rs:565`、`isobmff_write.rs:1013-1019`）要改成用后端返回的实际值，否则 4:4:4 降级后 hvcC 会和 SPS 对不上。这是调用点上唯一必须的改动。

**`vt_hevc.c` 的行为。**

- 一次调用编一批同规格的图，用一个 `VTCompressionSession`，按顺序逐张编码并等待输出（现有 Swift 实现 74 块 0.11 秒，不需要多线程）。
- 会话属性：对应的 profile、`RealTime=false`、`AllowFrameReordering=false`、`MaxKeyFrameInterval=1`、`Quality`，以及色彩三元组。每帧带 `ForceKeyFrame`。
- 编码器选择：优先硬件，允许软件。读 `UsingHardwareAcceleratedVideoEncoder` 写进调试日志。保留一个环境变量强制软件编码器，供测试和排查用。
- 输出：第一张图前面拼上格式描述里的 VPS/SPS/PPS，后面每张只有图像数据；逐张比对参数集，不一致就报错。
- 每张图之间检查内核的取消标志（沿用 `hevc.rs:668-672` 的做法）。

**构建脚本。** `build_apple.sh`：

- 默认设 `XDREMUX_HEVC_BACKEND=videotoolbox`，不再调用 `build_x265`，`arch_lib` 里不再把 `libx265.a` 并进归档（`libtool` 那一步只剩 Rust 静态库，可以直接拷贝）。
- 保留一个开关（例如 `XDREMUX_APPLE_HEVC=x265`）临时构建旧版，用于第一、二阶段的对照样张；收尾阶段删除。
- `BUILD_RECORD.txt` 里加一行 `hevc_backend=`。

`build_ios.sh`、`build_ios_sim.sh`（给 Flutter 用）不动。

**保证其他平台不受影响。**

- 默认后端仍是 x265，所有改动都在 `cfg` 之后。
- `ci.yml` 和 `conformance.yml` 现有的 `cargo test`（x265 与 ffmpeg 两种）原样保留，必须继续全绿。
- 拆分 `hevc.rs` 的那个 PR 单独做，要求 x265 后端的产物逐字节不变：`tests/fixtures_gate.rs` 和 `tests/jpeg_hdr_regression.rs` 里的 SHA-256 断言不改一个字符就能通过。
- 新增一个 macOS CI 任务，用 VideoToolbox 后端跑 `cargo test`（硬件编码器不可用时走软件编码器）。

## 5. 分阶段计划

每个阶段一个 PR，未经用户确认不合并。提交信息用英文。

### 阶段 0：可行性验证（不合并产品代码）

目的：用最挑剔的路径确认苹果相册接受 VideoToolbox 编出来的文件，再决定后面的范围。选**摄影风格**，因为它一次覆盖三种码流：增益图、单色天空遮罩、10 位线性缩略图。人像作为第二条。

范围：

- 在一个实验分支上给内核加一个只供实验用的开关：`open_encoder` / `encode_thumbnail_10bit` 之外另开一条路，从环境变量指定的目录里读取事先编好的 Annex-B 流代替 x265 的输出。内核已经有类似的诊断开关（`XSTYLES_SKY_STREAM`、`XSTYLES_LINEAR_STREAM`，`styles_native.rs:139-147、206-218`），天空遮罩和线性缩略图可以直接用它们，不用改代码；增益图用现有的硬件开关路径。
- 用 `vtprobe.swift` 扩一个小工具，按 §4 的配置把内核导出的平面数据编成 Annex-B。
- 这个 PR 只包含实验工具、样张清单和结论文档，或者干脆不开 PR，只把结论记进本文件。由用户决定。

样张（每类至少 2 张，来自现有样本库）：

1. OPPO ProXDR，单通道增益图，开摄影风格。
2. OPPO UHDR 模式，三通道增益图（验证 4:4:4 改 4:2:0），开摄影风格。
3. Ultra HDR JPEG 输入（验证主图合成）。
4. OPPO 人像，开人像。
5. 华为人像转苹果人像。
6. 实况照片，开摄影风格（验证 MOV 里的两条轨道）。

验收标准：

- 每张样张各出一份 x265 版和一份 VideoToolbox 版。
- 内核自检全部通过：`xdremux_verify_output`、`xdremux_verify_styles_output`、`xdremux_verify_portrait_output`。
- 在 macOS 照片 App 和一台 iPhone 的相册里逐张核对，VideoToolbox 版与 x265 版表现一致：
  - HDR：缩略图和大图都有 HDR 提亮，信息面板显示 HDR。
  - 摄影风格：编辑界面出现“风格”，可以切换风格、拖动色调与色彩，保存后不报错。
  - 人像：显示“人像”标记，编辑里可以调光圈、点选对焦点。
  - 实况：长按能播放，编辑里风格对视频也生效。
- `ffprobe -show_streams` 记录每种码流的 profile、像素格式、色彩三元组和范围，写进结论。
- 记录硬件编码器对非 16 倍数尺寸的取整是否影响相册识别。

验证方法：手工，产出一张对照表（样张 × 平台 × 项目，通过或不通过），附在本文件末尾。

决策点：

- 全部通过：按阶段 1–5 推进。
- 只有单色遮罩的尺寸取整有问题：这类图改用软件编码器或预先填充，继续推进。
- iPhone 上某种 profile 的硬件和软件编码器都不可用，或相册不认：停下来，回到 §7 重新讨论范围（例如该功能在苹果平台暂时下线）。

### 阶段 1：`hevc.rs` 拆分与后端抽象（不改行为）

范围：按 §4 把 `hevc.rs` 拆成 `hevc/mod.rs`、`hevc/x265.rs`、`hevc/ffmpeg.rs`，引入内部统一请求；`build.rs` 认识 `XDREMUX_HEVC_BACKEND`，但此时只接受 `x265` 和 `ffmpeg`。调用点改为使用后端返回的实际色度格式。

涉及文件：`xdremux/rust/src/hevc.rs`（拆分）、`build.rs`、`Cargo.toml`、`lib.rs`、`uhdr_jpeg.rs`、`isobmff_write.rs`、`watermark_codec.rs`、`linear_thumbnail.rs` 等调用点的少量改动。

验收标准：

- x265 后端下 `cargo test --workspace` 全绿，`tests/fixtures_gate.rs` 与 `tests/jpeg_hdr_regression.rs` 的 SHA-256 断言未修改。
- ffmpeg 后端下 `conformance.yml` 的测试全绿。
- 所有平台的 CI 全绿（Flutter、Android、Windows、Linux、鸿蒙的构建脚本未改）。
- 对同一批样张，重构前后 x265 后端的输出文件逐字节相同。

验证方法：CI；本机对样本目录跑一遍转换并比对哈希。

### 阶段 2：VideoToolbox 后端（内核）

范围：新增 `src/vt_hevc.c` 和 `hevc/vt.rs`，覆盖单色 8 位、4:2:0 8 位（三种色彩标记）、4:2:0 10 位；`build.rs` 接受 `videotoolbox`。这个阶段**不**改 `build_apple.sh` 的默认值，原生版继续用 x265 出包。

涉及文件：`xdremux/rust/src/vt_hevc.c`（新）、`xdremux/rust/src/hevc/vt.rs`（新）、`build.rs`、依赖 x265 特性的测试（`hevc.rs:1430-1486` 的两个 10 位测试、`batch_encode_matches_single_tile_headers`）按后端加条件或改写、`examples/x265_diag.rs` 等三个示例加 `cfg`、`.github/workflows/apple-ci.yml`（新增任务）。

验收标准：

- `XDREMUX_HEVC_BACKEND=videotoolbox cargo test -p xdremux-core` 在 macOS 上全绿（字节级哈希断言对该后端跳过，并在测试里写明原因）。
- 新增的后端单元测试通过：
  - 每种布局编出的 SPS 的 profile、色度格式、位深符合预期。
  - 批量编码时第一条流带参数集，其余不带；各块参数集一致。
  - 用内核自带的解码器（`heif-oxide` / `rust_h265`）解回 8 位 4:2:0 图块，PSNR 高于约定阈值（阈值在本阶段按样张定，写进测试）。
  - OPPO 约定路径编出的 VUI 是 `matrix=6 / primaries=5 / transfer=13 / full_range=1`；带 ICC 路径的 VUI 符合阶段 0 定下的结论。
  - 非 16 倍数尺寸、64×64 以下的小图能编出来。
  - 取消标志置位后批量编码中途返回。
- 默认后端（x265）的全部测试仍然全绿、输出不变。
- `Quality` 取值表定稿：每个内容类别一个值，附样张上的 PSNR/SSIM 与体积对比（相对 x265）。

验证方法：`cargo test`（两种后端）；新增的 macOS CI 任务；`ffprobe` 抽查；用阶段 0 的样张重跑对照表。

### 阶段 3：原生版切到 VideoToolbox 后端

范围：`build_apple.sh` 默认用 VideoToolbox 后端，不再构建和合并 x265；Swift 包改链接；删除 Swift 侧的硬件路径和设置项。

> 按 §7 的决定记录调整：GitHub 构建保留 x265 并在设置里可选，“硬件编码”开关改为编码器选择而不是删除；只出 arm64。下面的文件清单和验收标准里与此冲突的条目（删除设置项、三个切片 x265 计数为 0、Intel Mac 加测）只适用于纯 VideoToolbox 的商店构建或已取消。

涉及文件：

- `xdremux/rust/build_apple.sh`
- `apps/apple/Packages/XDRemuxKit/Package.swift`（去掉 `c++`，加四个系统框架；注释更新）
- `apps/apple/project.yml:101` 附近
- `apps/apple/Packages/XDRemuxKit/Sources/XDRemuxKit/HardwareTiles.swift`（删除）
- `apps/apple/Packages/XDRemuxKit/Sources/XDRemuxKit/Pipeline.swift:119-148`（去掉硬件分支）
- `apps/apple/Packages/XDRemuxKit/Tests/XDRemuxKitTests/HardwareTilesTests.swift`（删除或改成整条流水线的样本测试）
- `apps/apple/App/Views/SettingsView.swift:8、94-102`（去掉“硬件编码”开关）与 `Localizable.xcstrings:5011-5022`
- `XDRemuxModel/ConversionConfig.swift:145` 的 `hardwareEncode`：字段保留以兼容已存的配置和 Flutter 的配置键，但不再生效
- `Sources/xdremux-cli/XDRemuxCLI.swift:134、140、239、313、355`（“静音 x265 日志”的选项和说明）
- `.github/workflows/apple-ci.yml:31-40`（去掉 x265 缓存）
- `apps/apple/README.md:69、85、99`

验收标准：

- `build_apple.sh` 全程不触碰 `vendor/x265`；在一个没有 `vendor/x265` 的干净检出上能成功。
- `strings -a libXDRemuxCore.a | /usr/bin/grep -ci x265` 对三个切片都是 0；`nm` 里没有 `x265_` 开头的符号。
- `swift test`、命令行工具冒烟、macOS App 与 iOS 模拟器构建在 CI 上全绿。
- 阶段 0 的对照表在 macOS 和 iPhone 真机上用正式构建重跑一遍，全部通过。
- 至少两台 iPhone（一台 A12–A14，一台近两年机型）和一台 iPad 上跑通全部样张类别；有 Intel Mac 的话加测一台。
- 水印写回的产物在一台 OPPO 手机相册里与原图并排观感一致。
- 性能：整批样张的转换耗时不比 x265 版慢（预期更快），内存峰值不升高。记录数据。

验证方法：CI；真机手工核对；`XDREMUX_SAMPLE_DIR` 样本测试。

### 阶段 4：发布脚本与许可收尾

范围见 §6。

涉及文件：`tools/apple/package_release.sh:108-114`、`tools/apple/upload_testflight.sh:130-131`、`LICENSING.md`、`README.md:242`、`apps/apple/README.md`、应用内的开源许可页（原生版目前在 `apps/apple/App/Views/ContentView.swift` 一带，需确认位置）、`docs/plans/apple-native.md`（追加记录）。

验收标准：

- 两个脚本在产物里发现 x265 字符串时失败退出；用旧的 x265 版 XCFramework 故意跑一次，确认会被拦下。
- 用新脚本打出 DMG、未签名 IPA 和 TestFlight 包，全部通过检查。
- `LICENSING.md` 写清楚苹果原生版不含 x265，以及它实际适用的许可（取决于 §7 的决定）。
- 应用内许可页与实际链接的第三方组件一致。

验证方法：本机跑两个脚本；检查产物；人工核对文档。

### 阶段 5：清理（可选）

范围：把 `x265_encode_tiles` 等入口改成与后端无关的名字；删掉 `build_apple.sh` 里临时保留的 x265 开关；删掉只为实验加的诊断开关；更新 `docs/formats/hevc-hevc-conventions.md`，补一节 VideoToolbox 后端的约定和 `Quality` 取值表。

验收标准：所有平台 CI 全绿；x265 后端输出仍逐字节不变。

## 6. 许可与发布层面的收尾

**确认苹果包里不含 x265。**

- `tools/apple/package_release.sh:113` 现在要求二进制里**必须**有 `x265` 字符串。改成**不得**出现（不区分大小写），出现即失败。同时检查 macOS 和 iOS 两个二进制。
- `tools/apple/upload_testflight.sh:130-131` 现在只检查内核在不在。加上同样的“不得含 x265”检查，放在上传之前。
- 归档后符号已被剥离，所以以 `strings -a` 为准；对未剥离的 `libXDRemuxCore.a` 另外用 `nm` 查 `x265_` 符号，放进 `build_apple.sh` 的末尾，写进 `BUILD_RECORD.txt`。
- 检查范围要包括分享扩展 `XDRemuxShare.appex` 的二进制和 `XDRemuxTransferCore.framework`。
- 注意误报：内核源码里的错误信息和日志有 “x265” 字样（例如 `hevc.rs` 的 `xlog`、`watermark_codec.rs:985` 的 `record_phase("x265_encode", ...)`）。VideoToolbox 后端下这些字符串要么被 `cfg` 排除，要么改名，否则检查会一直失败。这项工作放在阶段 2、3。

**GitHub 发布的 DMG 与未签名 IPA。**（用户已决定暂时保留 x265 并做成设置里可选，见 §7 的决定记录；以下是原建议，留待以后移除时参考。）建议一并去掉 x265，只维护一种苹果构建：

- 两种构建意味着两套测试矩阵，而且 GitHub 版和商店版的输出会不一样，用户反馈难以对应。
- VideoToolbox 版在阶段 3 之后就是经过完整验证的那一版。
- 如果用户希望 GitHub 版保留 x265（例如为了 4:4:4 增益图），阶段 3 里保留的构建开关可以继续留着，但要接受上述代价。见 §7。

**其他会进苹果包的第三方代码。** 调研时顺带核对了一遍，结论是去掉 x265 后没有其他 GPL 组件：

- `heif-oxide`、`rust_h265`、`jpeg-decoder`、`quick-xml`、`serde_json`、`zstd`、`png`：MIT 或 Apache-2.0（`cargo metadata`）。
- `libheif-decoder` 特性：`build_apple.sh` 没有启用，苹果包里不含 libheif / libde265。保持不启用。
- `XDRemuxTransferCore`：LocalSend core，Apache-2.0。
- `swift-argument-parser`：Apache-2.0，只进命令行工具。

**文档。**

- `LICENSING.md:13`（“各平台安装包因静态链接 x265 等 GPL 组件，整体按 GPL 分发”）和 `:30`（x265 一节）要改成区分平台：苹果原生版不含 x265；其他平台不变。
- `LICENSING.md` 开头声明全仓库是 GPL-3.0-only。App Store 版要以什么许可分发，需要用户和上游作者落成文字（§7），这不是技术问题，但不写清楚的话“去掉 x265”并不能单独解决商店分发的许可问题。
- `README.md:242` 写着“Apple 私有框架相关路径……不用于 App Store 分发”，那是针对 Flutter 版的 `SwiftBackend`。补一句说明原生版不使用私有 API。
- 应用内开源许可页：去掉 x265（如果列了），列出实际链接的组件。

## 7. 开放问题（需要用户决定）

**用户决定（2026-11-13）。** 下面四项已定，原问题保留作背景；与正文冲突处以本段为准。

- **问题 1：接受。** 三通道增益图在 VideoToolbox 后端下改为 4:2:0。阶段 0 仍要出对比样张，但不再作为是否继续的门槛。
- **问题 2：暂时做成设置里可选。** GitHub 发布的 DMG 和未签名 IPA 暂时保留 x265，由用户在设置里选编码器；默认 VideoToolbox。TestFlight / App Store 构建不链接 x265，也不显示这个选项。对方案 C 的影响：
  - 后端不能只是编译期互斥。`XDREMUX_HEVC_BACKEND` 增加一个取值（暂名 `videotoolbox+x265`）：两个后端都编进去，设 `cfg(xdremux_hevc_vt)` 和 `cfg(xdremux_hevc_x265)`，运行期按转换配置里的编码器字段分发。`videotoolbox` 取值仍是纯 VideoToolbox，不查找 `libx265.a`。
  - `build_apple.sh` 用一个开关决定出哪一种（暂名 `XDREMUX_APPLE_HEVC=vt|vt+x265`）。`package_release.sh` 用带 x265 的那种并继续断言二进制里有 x265；`upload_testflight.sh` 用纯 VideoToolbox 的那种并断言不得含 x265。两个脚本都要核对 `BUILD_RECORD.txt` 的 `hevc_backend=`，防止拿错内核。
  - 内核经 C ABI 报告可用的编码器（`xdremux capabilities` 已有类似输出），界面据此决定是否显示选项，不靠 Swift 侧的编译条件。
  - 代价按 §6 所述接受：两套测试矩阵，GitHub 版选 x265 时输出与商店版不同。x265 路径保持与现状逐字节一致，沿用现有回归断言。
  - “暂时”的含义：VideoToolbox 版在真机上稳定后再决定是否移除，届时回到 §6 的原建议。
- **问题 3：暂不支持 Intel Mac。** macOS 切片只出 arm64（`XDREMUX_APPLE_ARCHS=arm64` 成为默认），iOS 模拟器切片同样只出 arm64。README 第 37、98 行关于 x86_64 的说明在阶段 3 一并改掉。阶段 3 验收里的“有 Intel Mac 的话加测一台”取消。
- **问题 4：参照问题 2。** “硬件编码”开关不删除，改成编码器选择（VideoToolbox / x265）。只有内核报告两个后端都可用时才显示，也就是只在 GitHub 构建里出现。`ConversionConfig.hardwareEncode` 字段沿用：真 = VideoToolbox，假 = x265；纯 VideoToolbox 构建里忽略该字段。默认值改为真，已存的旧配置需要迁移一次（旧默认是假，不能直接沿用，否则老用户仍停在 x265）。`HardwareTiles.swift` 和 `Pipeline.swift` 的 Swift 侧硬件分支照原计划删除，选择权下沉到内核。命令行工具相应提供同一个选项。

**用户决定（2026-11-14）。** TestFlight 版目前先带编码器切换，即用 `vt+x265` 内核，与 GitHub 发布包相同。上面问题 2 里“TestFlight / App Store 构建不链接 x265”一句只对 App Store 变体继续成立。`upload_testflight.sh` 默认 `vt+x265`，`XDREMUX_APPLE_HEVC=vt` 出纯 VideoToolbox 版；脚本已核对 `hevc_backend=` 并按变体扫描 x265。阶段 4 里“`upload_testflight.sh` 断言不得含 x265”相应改为只对 `vt` 变体。

**用户决定（2026-11-16）。** 暂时不去掉 x265，维持现在的切换机制：GitHub 发布包和 TestFlight 版继续用 `vt+x265` 内核，默认 VideoToolbox，设置里可切回 x265。阶段 4（发布脚本断言、许可文档、应用内许可页面）暂不执行，等用户重新提出。许可层面的未决事项（问题 7，带 x265 的 TestFlight 版与 GPL 是否相容）不因此消失，公开测试链接开放前仍需定下来。

仍未决定：问题 5–10。其中问题 7（许可文本）决定阶段 4 的文档，并且是公开 TestFlight 之前必须落定的一项。

1. **三通道增益图从 4:4:4 改成 4:2:0。** 这会改变苹果平台上所有 UHDR 模式照片的增益图格式（OPPO 兼容模式和现有硬件开关本来就是 4:2:0）。是否接受？如果阶段 0 的对比显示有可见差异，备选是 10 位 4:2:2（仅硬件编码器，兼容性未知）。
2. **GitHub 发布的 DMG / IPA 是否也去掉 x265。** 建议是。
3. **是否继续支持 Intel Mac。** 现在的构建带 x86_64 切片。Intel Mac 上 Monochrome 和 Main10 的编码能力没有机器可测。选项：继续带上并标注“未验证”；或者 macOS 版只出 arm64。
4. **“硬件编码”开关的去留。** 方案 C 下所有编码都走 VideoToolbox，这个开关没有意义。建议删除界面项，配置字段保留但不生效。是否同意？
5. **是否保留强制软件编码器的隐藏开关。** 对排查机型差异有用，但多一条要测的路径。
6. **阶段 0 用不用开 PR。** 它只产出实验工具和结论。可以只把结论记进本文件。
7. **许可文本。** 原生版以什么许可上架（例如对 App Store 分发的附加许可或双重许可），需要用户和上游作者确认后写进 `LICENSING.md`。这决定阶段 4 的文档怎么写。
8. **画质基准怎么定。** `Quality` 取值是按“与 x265 版 PSNR 相当”定，还是按“体积相当”定？两者在硬件编码器上通常不能同时满足。建议主图按画质，遮罩和增益图按体积上限。
9. **`lib.rs:2306` 的 4:4:4 主图。** 这条路径在方案 C 下会随硬件路径一起删除（`xdremux_prepare_tiles` 仍留给 Flutter 版）。是否顺手把它改成 4:2:0，还是留给 Flutter 侧另行处理？
10. **最低系统版本。** 如果 iOS 17.0–17.3 上遇到编码器问题（§3.3 第 5 点），是否愿意把最低版本提到 17.4？

## 8. 风险与待验证项汇总

| 项 | 状态 | 在哪个阶段解决 |
|---|---|---|
| 苹果相册接受 VideoToolbox 编的摄影风格、人像、实况文件 | 待验证（上游 macOS 版同样做法可行，是旁证） | 阶段 0 |
| iPhone 硬件编码器支持 Monochrome 与 Main10 静态图 | 待验证 | 阶段 0 |
| 硬件编码器的尺寸取整（裁剪窗口）不影响辅助图识别 | ImageIO 已通过，相册待核对（§9.5） | 阶段 0 |
| 三通道增益图 4:2:0 的画质影响 | macOS HDR 渲染无明显差异（§9.3） | 阶段 0 |
| VideoToolbox 原样写出 OPPO 约定的 VUI | 已验证（§9.4） | 阶段 0 |
| 带 ICC 主图的 VUI（未指定原色与传输函数） | 已验证（§9.4） | 阶段 0 |
| `Quality` 取值与 x265 的画质、体积对应关系 | 待校准 | 阶段 2 |
| OPPO 相册接受 Main profile 的 4:2:0 增益图块与写回主图 | 待验证 | 阶段 3 |
| iOS 17.0–17.3 的软件编码器回退 | 待验证 | 阶段 3 |
| Intel Mac | 待验证或放弃支持 | 阶段 3（取决于 §7 第 3 点） |
| CI 虚拟机里没有硬件编码器 | 已知，靠软件编码器回退 | 阶段 2 |
| 输出不可字节复现，测试只能查结构和误差 | 已知，测试策略已调整 | 阶段 2 |
| 二进制里残留 “x265” 字符串导致发布检查误报 | 已知 | 阶段 2、3 |

## 9. 阶段 0 结果（2026-11-13，机器侧）

### 9.1 做法

- 实验分支 `exp/apple-vt-phase0`（工作树 `/Volumes/MacData/XDRemux/wt-vt-phase0`，本地提交 `47f63e6`，未推送，不合并）。
- 内核加了一个只供实验用的开关 `XDREMUX_EXP_ENCODER=<工具路径>`：`x265_encode_tiles_inner` 和 `encode_thumbnail_10bit` 把平面数据写到临时目录，交给外部工具编码，再读回 Annex-B 流。三通道图一律按 4:2:0 走。
- 外部工具 `tools/exp/vtenc.swift` 只用公开的 VideoToolbox API，默认硬件编码器，`Quality` 统一取 0.9（未校准）。
- `tools/exp/run_phase0.sh` 对每张样张各跑一遍 x265 和 VideoToolbox，走 `xdremux_convert_pipeline`，配置为苹果输出加摄影风格（人像样张另加人像）。
- 环境：Apple M6，macOS 27.2.1。

产物在 `/Volumes/MacData/XDRemux/release-artifacts/vt-phase0/`，`x265/` 和 `vt/` 两个子目录文件名一一对应。

### 9.2 样张与内核自检

| 编号 | 来源 | 类别 | x265 版 | VideoToolbox 版 |
|---|---|---|---|---|
| A1、A2 | OPPO HEIC | 单通道增益图，摄影风格 | 通过 | 通过 |
| B1、B2 | OPPO HEIC（大师模式） | 三通道增益图，摄影风格 | 通过 | 通过 |
| C1、C2 | Ultra HDR JPEG | 主图合成，摄影风格 | 通过 | 通过 |
| D1、D2 | OPPO 人像 HEIC | 人像加摄影风格 | 人像自检不通过 | 人像自检不通过 |
| F1、F2 | OPPO 动态照片 JPEG | 实况加摄影风格 | 通过 | 通过 |

- “通过”指 `xdremux_convert_pipeline` 报告成功，`xdremux_verify_output` 和 `xdremux_verify_styles_output` 为真。
- D1、D2 两版都报 “output is missing Apple Portrait data”，与编码器无关，是自检本身的缺陷：
  - `verify_portrait_graph`（`xdremux/rust/src/lib.rs:2579`）要求存在类型等于 `"mimehdrgm-xmp"` 的条目。
  - 这个字符串是旧解析器把四字节类型 `mime` 和条目名 `hdrgm-xmp` 连读出来的。提交 `97269d1`（2026-09-10）把 `parse_iinf` 改成只取四字节类型（`isobmff.rs:652-661`）之后，条目类型只会是 `mime`，这个条件永远为假。
  - 两张样张的输出里条目是齐的：文件里有 `mime` 加 `hdrgm-xmp` 的条目，四个人像字符串都在，ImageIO 也读得出视差图和全部人像遮罩（见下表）。
  - 影响范围：`xdremux_verify_portrait_output` 和 `xdremux_convert_pipeline` 的人像校验，从 `v0.4.3`、`apple-v0.1.0`、`harmony-v0.5.1` 起的版本都带着。只要开了人像，转换就会在校验这一步报失败。
  - 修复在 PR BeetMan/XDRemux-Flutter#99（分支 `fix/portrait-verify-mime`，未合并）：从 `raw_infe` 里读条目名，要求有具名的 `hdrgm-xmp` 条目和至少一个无名 `mime` 条目，另加一条回归测试。修后两张人像样张的校验结果是 `["iso","styles","portrait"]`。
- 华为人像没有样张，未测。
- OPPO 输出模式下的水印写回主图没有跑整条流程，只单独验证了色彩标记（见 9.4）。
- VideoToolbox 版的日志里没有任何一处直接打开 x265，全部编码都走了外部工具。

### 9.3 ImageIO 解码对照（macOS）

两版文件都能被 ImageIO 解出主图和全部辅助图，尺寸一致。下表是 VideoToolbox 版相对 x265 版的差异。

| 编号 | 主图 | 增益图或 HDR 渲染 | 遮罩与视差 |
|---|---|---|---|
| A1 | 逐像素相同（主图未重编码） | 增益图 PSNR 71.0 dB；HDR 峰值 1.21 对 1.21 | 天空遮罩相同 |
| A2 | 相同 | 增益图 PSNR 51.8 dB；HDR 峰值 2.75 对 2.75 | 天空遮罩相同 |
| B1 | 相同 | HDR 峰值 4.96 对 4.96，平均绝对差 0.0005，最大 0.32 | 天空遮罩相同 |
| B2 | 相同 | HDR 峰值 3.02 对 3.02，平均绝对差 0.0001 | 天空遮罩相同 |
| C1 | PSNR 49.6 dB | HDR 峰值 1.08 对 1.08 | 天空遮罩相同 |
| C2 | PSNR 51.1 dB | HDR 峰值 4.75 对 4.75 | 天空遮罩相同 |
| D1 | PSNR 51.6 dB | HDR 峰值 2.50 对 2.49 | 六种遮罩相同；视差平均绝对差 0.0008（量程 0–2.1） |
| D2 | PSNR 49.8 dB | HDR 峰值 2.09 对 2.09 | 遮罩 PSNR 64–66 dB；视差平均绝对差 0.0007 |
| F1 | PSNR 49.8 dB | HDR 峰值 3.73 对 3.81 | 天空遮罩相同 |
| F2 | PSNR 48.6 dB | HDR 峰值 2.97 对 3.00 | 天空遮罩相同 |

- HDR 渲染用 `kCGImageSourceDecodeToHDR` 解到扩展线性 Display P3，按四分之一尺寸比较。
- B1、B2 的 x265 版增益图是 4:4:4，VideoToolbox 版是 4:2:0，HDR 渲染的平均差在 0.0005 以内。三通道增益图改 4:2:0 在 macOS 的渲染结果上看不出问题。
- 实况的 MOV 两版轨道结构相同：主视频 Main10，128×86 的 Main10 线性缩略图轨，三条 256×170 的单色轨。

### 9.4 码流记录（`ffprobe`）

| 用途 | profile | 像素格式 | 范围 | 原色 / 传输 / 矩阵 |
|---|---|---|---|---|
| 单通道增益图块、各类遮罩 | Rext（单色） | gray | 全范围 | 未指定 |
| 三通道增益图块 | Main | yuvj420p | 全范围 | bt709 / bt709 / bt709 |
| 带 ICC 的合成主图块 | Main | yuvj420p | 全范围 | 未指定 / 未指定 / bt709 |
| OPPO 约定（单独验证） | Main | yuvj420p | 全范围 | bt470bg / iec61966-2-1 / smpte170m |
| 线性缩略图 | Main 10 | yuv420p10le | 有限范围 | 未指定 |

- 色彩标记要用会话属性（`kVTCompressionPropertyKey_ColorPrimaries` 等）设置。只在像素缓冲上挂附件不会写进码流。
- OPPO 那组 “limited 数据标 full range” 的标记可以由 VideoToolbox 原样写出。OPPO 相册是否接受，仍要在 OPPO 手机上验证。

### 9.5 尺寸取整

- 硬件编码器把编码尺寸取整（例如线性缩略图 682×1024 编成 688×1024），靠裁剪窗口还原。
- 样张里非 16 倍数的遮罩（1232×1640、3242×5444、1500×2000）和 256×170 的视频轨，ImageIO 与 `ffprobe` 读回的都是正确尺寸。
- 苹果相册对这些取整后的辅助图是否照常识别，属于下面的人工核对。

### 9.6 体积

`Quality` 0.9 下，十张里有七张 VideoToolbox 版比 x265 版小 4%–25%（F1：4.46 MB 对 5.92 MB），A1、A2、D2 反而大 2%–15%（A2：1.77 MB 对 1.54 MB）。画质对应关系留到阶段 2 校准。

### 9.7 还没做的：人工核对（需要用户）

把 `vt/` 和 `x265/` 两个目录的文件分别导入 macOS 照片 App 和一台 iPhone，逐项对照。实况用 `F1-live-styles-live/`、`F2-live-styles-live/` 里的 HEIC 加 MOV 成对导入。

| 项目 | 样张 | macOS 照片 | iPhone 相册 |
|---|---|---|---|
| HDR 提亮，信息面板显示 HDR | 全部 | 待核对 | 待核对 |
| 编辑里出现“风格”，可切换、可拖动色调与色彩，保存不报错 | A、B、C、F | 待核对 | 待核对 |
| 显示“人像”标记，可调光圈、点选对焦点 | D | 待核对 | 待核对 |
| 实况长按能播放，风格对视频也生效 | F | 待核对 | 待核对 |

仍然待验证、这一步覆盖不到的：

- iPhone 自己的编码器是否支持单色和 Main10 静态图。上面的文件都是在 Mac 上编的，只能验证相册是否接受这种码流。要验证 iPhone 编码器，需要阶段 2 的后端跑在真机上，或者把 `vtenc` 包成一个最小的 iOS 测试。
- 华为人像，缺样张。
- OPPO 相册对 VideoToolbox 版 OPPO 输出的识别。

### 9.8 人工核对的初步结果（2026-11-13，macOS 照片 App）

- 三组样张已导入本机照片 App 的三个相簿：`XDRemux 阶段0 x265`、`XDRemux 阶段0 vt`（硬件编码器）、`XDRemux 阶段0 vt-sw`（软件编码器，文件在 `/Volumes/MacData/XDRemux/release-artifacts/vt-phase0-sw/vt-sw/`）。实况的 HEIC 和 MOV 都被配成了一张实况照片。
- 用户初看三组的显示都正常。
- 发现一个问题：实况样张 F1（`标准 1x.heic`，4416×6624）在照片 App 里调整并保存后，整张图出现绿色细网格。**三组都出现**，包括 x265 版，所以与换编码器无关，是现有输出的问题。
- 还不清楚的：具体是哪种调整触发；其他样张是否也有；iPhone 相册上是否一样。原因未查。
- 对本计划的影响：不构成 VideoToolbox 方案的阻碍，但摄影风格“保存不报错”这一项目前在 x265 基线上就不成立，核对表里这一项要等这个问题查清后再判。
- iPhone 相册的核对仍未做。

### 9.9 绿色网格的排查记录（2026-11-13，与去 x265 无关的现有问题）

- 触发条件：主图 4416×6624（OPPO “标准 1x / 3x” 带水印边框的 JPEG）加摄影风格，在 macOS 照片 App 里切换风格并保存。刚保存时显示正常，离开这张照片再回来才出现，说明是后台的全尺寸渲染出的问题。
- 已排除：编码器（x265、VideoToolbox 硬件、软件三版都有）、实况配对（纯静态图也有）、主图图块数量（图块改 1024 后仍有；6144×8192、192 个图块的样张正常）、线性缩略图内容（导出后是干净的）。
- 不开风格的同一张图，调整保存正常。
- 从照片 App 导出保存后的图逐像素测量：黑线成对出现，周期正好 23 像素，绿线周期 46 像素。4416÷23=192，6624÷23=288，对应风格增量图 1920×2880 的每 10 个像素。
- 已确认原因在风格增量图的声明尺寸与主图的比例：同一张图把增量图尺寸改成 1472×2208（比例 3.0）或 1840×2760（比例 2.4）就正常，保持 1920×2880（比例 2.3）就出绿格。
- 还不知道照片 App 的确切规则。目前所有数据点里，只有 2.3 这个比例在单精度浮点下正反两个方向都向下舍入，这是一个待验证的猜测。第四轮样张（K1 960×1440、K2 1600×2400、K3 1918×2878）用来验证。
- 排查样张在 `/Volumes/MacData/XDRemux/release-artifacts/vt-phase0-greengrid/`，照片 App 相簿 `XDRemux 绿格排查`。实验开关 `XEXP_DELTA_W` / `XEXP_DELTA_H` 只在实验工作树里，未提交。
- 修复会改 `styles_native.rs` 的 `fitted_size`，独立于本计划，单开 PR。

#### 第四轮结果与第五轮样张（2026-11-13）

第四轮结果：只有 K3（1918×2878）出绿格，K1（960×1440）和 K2（1600×2400）正常。“单精度舍入”的猜测被否定：它预期 K1 出绿格、K3 正常，结果正好相反。

目前 4416×6624 主图上的数据点：1920×2880、1918×2878 出绿格；1840×2760、1600×2400、1472×2208、960×1440 正常。规律仍不清楚。

真实 iPhone 样张（`test-media/sources/iphone-*`，51 张带风格）的增量图尺寸：

| 主图 | 增量图 | 比例 | 张数 |
|---|---|---|---|
| 4032×3024 | 2880×2160 | 1.4 | 11 |
| 5712×4284 | 4096×3072 | 约 1.394 | 38 |
| 8064×6048 | 5760×4320 | 1.4 | 2 |

iPhone 的增量图约为主图的 5/7，不设 2880 上限。我们的 `fitted_size` 把增量图限制在 2880×2560 以内，主图越大比例越偏离 iPhone。

第五轮样张（实验开关新增 `XEXP_DELTA_ROWS`、`XEXP_DELTA_COLS`，未提交）：

| 文件 | 增量图 | 比例 | 图块 |
|---|---|---|---|
| L1-std1x-delta3154x4732-apple57 | 3154×4732 | 1.4（iPhone 规则） | 7×10 |
| L2-std1x-delta2208x3312 | 2208×3312 | 2.0 | 5×7 |
| L3-std1x-delta2560x3840 | 2560×3840 | 1.725 | 5×8 |
| L4-std1x-delta2000x3000 | 2000×3000 | 2.208 | 5×6 |
| L5-std1x-delta1900x2850 | 1900×2850 | 2.324 | 5×6 |
| L6-std1x-delta1880x2820 | 1880×2820 | 2.349 | 5×6 |

结果待填。

#### 第五轮结果与修复（2026-11-13）

第五轮结果：只有 L4（2000×3000，比例 2.208）出绿格；L1（iPhone 的 5/7）、L2、L3、L5、L6 正常。

4416×6624 主图上，出绿格的增量图宽度是 1918、1920、2000，正常的是 1900 及以下、2208 及以上。照片 App 的确切规律仍不清楚，但 iPhone 自己用的 5/7 是正常的。

修复：分支 `fix/styles-delta-map-size`，工作树 `/Volumes/MacData/XDRemux/wt-delta-size`，已推送并开 PR #100。`styles_native.rs` 新增 `delta_map_layout`：旧上限会把增量图缩到主图的 0.7 倍以下时，改用 5/7 并按尺寸增加 512 图块；其余主图的尺寸和 30 个图块不变。`cargo test --release --lib`：307 通过，3 忽略。

受影响的主图：长边超过约 4100 的，以及 3072×4608、3072×4536 这类 2:3 的。4096×3072 不变（增量图仍是 2880×2160，文件大小相同）。

验证样张（修复后的代码生成，内核自检都通过，已导入相簿“XDRemux 绿格排查”）：

| 文件 | 主图 | 增量图 | 结果 |
|---|---|---|---|
| M1-fix-4416x6624 | 4416×6624 | 3154×4732 | 正常 |
| M2-fix-3072x4608 | 3072×4608 | 2194×3292 | 正常 |
| M3-fix-6144x8192 | 6144×8192 | 4388×5852 | 正常 |
| M4-fix-8192x6144 | 8192×6144 | 5852×4388 | 正常 |
| M5-fix-6484x10888 | 6484×10888 | 4632×7778 | 正常 |
| M6-fix-8192x7168 | 8192×7168 | 5852×5120 | 正常 |
| M7-fix-3072x4536 | 3072×4536 | 2194×3240 | 正常 |

M1–M7 人工核对全部正常。PR：https://github.com/BeetMan/XDRemux-Flutter/pull/100（未合并）。

未处理：`apps/flutter/ios/SwiftBackend/.../ApplePhotographicStylesPipeline.swift:2872` 有同样的 2880×2560 上限，没有改，也没有确认这条路径是否还在用。

## 10. 阶段 1 执行记录（2026-11-14，分支 `claude/refactor-hevc-backend-f63382`）

PR：https://github.com/BeetMan/XDRemux-Flutter/pull/107（提交 `97687fb`，基于 main `5518561`，未合并）。纯重构，没有 VideoToolbox 代码，没有改 `build_apple.sh`、Swift 包、各平台构建脚本和发布脚本。

### 10.1 做了什么

- `hevc.rs` 拆成 `hevc/mod.rs`（色彩转换、NAL 工具、hvcC、对外入口、测试）、`hevc/x265.rs`、`hevc/ffmpeg.rs`。
- 后端统一接口：`encode(&EncodeRequest, SourcePictures) -> EncodedTiles`。
  - `EncodeRequest`：宽高、`HevcLayout`（单色 / 4:2:0 / 4:4:4）、`HevcBitDepth`（8 / 10）、`HevcColor`（`Bt709Full`、`OppoSdr`、`IccPrimary`、`Bt601LimitedLinear`）、`HevcContent`（`Primary`、`GainMap`、`Matte`、`Disparity`、`LinearThumbnail`）。
  - `SourcePictures`：`Gray8` / `Rgb8` / `Rgb16`。传的是源像素而不是平面 YUV，因为 ffmpeg 后端一直是把 gray / rgb24 原样交给 ffmpeg 转换的，改成平面 YUV 会改变它的输出。x265 后端自己调 `mod.rs` 里的转换函数。
  - `EncodedTiles`：码流加后端实际使用的布局，`chroma_format_idc()` 给 hvcC 用。
- 运行期分发的位置：`HevcBackend::COMPILED` 列出本二进制里编进了哪些后端，`HevcBackend::active()` 决定当前用哪个，`encode()` 按它 `match`。现在只编一个后端，`active()` 直接取第一个。阶段 2 做 `videotoolbox+x265` 时只需让 `active()` 读转换配置，入口和后端都不用动。
- 入口函数名不变。`x265_encode_tiles` 多了一个 `HevcContent` 参数，返回值从 `Vec<Vec<u8>>` 变成 `EncodedTiles`；`encode_thumbnail_10bit` 不再带 `cfg(xdremux_main10)`，没有 10 位归档时返回 `Unsupported`（调用方本来就先查 `main10_available()`）。
- 调用点：内核 17 处、`tests/conformance` 8 处的 `extract_hvcc_config_with_chroma*` 改用后端返回的色度值。内容类别都按实际传入：增益图块 `GainMap`，合成主图、OPPO 写回、`container_build` 用 `Primary`，各类遮罩 `Matte`，人像视差图 `Disparity`，线性缩略图（含 8 位退路和黑色占位）`LinearThumbnail`。两个示例程序里的合成 RGB 图块用 `Primary` 并写了注释。
- `build.rs`：`XDREMUX_HEVC_BACKEND` 不设或 `x265` 为默认；`ffmpeg` 等价于 `XDREMUX_USE_FFMPEG=1`（旧变量继续有效）；其他取值 `panic!`。安卓仍强制 x265。新增 `cfg(xdremux_hevc_x265)`，`Cargo.toml` 的 check-cfg 已加。
- 顺手改了四处入库文档里指向 `hevc.rs` 和 `XDREMUX_USE_FFMPEG` 的说明（`docs/architecture/overview.md`、`docs/formats/hevc-hevc-conventions.md`、`docs/modules/hevc-x265.md`、`docs/operations/building.md`），只改路径和变量名。

### 10.2 实测（Apple M6，macOS 27.2.1）

哈希比对：用同一个驱动程序分别链接 main 和本分支的内核，经 `xdremux_convert_pipeline`、`xdremux_make_live_photo`、`xdremux_writeback_returned_photo` 跑同一批样张。脚本和产物在会话的临时目录里，没有提交。

| 后端 | 文件数 | 逐字节相同 | 易变字节之外相同 | 不同 |
|---|---|---|---|---|
| x265，转换与实况 | 32 | 20 | 12 | 0 |
| x265，OPPO 水印写回 | 6 | 4 | 2 | 0 |
| ffmpeg，转换与实况 | 32 | 20 | 12 | 0 |

- 样张 10 张：A1、A2（OPPO 单通道增益图）、B1、B2（大师模式三通道）、C1、C2（Ultra HDR JPEG）、D1、D2（OPPO 人像）、F1、F2（动态照片），与 §9.2 相同。每张跑三种配置：苹果输出加摄影风格（人像样张另加人像）、OPPO 输出、苹果输出且关 OPPO 兼容（4:4:4 增益图路径）。C1 在后两种配置下转换失败（“JPEG input requires an Ultra HDR gain map”），main 上同样失败，所以是 28 个 HEIC 加两组实况的 HEIC 和 MOV，共 32 个文件。
- “易变字节”：带摄影风格图或实况配对的输出里有按系统时间生成的 UUID 和时间戳，**同一个 main 二进制跑两遍就不一样**（每个文件 24–74 个字节，文件大小相同）。做法是用 main 跑三遍（ffmpeg 两遍）找出这些偏移，前后各扩 40 字节后屏蔽（每个文件 116–1315 字节，文件 1.5–16.9 MB），其余字节必须全部相同。不带风格的输出和两张人像加风格的输出是逐字节相同的。
- 写回的 6 个组合：B1、B2 的原图配上面生成的转换件，`output_mode` 0 和 1，带与不带水印还原。OPPO 约定的编码路径（`x265_encode_tiles_oppo_sdr`）在这里被走到（日志里有 360 多次 RGB 编码器打开）。

测试：

- x265：`cargo test --workspace` 340 通过，0 失败，7 忽略（内核 lib 308 通过）。`tests/fixtures_gate.rs`、`tests/jpeg_hdr_regression.rs` 没有改动。
- ffmpeg：`XDREMUX_USE_FFMPEG=1` 和 `XDREMUX_HEVC_BACKEND=ffmpeg` 两种写法，按 `conformance.yml` 的三条命令跑：工作区构建成功，内核 lib 304 通过，conformance 12 通过。
- `XDREMUX_HEVC_BACKEND=videotoolbox` 构建报错；`XDREMUX_HEVC_BACKEND=x265` 同时设了 `XDREMUX_USE_FFMPEG=1` 也报错。
- `tools/apple/check_header.sh` 通过，头文件无变化。
- `XDREMUX_APPLE_SLICES="macos" xdremux/rust/build_apple.sh` 成功，`apps/apple/Packages/XDRemuxKit` 的 `swift test`：20 个测试，6 个跳过，0 失败。（工作树里没有 `XDRemuxTransferCore.xcframework`，从主检出软链过来的，未提交。）
- 警告：x265（`--all-targets`）、x265 不带 10 位归档、ffmpeg 三种构建下，各目标的警告数与 main 相同。

### 10.3 与计划不一致之处

- `lib.rs` 里 `pub mod x265_ffi` 的条件没有改成 `cfg(xdremux_hevc_x265)`，仍是 `cfg(not(xdremux_ffmpeg_fallback))`。原因：cbindgen 会把这个条件抄进 `xdremux_core.h`（`#if !defined(XDREMUX_FFMPEG_FALLBACK) && defined(XDREMUX_MAIN10)`），一改头文件就变。两种写法现在等价。阶段 2 加 VideoToolbox 后端时必须改，届时头文件会跟着变一行。
- ffmpeg 后端返回的是“请求的布局”而不是它实际编出来的布局。它一直把灰度和不带 ICC 的 RGB 编成 4:4:4，但 hvcC 里写的是调用方要求的值；为了输出不变保留了这个不一致，代码里有说明。
- `assemble_prepared_tiles`（外部硬件编码器交回的图块）仍然写死 4:2:0：码流不是内核后端编的，没有返回值可用。加了注释。
- `encode_hevc_tile_gray` / `encode_hevc_tile_rgb` 这两个只有测试在用的单块函数没有并入统一请求。它们的参数和批量路径不同（`repeat-headers=1`、`frame-threads=1`、默认 4:4:4），并进去就得给请求加只为测试服务的字段。
- 线性缩略图 10 位路径的 “宽高不小于 64” 仍在 `linear_thumbnail.rs` 的调用点，没有下沉到后端。这是 x265 的限制，阶段 2 要改成问后端。
- `isobmff_write.rs`、`watermark_codec.rs` 里 `#[cfg(not(xdremux_ffmpeg_fallback))] drop_parameter_nals` 这类按后端区分码流形态的条件没有动。两个后端同时编入时这里要改成运行期判断。
- `XDREMUX_HEVC_BACKEND=x265` 与 `XDREMUX_USE_FFMPEG=1` 同时出现时直接报错，计划没有规定这种情况。

### 10.4 未验证

- 安卓、Windows、Linux、鸿蒙、Flutter iOS 的构建没有在本机跑，靠 CI。
- `tests/jpeg_hdr_regression.rs` 的两个测试是 `#[ignore]`，需要私有样张，没有跑。
- 华为人像仍然没有样张。
- 没有做任何相册里的人工核对；本阶段输出与 main 相同，不需要。

## 11. 阶段 2 执行记录（2026-11-14，分支 `feat/hevc-videotoolbox-backend`）

PR：https://github.com/BeetMan/XDRemux-Flutter/pull/108（提交 `d6e8302`、`7defd6f`，基于 main `4939c7b`，未合并）。默认后端仍是 x265，`build_apple.sh` 的默认值、App 界面、设置项、发布脚本、许可文档都没有动。

### 11.1 做了什么

- **构建。** `XDREMUX_HEVC_BACKEND` 新增 `videotoolbox`（不编译 `x265_helper.c`、不查找 `libx265.a`、不设 `xdremux_main10`）和 `videotoolbox+x265`（两个后端都编入）。非苹果目标直接报错。新 cfg：`xdremux_hevc_vt`。
- **后端。** `src/vt_hevc.c`（约 420 行）加 `src/hevc/vt.rs`。只用公开 C API。C 侧是会话式接口（打开 / 编一张 / 关闭），取消检查和参数集比对放在 Rust 里。
  - 一批图一个 `VTCompressionSession`，逐张强制关键帧并同步等输出。
  - 编码器规格里写 `EnableHardwareAcceleratedVideoEncoder=true`（优先硬件，允许软件）；硬件会话建不起来、或硬件编码器中途编某一张失败时，整批改用软件编码器重编（保证一批图仍共用同一份参数集）；`XDREMUX_VT_SOFTWARE=1` 强制软件。这个键在 iOS 上 17.4 才公开，用 `__builtin_available` 包住，17.0–17.3 走系统默认。
  - 色彩标记用会话属性设置。灰度图不设任何色彩属性。
  - 4:4:4 请求降为 4:2:0，`EncodedTiles.layout` 如实返回。
  - 第一张带 VPS/SPS/PPS，其余只留图像切片；逐张比对参数集，不一致报错。SEI、AUD 不拷贝。
  - 线性缩略图用 Main10 加 `x420`，没有 64 像素下限。
- **运行期选择。** `HevcBackend::active()` 的顺序：本次转换的选择（`xdremux_convert_pipeline` 配置里的 `hevcEncoder`，线程内作用域）→ 进程级选择（新 C 接口 `xdremux_set_hevc_encoder`，给实况、写回和旧入口用，它们没有配置参数）→ 环境变量 `XDREMUX_HEVC_ENCODER`（诊断和测试用，只在编入两个后端时生效）→ 构建默认值（VideoToolbox 在前）。本二进制没有的名字一律忽略，回到默认。
- **能力报告。** `xdremux_codec_capabilities` 增加 `hevcEncoders`（数组，默认在前）和 `defaultHevcEncoder`。界面据此决定是否显示选项。
- **§10.3 里的编译期条件。** `pub mod x265_ffi` 改为 `cfg(xdremux_hevc_x265)`；按后端区分码流形态的三处改成运行期的 `hevc::tile_stream_for_container`；线性缩略图的 64 像素下限改成 `hevc::main10_supported(w, h)`；`main10_available()` 也按当前后端判断。
- **C 头文件。** 新增 `xdremux_set_hevc_encoder`；去掉了误入头文件的内部测试函数 `xdremux_encode_10bit_planes_checked`（在 `cbindgen.toml` 里排除）。用 cbindgen 重新生成。
- **不含 “x265”。** 入口改名为 `encode_tiles`、`encode_tiles_oppo_sdr`、`encode_icc_primary_tiles`；写回计时的阶段名在 VideoToolbox 下是 `videotoolbox_encode`（x265、ffmpeg 下仍是 `x265_encode`）；脚手架阶段的诊断变量 `XSCAFFOLD_X265_MATTE_420` 只在带 x265 或 ffmpeg 的构建里存在。
- **`build_apple.sh`。** 非默认开关 `XDREMUX_APPLE_HEVC=x265|vt|vt+x265`，`BUILD_RECORD.txt` 多一行 `hevc_backend=`。`vt` 时不构建也不合并 x265。
- **Swift。** 只改了 `XDRemuxKit/Package.swift`：加链接 VideoToolbox、CoreMedia、CoreVideo、CoreFoundation，`c++` 保留。
- **CI。** 新工作流 `.github/workflows/apple-vt-core.yml`：VideoToolbox 后端跑 `cargo test -p xdremux-core`，再检查 release 库里没有 x265 字符串和符号。触发条件按 #101 的规则：main 上内核有改动时跑一次；PR 只在改到 `hevc/vt.rs`、`vt_hevc.c` 或工作流本身时跑；可手动触发。
- **诊断开关。** `XDREMUX_HEVC_DEBUG=1` 每批编码打印一行（编码器、内容类别、尺寸、请求与实际布局、字节数），所有后端通用；`XDREMUX_VT_QUALITY_<PRIMARY|GAINMAP|MATTE|DISPARITY|LINEAR>` 覆盖某一类的 `Quality`。

### 11.2 `Quality` 取值表

做法：临时给内核加了一个导出源像素的补丁（未提交），用十张样张的真实转换导出 54 批源图；一个仓库外的探针程序链接双后端内核，对每批分别用 x265 和 VideoToolbox（多个 `Quality`）编码，码流用 ffmpeg 解码后与源图比亮度 PSNR。主图和增益图图块每批抽 12 块，其余整张。硬件编码器，Apple M6。

| 内容类别 | `Quality` | 体积（相对 x265） | 亮度 PSNR | x265 的 PSNR | 定值依据 |
|---|---|---|---|---|---|
| 主图（8 位 4:2:0） | 0.92 | 100.0% | 54.29 dB | 54.21 dB | 画质对齐 |
| 增益图，灰度 | 0.87 | 95.8% | 58.14 dB | 57.01 dB | 体积上限 |
| 增益图，彩色（4:2:0；x265 是 4:4:4） | 0.93 | 98.1% | 60.02 dB | 58.95 dB | 体积上限 |
| 遮罩 | 0.90 | 45.3% | 85.62 dB | 80.13 dB | 远低于上限，已高于 x265 |
| 视差图 | 0.88 | 96.1% | 60.92 dB | 58.13 dB | 体积上限 |
| 线性缩略图（Main10） | 0.70 | 112.5% | 51.21 dB | 50.36 dB | 画质对齐 |

硬件编码器上相邻取值的数据（体积占 x265 的比例 / PSNR 差）：

| 类别 | 0.85 | 0.9 | 0.95 |
|---|---|---|---|
| 主图 | 47.5% / −4.98 | 83.7% / −1.33 | 135.0% / +2.65 |
| 增益图，灰度 | 77.3% / −0.10 | 130.0% / +2.97 | 222.8% / +7.09 |
| 增益图，彩色 | 52.5% / −4.75 | 77.1% / −1.17 | 116.8% / +2.82 |
| 遮罩 | 41.0% / +1.61 | 45.3% / +5.49 | 53.2% / +11.79 |
| 视差图 | 71.4% / +0.65 | 116.0% / +4.42 | 222.1% / +13.22 |
| 线性缩略图 | 238.2% / +7.00 | 421.8% / +11.84 | 686.1% / +16.82 |

- 硬件编码器在 1.0 时解码结果与源图完全相同（无损），主图体积是 x265 的 215%。
- 彩色增益图只比了亮度；x265 的体积里含全分辨率色度。
- 软件编码器同一取值更省也更差：主图 0.92 是 x265 体积的 79.2%、PSNR 低 1.49 dB；0.95 是 108.8%、高 1.34 dB。取值表只按硬件编码器校准，没有给软件编码器单独定值。
- 十张样张（带摄影风格）的整文件体积：VideoToolbox 版相对 x265 版在 −5.8% 到 +16.6% 之间（D1 +16.6%，B2 +7.7%，F1 +7.3%，其余 ±2% 以内或更小）。

### 11.3 实测（Apple M6，macOS 27.2.1）

| 项目 | 结果 |
|---|---|
| 默认 x265 构建 `cargo test --workspace` | 340 通过，0 失败，7 忽略；回归哈希断言未改 |
| x265 构建输出对比 main（阶段 1 的基线和脚本，32 个文件） | 20 个逐字节相同，12 个在易变字节之外相同，0 个不同 |
| ffmpeg 两种写法，`conformance.yml` 的命令 | 内核 lib 304 通过，conformance 12 通过；输出对比 main 32 个文件 0 不同 |
| `videotoolbox` 构建 `cargo test --workspace` | 351 通过，0 失败；`XDREMUX_VT_SOFTWARE=1` 下同样 351 通过 |
| `videotoolbox+x265` 构建 `cargo test --workspace` | 354 通过，0 失败；默认（VideoToolbox）和 `XDREMUX_HEVC_ENCODER=x265` 各跑一遍 |
| 双后端构建选 x265（转换走配置键，实况和写回走进程级接口）对比 main | 32 个文件：20 个逐字节相同，12 个易变字节之外相同；写回 2 个文件逐字节相同 |
| 十张样张跑 VideoToolbox（纯构建和双后端构建，各三种配置） | 32 次里 30 次成功，与 x265 相同（失败的两次是 C1 不开风格，main 上同样失败）；三个自检的结果与 x265 版逐项相同（人像两张 `["iso","styles","portrait"]`） |
| ImageIO 解十张 VideoToolbox 版 | 主图和全部辅助图都能解出，有无和尺寸与 x265 版一致；HDR 渲染与 x265 版的平均绝对差最大 0.0022，视差图平均绝对差 0.0008（量程 0–2.1） |
| `ffprobe` 看 VideoToolbox 码流（硬件和软件各一遍） | 单色：Rext、gray、全范围、未指定；彩色增益图和主图：Main、yuvj420p、bt709 三项；OPPO 约定：Main、yuvj420p、全范围、bt470bg / iec61966-2-1 / smpte170m；线性缩略图：Main 10、有限范围、未指定。与 §9.4 一致。带 ICC 的主图（只写矩阵）由解析 VUI 的单元测试覆盖 |
| VideoToolbox 构建跑写回 | 3 个组合都成功并通过校验 |
| 纯 `videotoolbox` 的 release 库和 XCFramework | `strings -a` 里 x265 计数 0，`nm` 里没有 x265 |
| `XDREMUX_APPLE_HEVC=vt build_apple.sh`，先把 `vendor/x265` 挪走 | 构建成功 |
| VideoToolbox 版 XCFramework 上 `XDRemuxKit` 的 `swift test` | 20 个测试 0 失败（不给样张时 6 个跳过；给了 `XDREMUX_SAMPLE_DIR` 和 `XDREMUX_MOTION_SAMPLE_DIR` 后 0 跳过 0 失败） |
| 命令行工具冒烟（VideoToolbox 版） | `--version`、`capabilities`（报告 `["videotoolbox"]`）、一张人像加风格的转换、`verify` 都成功 |
| `XDREMUX_APPLE_HEVC=vt+x265 build_apple.sh` | 构建成功 |
| iOS 真机和模拟器目标 | `vt_hevc.c` 与内核能编译，没有运行 |
| `tools/apple/check_header.sh` | 通过 |
| 警告 | x265 和 ffmpeg 构建各目标的警告数与 main 相同 |

VideoToolbox 后端新增的单元测试（13 个，双后端构建另有 1 个；只查结构和解码误差）：各布局 SPS 的 profile、色度格式、位深；BT.709、OPPO、ICC 三种 VUI；4:4:4 降级后如实返回；批量时参数集只在第一条流；非 16 倍数和 64 以下的尺寸（最小 16×16）编出来且裁剪后尺寸正确；32×24 的 Main10；硬件和软件会话；取消；8 位和 10 位的解码亮度 PSNR（本机 54–63 dB，阈值 38 dB）；双后端构建里作用域选择能切到 x265 并保持 4:4:4。

### 11.4 与计划不一致之处

- 入口改名提前到了本阶段（原定阶段 5）。旧名字会留在符号表里，纯 VideoToolbox 的库过不了 “不含 x265” 的检查。
- `Quality` 表里增益图按灰度和彩色分了两个值，一个值没法同时满足两者的体积上限。
- 线性缩略图按画质对齐定值，体积比 x265 多 12.5%（每个文件约 5 KB），没有按体积上限。
- 除了配置键，还加了进程级的 `xdremux_set_hevc_encoder`，因为实况和写回的接口没有配置参数。
- C 侧是会话式接口而不是 “一次调用编一批”。
- 码流里不保留 SEI（§3.1 说硬件编码器会输出前缀 SEI）；容器里本来就会被 `drop_parameter_nals` 去掉。
- `videotoolbox+x265` 构建没有进 CI（需要在 macOS runner 上恢复 x265 缓存），只在本机测了。
- 计划里 “用内核自带解码器解回并比 PSNR” 只做了 8 位和 10 位的 4:2:0；单色码流 `rust_h265` 解不了，校准时用的是 ffmpeg。
- 示例程序 `x265_diag`、`enc_test`、`tile_stream_probe` 只做了能编译的最小改动。
- `examples/` 和 `tests/conformance` 里沿用的旧入口名一并改了。

### 11.5 未验证

- **iPhone、iPad 真机都没有连接。** iPhone 自己的编码器（尤其是 Monochrome 和 Main10 静态图）、iOS 17.0–17.3 上没有编码器选择键时的行为、iOS 相册的识别，这一轮都无法验证。
- macOS 照片 App 和 OPPO 相册的人工核对这一轮没有做。
- 新 CI 工作流第一次在 GitHub 的 runner 上跑，319 个测试里失败 1 个：虚拟机的硬件编码器接受了会话，却在编 2016×1512 的单色图时报错（状态码 −17691）。第二个提交 `7defd6f` 为此加了“整批改用软件编码器重编”。这条退路在本机触发不了，只能靠 CI 验证；结果见 PR。
- x86_64 切片能构建，没有运行（已决定不支持 Intel Mac）。安卓、Windows、Linux、鸿蒙的构建没有在本机跑。
- 取值表没有在软件编码器和其他芯片上校准。
- 华为人像仍然没有样张。

### 11.6 留给阶段 3 的事

- `Package.swift` 里的 `c++` 和 `project.yml` 的 `-lc++` 在纯 VideoToolbox 构建下可以去掉。
- 命令行工具的帮助文字里还有 “x265”（`XDRemuxCLI.swift` 134、140、239、313、355 行），纯 VideoToolbox 的 App 和工具二进制要过字符串检查就得改。
- Swift 侧把 `ConversionConfig.hardwareEncode` 映射成配置里的 `hevcEncoder`，并在启动时按需调用 `xdremux_set_hevc_encoder`；是否显示选项看 `hevcEncoders` 的个数。
- `HardwareTiles.swift` 的硬件分支和内核的 `xdremux_prepare_tiles` 路径在 VideoToolbox 版 XCFramework 上仍然可用（`swift test` 通过），删除与否按原计划。

## 12. 阶段 3 执行记录（2026-11-14，分支 `feat/apple-videotoolbox-default`）

PR：https://github.com/BeetMan/XDRemux-Flutter/pull/109（提交 `709a1a7` 加一条文档提交，基于 main `0fcd5d8`，未合并）。没有改 Rust 代码，其他平台不受影响。入库的执行记录在 `docs/plans/apple-native.md`（“内核改用 VideoToolbox 编码，x265 变成可选”一条）。

### 12.1 做了什么

- **构建。** `build_apple.sh` 默认 `XDREMUX_APPLE_HEVC=vt`、`XDREMUX_APPLE_ARCHS=arm64`。`vt+x265`、`x265` 保留为显式取值。
- **libc++ 的链接。** 带 x265 的构建在打进 XCFramework 的 `module.modulemap` 里加一行 `link "c++"`，导入模块时自动链接。`Package.swift` 的 `.linkedLibrary("c++")` 和 `project.yml` 的 `-lc++` 都删了；`vt` 和 `vt+x265` 两种内核用同一份包清单和工程都能链接（两种都实际构建过 App、命令行工具和测试）。
- **发布脚本。** `package_release.sh` 显式传 `XDREMUX_APPLE_HEVC=vt+x265`，`upload_testflight.sh` 显式传 `vt`。其余逻辑未动。
- **Swift。** 删除 `HardwareTiles.swift`、`Pipeline.swift` 的硬件分支、`HardwareTilesTests.swift`。新增 `HEVCEncoders.swift`：解析能力报告里的 `hevcEncoders` / `defaultHevcEncoder`，把 `hardwareEncode` 映射成编码器名字（真 → 不传，用内核默认；假 → 另一个编码器），并封装 `xdremux_set_hevc_encoder`。`configJSON` 在需要时注入 `hevcEncoder`。
- **设置。** “硬件编码（VideoToolbox）”开关改成“编码器”选择器，放在原来的“编码”一节；`hevcEncoders` 只有一个时整节不显示。文案中英文都有：`编码器 / Encoder`、`VideoToolbox（系统编码器） / VideoToolbox (system encoder)`，以及一条带占位符的说明（占位符是内核报告的另一个编码器的名字）。旧的三条词条删掉了。
- **迁移。** `ConversionConfig` 新增 `encoderChoiceVersion`（键同名，当前值 1）。解码时没有这个键就把 `hardwareEncode` 置为新默认值真，并把版本记为 1；有这个键就照存的值来。
- **命令行工具。** `--encoder <名字>`（`convert`、`edit-copy`、`writeback`），走进程级选择；名字不在内核报告里时报错并列出可用值。只有一个编码器时这个选项不出现在帮助里。帮助文字和注释里的 “x265” 都去掉了。
- **CI。** `apple-ci.yml` 去掉 `X265_TAG`、x265 缓存和构建两步；Rust 目标只装 `aarch64-apple-darwin`、`aarch64-apple-ios-sim`；切片检查改成 arm64 加 `hevc_backend=vt` 加 x265 字符串计数为 0。
- **文档。** `apps/apple/README.md`（构建步骤、编码器一节、链接说明、arm64、命令行选项）；`docs/plans/apple-native.md` 加一条记录；`tools/apple/verify_local.sh` 的切片检查和前置条件说明。

### 12.2 实测（Apple M6，macOS 27.2.1）

| 项目 | 结果 |
|---|---|
| 默认 `build_apple.sh`，`vendor/x265` 挪走 | 三个切片都构建成功，`hevc_backend=vt`、`archs=arm64` |
| x265 字符串与符号 | 三个切片的 `libXDRemuxCore.a`：`strings -a` 计数 0，`nm` 无 `x265_`。macOS App（Debug，三个可执行文件）、整个 `.app` 目录、命令行工具、TestFlight 归档里的 iOS App 和分享扩展：计数都是 0 |
| `swift test`（默认内核） | 99 个测试 0 失败。不给样张 9 个跳过；给了两个样张目录后只有 3 个需要外部对端的传输测试跳过 |
| `swift test`（`vt+x265` 内核，带样张） | 0 失败 |
| macOS App、iOS 模拟器构建 | 两种内核各构建一遍，都成功 |
| 命令行工具冒烟（默认内核） | `--version`、`capabilities`（`["videotoolbox"]`）、转换、`verify` 正常；`--encoder nope` 报错并列出可用值 |
| `vt+x265`：两种选择各转一张（B1，Apple 标准） | App 的代码路径（包测试）和命令行各做一遍。选 x265 的输出与阶段 1 基线里 main 的 x265 版逐字节相同；选 VideoToolbox 的输出两条路径也相同 |
| 设置截图 | `vt+x265`：出现“编码 / 编码器”，当前值 VideoToolbox；`vt`：“OPPO 兼容”后面直接是“高级”，没有这一节。两张图在共享笔记目录：`phase3-settings-vt+x265.png`、`phase3-settings-vt-only.png` |
| 十张样张，默认构建的命令行工具 | 10 张全部成功；`verify_output`、`verify_styles_output` 全真，两张人像的 `verify_portrait_output` 为真 |
| 旧设置迁移 | 单元测试 4 个。另外把本机 App 实际存着的记录（`hardwareEncode:false`、无版本号）拷到临时偏好域，经真实 `UserDefaults` 读入再保存：得到 `hardwareEncode:true`、`encoderChoiceVersion:1`，其余字段不变。App 自己的偏好域前后哈希相同 |
| `package_release.sh` | 完整跑通，退出码 0：重建两个 XCFramework（内核 `vt+x265`）、macOS Release、iOS 归档、DMG（8.7 MB）、未签名 IPA（5.9 MB），现有检查全部通过 |
| `upload_testflight.sh`（不带 `XDREMUX_UPLOAD`，带 `XDREMUX_SKIP_TRANSFER=1`） | 重建 `vt` 内核，自动签名归档成功，导出成功（6.0 MB），没有上传 |
| `tools/apple/check_header.sh` | 通过（头文件没有变化） |

耗时与内存（十张样张逐张一个进程，Apple 标准加摄影风格；内存是单个进程的最大常驻集）：

| 构建 / 编码器 | 整批耗时 | 内存峰值 |
|---|---|---|
| 默认 `vt` 构建 | 18.3 秒（复测 18.4 秒） | 1.73 GB（复测 1.79 GB） |
| `vt+x265` 构建，选 VideoToolbox | 18.2 秒 | 1.63 GB |
| `vt+x265` 构建，选 x265 | 24.4 秒 | 1.93 GB |

逐张（默认构建 / x265）：A1 1.48 / 1.30 秒，A2 1.16 / 1.18，B1 3.39 / 4.18，B2 2.87 / 3.22，C1 1.27 / 1.76，C2 1.40 / 2.08，D1 1.52 / 2.13，D2 1.39 / 1.93，F1 2.34 / 4.10，F2 1.48 / 2.51。只有单通道增益图且不重编主图的 A1 比 x265 略慢。

### 12.3 与计划不一致之处

- 计划写的是“`Package.swift` 去掉 `c++`”。实际做法是让带 x265 的 XCFramework 自己通过模块映射声明要链接 libc++，这样纯 VideoToolbox 构建不声明，带 x265 的构建也不用改包清单。
- 选择器第二项和说明文字里的编码器名字取自内核，不是本地化字符串；否则商店构建的二进制和资源里会有 “x265”。
- `build_apple.sh` 保留了 `x265`（只有 x265）这个取值，用来出对照版本。
- 计划 §5 阶段 3 的验收里“三个切片”指 macOS、iOS、iOS 模拟器；默认构建三个都出了并查过。
- “整批转换耗时不比 x265 慢”成立；“内存峰值不升高”成立（1.63–1.79 GB 对 1.93 GB）。
- `verify_local.sh` 不在计划的文件清单里，一并改了。

### 12.4 这一步留下的缺口（阶段 4 处理）

- 两个发布脚本配 `XDREMUX_SKIP_CORE=1` 时都不核对 `BUILD_RECORD.txt` 的 `hevc_backend=`。`package_release.sh` 有“必须含 x265”的断言兜底；`upload_testflight.sh` 没有任何兜底，复用到 `vt+x265` 的内核会照常归档。脚本头部注释里已写明，并提醒不要把 `XDREMUX_SKIP_CORE=1` 和 `XDREMUX_UPLOAD=1` 一起用。
- “不得含 x265”的断言、许可文档、应用内许可页都没有做。

### 12.5 未验证

- **真机。** `xcrun devicectl list devices` 显示 iPhone 16e、iPad mini、iPhone Air 三台都是 unavailable，没有连接。真机编码器（单色、Main10）、iOS 相册识别、OPPO 相册、“两台 iPhone 加一台 iPad” 的验收都没做。
- macOS 照片 App 的人工核对没做。
- 在 App 界面里切换编码器后再转换，没有实际操作，只截了设置界面；转换用的是同一套代码的包测试和命令行。
- 旧设置的迁移没有在 App 进程里观察，只经 `SettingsStore` 和真实 `UserDefaults` 验证。
- iOS 模拟器只构建，没有运行。
- 新的 `apple-ci.yml` 在 GitHub runner 上的结果见 PR。

### 12.6 过程中对本机的影响

- 截图时启动了两次 Debug 版 App，用 `CFFIXED_USER_HOME` 指到临时目录，没有读写真实的队列和输出目录；App 的真实偏好域前后未变。屏幕左上角当时有一个系统权限提示框，没有点它，截图一角能看到。
- 迁移验证用的临时偏好域 `io.github.beetman.xdremux.swiftui.p3migration` 已删除；清理时执行过一次 `killall cfprefsd`（偏好设置守护进程会自动重启）。
- `upload_testflight.sh` 的自动签名带 `-allowProvisioningUpdates`，可能在开发者账号里更新了描述文件；没有上传任何构建。
- 工作树里留有 `apps/apple/build/release/0.1.1/` 和 `apps/apple/build/testflight/0.1.1-2/` 两套产物（不入库）。
