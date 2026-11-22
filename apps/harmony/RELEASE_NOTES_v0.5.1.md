# XDRemux 鸿蒙原生版 0.5.1

本版同步 Flutter 0.4.4 的共享 Rust 核心，保留鸿蒙原生的图库、队列、设置和照片浏览交互。

## 更新内容

- 支持符合条件的 OPPO 前置人像 HEIC 生成 Apple 人像数据。
- 修复 OPPO 拍摄分类对 bit 33 的识别，避免部分原图被误判为未知标记。
- 同步华为动态人像的静帧隔离、Live Photo 输出安全、JPEG HDR 元数据与色彩空间、Apple MakerNote 保留等核心修复。
- 修复照片尚在读取时返回，遗留忙碌状态导致图库后续点击无效的问题。

## 安装与升级

- 下载本页 `XDRemux-HarmonyOS-Native-0.5.1-unsigned.hap`。当前附件为 Debug / `debug:true` 未签名包，Rust 核心保持 Release 优化；请使用匹配原生包名、证书与目标设备的开发 Profile 自签后安装，不是免签安装包或应用市场上架包。
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

## 2026-10-22 开发自签包替换（当前附件）

- 按用户要求直接替换同名 HAP，不另开版本、不移动 `harmony-v0.5.1` 标签；继续使用该标签 `67ff09cd` 的业务源码、`.arkui` 身份和 `0.5.1` / code `50100`。
- 使用 `devecocli build --product default --build-mode debug`，包内确认 `app.debug:true`、`app.buildMode:debug`。Rust 核心继续使用 Release 优化，包内 SHA256 `3caa2d3b3c3f56537bb2c4382787b781ef9e17011aeff5e5627f0838e3b4a8ec` 与先前 Release HAP 完全一致。
- 当前 HAP 为 6,811,477 bytes，SHA256 `61e2f0b5667b2b668e1ae3772aae9825ede62e3a2dc4d05ef1940b4621856bbc`，对应 `SHA256SUMS.txt` 一并更新；之前 Release HAP 已本地备份。重新下载后的 HAP、校验文件、GitHub 服务器摘要与发布正文均核对通过。
- DevEco Debug 完整编译、身份/版本/API/核心一致性、ZIP CRC、无 HAP Signing Block、16 组模型/队列测试与 5 项 HAP 校验器测试通过。本轮未进行实际自签安装或照片转换验收，不声称所有自签工具已测试。
- 此节替代下方历史记录中的 Release/`debug:false` 安装要求。开发签名仍受证书、包名、设备范围和有效期约束；未上传本机签名材料。

## 2026-10-22 重新编译补充（历史，已被上方 Debug 包替换）

- 从同一发布标签 `harmony-v0.5.1` / `67ff09cd` 重新构建，仍为 `.arkui`、`0.5.1` / code `50100`、ARM64、最低 API 18、目标 API 26，不移动标签或改变业务源码。
- 单独重新编译该标签的 Rust `0.4.4` 核心，不混用 Flutter 标签核心；包内核心 SHA256 `3caa2d3b3c3f56537bb2c4382787b781ef9e17011aeff5e5627f0838e3b4a8ec` 与上一份已上传包一致。桥接库、资源清单来自本次干净构建。
- DevEco release 构建、全部 24 个桥接符号、身份/版本/API、ZIP CRC 与无签名块校验通过；16 组模型/队列测试与 5 项 HAP 校验器测试再次通过。独立快速 ArkTS 检查对 `@Available` 报错，实际编译通过，不将快速检查记为通过。
- 已重新上传 `XDRemux-HarmonyOS-Native-0.5.1-unsigned.hap`，5,903,559 bytes，SHA256 `0df31311f3eec6d743bbbf51007d63af34fcd863bd2a4835b7512d5aa31e8648`，同步 `SHA256SUMS.txt`，GitHub 服务器摘要匹配；旧发布资产已下载留存。
- **此包为 Release / `debug:false`，需要匹配的发布证书和发布 Profile，不能直接用 Development Profile 签名**。只有开发签名时请从源码构建 debug 包；这与 Flutter OHOS 的 Profile/`debug:true` 包不同。未上传本机证书、Profile 或密钥，未进行新一轮安装和照片实机验收。
