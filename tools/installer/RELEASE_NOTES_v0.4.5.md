# v0.4.5 — JPEG 色彩修复、iPhone Duo 适配与 Linux 预览

## iPhone Duo 与 Apple 平台

- 适配 iPhone Duo 的 trailing vertical bar，将工具按钮放入系统预留的侧边区域；宽屏/双屏布局优化主操作位置，队列较长时仍能方便地开始转换。
- 修复部分 HDR HEIC 在 iOS 上显示为黑色缩略图的问题：原生缩略图经过明确的 8-bit sRGB 上下文后再编码，异常黑图交给 Rust 预览回退，只影响界面预览。
- iOS 发包使用 Xcode 27.1 / iOS 27.1 SDK.
- Duo 适配包含已接入的侧栏和主操作布局，UIHinge 驱动的折叠态专用布局尚未接入。

| 合上 · 空队列 | 合上 · 队列 ≥ 4（主操作浮动） |
|---|---|
| ![合上竖屏](https://raw.githubusercontent.com/BeetMan/XDRemux-Flutter/main/screenshots/duo-folded.png) | ![合上竖屏，队列较长时主操作浮动](https://raw.githubusercontent.com/BeetMan/XDRemux-Flutter/main/screenshots/duo-folded-queue.png) |

| 展开 · 竖屏（669×951） | 展开 · 横屏（951×669） |
|---|---|
| ![展开竖屏](https://raw.githubusercontent.com/BeetMan/XDRemux-Flutter/main/screenshots/duo-unfolded-portrait.png) | ![展开横屏](https://raw.githubusercontent.com/BeetMan/XDRemux-Flutter/main/screenshots/duo-unfolded-landscape.png) |

采集于 iOS 27.1 模拟器；真机折叠/展开姿态与图库导出仍需发布前补验。

## JPEG 色彩配置保留

- 修复带 P3、sRGB 等 RGB ICC 的 JPEG 转 HEIC 时丢失源色彩配置的问题。HDR JPEG 与现有普通 JPEG 摄影风格源重建路径均保留原始 RGB ICC，不先压到 sRGB，也不按相机名或 profile 描述猜色域。
- ICC 写入 HEIC 主图及主图瓦片的 `colr/prof`；配套 `nclx` 与主图 HEVC VUI 明确使用实际编码的 BT.709 YCbCr 矩阵及全范围，不再同时声称源像素是 BT.709 色域/传递函数。原编码质量与增益图处理方式不变，无 ICC 的输入保留既有行为。
- 校验 ICC 分段序号、缺段、重复、大小、头部及 tag 范围。当前直接保留 RGB ICC v2/v4；CMYK/灰阶 ICC 或不支持的 profile 明确报错，不把未经色彩管理转换的像素套上错误配置。

## JPEG HDR 兼容性（Issue #11）

- 修复部分小米 / 红米 Ultra HDR JPG 在 0.4.4 中被误显示为 SDR、无法转换的问题：照片包含当前不支持版本的 ISO 元数据时，允许使用同一增益图对应的有效 Adobe HDR XMP，继续生成 HDR HEIC。
- 回退仅针对 ISO 版本不支持，不放宽数据截断、重复 ISO 段、非法数值等校验；Adobe 回退也必须通过命名空间、版本、数值、范围与 SDR 底图检查。无法可靠解析时仍明确失败，不静默丢掉 HDR。
- Flutter 照片详情新增“HDR 解析失败”与原因，信息复制中一并保留错误；不会把解析失败当作“无（SDR）”。EXIF 可继续显示。
- 使用 Issue #11 原始 JPEG 验证 Apple 标准与 OPPO 兼容两种输出，均通过 HDR 增益图结构检查，亮度倍率约 2.18×，原图哈希不变。

## Linux 桌面预览

- 新增 GTK 桌面目标、拖放 / 命令行导入、Rust FFI、AppImage/tar.gz 打包和用户级安装。移除 Linux 不使用的托盘/JNI 插件，系统托盘和完成通知暂未接入。
- 修正 Cargo 库查找路径及安装路径特殊字符转义；Ubuntu libnuma 通过 HTTPS 下载并校验包和缓存 SHA256，x265 缓存与较新发行版隔离。
- Ubuntu 22.04 构建和打包通过，核心最高 GLIBC 需求为 2.35；Linux 仍按预览支持发布，不代表所有发行版已完整验收。

## 安装说明

### macOS（Apple Silicon）

1. 下载 `XDRemux-macOS-0.4.5.dmg`，打开后将 `XDRemux.app` 拖入「应用程序」。
2. 本包未做 Developer ID 签名与公证。确认从本项目官方发布页下载后，在 **Mac 的「终端」** 执行以下授权命令，再打开应用：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/XDRemux.app"
```

按提示输入 Mac 登录密码（输入时终端不会显示字符）。命令只清除这个 App 的下载隔离标记，不需要全局关闭 Gatekeeper 或 SIP；如果安装到其他目录，请将路径改成实际的 `XDRemux.app` 路径。若仍提示文件损坏，请先重新下载，不要反复降低系统安全设置。

也可在尝试打开后，到「系统设置 → 隐私与安全性」点击「仍要打开」。照片、文件等访问权限与上述启动授权不同，使用对应功能时再按系统提示授予。当前 DMG 仅支持 Apple Silicon，不支持 Intel Mac 转换。

### iOS（需签名侧载）

下载 `XDRemux-iOS-0.4.5-unsigned.ipa`。这是**未签名 IPA**，不能在「文件」App 中直接点开安装，也不是 App Store / TestFlight 安装包。

请使用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名并安装；按所用方式完成系统要求的开发者模式或证书信任设置。签名有效期、设备范围和刷新要求由所用账号、证书及工具决定，过期后需重新签名或刷新。最低系统为 iOS 15，Duo 新功能需相应新系统；使用相册导入或保存时仍需单独允许照片权限。

### HarmonyOS（两种 HAP 均需开发签名侧载）

本发布页同时提供：

- **原生版 0.5.2**：`XDRemux-HarmonyOS-Native-0.5.2-unsigned.hap`，ArkUI 原生界面，包名 `io.github.beetman.xdremux.arkui`；Debug 包，Rust 核心保持 Release 优化。
- **Flutter 版 0.4.5**：`XDRemux-HarmonyOS-0.4.5-unsigned.hap`，包名 `io.github.beetman.xdremux`；profile AOT 包，保留开发签名所需的 `debug:true`。

两份都是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与所选版本**包名、开发证书和目标设备范围**匹配的 Development Profile，完成签名后再安装。

两版可共存，但应用身份和签名配置不同，不能直接互换。覆盖升级同一版本线时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。开发签名受 Profile 有效期和设备范围限制。
