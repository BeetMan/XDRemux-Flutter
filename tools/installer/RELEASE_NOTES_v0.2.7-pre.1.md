# XDRemux v0.2.7-pre.1

Android 崩溃修复（仅 APK）。

- **修复 Android 缩略图线程崩溃**：解码失败的 HEIC（如部分 OPPO ProXDR 文件）在写入缩略图缓存时对 `ConcurrentHashMap` 存入 null，触发 `NullPointerException` 导致 app 崩溃。现在只缓存成功的解码结果，失败时走 Dart 侧 FFI 兜底，不再崩溃。

版本号 `0.2.7+17`。本版本为 pre-release，仅提供 Android APK 供验证。
