# 鸿蒙硬件 HEVC 编码可行性评估（2026-11-15）

> 问题：鸿蒙原生版转换慢。主线已把 HEVC 编码拆成可替换的后端（#107），并为 Apple 加了 VideoToolbox 硬件编码（#108）。鸿蒙能否用系统的 AVCodec 硬件编码器做同样的事，值不值得做。
> 结论状态：**部分实测**。x265 NEON 的速度和输出一致性在 Apple M6 上实测，OHOS 交叉编译已实测；AVCodec 部分只核对了 SDK 头文件（DevEco SDK，API 26），**没有在真机上跑过**。
> 已采纳：§2.2 的 NEON 配置已于同日写入 `xdremux/rust/build_ohos.sh`；手机上的计时（§5 第 1 项）尚未完成。

## 0. 结论

1. **先给鸿蒙的 x265 打开 NEON，建议马上做。**
   - 现在 `xdremux/rust/build_ohos.sh:60,79` 用 `-DENABLE_ASSEMBLY=OFF` 编 8-bit 和 10-bit x265，手机上跑的是纯 C 代码。vendored 的 x265 4.2 自带 ARM64 NEON 汇编和 intrinsics（`source/common/aarch64/`）。主线 `release.yml:579` 的注释说 "x265's NASM assembly is x86-only"，对 ARM 不成立。
   - 在 Apple M6 上实测（单线程，核心的实际参数，真实 OPPO 照片切成 512 块）：主图快 1.36–1.58 倍，灰度增益图快 2.34 倍（§2）。
   - 输出不变：四种编码配置下，slice 和参数集都逐字节相同（§2）。
   - 要注意一点：鸿蒙工具链下 x265 不做运行时 CPU 检测。默认配置只启用所有 ARMv8-A 都有的基础 NEON，是安全的。但如果按 x265 文档加上 `-DCROSS_COMPILE_ARM64=ON`，它会把 dotprod、i8mm、SVE 都编译进去并无条件使用，在不支持的手机上会崩溃。建议在脚本里显式关掉这些扩展（§2.2）。
2. **硬件编码后端：有条件，先在真机上测，现在不写后端。**
   - 有 API 支持：每帧关键帧、恒定质量模式、色彩描述、取参数集，而且能从 Rust 的 cdylib 直接链接（§3）。
   - 做不到：4:4:4、单色 4:0:0、以 YUV 输入的 10-bit。所以单色增益图、蒙版、视差图和 Main10 线性缩略图都要留在 x265，硬件编码器只能接主图（4:2:0）和彩色增益图（§4）。
   - 决定成败但只能真机测的：手机硬件编码器的画质上限能否接近 x265 CRF14（本次实测的主图块平均 QP 只有 3–10）；能否编 512×512；是否支持 CQ / SQR 模式、质量范围是多少。阶段 0 的测试方案见 §5。
   - 收益：主图几乎占了全部编码时间（M6 单线程，48 块主图 4.3–5.2 s，12 块增益图 0.13 s）。硬件编码器能实时编 4K，画质过关的话，主图编码有望从秒级降到几百毫秒。

## 1. 现状

- **后端接口**（`xdremux/rust/src/hevc/mod.rs`）：每个后端实现 `encode(&EncodeRequest, SourcePictures) -> EncodedTiles`。
  - `EncodeRequest` 包含宽高、样本布局（`Monochrome` / `Yuv420` / `Yuv444`）、位深、四种颜色约定（`HevcColor`）和内容类别（`HevcContent`：主图、增益图、蒙版、视差、线性缩略图）。
  - 后端做不到所要求的布局时，可以换一种，并在 `EncodedTiles::layout` 里如实报告；VideoToolbox 就把 4:4:4 编成 4:2:0。
- **x265 参数**（`hevc/x265.rs` `open_encoder`，第 332 行起）：
  - 主图（RGB）：`medium` CRF14；OPPO 回写用 `fast`。按请求编 4:4:4（`main444-8`）或 4:2:0（`mainstillpicture`）。
  - 增益图：`ultrafast` CRF18，`i400` 单色。代码注释说明 Android 的增益图解码只认单色。
  - 所有类别：`keyint 1`、`bframes 0`、`rc-lookahead 0`、`repeat-headers 0`。批量编码时每块一个会话，最多 4 块并行（第 438 行）。
  - 第 350 行的注释记录：在麒麟设备上用 `medium` 编一整张 4K 主图约 15 s。
