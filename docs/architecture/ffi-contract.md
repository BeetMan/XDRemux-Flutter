# Dart ↔ Rust FFI 契约

> 对应代码：`apps/flutter/lib/ffi/xdremux_ffi.dart`（绑定）、`xdremux/rust/src/lib.rs`（导出，28 个 `extern "C"` 函数）。

## 1. 库加载

| 平台 | 方式 |
|---|---|
| Android | `DynamicLibrary.open('libxdremux_core.so')`（jniLibs 打包） |
| iOS | `DynamicLibrary.process()`（静态链接进主二进制） |
| Windows | 安装目录/开发目录搜索 DLL |
| macOS | 多级回退：dylib 裸名（rpath）-> 可执行文件旁 -> `../Frameworks` -> `../../Frameworks` |
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
- `xdremux_progress_end(handle)`：释放

## 3. 主要导出清单

| 函数 | 用途 |
|---|---|
| `xdremux_version` | 版本串（与 Cargo 一致） |
| `xdremux_classify` / `xdremux_inspect` | 输入分类 / 结构检查 |
| `xdremux_convert` / `xdremux_convert_with_progress` | ProXDR -> ISO 转换（含 Ultra HDR JPEG 输入） |
| `xdremux_writeback_returned_photo` | 回传照片写回（全平台统一） |
| `xdremux_diagnose_portrait` | 人像深度诊断 |
| `xdremux_motion_photo_inspect` / `xdremux_motion_photo_split` | 动态照片识别 / 拆分 |
| `xdremux_live_photo_pair_valid` | Live Photo HEIC+MOV 配对校验 |
| `xdremux_prepare_tiles` / `xdremux_assemble_tiles` | 分块转换（长图/大图内存控制） |
| `xdremux_verify_output` / `xdremux_verify_styles_output` / `xdremux_verify_portrait_output` | 输出合法性自检（可解码 + 结构检查） |

## 4. 变更纪律

1. 改 FFI 签名 = 同时改两侧 + 更新本页表格
2. 新增返回堆内存的导出 = 必须配套 free 函数
3. Dart 侧错误处理只依赖 JSON 报告字段，不做异常字符串匹配
4. conformance 测试（`tests/conformance`）覆盖 Rust 侧逻辑；FFI 边界用 `apps/flutter/test/ffi_smoke_test.dart` 冒烟
