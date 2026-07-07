# XDRemux 跨平台开发指南

## 项目概述

XDRemux 是一个将 OPPO/OnePlus/realme 设备拍摄的 ProXDR HEIC 转换为 ISO 21496-1 HDR HEIC 的工具。

### 目标平台
- Android
- iOS
- Windows
- macOS

### 技术栈
- **核心逻辑**: Rust (跨平台、高性能、内存安全)
- **UI 层**: Flutter (跨平台 UI 框架)
- **桥接层**: Dart FFI (Foreign Function Interface)

---

## 开发环境配置

### 1. 基础工具安装

#### Windows

```powershell
# 安装包管理器 (可选)
winget install --id Microsoft.PowerShell

# 安装 Rust
winget install Rustlang.Rustup

# 安装 Flutter
winget install Flutter.Flutter

# 安装 Git
winget install Git.Git

# 安装 VS Code
winget install Microsoft.VisualStudioCode

# 安装 Visual Studio Build Tools (Windows 桌面开发)
winget install Microsoft.VisualStudio.2022.BuildTools
# 选择 "Desktop development with C++" 工作负载
```

#### macOS

```bash
# 安装 Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 安装 Flutter
brew install flutter

# 安装 Xcode (App Store)
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# 安装 Android Studio
brew install --cask android-studio

# 安装 libheif
brew install libheif
```

#### Linux (Ubuntu/Debian)

```bash
# 安装基础依赖
sudo apt update
sudo apt install -y curl wget git unzip xz-utils zip

# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 安装 Flutter
sudo snap install flutter --classic

# 安装系统库
sudo apt install -y \
    clang cmake ninja-build pkg-config \
    libgtk-3-dev \
    libheif-dev \
    libde265-dev \
    libx265-dev

# 环境变量
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### 2. Rust 目标平台

```bash
# 添加交叉编译目标
rustup target add aarch64-linux-android    # Android ARM64
rustup target add armv7-linux-androideabi  # Android ARM32
rustup target add x86_64-linux-android     # Android x86_64
rustup target add aarch64-apple-ios        # iOS ARM64
rustup target add x86_64-apple-darwin      # macOS x86_64
rustup target add aarch64-apple-darwin     # macOS ARM64
rustup target add x86_64-pc-windows-msvc  # Windows x86_64
```

### 3. VS Code 扩展

```bash
code --install-extension Dart-Code.flutter
code --install-extension Dart-Code.dart-code
code --install-extension rust-lang.rust-analyzer
code --install-extension serayuzgur.crates
code --install-extension vadimcn.vscode-lldb
```

---

## 项目结构

```
xdremux-flutter/
├── rust/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs              # FFI 导出接口
│       ├── container.rs        # HEIC 容器解析
│       ├── iso21496.rs         # ISO 21496-1 元数据
│       ├── gainmap.rs          # Gain Map 处理
│       ├── edr.rs              # EDR 计算器
│       └── heif_io.rs          # HEIF I/O
├── lib/
│   ├── main.dart               # 应用入口
│   ├── screens/
│   │   ├── home_screen.dart    # 主界面
│   │   └── convert_screen.dart # 转换界面
│   ├── widgets/
│   │   └── file_picker_widget.dart
│   ├── services/
│   │   └── xdremux_service.dart
│   └── ffi/
│       └── xdremux_ffi.dart    # FFI 桥接
├── android/
├── ios/
├── windows/
├── macos/
├── pubspec.yaml
└── README.md
```

---

## 核心文件

### 1. rust/Cargo.toml

```toml
[package]
name = "xdremux-core"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
heif = "0.16"
image = "0.25"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
thiserror = "2.0"

[profile.release]
opt-level = "s"
lto = true
```

### 2. rust/src/lib.rs

```rust
pub mod container;
pub mod iso21496;
pub mod gainmap;
pub mod edr;
pub mod heif_io;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
pub struct ConversionResult {
    pub success: bool,
    pub mode: *mut c_char,
    pub edr_scale: f64,
    pub error_message: *mut c_char,
}

#[no_mangle]
pub extern "C" fn xdremux_convert(
    input_path: *const c_char,
    output_path: *const c_char,
    oppo_compat: bool,
) -> ConversionResult {
    let input = unsafe { CStr::from_ptr(input_path) }
        .to_str()
        .unwrap_or("");
    let output = unsafe { CStr::from_ptr(output_path) }
        .to_str()
        .unwrap_or("");

    match container::extract_lhdr(input) {
        Ok(lhdr) => {
            let edr_scale = if lhdr.mode == "uhdr" {
                let meta = iso21496::build_iso21496_metadata_from_uhdr(&lhdr.meta_floats);
                meta.scale
            } else {
                edr::edr_scale_calculator(&lhdr.meta_floats)
            };

            let iso_meta = iso21496::build_iso21496_metadata(edr_scale);

            match heif_io::write_heic(output, &lhdr, &iso_meta, oppo_compat) {
                Ok(()) => ConversionResult {
                    success: true,
                    mode: CString::new(lhdr.mode.clone()).unwrap().into_raw(),
                    edr_scale,
                    error_message: std::ptr::null_mut(),
                },
                Err(e) => ConversionResult {
                    success: false,
                    mode: std::ptr::null_mut(),
                    edr_scale: 0.0,
                    error_message: CString::new(e.to_string()).unwrap().into_raw(),
                },
            }
        }
        Err(e) => ConversionResult {
            success: false,
            mode: std::ptr::null_mut(),
            edr_scale: 0.0,
            error_message: CString::new(e.to_string()).unwrap().into_raw(),
        },
    }
}

