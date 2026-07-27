# XDRemux v0.1.3

Android 文件导入修复：

- 修复 release APK 中选择 HEIC/HEIF 后文件无法加入队列的问题。
- `classify()` 不再从 spawned isolate 调用动态加载的 Rust FFI；Android release 构建统一在 root isolate 执行该调用。
- 版本号更新为 `0.1.3+5`，继续使用 v0.1.2 的稳定 release 签名密钥，可直接覆盖升级。
