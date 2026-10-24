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
- [x] Android 修正版独立预检：[run 40125224379](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/40125224379)，源码 `c33bd596`，构建、APK ABI/ELF/CRC 门禁与 artifact 上传全部通过，publish 为 skipped；其余平台未重跑，因为应用业务源码和各自构建输入未变。
- [x] 最终改动只读复核未发现发布权限、SDK 路径、平台选择或 APK 校验阻塞。APK 门禁 5 项测试（6 个子场景）通过，并实际拒绝首轮混合 ABI 包。

## 候选构建

| 平台 | 目标 | 状态 |
|---|---|---|
| Windows | x64 Setup | 云端构建、打包与 artifact 上传通过 |
| Android | ARM64 APK，沿用正式签名 | 修正版构建、签名、版本、ARM64-only、6 份 ELF 和 CRC 验证通过 |
| macOS | Apple Silicon DMG | 云端构建、代码封装校验和 DMG 打包通过 |
| iOS | ARM64 unsigned IPA，Xcode 27.1 | 云端归档/FFI 导出/IPA 打包通过；下载后确认设备 ARM64、版本 0.4.5+39、SDK 27.1、最低系统 15.0、ZIP CRC |
| Linux | x64 AppImage / tar.gz / SHA256，预览 | 统一流程构建、glibc/依赖检查和打包通过；独立上传 job 跳过 |
| Flutter HarmonyOS | ARM64 profile AOT / debug:true unsigned HAP | 隔离构建及静态校验通过，未安装/运行 |

OHOS：忽略目录 `target/oh045-1025/XDRemux-HarmonyOS-0.4.5-unsigned.hap`，37,422,649 bytes，SHA256 `C43C01A4031150658D38496CACCFF22406E9289254B2F73C7B6691AE10630C1F`。源码 `ebabc301` 与候选业务树一致（后续只改 workflow/文档）；SDK `62357a93` 的 profile kernel 经固定哈希校验。全量 ArkTS/profile 构建成功；包版本 `0.4.5+39`、ARM64-only、profile AOT/development flags、37 个 FFI、174 个核心导入、运行库来源及 ZIP CRC 检查通过；签名工具确认无 HAP Signing Block。完整命令、vendor 文件哈希及证据在该目录 `BUILD-REPORT.md`。

OHOS 隔离配置沿用已验证的 vendor 快照，移除不可获取的 Hvigor 6.24.4 显式依赖并使用 DevEco 自带工具链，排除 x64 库；没有修改业务源码、共享签名或已发布资产。当前 SDK 默认 target API 26/min API 18，有既有编译警告；未实际自签、安装、启动或验证照片转换，SDK stub 符号检查不替代设备 API 验收。

首轮云端 run 总体成功，publish 和 Linux 独立附件上传均 skipped。Android 首轮下载后以 SDK 36.1.0 `apksigner` 验证签名，证书 SHA256 与正式 v0.4.4 完全一致：`6ed2b419bc97670d3d7bbec361419bb325e71f89ed3087779776acfd6aa3e9db`；`aapt` 显示 0.4.5+39/min24/target36，但同时列出 arm64、armv7、x86_64，Rust 核心却只有 arm64。原因是 Flutter 3.35+ 自动预填 ABI，旧代码只追加 ARM64 而未清空默认集合（[官方迁移说明](https://docs.flutter.dev/release/breaking-changes/default-abi-filters-android)）。本轮清空后重设 ARM64，并在 CI 使用 `--target-platform android-arm64`；新增 APK ELF/CRC/ABI 完整性门禁，初版不得作为最终候选分发。

Android 修正版 `XDRemux-Android-ci-c33bd59.apk`，11,931,701 bytes；本地再次执行 `verify_apk.py`、`apksigner`、`aapt`：6 份 ARM64 ELF、CRC、正式证书指纹一致，0.4.5+39/min24/target36，只列 `arm64-v8a`。初版保留在 `target/preflight-045/rejected/android-pre-abi-fix/`，未删除，不能用于验收。

## 构建完成与候选留存

- [x] 六平台候选已下载/集中留存在忽略目录 `target/preflight-045/cloud/`：Windows Setup、Android APK、macOS DMG、iOS unsigned IPA、Linux AppImage/tar.gz/sha256、Flutter OHOS unsigned HAP。没有提交二进制。
- [x] 下载后的 iOS IPA 版本、设备 ARM64、Mach-O SDK 27.1/最低系统 15.0、ZIP CRC 通过；Linux 两个资产 SHA256 与校验文件一致，主程序/核心/引擎/libnuma 为 x64 ELF，无 JNI JVM 库。Windows installer ProductVersion 为 0.4.5。
- 文件大小与 SHA256、iOS/Linux 实包验证结果记录在 `target/preflight-045/cloud-verification.json`。OHOS 完整静态证据在 `target/oh045-1025/BUILD-REPORT.md`。本轮没有签名或安装 iOS/HAP，没有启动候选 app 或操作手机。
- [x] 准备改动已同步 main（代码/验证记录提交 `7484f018`）；其 [CI](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/40125969937) 与 [Conformance](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/40125969938) 全部通过，包含新增 SDK/APK 门禁测试。不创建 v0.4.5 标签，不发布或修改任何 GitHub Release；全平台构建/静态检查完成不等于下面的人工验收已通过。

Windows ARM64 不可交付，不计入六平台门禁；本次实验任务在 Flutter SDK setup 按预期失败。鸿蒙原生已由独立流程发布 `harmony-v0.5.2`（2026-10-25 本地时间），本轮未修改或重打原生包。云端预检产物可能使用 `ci-<sha>` 文件名，但应用内部版本必须是 0.4.5；正式发布才使用标签版本文件名。

## 人工验收（与构建成功分开记录）

- [ ] 各候选包安装/启动，检查 app/core 版本与来源提交；iOS 使用本机授权签名，OHOS 使用匹配的开发签名，不把 unsigned 当作免签。
- [ ] 两张 JPEG 原图（Issue #11 与 MIX Flip 2）分别验证 HDR 识别、ICC 色彩、Apple/OPPO 输出与水印画布；不上传私有样片。
- [ ] iOS/macOS 的 HDR 缩略图非黑、颜色和方向正常，Duo 侧栏、窗口尺寸/旋转/折叠布局不遮挡主操作。
- [ ] Live Photo 成对文件导出与 Apple Photos 配对、iOS PhotoKit 保存、Android 保存两份文件分别验证；OHOS 未接入的统一图库保存/配对分享仍明确列为限制。
- [ ] 收齐构建、签名说明、校验和和验收结果后，再由用户决定是否正式发布 v0.4.5。