- **构建**：x265 的汇编在所有 ARM 构建里都是关闭的：`build_ohos.sh`、`build_apple.sh`、`build_ios.sh`、`build_ios_sim.sh`，以及 `release.yml` 的 macOS 构建。

## 2. x265 NEON 实测

### 2.1 速度与输出一致性

方法：
- 测试程序是 `docs/research/x265_tile_bench.c`，参数与核心的批量路径相同，每块一个单帧会话，`pools 1` 单线程。
- 素材是 `test-media/sources/oppo-motion-photos/IMG20260721222112.jpg`（3072×4096），主图切成 48 个 512 块；灰度增益图缩到 1536×2048，切成 12 块。
- 每组跑两遍取最快。哈希只计 slice 和 VPS/SPS/PPS，不计 SEI：x265 的信息 SEI 里写有 cpuid，而容器写入时本来就丢弃 SEI。
- 机器：Apple M6，macOS，x265 4.2（e444744），Release。

| 编码配置（每块耗时，ms） | 关汇编（现状） | 仅 NEON | NEON + dotprod/i8mm/SVE | 仅 NEON 的加速 | 输出 |
|---|---|---|---|---|---|
| 主图 4:4:4 `medium` CRF14 | 159.7 | 111.7 | 109.2 | 1.43× | 三者相同（2,929,459 字节） |
| 主图 4:2:0 `medium` CRF14 | 122.9 | 90.4 | 90.9 | 1.36× | 三者相同（2,591,523 字节） |
| OPPO 回写 4:4:4 `fast` CRF14 | 164.5 | 104.1 | 105.3 | 1.58× | 三者相同（2,926,973 字节） |
| 灰度增益图 4:0:0 `ultrafast` CRF18 | 26.0 | 11.1 | 11.1 | 2.34× | 三者相同（308,158 字节） |

- 编码结果逐字节相同：x265 的 NEON 代码与 C 代码结果一致，所以打开以后只改变速度，转换出来的文件不变。
- M6 是很宽的乱序核心，C 代码本身就跑得快。手机核心上 SIMD 带来的提升通常不会更小，但需要在真机上确认（§5 第 1 项）。
- 只开 NEON 和全开扩展的速度几乎一样，所以关掉可选扩展不损失什么。

### 2.2 鸿蒙上只用基础 NEON

- x265 只在 `CMAKE_SYSTEM_NAME` 为 `Linux|FreeBSD|OpenBSD|Darwin|Windows` 时才开启 ARM64 运行时 CPU 检测（`source/CMakeLists.txt:96-99`）。DevEco 的 `ohos.toolchain.cmake` 把系统名设为 OHOS，所以检测是关闭的。
- 检测关闭、又没有设 `CROSS_COMPILE_ARM64` 时，x265 只在 Linux 和 Darwin 上检查编译器是否支持 dotprod、i8mm、SVE（`source/CMakeLists.txt:342-358`）。在 OHOS 上它会提示 "Compile-time CPU feature detection unsupported"，一个扩展都不启用，只剩基础 NEON。
- 已用 DevEco 工具链交叉编译验证：默认配置和显式关闭扩展的配置，生成的定义都只有 `HAVE_NEON=1`（另有 `HAVE_GETAUXVAL` 等），静态库里没有 SVE、dotprod、i8mm 符号。
- **必须给汇编传目标**（2026-11-16 真机发现）：x265 用自定义命令汇编 `.S` 文件（`source/CMakeLists.txt:959-971`），拿不到工具链的 `--target`，clang 会按主机编译：在 macOS 上编成 Mach-O，在 Linux 上编成 x86。链接器跳过这些目标文件，核心里的 NEON 函数全部未定义；手机按 `BIND_NOW` 加载时失败，应用提示 Rust 核心不可用。上面统计的 NEON 符号其实来自这些 Mach-O 文件，没能发现问题。要传 `-DASM_FLAGS=--target=aarch64-linux-ohos`（会传到那条自定义命令），`build_ohos.sh` 编完后还会检查核心里没有未解析的 x265 符号。
- 危险的配置是 x265 文档里交叉编译用的 `-DCROSS_COMPILE_ARM64=ON`。它会把全部扩展都编译进去，而在检测关闭时，`common/aarch64/cpu.h:200` 起的分支会**无条件**启用这些扩展，遇到不支持这些指令的 CPU 就会因非法指令崩溃。所以不要使用这个开关，同时显式关掉扩展，以免以后的改动在不知不觉中把它们打开。

