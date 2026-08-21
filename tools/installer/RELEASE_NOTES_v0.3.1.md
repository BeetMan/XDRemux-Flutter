# XDRemux v0.3.1

## 本版本

- 完善 Apple/OPPO 回传照片写回流程。
- Apple 标准输出使用 Rust 生成新的 Apple Photographic Styles graph。
- OPPO 兼容输出恢复原始完整水印 canvas、HDR/UHDR graph 和 OPPO 尾部数据。
- Apple/OPPO 工作流的编辑副本和最终输出统一提供保存、打开、分享三个文件操作。
- 桌面端支持“另存为”，Android/iOS 支持保存到照片图库。

## 验收重点

1. Apple 标准输出的 HDR、Apple Styles 入口和原始水印。
2. OPPO 兼容输出的水印颜色、HDR 和 OPPO Gallery 兼容性。
3. Windows、Android、macOS 文件保存、打开和分享流程。

## 已知限制

- Apple Photographic Styles 的旧 Photos 编辑状态不写回；Apple 标准输出生成新的 Styles recipe。
- Apple/OPPO 输出仍需在真实 Photos 和 OPPO Gallery 设备上验证。
- macOS 分发仍为本地 unsigned 构建，未纳入 GitHub Actions 签名发布。
