# XDRemux Flutter

English Version | [中文版](#中文版)

A cross-platform ProXDR HEIC converter for OPPO/OnePlus/realme devices, built with Flutter + Rust.

[![Flutter](https://img.shields.io/badge/Flutter-3.24-blue.svg)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.80-orange.svg)](https://www.rust-lang.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-WIP-yellow.svg)]()

> ⚠️ **Work in Progress**
>
> This project is in early development stage. Core functionality is being ported from the original Python/Swift implementation.
>
> Current status: Project initialized, Rust FFI designed, Flutter UI skeleton created. Core engine still in progress.
>
> Contributions welcome!

---

## 中文版

XDRemux Flutter 是 [XDRemux](https://github.com/21Z121Z1/XDRemux) 的跨平台版本，支持 Android、iOS、Windows 和 macOS。

它能将 OPPO、OnePlus、realme 设备拍摄的 ProXDR HEIC 照片转换为符合 ISO 21496-1 标准的 HDR HEIC 文件。

### 致谢

本项目基于 [21Z121Z1/XDRemux](https://github.com/21Z121Z1/XDRemux) 的核心算法和研究成果，在此感谢原作者的贡献。

原项目使用 Swift + Python 实现，本项目使用 Flutter + Rust 重写，实现了真正的跨平台支持。

---

## Features

- 📱 **跨平台**: Android、iOS、Windows、macOS
- ⚡ **高性能**: Rust 核心引擎，接近原生性能
- 🎨 **现代 UI**: Flutter Material Design 3
- 🔄 **批量转换**: 支持多文件同时转换
- 📷 **OPPO 兼容**: 支持 OPPO 相册兼容模式

## Supported Devices

XDRemux supports OPPO, OnePlus, and realme devices that can capture ProXDR photos:

| Brand | Models |
|-------|--------|
| OnePlus | OnePlus 12/13/15, Ace 3/5/6 series |
| OPPO Find | X6/X7/X8/X9 series, N3/N5/N6 |
| OPPO Reno | Reno10-16 series |
| OPPO K | K12/K13/K15 series |
| realme GT | GT5/GT6/GT7/GT8 series |
| realme Neo | Neo6/Neo7/Neo8 series |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Core Engine | Rust |
| UI Framework | Flutter |
| FFI Bridge | dart:ffi |
| HEIF Support | libheif |
| Image Processing | image-rs |

## Getting Started

### Prerequisites

- Flutter SDK 3.24+
- Rust 1.80+
- Android Studio (for Android)
- Xcode (for iOS/macOS)
- Visual Studio Build Tools (for Windows)

### Installation

```bash
# Clone the repository
git clone https://github.com/BeetMan/XDRemux-Flutter.git
cd XDRemux-Flutter

# Install Flutter dependencies
flutter pub get

# Build Rust core
cd rust && cargo build --release && cd ..
```

### Build

```bash
# Android
flutter build apk --release

# iOS
flutter build ios --release

# Windows
flutter build windows --release

# macOS
flutter build macos --release
```

## Usage

### Single File Conversion

```dart
import 'services/xdremux_service.dart';

final result = await XdRemuxService.convert(
  '/path/to/input.heic',
  '/path/to/output.heic',
  oppoCompat: false,
);
```

### Batch Conversion

```dart
final results = await XdRemuxService.batchConvert(
  '/path/to/input/',
  '/path/to/output/',
  oppoCompat: true,
);
```

## Project Structure

```
XDRemux-Flutter/
├── rust/                    # Rust core engine
│   ├── src/
│   │   ├── lib.rs          # FFI exports
│   │   ├── container.rs    # HEIC container parser
│   │   ├── iso21496.rs     # ISO 21496-1 metadata
│   │   ├── gainmap.rs      # Gain Map processor
│   │   ├── edr.rs          # EDR calculator
│   │   └── heif_io.rs      # HEIF I/O
│   └── Cargo.toml
├── lib/                     # Flutter app
│   ├── main.dart
│   ├── screens/
│   ├── services/
│   └── ffi/
├── android/
├── ios/
├── windows/
└── macos/
```

## API Reference

### FFI Functions

```rust
// Convert a single file
#[no_mangle]
pub extern "C" fn xdremux_convert(
    input_path: *const c_char,
    output_path: *const c_char,
    oppo_compat: bool,
) -> ConversionResult;

// Free result memory
#[no_mangle]
pub extern "C" fn xdremux_free_result(result: ConversionResult);
```

### Dart API

```dart
class XdRemuxService {
  /// Convert a single ProXDR HEIC file
  static Future<bool> convert(
    String inputPath,
    String outputPath, {
    bool oppoCompat = false,
  });

  /// Batch convert multiple files
  static Future<List<Map<String, dynamic>>> batchConvert(
    String inputDir,
    String outputDir, {
    bool oppoCompat = false,
  });
}
```

## Known Limitations

- HEIF support requires Android API 26+ (Android 8.0)
- HEIF support requires iOS 11+
- Windows requires HEIF extension or bundled libheif

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [XDRemux](https://github.com/21Z121Z1/XDRemux) - Original implementation by [21Z121Z1](https://github.com/21Z121Z1)
- [Flutter](https://flutter.dev) - Cross-platform UI framework
- [Rust](https://www.rust-lang.org) - Systems programming language
- [libheif](https://github.com/novice-lab/libheif) - HEIF/HEIC codec library
