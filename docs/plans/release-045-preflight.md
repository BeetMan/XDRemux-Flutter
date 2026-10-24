# 0.4.5 六平台发版预检（2026-10-25）

范围：Flutter `0.4.5+39` / Rust `0.4.5`。用户授权准备并验证六平台候选，保留 iPhone Duo 新 SDK 功能；暂不打 tag、不创建或修改 Release、不安装到手机，不同步升版鸿蒙原生。

## 源码和流程

- 基线 `ebabc301`，包含 JPEG HDR/ICC、Linux、Duo 布局、Apple HDR 缩略图及 iOS 模拟器/部署目标修复。
- [x] 保留 typed iOS 27.1 API 与运行时检查，发布 runner 改为 `xcode-27` 并显式选择 Xcode 27.1；早期 SDK/API typecheck，x265 缓存按 SDK 隔离。应用最低系统仍为 iOS 15.0。
- [x] Linux 改为可复用 workflow，纳入统一构建、附件检查和发布成功门禁；预检无标签时不执行 publish，Linux 独立附件 job 也不在 Release 调用中执行。
- [x] Release 说明补齐 Duo、HDR 黑缩略图、iOS 模拟器和六平台边界；主 README 的正式下载仍为 v0.4.4。
- [x] SDK 守卫的模拟工具测试：拒绝旧/非法 SDK、接受 27.1+、SDK 新但 API 编译失败时仍失败，共 10 个子场景通过。云端真实 Xcode 27.1 的 Duo API typecheck 也通过；不等同于归档或真机验收。
- [x] Windows 本地 Rust `cargo +1.96.1 test --locked -p xdremux-core` 258 passed / 7 ignored；Flutter analyze 无问题、145 tests 通过，暂存测试 DLL 后按哈希恢复。
- 云端只构建预检：[Release run 40124102998](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/40124102998)，源码 `605112a7`。在普通分支手动执行，不能触发 tag-gated publish。

## 候选构建

| 平台 | 目标 | 状态 |
|---|---|---|
| Windows | x64 Setup | 待云端预检 |
| Android | ARM64 APK，沿用正式签名 | 待云端预检；本地 CLI 确认 SDK 路径 |
| macOS | Apple Silicon DMG | 待云端预检 |
| iOS | ARM64 unsigned IPA，Xcode 27.1 | 真实 SDK/API 探针及 Rust 核心构建通过，归档预检中 |
| Linux | x64 AppImage / tar.gz / SHA256，预览 | 待统一流程预检 |
| Flutter HarmonyOS | ARM64 profile AOT / debug:true unsigned HAP | 待隔离构建及结构校验 |

Windows ARM64 不可交付，不计入六平台门禁；本次实验任务在 Flutter SDK setup 按预期失败。鸿蒙原生已由独立流程发布 `harmony-v0.5.2`（2026-10-25 本地时间），本轮未修改或重打原生包。云端预检产物可能使用 `ci-<sha>` 文件名，但应用内部版本必须是 0.4.5；正式发布才使用标签版本文件名。

## 人工验收（与构建成功分开记录）

- [ ] 各候选包安装/启动，检查 app/core 版本与来源提交；iOS 使用本机授权签名，OHOS 使用匹配的开发签名，不把 unsigned 当作免签。
- [ ] 两张 JPEG 原图（Issue #11 与 MIX Flip 2）分别验证 HDR 识别、ICC 色彩、Apple/OPPO 输出与水印画布；不上传私有样片。
- [ ] iOS/macOS 的 HDR 缩略图非黑、颜色和方向正常，Duo 侧栏、窗口尺寸/旋转/折叠布局不遮挡主操作。
- [ ] Live Photo 成对文件导出与 Apple Photos 配对、iOS PhotoKit 保存、Android 保存两份文件分别验证；OHOS 未接入的统一图库保存/配对分享仍明确列为限制。
- [ ] 收齐构建、签名说明、校验和和验收结果后，再由用户决定是否正式发布 v0.4.5。
