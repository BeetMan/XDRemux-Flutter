# XDRemux v0.2.7-pre.2

Android 预览图权限修复（仅 APK）。

- **修复未授权「所有文件访问」时选择照片预览失败**：作用域存储下 app 未授予 MANAGE_EXTERNAL_STORAGE 时，真实路径 `File.exists()` 报告存在但 Rust 原生读取报 `Permission denied`，导致选图后无法生成预览图。现在未授权时统一走 content-URI 缓存副本（picker 授权可读），预览与转换恢复正常；GPS 保留仍需授权（OPPO 已知限制）。
- 包含 v0.2.7-pre.1 的缩略图缓存 null 崩溃修复。

版本号 `0.2.7+17`。本版本为 pre-release，仅提供 Android APK 供验证。
