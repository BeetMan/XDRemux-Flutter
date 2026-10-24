# XDRemux 鸿蒙原生版 0.5.2

同步主线 `ebabc301` 的共享 Rust `0.4.5` 核心。原生 App 为 `0.5.2` / code `50200`；Flutter 当前正式版本仍为 `0.4.4`，两端独立发布。

## 更新内容

- 修复部分 JPEG HDR 的 ISO 元数据版本不支持时无法转换的问题：仅在同一增益图具有有效 Adobe HDR XMP 时回退，不放宽损坏数据校验。
- HDR JPEG 与普通 JPEG 摄影风格源重建时保留原始 RGB ICC 色彩配置，避免直接丢弃 P3 等源配置；不支持的 profile 明确报错。
- 保留原生 Apple 摄影风格/人像识别，以及照片读取中返回后释放图库忙碌状态的修复。
- Flutter 双栏界面、Linux 桌面、iOS 模拟器及缩略图修改只同步源码，不作为 ArkUI 新功能。

## 安装与升级

- 下载 `XDRemux-HarmonyOS-Native-0.5.2-unsigned.hap`。本包是开发自签用 **Debug unsigned HAP**（`app.debug:true`），Rust 核心保持 Release 优化。
- 应用名 **XDRemux**，包名 `io.github.beetman.xdremux.arkui`，ARM64，版本 `0.5.2` / code `50200`。请使用匹配包名、证书和目标设备的开发 Profile 自签；不是免签安装包或应用市场上架包。
- 现有 `.arkui` 用户使用相同签名可覆盖升级并保留数据；Flutter 和早期 `.native` 版是独立应用身份。
- 以 HarmonyOS 7 / API 26 为开发基准，清单最低兼容 API 18；旧系统仍需按设备验证。
- 附件 `SHA256SUMS.txt` 可用于校验下载文件。

## 验证与使用范围

- Rust workspace 回归通过；另用静态 x265 跑过 238 项核心测试，两张真实 JPEG 的 Apple 标准/OPPO 兼容输出回归通过，覆盖 HDR 增益图、ICC/水印画布和原图完整性。
- 16 份鸿蒙模型/队列测试、5 项 HAP verifier 测试及 C++ PS3 辅助回归通过。HAP 身份/版本/API、CRC、图标、Debug 标记和无 HAP Signing Block 检查通过；FFI 实读核心 `0.4.5`，24 个 OHOS 桥接符号齐全。
- 本版本尚未做新一轮设备安装、目标图库/HDR 显示、摄影风格或人像编辑验收。主机文件级回归不替代真机显示与编辑效果验收。
- 转换保持前台运行；人像、摄影风格与 Live Photo 仍含实验能力。Live Photo 通过队列成对导出 HEIC + MOV，需一起传输和导入。未启用可选 libheif 解码器。

原生版本使用独立标签 `harmony-v0.5.2`，不接管 Flutter 版的 Latest 下载入口。
