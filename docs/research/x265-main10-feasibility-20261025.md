# x265 Main10（10-bit）可行性验证（2026-10-25）

> 问题：线性缩略图从 8-bit Apple Log 升级到原生同级的 16-bit codes + Main10 HEVC，需要 10-bit x265 静态库与编码路径。本次只回答"能不能做、怎么做、风险在哪"，不做生产接入。
> 结论状态：**已实测**（Windows 11 / MSVC 14.51 / x265 4.2 / cmake 4.4.4 / Ninja）。
> 上游参照：`upstream/main` 的 Apple VideoToolbox Main10 只覆盖 macOS 原生路径；本移植是全平台 Rust，必须自备 10-bit 工具链。

## 0. 结论

**可行。** 用 x265 官方的 multilib 机制给 10-bit 库打上独立命名空间 `x265_10bit`，与现有 8-bit 库一起静态链接，就能在同一个二进制里同时提供 8-bit 与 10-bit 编码器。探针已跑通：`x265_10bit::x265_api_get(0)` 返回 `bit_depth=10`，编码一帧 64×64 4:2:0 10-bit，`ffprobe` 判定 `profile=Main 10`、`pix_fmt=yuv420p10le`、2411 字节。

但有一个**必须验证的链接语义风险**（§4），在接入生产前要用真实缩略图做编码/解码回归。

## 1. 构建配方（Windows，已实测）

x265 4.2 自带 multilib 开关：`EXPORT_C_API=OFF` 时 `api.cpp` 与全部核心对象进入 `namespace X265_NS`，本仓库的 vendored 源码会把命名空间定为 `x265_10bit`（`source/CMakeLists.txt:790-807`）。`vendor/x265` 里已有 `XDREMUX_SKIP_RC` 补丁，用于在非 git checkout（vendored 子目录）下跳过 RC 版本号解析——否则 configure 会因 `X265_LATEST_TAG` 为空在 `source/CMakeLists.txt:1128` 报 `list GET given empty list`。

```bat
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cd xdremux\rust\vendor\x265
cmake -S source -B build_windows_10bit -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DENABLE_CLI=OFF -DENABLE_SHARED=OFF -DENABLE_ASSEMBLY=OFF -DXDREMUX_SKIP_RC=ON ^
  -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
cmake --build build_windows_10bit -j 8
:: 产物：build_windows_10bit\x265-static.lib
```

实测耗时：configure ~20s、构建 ~3–5 分钟；产物 `x265-static.lib`。

注意事项：

- **`ENABLE_ASSEMBLY=OFF` 只是本机没有 nasm 的临时取值**。生产构建应与现有 8-bit 库保持一致（`ENABLE_ASSEMBLY=ON`，需要 nasm），否则 10-bit 编码会明显变慢。
- 生成器用 **Ninja + cl**（vcvars 后）可绕开 CMake 对 VS 18 实例的探测失败（`No CMAKE_C_COMPILER could be found`）。用 VS 生成器亦可，但需保证 CMake 能识别 VS 18。
- 必须 `/MD`（动态 CRT）与 Rust/cargo 的默认一致；直接 `cl` 编译探针时若用默认 `/MT` 会报 `LNK2038 RuntimeLibrary 不匹配`。

## 2. 链接与调用语义（已实测）

10-bit 库**不能单独链接**：它的核心对象引用的是**全局 C API 符号**（`x265_picture_alloc`、`x265_param_parse`…），而这些符号由 `EXPORT_C_API=ON` 的 8-bit 库提供；10-bit 库自己只导出 `x265_10bit::` 命名空间内的 C++ 符号。因此：

```bat
cl /nologo /MD /std:c++17 /EHsc /O2 /I vendor\x265\include probe.cpp ^
   vendor\x265\build_windows_10bit\x265-static.lib ^
   vendor\x265\build_windows\Release\x265-static.lib advapi32.lib
```

- 10-bit API 只能通过 `x265_10bit::x265_api_get(0)` 拿到 `const x265_api*`，之后**全部走函数指针**（`api->param_alloc/param_parse/picture_init/encoder_open/encoder_encode/...`），不要再直接调用全局 C 函数（那是 8-bit 版）。
- 8-bit 既有路径完全不受影响；10-bit 只是同一个二进制里多一套编码器。

## 3. 关键坑：单帧会被标成 Main10 Intra（Rext）

`encoder/level.cpp:72-113` 的逻辑：`onePictureOnlyConstraintFlag = (param.totalFrames == 1)` → `intraConstraintFlag` → 10-bit 单帧选择 `Profile::MAINREXT`（profile_idc **4**，即 "Main10 Intra"）。**硬件解码器普遍不支持 Rext**，直接用于 HEIC 缩略图有风险。

