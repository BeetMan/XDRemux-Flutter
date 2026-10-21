# v0.4.4 — Live Photo 完整导出与 macOS 打包修复

## 新功能

- **iOS 应用内直接保存 Live Photo**：转换完成后可从 app 内保存，PhotoKit 以同一事务写入 `.photo` + `.pairedVideo`，在「照片」中是一个可播放、有声音的实况照片，而不是两张普通文件。单项与批量的保存结果一致。
- **OPPO 前置摄像头人像**：支持从 OPPO 前摄原图的深度信息生成 Apple 人像结构（此前仅支持后摄/华为样片）。
- **编解码诊断**：新增 codec 能力与失败诊断面板，可查看当前平台的解码能力、失败原因分类，并复制/导出诊断信息。
- **主图预览**：预览改用 Rust 侧解码，颜色与方向与导出结果一致（含 HDR 主图）。

## 修复与可靠性

- **macOS 打包修复**：Rust 核心 dylib 改由 Xcode 的 `Bundle Framework` 拷贝阶段随构建产出，签名封印包含该 dylib；此前是构建后手工拷入，会把 app 的代码签名封印弄坏。CI 改为断言 dylib 存在且 `codesign -v --deep --strict` 通过，不再静默补拷。
- **Live Photo 导出完整性**：合成后在临时目录校验配对（同名 MOV 与静帧匹配）、复制后再次校验，校验失败不报成功；重试与 checkpoint 恢复同样按配对校验，配对缺失时明确标为失败。
- **OPPO 分类标记**：接受用户注释中的 bit 33。带该位的原图此前被判为「未知标记、不可分类」，输出会落到默认目录；现在正常识别为「普通拍照」并进入对应拍摄模式目录。
- **JPEG HDR 元数据、Apple MakerNote 保留**：转换后保留可继续编辑所需的 MakerNote 字段。
- 修复缩略图缓存/队列测试依赖 Windows 原生通道的问题（只影响测试宿主，产品路径不变）。
- macOS / Linux 上 `flutter test` 现在能真正加载打包的 Rust 核心（此前 macOS 上 3 项 FFI 冒烟测试因裸文件名加载失败，Linux 上则因断言恒真而未暴露问题）。

## 工具链

- 升级到 Flutter 3.47.7 / Dart 3.13.5（`.fvmrc` 与全部 CI/发布工作流同步固定）。
- 依赖改为提交锁文件 + `--enforce-lockfile` 安装，发布构建不再意外重新解析插件版本。

## 使用说明与边界

- **macOS 包仅支持 Apple Silicon（M 系列）**：包内 Rust 核心目前只有 arm64 切片（app 主体虽是 universal），Intel Mac 上可以启动，但转换会因核心无法加载而失败。请 Apple Silicon 用户使用本包；Intel Mac 用户请保留 0.4.3 或等待后续版本。这一限制在 0.4.3 同样存在，不是本版引入的。
- **macOS 包未签名、未公证**：从 GitHub 下载的 DMG 首次打开会被 Gatekeeper 拦截，请在「系统设置 → 隐私与安全性」中允许，或右键点击 app 选择「打开」。本次已保证 app 的签名封印有效，因此不会再出现「已损坏」提示；但要让 macOS 完全放行仍需 Apple 开发者账号的 Developer ID 与公证，本轮未做。
- **iOS 包未签名 IPA**：需要用侧载工具（AltStore / Sideloadly / 自签）安装；免费个人团队的描述文件 7 天有效。安装后首次打开需在「设置 → 通用 → VPN 与设备管理」信任。
- **Windows ARM64 安装器为实验性**：该 job 失败不会阻塞发布，因此部分版本可能不提供 ARM64 安装器；请优先使用 x64 安装器（ARM64 机器可通过 x64 模拟运行）。
- **可选的 libheif 解码**：默认不启用，发布包使用内置默认解码路径；只有本地构建显式开启该 feature 才会启用。
- **HarmonyOS**：Flutter 版 HAP 不在 CI 中构建，作为资产手工附加；Flutter OHOS 的多文件分享（配对 HEIF + MOV 两个附件）尚未实现，成对导出请使用原生应用。原生 0.5.1 与本次 Flutter 源码不同步，不作为已验收版本。
- 转换不会移动或删除原图；输出写到设定目录下的拍摄模式子目录。

