# XDRemux SwiftUI 0.1.1（预发布）

iOS / iPadOS / macOS 的原生 SwiftUI 版，和 Flutter 版共用同一个 Rust 内核（`0.4.7`）。
Bundle ID `io.github.beetman.xdremux.swiftui`，与 Flutter 版（`io.github.beetman.xdremux`）是两个独立的应用，
可以同时安装、互不覆盖。Flutter 版仍是 Apple 平台的正式版本，本版用独立标签 `apple-v0.1.1` 发布，不接管 Latest。

## 0.1.1 更新内容

- **队列内逐张独立转换设置**：在照片详情页修改输出模式（OPPO 兼容 / Apple 标准）、摄影风格 2 / 3、Apple 人像数据时仅作用于当前照片，不会覆盖全局默认设置或队列中其他照片；卡片右上角提供「恢复默认」按钮回到跟随全局设置，逐张选项随队列日志持久化，列表行摘要同步标记当前照片的独立设置。
- **普通照片与华为 HDR 单张放行**：当全局默认为「OPPO 兼容」时，普通照片（非 ProXDR 的 HEIC / JPEG）与被跳过策略拦截的华为原生 HDR 照片仍保留「转换选项」卡片，无需先修改全局设置，直接在单张详情里切为「Apple 标准 + 摄影风格」即可放行转换。
- **列表工具栏批量动作**：
  - **全部存入照片**（iOS）：在主列表工具栏菜单中一键将队列里已转换完成、尚未写入系统照片库的照片存入相册；当所有已完成项均已存入（例如开启了「转换完成后自动存入照片」）时，按钮文案显示为「已全部存入照片」（局域网传输收件箱同步支持该状态文案）。
  - **清除已完成**（iOS / macOS）：移出列表中已转换完成的照片并清理导入副本，输出文件保留；清理前弹窗确认张数（iOS 额外提示尚未存入系统照片库的张数）。

## 功能概览

### 转换

- 导入：macOS 拖放、打开文件 / 文件夹、Finder "打开方式"；iOS 系统照片选择器、"文件"、分享面板（Share Extension）。
- 详情优先：先看识别结果（ProXDR / Ultra HDR 类型、EXIF、HDR 信息），再按全局或单张决定转换选项；按住 "HDR" 按钮对比原图。
- OPPO 兼容与 Apple 标准两种输出，摄影风格 2 / 3、人像、动态照片 → Live Photo（HEIC + MOV 成对，可存为实况）。
- 普通照片（非 ProXDR 的 HEIC / JPEG，包括华为、iPhone 拍摄的）在 "Apple 标准 + 摄影风格" 下也可以转换，与 Flutter 版一致。
- 单张或批量转换，带进度、可取消；输出先写临时路径、校验通过才落盘，失败不留伪成功文件、不动原图。
- 支持的机型上走 VideoToolbox 硬件编码分块路径。
- iOS 可选 "转换完成后自动存入照片" 或手动 "全部存入照片"；导出到照片 / 分享 / 存储面板 / Finder；批量整理页。
- 设置与队列持久化；macOS 可与 Flutter 版互读检查点。
- 中 / 英双语，可在设置里切换。

### 局域网互传（LocalSend 协议）

- 与 Flutter 版、鸿蒙原生版和官方 LocalSend 互传照片 / 视频；发送页可选转换列表、系统照片（实况按原名发静帧 + MOV）或任意文件。
- 设备名默认为机型名，可修改；iPhone 上无多播授权时自动扫描网段，也可手动输入 IP:端口。
- 收件箱：预览、加入转换队列、存入照片（同名 `.mov` 或 `.pvt.zip` 还原为一张实况）。

## 安装

### macOS（Apple Silicon，macOS 14 起）

1. 下载 `XDRemux-Apple-macOS-0.1.1.dmg`，打开后把 `XDRemux.app` 拖入"应用程序"。
2. 本包只做了 ad-hoc 签名，没有 Developer ID 签名与公证。确认从本项目官方发布页下载后，在 **Mac 的"终端"** 执行以下命令再打开：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/XDRemux.app"
```

命令只清除这个 App 的下载隔离标记，不需要全局关闭 Gatekeeper 或 SIP；装到其他目录请改成实际路径。
也可以在尝试打开后，到"系统设置 → 隐私与安全性"点"仍要打开"。应用运行在沙盒里，照片、文件夹访问按系统提示授权。
只有 Apple Silicon 包，不支持 Intel Mac。

### iOS / iPadOS（iOS 17 起，需签名侧载）

下载 `XDRemux-Apple-iOS-0.1.1-unsigned.ipa`。这是**未签名 IPA**，不能在"文件"App 里直接安装，也不是 App Store / TestFlight 包。
请用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名后安装，并按工具要求完成开发者模式或证书信任设置；
有效期、设备范围和刷新要求由所用账号、证书与工具决定。

- 使用相册导入或存入照片时需要允许照片权限，局域网互传需要"本地网络"权限。
- 分享面板里的 "XDRemux" 入口依赖 App Group `group.io.github.beetman.xdremux.swiftui`：签名时如果工具没有给主应用和扩展签上同一个 App Group，这个入口会不可用，其余功能不受影响。
- `SHA256SUMS.txt` 可用于校验下载文件。

## 验证范围

- 内核与传输库与 `0.4.7` 一致（见发布页附带的 `BUILD_RECORD.txt`）；Swift 包单元测试（58 项模型测试，含逐张选项覆盖与队列日志往返）通过。
- macOS（Apple Silicon）与 iPhone Duo 模拟器：逐张转换选项独立覆盖与「恢复默认」、普通照片 / 华为 HDR 单张开启摄影风格放行、「全部存入照片 / 已全部存入照片」与「清除已完成」确认弹窗验证通过。
- 延续 `0.1.0` 在 iPhone 16e 与 iPad mini（A17 Pro）真机上的相册导入、转换、自动存入照片、横竖屏两栏布局与分享面板验证基线。

## 已知限制 / 未验证

- 未签名、未公证；没有 TestFlight 或 App Store 分发。
- 真机自动发现（无多播授权，走网段扫描）尚未在本版安装包上验证；侧载工具重签后的 Share Extension 取决于它是否签上 App Group。
- 没有应用内更新检查；新版本请看本项目 Releases。