实测对照：

| `totalFrames` | `keyint` | ffprobe profile | 结论 |
|---|---|---|---|
| 1 | 1 | Rext | 单帧标记导致 |
| 1 | 250 | Rext | 仍是单帧标记 |
| **2** | 250 | **Main 10** | ✅ 只喂一帧后 flush，流内仍只有一帧 |

生产实现必须 `totalFrames >= 2`（或 0）但只提交一帧，再 flush 收尾。这一点在接入时要用断言固定住（校验 SPS `profile_idc == 2`）。

## 4. 未验证风险（接入前必须回归）

1. **内部符号绑定的 UB 风险**：10-bit 核心对象内部的全局 C 调用（如 `Encoder::encode` 里调 `x265_encoder_reconfig`）会绑定到 **8-bit 库的包装函数**，后者把 encoder 指针按 8-bit `Encoder*` 解释。简单探针（无 reconfig/zone/analysis 路径）跑通不代表所有路径安全。接入前必须用**真实缩略图分辨率与真实数据**做编码→解码（ffmpeg / heif-oxide / 真机 Photos）回归，确认没有崩溃或错误像素。
2. **hvcC 组装**：现有 `extract_hvcc_config_with_chroma` 从 SPS 取 profile/compat/level，但 10-bit 的 `bitDepthLumaMinus8` 等字段与 chroma format 需要正确写入 hvcC；接入时要按 HEVC 规范补齐并用 ffprobe/Photos 双向校验。
3. **其它平台构建**：Linux CI、Android（NDK 静态）、iOS（Xcode 静态）、OHOS（DevEco NDK）都需要各自构建 10-bit 静态库；本机只在 Windows 验证过配方，其余平台的等价命令未验证。
4. **真机验收**：Main10 缩略图是否被 Photos 接受、显示是否与原生一致，仍属未验证（与 8-bit 版本一样需要真机 A/B）。

## 5. 接入方案（建议顺序）

1. **C 桥**：在 `x265_helper.c`（已按 C++ 编译）里加 `xdremux_10bit_api()` 返回 `x265_10bit::x265_api_get(0)`，以及一个 10-bit 单帧编码函数（16-bit 平面 → 长度前缀 NAL + 首尾长度）。保持 C ABI，Rust 侧不接触 `x265_api` 结构布局。
2. **Rust 侧**：`hevc.rs` 增 `x265_encode_tiles_10bit()`；`linear_thumbnail.rs` 在 10-bit 可用时用 `apple_log::thumbnail_codes()`（16-bit）+ 10-bit 编码，`LinearThumbnailOutput` 记录 bit depth；`styles_native` 的 hvcC 组装按 10-bit 补齐字段。
3. **构建接线**：`build.rs` 在存在 `build_*_10bit` 库时追加链接并 `cfg` 标记；**库缺失时自动回退到现有 8-bit Apple Log 路径**（已合入 main），保证 5 平台渐进启用。
4. **平台推进**：Windows/Linux → Android → iOS/OHOS；iOS 也可评估直接走 VideoToolbox Main10（上游同路线）以规避 x265 静态多库的复杂度。
5. **验证门槛**：单元测试（profile_idc=2 断言、16-bit→10-bit 量化）、ffprobe 校验、真机 Photos A/B。

成本估计：Windows/Linux 接线 1–2 天；其余平台构建脚本与回归 2–4 天（取决于 NDK/Xcode 环境）。

## 6. 复跑方式

探针源码与 bat 在会话临时目录（`%TEMP%\x265_main10_probe\`），不属于仓库。复跑要点：

```bat
:: 1. 按 §1 构建 10-bit 库
:: 2. 按 §2 用两个静态库编译 probe.cpp
:: 3. 运行 probe.exe（PASS 判据：profile_idc==2 且 total_bytes>0）
:: 4. ffprobe 校验：profile=Main 10, pix_fmt=yuv420p10le
```

## 7. 不适用条件

- 本结论只覆盖 Windows + x265 4.2 + MSVC 14.51；换工具链、换平台需重新验证。
- 探针只编码 64×64 合成灰块，不覆盖真实照片分辨率、内容自适应与性能。
- 不主张"Main10 一定被 Apple Photos 接受"：真机验收仍是独立门槛。
- 若决定 iOS 走 VideoToolbox Main10，则本文的 x265 静态多库方案对 iOS 不适用。
