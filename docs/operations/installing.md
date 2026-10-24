# 安装与侧载

适用附件：Flutter v0.4.5，以及同页提供的鸿蒙原生 0.5.2。仅从[官方发布页](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/v0.4.5)下载；两条鸿蒙版本线保持独立。

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

## 参考

- [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)（系统设置中的单 App 安全例外）。
- [Apple：向已注册设备分发 App](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)（iOS 签名和设备范围）。
