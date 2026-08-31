# XDRemux v0.3.2

质量闭环版本：鸿蒙 NEXT 支持落地、写回提速一倍、写回恢复 GPS、依赖升级消除构建警告，全平台 CI 补齐 macOS/iOS。

## 本次更新

### 新平台：鸿蒙 NEXT（研究级）

在华为 PLR-AL50（HarmonyOS 7.0.0.102）真机验证全功能可用：

- 完整转换链路（Rust 核心 OHOS 构建 + CPF-Flutter 工具链）
- 从图库选图（HEIC 原图，不转码；API 26 兼容声明）
- 保存到图库（PhotoAccessHelper）
- 系统分享输出 / 从文件管理器接收分享（原始字节）
- 工作流写回（恢复原机水印 + OPPO 兼容输出）
- 批量完成通知
- 构建方式：`tools/ohos/build_hap.ps1`（需本机 DevEco Studio 自动签名），CI 探针（公开 SDK）见 `.github/workflows/ohos-ci.yml`

### 性能

- 写回 tile 批编码并行化（最多 4 工作线程）+ 写回光栅 fast preset：**手机端写回 ~22s → ~10s**，全平台受益
- 写回报告新增 `timingsMs` 阶段耗时分解（排查性能回归用）

### 修复

- 写回输出恢复 donor 的 Exif（含 GPS），两条输出路径统一
- 通知插件钉 v19（位置参数 API，与鸿蒙 fork 统一）

### 工程

- 依赖升级链消除构建警告：file_picker v12 / win32 v6 / package_info_plus 10 / share_plus 13 / shared_preferences 2.5 / Kotlin 2.3.10
- `flutter analyze` 零警告；Android 构建无 KGP 警告
- CI 补齐 macOS DMG 与 iOS unsigned IPA 自动发布
- 技术文档体系落地（`docs/`，23 页 + 索引）

## 下载

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows x64 | `XDRemux-Windows-0.3.2-Setup.exe` | 安装包 |
| Windows ARM64 | `XDRemux-Windows-arm64-0.3.2-Setup.exe` | 实验性 |
| macOS | `XDRemux-macOS-0.3.2.dmg` | 未公证；首次右键打开 |
| Android | `XDRemux-Android-0.3.2.apk` | - |
| iOS | `XDRemux-iOS-0.3.2-unsigned.ipa` | 未签名，需自行签名安装 |
| 鸿蒙 NEXT | 无 CI 产物 | 本地构建：`tools/ohos/build_hap.ps1` |

## 验证状态

- Windows / Android / macOS / iOS / 鸿蒙（PLR-AL50）：均已构建；Android + 鸿蒙真机回归通过；iOS 真机待验证
