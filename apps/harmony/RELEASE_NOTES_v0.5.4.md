# XDRemux 鸿蒙原生版 0.5.4

同步主线 `ce35efd`，共享 Rust 内核升至 `0.4.7`（与 Flutter v0.4.7 相同）。原生 App 为 `0.5.4` / code `50400`；Flutter 版与原生版独立发布。

## 更新内容

### 局域网互传（LocalSend）

- 底部新增「互传」页（图库 / 队列 / 互传 / 设置）：同一 Wi-Fi 下的手机和电脑之间直接收发照片和视频，不经过云端。协议兼容 LocalSend，可以和官方 LocalSend 应用、XDRemux Flutter 版互传。
- 分为「发送」和「接收」两页，样式与队列页一致。
- 发送：在设备列表里点一下即可发送；可以「选择照片」从相册挑选，也可以在队列详情里点「发送到其他设备」直接带上转换结果。找不到设备时会自动扫描同一网段，仍然找不到时可以手动输入对方 IP。
- 接收：在接收页手动打开「可被发现」，每次有人发来文件都需要你点「接收全部」或「拒绝」。接收开启后可以切到其他页面继续接收，应用切到后台会停止。有待确认的文件时，底部「互传」会显示数量。
- 本机默认以机型命名（如「HUAWEI Pura X View」），可以修改；「对方找不到本机？」会列出本机地址。
- 收件箱：
  - 收到的照片显示预览。
  - 同名的照片 + `.mov`（iPhone LocalSend 发来的实况）和 `.pvt.zip` 显示为一张实况照片。
  - 右侧「+」把照片加入转换队列（同时存入本地图库作为原图），也可以「全部加入队列」。
  - 点按卡片可以「存入图库」「存入相册」（实况照片存为照片 + 视频）「分享」「删除」；收件箱可以清空（清空前会确认）。
- 发送实况照片配对时，HEIC 与 MOV 一起发出，并使用原照片的文件名。
- 传输过程中屏幕保持常亮。

### Live Photo

- 修复开启「摄影风格」时，部分实况照片（如 OPPO Find X8 Ultra 普通拍照的 UHDR 实况）生成 Live Photo 配对失败、提示「Live Photo pair is missing or invalid」的问题（内核 0.4.6 中存在）。

### 开源许可

- 本项目自 v0.4.6 起按 GPL-3.0-only 授权，历史版本另行补充授权，详见仓库中的 `LICENSING.md`。
- 设置中新增「开源许可」，可查看 XDRemux（GPL-3.0-only）、x265（GPL-2.0-or-later）和 LocalSend（Apache-2.0）的许可全文及源代码地址。

## 安装与升级

- 下载 `XDRemux-HarmonyOS-Native-0.5.4-unsigned.hap`。本包是开发自签用 **Debug unsigned HAP**（`app.debug:true`），Rust 核心保持 Release 优化。
- 应用名 **XDRemux**，包名 `io.github.beetman.xdremux.arkui`，ARM64，版本 `0.5.4` / code `50400`。请使用匹配包名、证书和目标设备的开发 Profile 自签；不是免签安装包或应用市场上架包。
- 现有 `.arkui` 用户使用相同签名可覆盖升级并保留数据；Flutter 和早期 `.native` 版是独立应用身份。
- 本版本新增网络权限 `ohos.permission.INTERNET` 和 `ohos.permission.GET_NETWORK_INFO`，仅用于局域网互传；接收只在你手动开启后才监听局域网端口。
- 以 HarmonyOS 7 / API 26 为开发基准，清单最低兼容 API 18；旧系统仍需按设备验证。
- 附件 `SHA256SUMS.txt` 可用于校验下载文件。

## 验证与使用范围

- Rust 内核回归 305 项通过（3 项忽略）；19 份鸿蒙模型/队列/互传测试、5 项 HAP verifier 测试及 C++ PS3 辅助回归通过。
- HAP 身份/版本/API、Debug 标记、ZIP CRC 和无 HAP Signing Block 检查通过；内核版本 `0.4.7`，桥接层所需的转换与互传接口全部可解析。
- 真机（HUAWEI Pura X View，HarmonyOS 7.0.0.111）与 macOS 上的 LocalSend 1.18.2 互通：设备发现、接收（含实况照片分组与预览）、加入转换队列、从队列发送、手动输入 IP 连接均已验证。
- **尚未在真机验证**：「存入相册」、分享、选择照片发送，以及靠网段扫描发现设备；与 iPhone / Android 上 LocalSend 的直接互传。
- 转换保持前台运行；人像、摄影风格、Live Photo 与局域网互传仍含实验能力。未启用可选 libheif 解码器。

原生版本使用独立标签 `harmony-v0.5.4`，不接管 Flutter 版的 Latest 下载入口。
