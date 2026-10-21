# XDRemux 鸿蒙原生版 0.5.1

本版同步 Flutter 0.4.4 的共享 Rust 核心，保留鸿蒙原生的图库、队列、设置和照片浏览交互。

## 更新内容

- 支持符合条件的 OPPO 前置人像 HEIC 生成 Apple 人像数据。
- 修复 OPPO 拍摄分类对 bit 33 的识别，避免部分原图被误判为未知标记。
- 同步华为动态人像的静帧隔离、Live Photo 输出安全、JPEG HDR 元数据与色彩空间、Apple MakerNote 保留等核心修复。
- 修复照片尚在读取时返回，遗留忙碌状态导致图库后续点击无效的问题。

## 安装与升级

- 下载本页 `XDRemux-HarmonyOS-Native-0.5.1-unsigned.hap`。发布包未签名，请用 DevEco Studio 完成本地签名后安装。
- 应用名 **XDRemux**，包名 `io.github.beetman.xdremux.arkui`，版本 `0.5.1` / code `50100`，ARM64。
- 现有 `.arkui` 用户使用相同签名可覆盖升级并保留数据；Flutter 版和早期 `.native` 版是独立应用身份。
- 以 HarmonyOS 7 / API 26 为开发基准；清单最低兼容 API 18，旧系统适配仍需按设备验证。

## 功能范围

- 图库原图保存在应用私有沙箱；导入资源先物理复制，再交给 Rust 读取。
- Live Photo 通过队列导出配对 HEIC + MOV，需要一起传输并导入目标相册；单张文件分享不自动成为系统 Live Photo。
- 转换保持前台运行。摄影风格、人像和 Live Photo 包含实验性实现，实际编辑能力取决于源照片和目标系统。
- 本版未启用可选 libheif 解码器，也不包含 Flutter 的 iOS PhotoKit 保存或编解码诊断界面。

本版本采用独立发布标签 `harmony-v0.5.1`，Flutter 跨平台版对应 `v0.4.4`。

## 本轮验证

- Rust workspace 回归通过，核心单元测试 226 passed / 3 ignored；主机测试使用既有 FFmpeg 编码 fallback。
- 6 项显式启用的华为私有样片回归通过；16 份鸿蒙模型/队列测试、5 项 HAP 校验器测试和 C++ PS3 辅助回归通过。
- FFI 版本读取为 `0.4.4`，bit 33 分类冒烟通过，OHOS 核心保留全部 24 个原生桥接符号，并按对应 free 函数释放主机冒烟中的 Rust 分配。
- `devecocli` Release 构建、unsigned HAP 身份/API/核心库校验与归档 CRC 检查通过；发布页附 `SHA256SUMS.txt`。
- 本次未连接调试设备，未做 0.5.1 的新一轮安装和 Apple Photos 真机验收。此前已验证原生界面基础流程与图库返回修复；构建及结构校验不替代目标相册的实际编辑验收。