## 升级提示

- 本版为正式版本（非预览版），所有 0.4.3 客户端会收到更新提示。
- 升级后版本号变为 `0.4.4+38`；Android 使用同一发布证书，可直接覆盖安装（会重启并可能丢失尚未开始转换的内存队列）。
- 若此前用 0.4.3 转换过带未知标记位的 OPPO 原图，升级后重新转换会输出到拍摄模式子目录，可能出现与旧输出不同目录下的重复文件，请按需清理或开启「跳过已有有效输出」。

## 本轮验证记录

- Rust：`cargo test --release -p xdremux-core` 246 passed / 5 ignored；可选 libheif 核心单独回归通过。
- Flutter：macOS 上 `flutter test` 139 passed / 2 skipped / 0 failed；`flutter analyze` 无问题；`pub get --enforce-lockfile` 通过。
- macOS：release 构建 61.3MB，`Contents/Frameworks/libxdremux_core.dylib` 存在、`codesign -v --deep --strict` 通过（sealed files 30），应用启动后实际映射该 dylib，`xdremux_version()` 返回 `0.4.4`。
- iOS：release 归档成功，37/37 个 Dart 侧运行时 FFI 符号在 dead_strip 后仍导出；实机转换两对 HEIF/MOV 配对标识逐对一致，用户确认保存到相册后为可播放、有声音的 Live Photo。
- Android：Flutter 3.47.7 候选包用户验收通过（同签名覆盖安装）。
- Windows：包内 FFI 回归（转换、Styles 图结构、PNG 主图预览、原图哈希）与 37 个 manifest 文件哈希校验通过，**尚无本轮人工验收**。
- 鸿蒙：Profile/AOT 未签名 HAP 构建通过，签名覆盖安装后启动 smoke 通过；完整功能未验收。

未覆盖、不据此宣称通过：macOS 端完整 UI 流程（多选 / 中文路径 / 拖放、摄影风格、人像、批量取消与重试、Photos 导入与投送）、iPhone 相册权限拒绝后重试与批量/自动保存、Windows 人工验收、鸿蒙完整功能。

## 2026-10-22 补充：Flutter OHOS 0.4.4

- 已追加资产 `XDRemux-HarmonyOS-0.4.4-unsigned.hap`，37,359,949 bytes；发布标签 `v0.4.4` / 源码 `6c34ed42`，应用 `0.4.4+38`，包名 `io.github.beetman.xdremux`，ARM64，最低 API 18、目标 API 26。
- 使用独立 OHOS Flutter SDK（框架提交 `62357a93`、Dart 3.11.5）及启动修复后的平台内核缓存。Profile/AOT、清单 `debug: true`、未签名，可用匹配设备的 Development Profile 自签；不是官方 Flutter 3.47.7 构建的鸿蒙包。
- 重新编译该标签的 Rust 核心，未启用可选 libheif。37 个 Dart FFI 符号、包身份/版本、ARM64 AOT/引擎/核心/运行库、ZIP CRC 与无签名块检查通过；本轮未重新安装或进行转换/图库实机验收。
- **Flutter OHOS 统一相册保存入口目前未接入（普通静图也受影响），HEIF/MOV 双文件分享尚未实现**。转换生成文件不等于已保存到系统相册；成对文档导出请用独立的鸿蒙原生 0.5.1。
- SHA256 `e33fcf692c3b7810579a065e2b627e4bb5ae16ea93697e3ee32037ca60bfbe96`，附 `SHA256SUMS-HarmonyOS-0.4.4.txt`；GitHub 服务器摘要已回读核对。发布页保留现有正文，追加构建与限制说明，不移动标签或修改其他平台资产。
