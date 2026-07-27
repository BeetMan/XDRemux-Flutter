# XDRemux v0.1.4

Android release 修复：

- 修复 release APK 中选择 HEIC/HEIF 后文件无法加入队列的问题。
- `classify()` 不再从 spawned isolate 调用动态加载的 Rust FFI；Android release 构建统一在 root isolate 执行该调用。
- 修复 Android CI 的 Gradle 仓库顺序：官方 Google/Maven Central 优先，阿里云镜像作为后备，避免镜像暂时 502 阻断发版。
- 版本号更新为 `0.1.4+6`，继续使用 v0.1.2 的稳定 release 签名密钥，可直接覆盖升级。
