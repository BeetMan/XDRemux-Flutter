# XDRemux v0.1.2

Android 发布构建与图标修复：

- launcher 改为使用独立的 XDRemux adaptive icon 资源名，避免设备 launcher 继续显示 Flutter 初始图标。
- 本地 release 与 GitHub Actions release 统一使用同一套 keystore；CI 缺少签名密钥时会直接失败，不再生成无法互相覆盖的临时 debug 签名 APK。
- Android `versionCode` 改为以 `apps/flutter/pubspec.yaml` 为唯一来源；发布 tag 必须与 pubspec 版本一致，本版本为 `0.1.2+4`。

注意：`v0.1.1` 是由 GitHub runner 的临时 debug key 签名的旧构建。签名切换后，首次安装 `v0.1.2` 需要先卸载旧版 `v0.1.1`，后续版本即可直接覆盖更新。
