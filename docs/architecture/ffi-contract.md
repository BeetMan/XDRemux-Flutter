# Dart ↔ Rust FFI 契约

> 对应代码：`apps/flutter/lib/ffi/xdremux_ffi.dart`（Dart 绑定）、`xdremux/rust/src/lib.rs`（导出，43 个 `extern "C"` 函数）、
> `xdremux/rust/include/xdremux_core.h`（cbindgen 生成的 C 头文件，原生 Apple 应用经 `XDRemuxCoreC` 模块导入；
> 改导出后用 `tools/apple/check_header.sh` 校验）。

## 1. 库加载

| 平台 | 方式 |
|---|---|
| Android | `DynamicLibrary.open('libxdremux_core.so')`（jniLibs 打包） |
| iOS | `DynamicLibrary.process()`（静态链接进主二进制） |
| Windows | 安装目录/开发目录搜索 DLL |
| macOS | 多级回退：dylib 裸名（rpath）-> 可执行文件旁 -> `../Frameworks` -> `../../Frameworks` |
| 原生 Apple（SwiftUI） | 静态链接 `XDRemuxCore.xcframework`（`xdremux/rust/build_apple.sh`），Swift 直接引用符号，无需 `-u` 保留 |
| 鸿蒙 | `DynamicLibrary.open('libxdremux_core.so')`（`ohos/entry/libs/arm64-v8a/` 打包） |

绑定在 `XdRemuxFFI` 中以 `lookupFunction` 静态缓存。**添加新导出函数时两侧命名必须同步**：Rust 侧 `xdremux_<snake_case>`，Dart 侧 `_<camelCase>`。

## 2. 调用模式

### 2.1 重负载调用必须走 Isolate

转换、写回、分类等长耗时调用一律 `Isolate.run(() => XdRemuxFFI.xxx(...))`（见 `xdremux_service.dart`）。FFI 是同步阻塞调用，直接在主 isolate 会卡 UI。

### 2.2 字符串返回协议（JSON 报告）

返回 `*mut c_char` 的函数（`xdremux_version`、`xdremux_diagnose_portrait`、`xdremux_writeback_returned_photo` 等）：

- Rust 侧 `CString::into_raw()` 交出所有权，内容是 JSON 序列化的报告对象
- Dart 侧用完后**必须**调 `xdremux_free_string(ptr)`，否则泄漏
- 报告字段约定：`success`（bool）、`errorMessage`（可空 string）+ 各功能字段（如写回的 `outputValid`、`rasterWatermarkRestored`、`restoredOppoEntries[]`）
- Dart 侧的契约：`report['success'] != true || report['outputValid'] == false` 即抛 `StateError`

### 2.3 结构体返回协议（不透明指针）

`ConversionResult`、`ClassificationResult`、`ThumbnailResult`、`PreparedTilesResult` 等：Rust 返回 `#[repr(C)]` 结构体（含 Rust 分配的内部缓冲指针），Dart 仅作为不透明句柄传递，**用完必须调对应的 `xdremux_free_*` 函数**。禁止在 Dart 侧解引用内部指针。

### 2.4 路径参数

所有路径用 `*const c_char`（UTF-8）。Rust 侧 null 检查 + UTF-8 校验，失败返回错误 JSON 而非 panic。**Rust 侧永不 panic 越过 FFI 边界**——所有入口都包在闭包里转 `Result`。

### 2.5 进度协议

- `xdremux_progress_begin() -> u32`：申请进度句柄
- `xdremux_progress_report(handle, current, total)`：Rust 内部上报
- `xdremux_read_progress_for(handle, buf: *mut u32)`：Dart 轮询（buf 4 个 u32）
- `xdremux_progress_cancel(handle)`：任意线程请求取消；worker 在下一块瓦片检查点停止，返回失败报告
  `error_message = "conversion cancelled"`，句柄仍由调用方 `xdremux_progress_end` 释放，残留输出由调用方删除。
  取消在 worker 认领句柄之前发出也有效（UI 先申请句柄再派发 worker）。
- `xdremux_progress_end(handle)`：释放

### 2.6 管线与规划（JSON 配置）

`xdremux_convert_pipeline(input, output, config_json, handle) -> char*` 在内核里完成
"转换 → 校验（ISO 增益图 + 按选项追加摄影风格 / 人像结构检查）→ 摄影风格 3 后处理（texture_styles + 语义 matte，
再校验）"，返回 JSON：`success`、`stage`（`config` / `convert` / `verify` / `styles3` / `done`）、`cancelled`、
`errorMessage`、`mode`、`family`、`edrScale`、`gainMapMax`、`outputValid`、`verified`、`styles3Applied`、`grainSeed`。
失败时残留输出由调用方删除；`handle` 与 §2.5 相同，取消时 `cancelled = true`。

