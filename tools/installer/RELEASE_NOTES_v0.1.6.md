# XDRemux v0.1.6

Android Release 导入修复：

- 修复 GitHub Actions 构建的 APK 缺少 NDK `libc++_shared.so`，导致 Rust 核心动态库无法加载、HEIC 分类失败的问题。
- Release workflow 现在显式把 Android NDK 的 C++ 运行库打包到 `arm64-v8a` APK 中。
- 保留 v0.1.5 的 OPPO/ColorOS 文件选择器字节与缓存路径兜底，以及明确错误提示。
- 版本号更新为 `0.1.6+8`，继续使用稳定 release 签名密钥，可直接覆盖升级。
