# XDRemux Flutter

[English](#english) | [中文](#中文)

A cross-platform ProXDR HEIC converter built with Flutter + Rust.

[![Flutter](https://img.shields.io/badge/Flutter-3.24-blue.svg)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.80-orange.svg)](https://www.rust-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20macOS-lightgrey.svg)]()
[![Status](https://img.shields.io/badge/Status-Work%20in%20Progress-yellow.svg)]()

> ⚠️ **Work in Progress**
>
> This project is in early development stage. The repository has just been created and core functionality is still being implemented.
>
> **Current status:**
> - ✅ Project structure initialized
> - ✅ Rust FFI interface designed
> - ✅ Flutter UI skeleton created
> - 🔨 Core Rust engine (porting from Python)
> - 🔨 HEIC container parser
> - 🔨 ISO 21496-1 metadata handler
> - ❌ Not yet functional
>
> Contributions and feedback are welcome!

---

## English

XDRemux Flutter is a cross-platform version of [XDRemux](https://github.com/21Z121Z1/XDRemux), supporting Android, iOS, Windows, and macOS.

It converts ProXDR HEIC photos captured on OPPO, OnePlus, and realme devices into standard ISO 21496-1 HDR HEIC files.

### Acknowledgments

This project is based on the core algorithms and research from [21Z121Z1/XDRemux](https://github.com/21Z121Z1/XDRemux). Special thanks to the original author for their contribution.

The original project uses Swift + Python implementation. This project rewrites it using Flutter + Rust for true cross-platform support.

---

## Features

- 📱 **Cross-platform**: Android, iOS, Windows, macOS
- ⚡ **High Performance**: Rust core engine
- 🎨 **Modern UI**: Flutter Material Design 3
- 🔄 **Batch Conversion**: Multiple file support
- 📷 **OPPO Compatibility**: OPPO Gallery compatible mode

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Flutter | 3.24+ | UI Framework |
| Rust | 1.80+ | Core Engine |
| Android Studio | Latest | Android Development |
| Xcode | 15.0+ | iOS/macOS Development |
| Visual Studio | 2022+ | Windows Development |

### Install

```bash
# Clone
git clone https://github.com/BeetMan/XDRemux-Flutter.git
cd XDRemux-Flutter

# Install dependencies
flutter pub get

# Build Rust core
cd rust && cargo build --release && cd ..
```

### Build for Each Platform

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

### Command Line

```bash
# Single file
flutter run -- --input photo.heic

# Batch
flutter run -- --input-dir photos/ --output-dir converted/
```

### Dart API

```dart
import 'services/xdremux_service.dart';

// Single file
await XdRemuxService.convert(
  'input.heic',
  'output.heic',
  oppoCompat: false,
);

// Batch
await XdRemuxService.batchConvert(
  'input/',
  'output/',
  oppoCompat: true,
);
```

## Architecture

```
┌─────────────────────────────────────────┐
│           Flutter UI Layer              │
│    (Android / iOS / Windows / macOS)    │
├─────────────────────────────────────────┤
│            Dart FFI Bridge              │
├─────────────────────────────────────────┤
│            Rust Core Engine             │
│  ┌─────────┬─────────┬─────────┬──────┐ │
│  │Container│ISO 21496│Gain Map │ EDR  │ │
│  │ Parser  │Metadata │Processor│Calc  │ │
│  └─────────┴─────────┴─────────┴──────┘ │
├─────────────────────────────────────────┤
│        libheif / image-rs               │
└─────────────────────────────────────────┘
```

## Supported Devices

| Brand | Series | Models |
|-------|--------|--------|
| OnePlus | Flagship | 12, 13, 15, 15T |
| OnePlus | Ace | Ace 3/5/6 series |
| OPPO | Find | X6/X7/X8/X9, N3/N5/N6 |
| OPPO | Reno | Reno10-16 series |
| OPPO | K | K12/K13/K15 series |
| realme | GT | GT5/GT6/GT7/GT8 series |
| realme | Neo | Neo6/Neo7/Neo8 series |
| realme | Number | 12/13/14/15 series |

## Project Structure

```
XDRemux-Flutter/
├── rust/                    # Rust core engine
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs           # FFI exports
│       ├── container.rs     # HEIC container parser
│       ├── iso21496.rs      # ISO 21496-1 metadata
│       ├── gainmap.rs       # Gain Map processor
│       ├── edr.rs           # EDR calculator
│       └── heif_io.rs       # HEIF I/O
├── lib/                     # Flutter application
│   ├── main.dart
│   ├── screens/             # UI screens
│   ├── services/            # Business logic
│   └── ffi/                 # FFI bindings
├── android/                 # Android platform
├── ios/                     # iOS platform
├── windows/                 # Windows platform
├── macos/                   # macOS platform
└── pubspec.yaml             # Flutter dependencies
```

## Development

### Run in Development

```bash
flutter run
```

### Run Tests

```bash
# Flutter tests
flutter test

# Rust tests
cd rust && cargo test
```

### Build for Release

```bash
# Clean build
flutter clean
flutter pub get
cd rust && cargo build --release && cd ..

# Build all platforms
flutter build apk --release
flutter build ios --release
flutter build windows --release
flutter build macos --release
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.

## Credits

- **Original Project**: [XDRemux](https://github.com/21Z121Z1/XDRemux) by [21Z121Z1](https://github.com/21Z121Z1)
- **Flutter**: [flutter.dev](https://flutter.dev)
- **Rust**: [rust-lang.org](https://www.rust-lang.org)
- **libheif**: [github.com/novice-lab/libheif](https://github.com/novice-lab/libheif)

---

## 中文

XDRemux Flutter 是 [XDRemux](https://github.com/21Z121Z1/XDRemux) 的跨平台版本，支持 Android、iOS、Windows 和 macOS。

它能将 OPPO、OnePlus、realme 设备拍摄的 ProXDR HEIC 照片转换为符合 ISO 21496-1 标准的 HDR HEIC 文件。

> ⚠️ **开发中**
>
> 本项目处于早期开发阶段，仓库刚刚创建，核心功能正在移植中。
>
> **当前进度：**
> - ✅ 项目结构初始化完成
> - ✅ Rust FFI 接口设计完成
> - ✅ Flutter UI 骨架创建完成
> - 🔨 核心 Rust 引擎（从 Python 移植中）
> - 🔨 HEIC 容器解析器
> - 🔨 ISO 21496-1 元数据处理
> - ❌ 尚未可用
>
> 欢迎贡献代码和反馈！

### 致谢

本项目基于 [21Z121Z1/XDRemux](https://github.com/21Z121Z1/XDRemux) 的核心算法和研究成果，在此感谢原作者的贡献。

原项目使用 Swift + Python 实现，本项目使用 Flutter + Rust 重写，实现了真正的跨平台支持。

---

## 功能特性

- 📱 **跨平台**: Android、iOS、Windows、macOS
- ⚡ **高性能**: Rust 核心引擎
- 🎨 **现代 UI**: Flutter Material Design 3
- 🔄 **批量转换**: 支持多文件同时转换
- 📷 **OPPO 兼容**: 支持 OPPO 相册兼容模式

## 快速开始

### 环境要求

| 工具 | 版本 | 用途 |
|------|------|------|
| Flutter | 3.24+ | UI 框架 |
| Rust | 1.80+ | 核心引擎 |
| Android Studio | 最新版 | Android 开发 |
| Xcode | 15.0+ | iOS/macOS 开发 |
| Visual Studio | 2022+ | Windows 开发 |

### 安装

```bash
# 克隆仓库
git clone https://github.com/BeetMan/XDRemux-Flutter.git
cd XDRemux-Flutter

# 安装 Flutter 依赖
flutter pub get

# 构建 Rust 核心
cd rust && cargo build --release && cd ..
```

### 构建

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

## 使用方法

### 命令行

```bash
# 单文件转换
flutter run -- --input photo.heic

# 批量转换
flutter run -- --input-dir photos/ --output-dir converted/
```

### Dart API

```dart
import 'services/xdremux_service.dart';

// 单文件转换
await XdRemuxService.convert(
  'input.heic',
  'output.heic',
  oppoCompat: false,
);

// 批量转换
await XdRemuxService.batchConvert(
  'input/',
  'output/',
  oppoCompat: true,
);
```

## 架构

```
┌─────────────────────────────────────────┐
│           Flutter UI 层                 │
│    (Android / iOS / Windows / macOS)    │
├─────────────────────────────────────────┤
│            Dart FFI 桥接层              │
├─────────────────────────────────────────┤
│            Rust 核心引擎                │
│  ┌─────────┬─────────┬─────────┬──────┐ │
│  │容器解析 │ISO元数据 │Gain Map │ EDR  │ │
│  │         │         │处理     │计算  │ │
│  └─────────┴─────────┴─────────┴──────┘ │
├─────────────────────────────────────────┤
│        libheif / image-rs               │
└─────────────────────────────────────────┘
```

## 支持设备

| 品牌 | 系列 | 机型 |
|------|------|------|
| 一加 | 旗舰 | 12、13、15、15T |
| 一加 | Ace | Ace 3/5/6 系列 |
| OPPO | Find | X6/X7/X8/X9、N3/N5/N6 |
| OPPO | Reno | Reno10-16 系列 |
| OPPO | K | K12/K13/K15 系列 |
| realme | GT | GT5/GT6/GT7/GT8 系列 |
| realme | Neo | Neo6/Neo7/Neo8 系列 |
| realme | 数字 | 12/13/14/15 系列 |

## 项目结构

```
XDRemux-Flutter/
├── rust/                    # Rust 核心引擎
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs           # FFI 导出接口
│       ├── container.rs     # HEIC 容器解析
│       ├── iso21496.rs      # ISO 21496-1 元数据
│       ├── gainmap.rs       # Gain Map 处理
│       ├── edr.rs           # EDR 计算器
│       └── heif_io.rs       # HEIF I/O
├── lib/                     # Flutter 应用
│   ├── main.dart
│   ├── screens/             # 界面
│   ├── services/            # 业务逻辑
│   └── ffi/                 # FFI 绑定
├── android/                 # Android 平台
├── ios/                     # iOS 平台
├── windows/                 # Windows 平台
├── macos/                   # macOS 平台
└── pubspec.yaml             # Flutter 依赖
```

## 开发

### 开发模式运行

```bash
flutter run
```

### 运行测试

```bash
# Flutter 测试
flutter test

# Rust 测试
cd rust && cargo test
```

### 发布构建

```bash
# 清理构建
flutter clean
flutter pub get
cd rust && cargo build --release && cd ..

# 构建所有平台
flutter build apk --release
flutter build ios --release
flutter build windows --release
flutter build macos --release
```

## 贡献

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

## 致谢

- **原项目**: [XDRemux](https://github.com/21Z121Z1/XDRemux) by [21Z121Z1](https://github.com/21Z121Z1)
- **Flutter**: [flutter.dev](https://flutter.dev)
- **Rust**: [rust-lang.org](https://www.rust-lang.org)
- **libheif**: [github.com/novice-lab/libheif](https://github.com/novice-lab/libheif)