#[no_mangle]
pub extern "C" fn xdremux_free_result(result: ConversionResult) {
    if !result.mode.is_null() {
        unsafe { drop(CString::from_raw(result.mode)); }
    }
    if !result.error_message.is_null() {
        unsafe { drop(CString::from_raw(result.error_message)); }
    }
}
```

### 3. lib/ffi/xdremux_ffi.dart

```dart
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

final class ConversionResult extends Struct {
  @Bool()
  external bool success;

  external Pointer<Utf8> mode;

  @Double()
  external double edrScale;

  external Pointer<Utf8> errorMessage;
}

final DynamicLibrary _lib = Platform.isAndroid
    ? DynamicLibrary.open('libxdremux_core.so')
    : Platform.isIOS
        ? DynamicLibrary.process()
        : Platform.isWindows
            ? DynamicLibrary.open('xdremux_core.dll')
            : DynamicLibrary.open('libxdremux_core.dylib');

typedef ConvertNative = ConversionResult Function(
    Pointer<Utf8> input, Pointer<Utf8> output, Bool oppoCompat);
typedef ConvertDart = ConversionResult Function(
    Pointer<Utf8> input, Pointer<Utf8> output, bool oppoCompat);

final ConvertDart _convert = _lib
    .lookupFunction<ConvertNative, ConvertDart>('xdremux_convert');

typedef FreeResultNative = void Function(ConversionResult result);
typedef FreeResultDart = void Function(ConversionResult result);

final FreeResultDart _freeResult = _lib
    .lookupFunction<FreeResultNative, FreeResultDart>('xdremux_free_result');

class XdRemuxFFI {
  static Future<ConversionResult> convert(
      String inputPath, String outputPath,
      {bool oppoCompat = false}) async {
    final input = inputPath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();

    try {
      final result = _convert(input, output, oppoCompat);
      return result;
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }

  static void freeResult(ConversionResult result) {
    _freeResult(result);
  }
}
```

### 4. pubspec.yaml

```yaml
name: xdremux
description: ProXDR HEIC to ISO 21496-1 HDR converter

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter
  ffi: ^2.1.0
  file_picker: ^8.0.0
  path_provider: ^2.1.0
  permission_handler: ^11.0.0
  shared_preferences: ^2.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  ffigen: ^13.0.0
  flutter_lints: ^3.0.0

flutter:
  uses-material-design: true
```

---

## 构建命令

### 开发阶段

```bash
# 安装依赖
flutter pub get

# 运行调试版本
flutter run

# 构建 Rust 核心
cd rust && cargo build --release && cd ..
```

### 构建发布版本

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release

# iOS
flutter build ios --release

# Windows
flutter build windows --release

# macOS
flutter build macos --release
```

---

## 测试

### 测试文件

在项目根目录创建 `trial/` 文件夹，放入 ProXDR HEIC 测试文件。

### Python 版本测试

```bash
# 安装依赖
python -m pip install pillow-heif Pillow numpy

# 单张转换
python xdremux/python/XDRemux.py convert --input trial/photo.heic --output trial/output.heic

# 批量转换
python xdremux/python/XDRemux.py batch --input-dir trial --output-dir trial/output
```

### Rust 版本测试

```bash
cd rust
cargo test
cargo run --example convert -- --input ../trial/photo.heic --output ../trial/output.heic
```

---

## 已知问题

1. **Android**: 需要 API 26+ (Android 8.0) 才能原生支持 HEIF
2. **iOS**: 需要 iOS 11+ 支持 HEIF
3. **Windows**: 需要安装 HEIF 扩展或内置 libheif
4. **包体积**: Python 方案会增加约 15-20MB

---

## 参考资料

- [Flutter FFI 文档](https://docs.flutter.dev/development/platform-integration/c-interop)
- [Rust FFI 文档](https://doc.rust-lang.org/nomicon/ffi.html)
- [libheif](https://github.com/novice-lab/libheif)
- [ISO 21496-1](https://www.iso.org/standard/80435.html)

---

## 原始项目信息

### GitHub 仓库

https://github.com/21Z121Z1/XDRemux

### 原始 Python 代码位置

```
xdremux/python/
├── container.py        # HEIC 容器解析
├── iso21496.py         # ISO 21496-1 元数据
├── heif_io.py          # HEIF I/O
├── edr.py              # EDR 计算器
├── gainmap.py          # Gain Map 处理
├── XDRemux.py          # CLI 入口
└── requirements.txt    # 依赖
```

### 依赖

```
pillow-heif>=0.15.0
Pillow>=11.0.0
numpy>=2.0.0
```

---

## 联系方式

如有问题，请在 GitHub 上提交 Issue。

---

最后更新: 2026-07-07
