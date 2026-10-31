# 许可说明

## 本项目代码

XDRemux-Flutter 的源代码按 **GNU General Public License 第 3 版（仅第 3 版，GPL-3.0-only）** 授权，全文见 [LICENSE](LICENSE)。范围包括 Flutter / Dart、Rust、Swift / Objective-C、ArkTS、构建与工具脚本，以及项目自写的文档（文件另有声明的除外）。

## 历史版本

本项目作者额外以 GPL-3.0-only 授权 v0.1.0 至 v0.4.6 的全部 Flutter 版发布标签，以及 `harmony-v*` 鸿蒙原生版发布标签。

- 这些版本中本项目自有代码此前附带的 MIT 授权继续有效，不因本说明撤回；v0.4.6 标签中的 `LICENSE` 文件仍是当时的 MIT 文本。
- 移植自上游的部分（见下节）按上游 GPL-3.0-only 授权使用。
- 各平台安装包因静态链接 x265 等 GPL 组件，整体按 GPL 分发。

请勿改写历史标签来表示当时已附带 GPL 声明。

## 来自上游 XDRemux 的代码

本项目基于 [21Z121Z1/XDRemux](https://github.com/21Z121Z1/XDRemux) 的研究与原版实现做跨平台移植，部分模块按上游代码重写或移植，例如：

- `xdremux/rust/src/styles_fit.rs`、`linear_thumbnail.rs`、`apple_log.rs`、`live_photo.rs`、`motion_photo.rs`、`iso_validate.rs`
- `apps/flutter/ios/SwiftBackend/Sources/XDremuxAppleProviders/` 下的 Semantic Style 校验、VideoToolbox HEVC 编码与 Vision 遮罩

上游作者自 2026-10-29 起以 GPL-3.0-only 授权其原创代码（含 v1.0–v1.4 历史版本），见上游 [LICENSING.md](https://github.com/21Z121Z1/XDRemux/blob/main/LICENSING.md)。这些部分的版权归上游作者所有，本项目按 GPL-3.0-only 使用和再分发。上游的样片（`fixtures/`）与 Core ML 模型不在 GPL 授权范围内，本仓库不包含这些内容。

## 第三方组件

第三方组件保留各自的原始许可，被包含在 GPL 作品中并不改变它们自身的许可：

- **x265**：GPL-2.0-or-later，静态链接进各平台的转换核心；源码与许可见 [x265](https://bitbucket.org/multicoreware/x265_git)。
- **libheif / libde265**（可选解码功能，默认不启用）：各自的许可见其上游项目，分发时保留其许可声明并遵守 LGPL 的重新链接要求。
- **Rust crates、Flutter / Dart 包与平台插件**：许可以各自包的声明为准（多为 MIT、BSD 或 Apache-2.0）。
- **鸿蒙平台的 Flutter 插件**（`tools/ohos/fetch_plugins.sh` 拉取的 CPF-Flutter 分支）：许可以各插件仓库的声明为准。

## 分发安装包时

发布的二进制（安装包、APK、IPA、HAP 等）对应的完整源代码就是同一发布标签下的本仓库内容。转发或修改后再分发时，请一并提供对应源代码，并保留本文件、[LICENSE](LICENSE) 及第三方组件的许可声明。

本许可不授予 HEVC 专利池许可、Apple SDK 权利、照片中人物的权利，也不授予任何第三方商标的使用权。