`xdremux_plan_output(input, config_json) -> char*` 只读：`classification`（modeKey / folderName / status / hdrKind /
family）、`convertible` 与 `convertError`、`huawei`（isHdr / hasXtstyle / portraitReady，非华为为 null）、`isMotionPhoto`、
`policy`（华为准入：普通华为 HDR 跳过，摄影风格 / 人像可转换 / 动态照片放行）、`output`（fileName、
captureModeFolder、outputModeFolder；Dart 按拍摄模式分目录、Swift 按输出模式分目录，两者都给）。

`config_json` 的键与 Dart / Swift `ConversionConfig` 一致：`outputMode`、`oppoCompatibility`、`oppoCameraTail`、
`strictTmap`、`applePhotographicStyles`、`applePhotographicStyles3`、`applePortrait`、`fileNameSuffix`、
`categorizeOutputByMode`；缺省键取共享默认值，枚举名到 `ConvertConfig` 字节的映射在 `pipeline.rs`（与两端
`rustValue` 表一致，Apple 输出强制 compat=0 / tail=0，摄影风格 3 蕴含摄影风格）。颗粒种子用 Dart `_grainSeedFor`
的哈希。两个返回值都用 `xdremux_free_string` 释放。

## 3. 主要导出清单

| 函数 | 用途 |
|---|---|
| `xdremux_version` | 版本串（与 Cargo 一致） |
| `xdremux_classify` / `xdremux_inspect` | 输入分类 / 结构检查 |
| `xdremux_huawei_inspect` | Huawei HDR / 人像 HEIC 只读识别与“无需转换”诊断（含 `xtstyle` 及 `huaweiPortrait` 的 `edof`、`auxC`、`auxl`、`RfDataB` 尺寸/字节形态；不做语义转换） |
| `xdremux_convert` / `xdremux_convert_with_progress` | ProXDR -> ISO 转换（含 Ultra HDR JPEG 输入） |
| `xdremux_writeback_returned_photo` | 回传照片写回（全平台统一） |
| `xdremux_diagnose_portrait` | 人像深度诊断 |
| `xdremux_motion_photo_inspect` / `xdremux_motion_photo_split` | 动态照片识别 / 拆分 |
| `xdremux_live_photo_pair_valid` | Live Photo HEIC+MOV 配对校验 |
| `xdremux_make_live_photo_bundle` / `xdremux_live_photo_bundle_valid` | 把已配对的 HEIC+MOV 打成 `.pvt` 包 / 校验 `.pvt` 包（见 `docs/formats/live-photo-pvt.md`） |
| `xdremux_prepare_tiles` / `xdremux_assemble_tiles` | 分块转换（长图/大图内存控制） |
| `xdremux_verify_output` / `xdremux_verify_styles_output` / `xdremux_verify_portrait_output` | 输出合法性自检（可解码 + 结构检查） |
| `xdremux_inject_texture_styles` / `xdremux_inject_semantic_mattes` | 摄影风格 3 后处理：在已转换 HEIC 上追加 texture_styles 项与 12 个语义 matte 占位（Dart / Swift 前端在校验通过后按顺序调用） |
| `xdremux_progress_cancel` | 取消运行中的转换（见 §2.5） |
| `xdremux_convert_pipeline` / `xdremux_plan_output` | 一次调用的转换管线与只读输出规划（见 §2.6），三端共用的策略 |

当报告含 `huaweiPortrait` 时，嵌套对象只描述观察到的 ISOBMFF 资源：
`edofItemId` / `edofDimensions` / `edofTileItemIds`、`edofAuxiliaryTypes`（`auxC`）、
`edofAuxlTargets`，以及 `RfDataB` 的 `cdsc` 目标、字节数、观察到的 header/平面
偏移、尺寸、sample 字节数和完整性。`safeToTransform` 固定为 `false`，
`recommendedAction` 为 `inspect-only`；这些字段不代表深度单位、通道语义或 Apple
人像兼容性，Flutter 只提供只读诊断入口，不启动转换。

动态照片报告的 `sourceKind` 还包括 `huaweiOpenHarmonyMotionPhoto`。该类型的
`huaweiMetadata` 只读返回 `coverTimeMs`、`startTimeMs`、`videoId` 和
`deferredVideoEnhanceFlag`；它不等同于 Apple Live Photo 元数据，也不自动触发重编码。

## 4. 变更纪律

1. 改 FFI 签名 = 同时改两侧 + 更新本页表格
2. 新增返回堆内存的导出 = 必须配套 free 函数
3. Dart 侧错误处理只依赖 JSON 报告字段，不做异常字符串匹配
4. conformance 测试（`tests/conformance`）覆盖 Rust 侧逻辑；FFI 边界用 `apps/flutter/test/ffi_smoke_test.dart` 冒烟