`build_ohos.sh` 中 8-bit 与 10-bit 两处 cmake 配置改为：

```sh
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=ON \
    -DENABLE_NEON_DOTPROD=OFF -DENABLE_NEON_I8MM=OFF \
    -DENABLE_SVE=OFF -DENABLE_SVE2=OFF -DENABLE_SVE2_BITPERM=OFF \
    -DASM_FLAGS=--target=aarch64-linux-ohos \
```

脚本只在 `libx265.a` 不存在时才重新配置，所以改完要先删掉 `vendor/x265/build_ohos` 和 `vendor/x265/build_ohos_10bit`。另外 Darwin 支持运行时检测，Flutter 的 iOS / macOS 构建如果仍用 x265，也能用同样的方式提速，而且可以保留全部扩展。这一点另行决定。

## 3. AVCodec 能力对照

依据 DevEco SDK 中的头文件 `native/sysroot/usr/include/multimedia/player_framework/`（API 26）。最低兼容 API 18。

| 要求（来自 #108 与核心） | AVCodec 的对应能力 | 判断 |
|---|---|---|
| 每块一帧、每帧都是关键帧 | `OH_MD_KEY_I_FRAME_INTERVAL` = 0 表示全部关键帧（API 9）；也可每帧发 `OH_MD_KEY_REQUEST_I_FRAME`（API 10） | 可行，需真机确认 0 被遵守 |
| 每帧及时取回结果 | 异步回调 `OH_VideoEncoder_RegisterCallback`（API 11），用条件变量包装成同步；或同步模式 `OH_MD_KEY_ENABLE_SYNC_MODE` + `OH_VideoEncoder_QueryInputBuffer` / `QueryOutputBuffer`（API 20） | 可行；同步模式要求运行时 API ≥ 20 |
| 512×512 块与小尺寸 | `OH_AVCapability_GetVideoWidthRange`、`GetVideoWidthAlignment`、`IsVideoSizeSupported` | 头文件里没有具体数值，需真机查询 |
| 8-bit 4:2:0 主图 | 缓冲区输入 `AV_PIXEL_FORMAT_YUVI420` / `NV12` / `NV21`；`HEVC_PROFILE_MAIN`、`HEVC_PROFILE_MAIN_STILL` | 可行 |
| 4:4:4（x265 的主图、彩色增益图） | profile 只有 MAIN、MAIN_10、MAIN_STILL、MAIN_10_HDR10(_PLUS)，没有 RExt | 不支持：像 VideoToolbox 一样编成 4:2:0 并报告 |
| 单色 4:0:0（增益图、蒙版、视差） | 没有单色像素格式或 profile | 不支持：只能编成中性色度的 4:2:0，Android 等解码器可能不认，所以留在 x265 |
| Main10 线性缩略图（BT.601 有限范围的 Apple Log 码值） | 缓冲区模式的 10-bit 输入只有 `AV_PIXEL_FORMAT_RGBA1010102`（API 20），由编码器自己做 RGB→YUV，码值无法控制；P010 只能走 surface 模式的 native buffer（`GetVideoSupportedNativeBufferFormats`，API 22） | 难做：留在 x265 10-bit |
| VUI 色彩描述、full range | `OH_MD_KEY_COLOR_PRIMARIES`、`TRANSFER_CHARACTERISTICS`、`MATRIX_COEFFICIENTS`、`RANGE_FLAG`（API 10） | 可行，需确认写进了 SPS 的 VUI |
| 画质控制 | `BITRATE_MODE_CQ` + `OH_MD_KEY_QUALITY`（范围由 `GetEncoderQualityRange` 查询）；`BITRATE_MODE_SQR` + `OH_MD_KEY_SQR_FACTOR`（0–51，API 20）；`QP_MIN` / `QP_MAX`（API 12） | 有接口；是否支持、上限多高只能真机测 |
| 一批共用一套参数集，并能取出 | 带 `AVCODEC_BUFFER_FLAGS_CODEC_DATA` 的输出缓冲（VPS/SPS/PPS）或 `OH_MD_KEY_CODEC_CONFIG`；带内重复的参数集由 `tile_stream_for_container` 去掉 | 可行：像 VideoToolbox 一样逐帧比较 |
| 硬件失败时回退 | `OH_AVCodec_GetCapabilityByCategory(..., HARDWARE / SOFTWARE)`；系统不保证有软件 HEVC 编码器 | 回退到 x265，构建时同时编入两个后端（同 `videotoolbox+x265`） |
| 从 Rust cdylib 调用 | NDK 提供 `libnative_media_venc.so`、`libnative_media_codecbase.so`、`libnative_media_core.so`，surface 模式另需 `libnative_window.so` | 可行，不需要经过 ArkTS |
| 并发与生命周期 | `OH_AVCapability_GetMaxSupportedInstances`；硬件实例与相机等共享，应用进入后台后可能被回收 | 有风险；应用的转换本来就只在前台进行 |

