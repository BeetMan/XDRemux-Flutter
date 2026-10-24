# 鸿蒙原生 0.5.2 开发构建（尚未发布）

- 同步主线 `ebabc301`，Rust 核心为尚未发布的 `0.4.5`；原生 App 为 `0.5.2` / code `50200`。
- 接入 JPEG HDR 的 ISO 版本回退修复与 RGB ICC 保留，保留原生 Apple 风格/人像识别及图库返回状态修复。
- Flutter 双栏布局、Linux 桌面、iOS 模拟器及缩略图修复仅同步源码，不作为 ArkUI 新功能。
- `.arkui` 包身份及队列/设置 schema 不变。生成的是 Debug unsigned HAP，Rust 核心保持 Release 优化；需使用匹配包名、证书与目标设备的开发 Profile 自签。
- 已通过 Rust workspace 回归、静态 x265 的 238 项核心测试、两张真实 JPEG 的两种输出模式回归、16 份鸿蒙 Node 测试、5 项 verifier 测试与 C++ PS3 辅助回归。
- HAP 身份/版本/API、CRC、图标、Debug 标记和无 HAP Signing Block 检查通过；FFI 核心版本 `0.4.5`、分类冒烟及 24 个 OHOS 桥接符号检查通过。
- 本次未安装到设备或验收目标图库/HDR/摄影风格/人像效果。未创建标签、未发布或替换任何 GitHub Release 资产；公开原生版仍为 `harmony-v0.5.1`。
