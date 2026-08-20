# XDRemux v0.3.0-pre.1

这是 v0.3.0 的跨平台预发布版本，主要用于 Windows 与 Android 真机验收。

## 本版本

- Rust 默认转换链支持 Apple 摄影风格和 Apple 人像模式设置；独立人像模式实验室页面暂时隐藏。
- Windows 支持“一帧影像，动用两台手机”文件往返流程。
- Android 支持 SAF 导入、OPPO 兼容文件生成、Apple 回传文件写回、保存图库和分享。
- Windows / Android 使用 Rust HEIF 编解码器恢复可见原机水印，并写回 OPPO 元数据与私有尾部数据。
- Apple 平台继续使用 ImageIO / 原生路径。
- Android 发布 APK 使用 arm64-v8a，并使用 GitHub Actions 受保护的 release keystore 签名。

## 验收重点

1. Android SAF 文件、分享导入和权限降级路径。
2. OPPO 原始照片 → Apple 照片编辑副本 → 回传照片 → OPPO 兼容输出。
3. 可见原机水印、元数据、尾部数据，以及 HDR / gain map 文件的打开和保存。
4. Windows 文件往返、输出目录、分享和 HEIC 重新打开。

## 已知限制

- 本版本为 pre-release，不代表 Apple Photos 或 OPPO 设备逐像素等价。
- Rust 可见水印恢复会解码、合成并重新编码 HEIF；最终颜色、HDR 和设备图库行为仍需真实设备确认。
- macOS / iOS 的签名、Apple Developer 分发和真机验收不由本次 Windows / Android GitHub Release 自动发布。
- Apple 摄影风格和人像模式仍属于实验性能力；人像模式实验室入口暂时关闭，但设置中的人像模式开关保留。