## 4. 硬件后端的形态（仅在 §5 通过时）

- **按内容类别分配**：
  - 主图（4:2:0）和彩色增益图交给 AVCodec。
  - 单色增益图、蒙版、视差、Main10 线性缩略图，以及要求 4:4:4 的请求，继续用 x265（NEON）。
  - 实现上需要让 `HevcBackend` 能按 `HevcContent` 选择后端；目前它是按整次转换选择的。
- **结构**：仿照 `vt_hevc.c` 和 `hevc/vt.rs`，新增 `ohos_hevc.c` 和 `hevc/ohos.rs`。
  - 打开：先查能力，再配置宽高、像素格式、profile、`I_FRAME_INTERVAL 0`、CQ 或 SQR、色彩键。
  - 编码每张图：取输入缓冲，按 `OH_MD_KEY_VIDEO_STRIDE` 拷入各平面，送入，等待输出。
  - 第一张图的参数集作为整批的基准，之后逐张比较；有任何失败，就把整批改用 x265 重编。
- **构建与选择**：`XDREMUX_HEVC_BACKEND=ohos+x265`，链接上面三个库。运行时通过 #108 新增的 `xdremux_set_hevc_encoder` 选择，App 设置里提供开关。
- **测试**：硬件输出会随设备和固件变化，测试只检查码流结构和解码误差，不比字节，和 VideoToolbox 一样。

## 5. 真机验证计划（阶段 0）

1. **NEON 计时**：同一张照片在 NEON 构建前后各转换一次，对比耗时，检查输出文件逐字节相同。用户的鸿蒙手机即可，不需要新工具。
2. **能力清单**：在手机上跑一个小 native 探针（用 hdc 推送可执行文件，或打一个测试 HAP），记录：
   - 硬件和软件 HEVC 编码器是否存在；
   - 尺寸范围与对齐，`IsVideoSizeSupported(512, 512)`；
   - 支持的像素格式和 profile；
   - CQ / SQR 是否支持，质量范围和 QP 范围；
   - 最大实例数。
3. **画质与速度**：仿照 #108 的阶段 0，从 10 张样张的真实转换中截取主图块，分别用 x265（NEON）和 AVCodec 编码。AVCodec 用 CQ 最高质量，并扫描 SQR factor 和 `QP_MIN`。在 Mac 上用 ffmpeg 解码，比较亮度 PSNR、大小和耗时。
4. **结构**：确认每帧都是 IDR、参数集稳定、VUI 正确；生成的 HEIC 在 iPhone 和 Mac 的「照片」里显示正常（增益图仍由 x265 编码）。
5. **建议的通过标准**：主图亮度 PSNR 比 x265 低不超过 0.5 dB，大小不超过 x265，整张主图编码至少快 5 倍。达不到就不写后端，只保留 NEON。

## 6. 建议顺序

1. x265 NEON：改 `build_ohos.sh`，重编内核，加上 §5 第 1 项的真机计时。改动小，没有画质风险。
2. 阶段 0 真机测试（§5 第 2–4 项），需要用户的手机。
3. 根据阶段 0 的数据决定是否实现 §4 的后端。
