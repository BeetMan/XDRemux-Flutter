# v0.4.8 — VideoToolbox 硬件编码、规范 HDR 写入与人像/实况加固

## HDR 与摄影风格

- **统一写入规范 `tmap`**：移除旧「严格 ISO tmap」选项，所有输出统一采用符合 ISO 21496-1 的 `62/142` 字节 `tmap`，消除开启旧开关时在标志字节后插入零字节导致的错位与第三方相册兼容性问题。旧配置文件与队列记录中保留的字段仍可正常读取。
- **为已转换照片继续追加摄影风格**：已转为 ISO HDR HEIC 或已写入「摄影风格 2」的照片，再次叠加「摄影风格 2 / 3」时不再丢失原有 HDR 增益图。
- **大图风格修复**：较大主图生成摄影风格 delta map 时按约 5/7 主图尺寸计算，不再封顶 2880×2560，修复在 Apple「照片」中编辑风格后出现绿色网格的问题。
- **鸿蒙增益图编码**：鸿蒙平台在所有输出模式下的三通道增益图统一采用 4:2:0 编码。

## 人像与动态照片

- **OPPO / ColorOS 17.24 人像与大师水印**：修复 17.24 人像的横屏帧布局、前置镜像与深度方向读取，新增根据尾部记录的画面矩形还原整圈大师水印边框，并修复部分人像样张转换时校验失败的问题；拆分出的动态照片 MP4 视频同步裁剪厂商尾部字节。
- **Live Photo 发布安全**：Live Photo 输出改走事务式发布（写临时隐藏文件、校验配对后再原子替换，失败自动回滚并保留错误信息），并修复 macOS 临时目录尚未创建时合成实况失败、以及无后缀输出误删同名原图的问题。
- **Apple 实况摄影风格**：在 Apple 平台上开启「实况 + 摄影风格」时，伴随轨道的线性缩略图和色调曲线改为逐视频帧生成，并加固视频时间范围与取消逻辑。

## 硬件编码与性能

- **macOS / iOS 接入核心 VideoToolbox**：Flutter macOS 与 iOS 的「GPU 硬件编码」开关现由 Rust 核心内的 VideoToolbox 后端驱动，支持与「摄影风格」等功能同时开启，批内遇到硬件编码异常时自动回退软件编码完成任务；Android 继续使用 MediaCodec 分块路径，Windows / Linux 使用 x265。
- **界面流畅度**：将导入照片探测与批量整理扫描移出 UI 主线程，减轻 Android 多选导入和目录整理时的卡顿。

## 应用图标、共存与安装包

- **应用图标与多端更名共存**：全平台更换为增益图设计的新图标；Flutter 的 **macOS（`XDRemux Flutter.app`）、iOS 与鸿蒙**桌面显示名统一改为 **`XDRemux Flutter`**（保留既有包名 `io.github.beetman.xdremux` / `com.example.xdremux` 与升级数据兼容），可与同机安装的 SwiftUI 原生版 / 鸿蒙原生版 **`XDRemux`** 直观区分。
- **macOS 安装窗**：DMG 改为带浅色网格背景与 `/Applications` 拖拽指引的安装窗口，未公证包底部附带开源许可与「隐私与安全性」直达快捷入口（`.inetloc`）。
- **开源许可**：继续遵循 GPL-3.0-only 授权，各平台安装包随附 `LICENSE` 与 `LICENSING.md`。

## 安装说明

### macOS（Apple Silicon）

1. 下载 `XDRemux-macOS-0.4.8.dmg`，打开后将 `XDRemux Flutter.app` 拖入「应用程序」（`v0.4.7` 及更早版本为 `XDRemux.app`；新版应用可与原生 SwiftUI 版 `XDRemux.app` 共存）。
2. 本包未做 Developer ID 签名与公证。确认从本项目官方发布页下载后，可双击安装包底部的「打开隐私与安全性 (Privacy & Security)」快捷入口点「仍要打开」，或在 **Mac 的「终端」** 执行以下授权命令后再打开应用：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/XDRemux Flutter.app"
```

按提示输入 Mac 登录密码（输入时终端不会显示字符）。命令只清除这个 App 的下载隔离标记，不需要全局关闭 Gatekeeper 或 SIP；如果安装到其他目录，请将路径改成实际的 `XDRemux Flutter.app` 路径。若仍提示文件损坏，请先重新下载，不要反复降低系统安全设置。当前 DMG 仅支持 Apple Silicon，不支持 Intel Mac 转换。

### iOS（需签名侧载）

下载 `XDRemux-iOS-0.4.8-unsigned.ipa`。这是**未签名 IPA**，不能在「文件」App 中直接点开安装，也不是 App Store / TestFlight 安装包。自本版起桌面显示名为 **`XDRemux Flutter`**（包名保持 `io.github.beetman.xdremux`，可直接覆盖旧版 Flutter 安装并保留数据，同时可与原生 SwiftUI 版 `XDRemux` 同机区分）。

请使用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名并安装；按所用方式完成系统要求的开发者模式或证书信任设置。签名有效期、设备范围和刷新要求由所用账号、证书及工具决定，过期后需重新签名或刷新。最低系统为 iOS 15，Duo 新功能需相应新系统；使用相册导入或保存时仍需单独允许照片权限，使用局域网互传时需允许「本地网络」权限。

### HarmonyOS（需开发签名侧载）

- **Flutter 版 0.4.8**：`XDRemux-HarmonyOS-0.4.8-unsigned.hap`，桌面显示名为 **`XDRemux Flutter`**，包名 `io.github.beetman.xdremux`；profile AOT 包，保留开发签名所需的 `debug:true`。
- **原生版 0.5.5**：同步使用 `0.4.8` 核心发布，桌面显示名为 **`XDRemux`**，包名 `io.github.beetman.xdremux.arkui`。安装包与说明见 [鸿蒙原生版 0.5.5 发布页](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.5)。

两版可共存，应用身份和签名配置不同，不能直接互换。Flutter 版 HAP 是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与包名、开发证书和目标设备范围匹配的 Development Profile，完成签名后再安装。覆盖升级时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。
