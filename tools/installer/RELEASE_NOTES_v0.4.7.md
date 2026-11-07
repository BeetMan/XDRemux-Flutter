# v0.4.7 — 局域网互传

## 局域网互传（LocalSend）

- 新增「局域网互传」：同一 Wi-Fi 下的手机和电脑之间直接收发照片和视频，不经过云端，也不需要数据线。协议兼容 LocalSend，可以和官方 LocalSend 应用互传。
- 分为「发送」和「接收」两页。发送时在列表里点选设备即可；对方需要在接收页手动打开接收，并逐次确认收下文件。
- 设备默认以机型命名（如「OPPO Find X8 Ultra」「iPhone 16e」），可在接收页修改。
- 找不到设备时会自动扫描同一网段，iPhone 也能直接发现其他设备；仍然找不到时可以手动输入 IP 和端口。
- 实况照片：发送 `.pvt` 实况时，静帧和视频会一起发出；收到的同名照片 + `.mov` 会显示为一张实况照片，存入相册时 iOS 上是实况照片，Android 上是图片 + 视频。
- 收件箱：
  - 收到的照片可以直接预览。
  - 照片可以「加入转换队列」，也可以全部加入；收件箱可以清空（清空前会确认）。
  - iOS 和 Android 上可以把收到的照片和视频「存入相册」，也可以全部存入；其他平台用导出保存。
  - 加入转换队列后，收件箱里的原文件会保留。
- iOS 和 Android 上传输过程中屏幕保持常亮，避免息屏后中断接收。
- 支持 Windows、macOS、Linux、Android、iOS 和鸿蒙 Flutter 版。

## Live Photo

- 修复开启「摄影风格」时，部分实况照片（如 OPPO Find X8 Ultra 普通拍照的 UHDR 实况）转换失败、提示「Live Photo pair is missing or invalid」的问题（0.4.6 中存在）。

## 开源许可

- 本项目自 v0.4.6 起按 GPL-3.0-only 授权，历史版本另行补充授权，详见仓库中的 `LICENSING.md`。
- 设置中新增「开源许可」，可查看本应用、x265 及各依赖组件的许可；各平台安装包随附 `LICENSE` 与 `LICENSING.md`。

## 安装说明

### macOS（Apple Silicon）

1. 下载 `XDRemux-macOS-0.4.7.dmg`，打开后将 `XDRemux.app` 拖入「应用程序」。
2. 本包未做 Developer ID 签名与公证。确认从本项目官方发布页下载后，在 **Mac 的「终端」** 执行以下授权命令，再打开应用：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/XDRemux.app"
```

按提示输入 Mac 登录密码（输入时终端不会显示字符）。命令只清除这个 App 的下载隔离标记，不需要全局关闭 Gatekeeper 或 SIP；如果安装到其他目录，请将路径改成实际的 `XDRemux.app` 路径。若仍提示文件损坏，请先重新下载，不要反复降低系统安全设置。

也可在尝试打开后，到「系统设置 → 隐私与安全性」点击「仍要打开」。照片、文件等访问权限与上述启动授权不同，使用对应功能时再按系统提示授予。当前 DMG 仅支持 Apple Silicon，不支持 Intel Mac 转换。

### iOS（需签名侧载）

下载 `XDRemux-iOS-0.4.7-unsigned.ipa`。这是**未签名 IPA**，不能在「文件」App 中直接点开安装，也不是 App Store / TestFlight 安装包。

请使用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名并安装；按所用方式完成系统要求的开发者模式或证书信任设置。签名有效期、设备范围和刷新要求由所用账号、证书及工具决定，过期后需重新签名或刷新。最低系统为 iOS 15，Duo 新功能需相应新系统；使用相册导入或保存时仍需单独允许照片权限，使用局域网互传时需允许「本地网络」权限。

### HarmonyOS（需开发签名侧载）

- **Flutter 版 0.4.7**：`XDRemux-HarmonyOS-0.4.7-unsigned.hap`，包名 `io.github.beetman.xdremux`；profile AOT 包，保留开发签名所需的 `debug:true`。
- **原生版 0.5.4**：同步发布，使用相同的 0.4.7 内核，新增「互传」页，包含本页的摄影风格修复。安装包与说明见 [鸿蒙原生版 0.5.4 发布页](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.4)，包名 `io.github.beetman.xdremux.arkui`。

两版可共存，应用身份和签名配置不同，不能直接互换。Flutter 版 HAP 是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与包名、开发证书和目标设备范围匹配的 Development Profile，完成签名后再安装。覆盖升级时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。
