# 安装与侧载

安装包分别见 [Flutter 0.4.8](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/v0.4.8)、[SwiftUI 0.1.2](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/apple-v0.1.2) 和[鸿蒙原生 0.5.5](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.5)。

### macOS（Apple Silicon）

- **Flutter**：打开 `XDRemux-macOS-0.4.8.dmg`，将 `XDRemux Flutter.app` 拖入「应用程序」。该版使用 ad-hoc 签名。若首次打开被拦截，确认来源后，在「系统设置 → 隐私与安全性」选择「仍要打开」。DMG 内附该设置页的快捷入口。
- **SwiftUI**：打开 `XDRemux-Apple-macOS-0.1.2.dmg`，将已公证的 `XDRemux.app` 拖入「应用程序」。两版可并存。

### iOS（需签名侧载）

Flutter 下载 `XDRemux-iOS-0.4.8-unsigned.ipa`，SwiftUI 下载 `XDRemux-Apple-iOS-0.1.2-unsigned.ipa`。两者都是**未签名 IPA**，不能在「文件」App 中直接点开安装，也不是 App Store / TestFlight 安装包。自 `v0.4.8` 起 Flutter 版桌面显示名为 `XDRemux Flutter`（保留包名 `io.github.beetman.xdremux`），以便与 SwiftUI 原生版 `XDRemux` 同机区分。

请使用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名并安装；按所用方式完成系统要求的开发者模式或证书信任设置。签名有效期、设备范围和刷新要求由所用账号、证书及工具决定，过期后需重新签名或刷新。Flutter 最低系统为 iOS 15，SwiftUI 为 iOS 17，Duo 新功能需相应新系统；使用相册导入或保存时仍需单独允许照片权限。

### HarmonyOS（两种 HAP 均需开发签名侧载）

请按包名选择对应版本的安装包。

- **原生版 0.5.5**：`XDRemux-HarmonyOS-Native-0.5.5-unsigned.hap`，ArkUI 原生界面，桌面显示名为 `XDRemux`，包名 `io.github.beetman.xdremux.arkui`。
- **Flutter 版 0.4.8**：`XDRemux-HarmonyOS-0.4.8-unsigned.hap`，包名 `io.github.beetman.xdremux`（自 `v0.4.8` 起桌面显示名为 `XDRemux Flutter`）。

两份都是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与所选版本**包名、开发证书和目标设备范围**匹配的 Development Profile，完成签名后再安装。

两版可共存，但应用身份和签名配置不同，不能直接互换。覆盖升级同一版本线时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。开发签名受 Profile 有效期和设备范围限制。

## 参考

- [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)（系统设置中的单 App 安全例外）。
- [Apple：向已注册设备分发 App](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)（iOS 签名和设备范围）。
