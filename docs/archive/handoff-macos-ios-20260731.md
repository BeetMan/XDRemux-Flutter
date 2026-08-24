# XDRemux 项目交接文档（Mac：iOS + macOS 版）

> 历史文档：其中的 iOS “尚未创建”结论已过时。v0.3.0 当前状态、实际工具链和验证结果见 `docs/v0.3.0-backend-validation.md`；不要直接按本文旧待办判断当前代码。

> 整理日期：2026-07-31
> 分支：`main` @ `99dcfaf`（与 `origin/main` 同步，工作区干净）
> 最新发布：v0.2.0（正式版，Windows + Android）

## 项目本质

将 OPPO / OnePlus / realme 拍摄的 **ProXDR HEIC** 转换为标准 **ISO 21496-1 HDR HEIC**。
Rust 重写核心转换逻辑 + Flutter 跨平台 UI。

**架构**：
- `xdremux/rust/` — Rust 核心（cdylib，FFI 导出），含 x265 静态链接编码器
- `apps/flutter/` — Flutter UI，通过 `dart:ffi` 调用 Rust 核心
- 转换流程：解析 HEIC → 提取/重建 gain map → 切 512×512 tile → x265 编码 → 组装 ISO HDR HEIC

## 当前平台状态（关键）

| 平台 | 状态 | 说明 |
|------|------|------|
| Windows | ✅ 可用（v0.2.0） | x265 静态链接，无 ffmpeg 依赖 |
| Android | ✅ 可用（v0.2.0） | x265 静态 + MediaCodec 硬件编码（默认关） |
| **macOS** | ✅ **已建好** | `apps/flutter/macos/` 完整，dylib 通过 `copy_dylib.sh` 注入 Frameworks |
| **iOS** | ❌ **从未创建** | **无 `apps/flutter/ios/` 目录**，需 `flutter create --platforms=ios` |

## macOS 版现状（你已能跑）

- `macos/` 目录完整：Runner、Podfile、entitlements、`copy_dylib.sh`
- **dylib 注入机制**：Rust 编译出 `libxdremux_core.dylib` 放到 `apps/flutter/Frameworks/`，`copy_dylib.sh`（Podfile post_install 触发）拷贝进 `.app/Contents/Frameworks/`
- **FFI 加载**（`lib/ffi/xdremux_ffi.dart` `_openMacOS()`）：按 `@rpath/@executable_path` 自动搜 Frameworks，多路径兜底
- 构建 macOS 版 Rust：`cargo build --release`（target 无特殊要求，本机默认即可）→ dylib 放 `Frameworks/`

## iOS 版待办（重点）

1. **创建 iOS 平台骨架**：
   ```bash
   cd apps/flutter
   flutter create --platforms=ios --org io.github.beetman .
   ```
2. **Rust 编译 iOS 静态库**（iOS 无 dylib，需 staticlib + `DynamicLibrary.process()`）：
   - 安装 target：`rustup target add aarch64-apple-ios`
   - **关键**：`Cargo.toml` 已含 `staticlib` crate-type（第 10 行 `crate-type = ["cdylib", "staticlib", "rlib"]`）
   - iOS 上 `_lib` 走 `DynamicLibrary.process()`（`xdremux_ffi.dart` 已写好）——FFI 符号需静态链接进 app
   - x265 需交叉编译 aarch64-apple-ios（参考 Android 的 `vendor/x265/build_android` 流程，iOS 用 `-target arm64-apple-ios`）
3. **连接静态库**：把 `libxdremux_core.a` 加进 Xcode 工程的 Link Binary / OTHER_LDFLAGS
4. **iOS 适配 UI**：Android 专属功能要隐藏（参考现有 `Platform.isAndroid` 的隐藏模式；注意 iOS 无 `receive_sharing_intent` 之外，文件导入可能需 `UIDocumentPicker` 或系统照片）

## 关键技术点

### Rust 核心（你大概率不用改，但要懂）
- `xdremux/rust/src/lib.rs` — 全部 FFI 导出（`#[no_mangle]` + `extern "C"`）
- `hevc.rs` — tile 编码器：
  - **单 tile**：`encode_hevc_tile_gray/rgb`（frame-threads=1）
  - **批量（新，4.34s→0.81s 的提速）**：`x265_encode_tiles` — 一个编码器实例编整张图，interleaved feed+drain，按 IDR 切分每 tile
- `isobmff_write.rs` — ISO HEIC 组装（`assemble_prepared_tiles` 通用）
- Android 硬件编码路径：`xdremux_prepare_tiles` / `xdremux_assemble_tiles` FFI + Dart 驱动 MediaCodec

### 版本 / 发布
- 版本号：`apps/flutter/pubspec.yaml`（当前 `0.2.0+13`）+ `xdremux/rust/Cargo.toml` + `lib.rs` 里 `CString::new("0.2.0")` + `tools/installer/xdremux.iss`（4 处同步）
- 发布流程：tag `v0.2.0`（无 `-` = 正式版）→ CI 自动构建 Windows + Android
- 注意：`docs/` 被 .gitignore 忽略，新文档要 `git add -f`

### macOS 特有
- 中文字体：`main.dart` 里 `Platform.isWindows ? 'Microsoft YaHei' : null`（macOS 用系统默认，无需改）
- dylib 签名：`copy_dylib.sh` 需 `codesign` 处理（app 签名时 Frameworks 里的 dylib 要重签）——若上架需注意

## 待决策 / 已知未做

- **桌面 GPU 编码**：评估后**暂缓**（`docs/desktop-gpu-encoding-assessment.md`）——x265 批量后桌面已够快（0.8s/张），GPU 只支持 4:2:0 且会牺牲 4:4:4
- **增量转换**：评估后不做（`skipExisting` + 文件复制已覆盖主要场景）
- **iOS 适配**：本文档第 4 节——你来
- **转换结果预览**：你判断过坑太大，未做
- **Linux**：未创建

## 验证清单（改动后必跑）

```bash
# Rust
cd xdremux/rust && cargo test   # 期望 118+ passed

# Flutter analyze
cd apps/flutter && flutter analyze

# macOS 构建（需先把 dylib 放 Frameworks/）
flutter build macos
```

## 已知坑（踩过）

1. **Windows ffmpeg DLL 冲突**：`0xc0000142` — 用绝对路径 `where` 解析
2. **Windows ffmpeg 管道死锁**：后台 stdin 线程 + 先 drain stdout
3. **Android 高通 NV12 半平面**：V-plane buffer limit 少 1 字节，U/V 要交错写共享 buffer（`MediaCodecHevcEncoder.kt`）
4. **hvcC level 解析**：从 SPS 读（VPS 偏移因编码器而异）
5. **Gradle strip .so**：打包后 hash 变化属正常
