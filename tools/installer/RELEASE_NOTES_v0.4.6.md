# v0.4.6 — Live Photo `.pvt` 包、实况编辑修复与摄影风格 HDR 缩略图

## Live Photo

- 新增「Live Photo 打包为 .pvt」，默认开启：实况照片输出为一个 `<名称>.pvt` 包（内含 HEIC、MOV 与 `metadata.plist`），和 AirDrop 传实况用的是同一种格式，Mac「照片」可直接导入为一张实况照片。从 0.4.5 升级同样默认开启；在设置里关闭即恢复为分开的 HEIC + MOV。
- 保存到相册（iOS、Android）后仍是一张实况照片。分享时 iOS 和 macOS 直接发送 `.pvt` 包，苹果设备收到即为实况照片；Android、Windows、Linux 和鸿蒙打包为一个 `.pvt.zip`。
- 修复安卓实况转换后，在苹果「照片」里编辑并保存时实况部分丢失的问题（0.4.5 起存在）。
- 摄影风格可以和实况一起使用：修复同时开启「摄影风格 3」和实况输出时，在苹果「照片」里点「编辑」会导致「照片」退出的问题（0.4.5 起存在）；「摄影风格 2」也不再在实况照片上被关闭。现在都可以正常编辑和调节风格，保存后实况保留，静帧与视频颜色一致。

## 摄影风格

- 设置中的两个开关按 Apple 官方名称改为「摄影风格 2」和「摄影风格 3」。
- 风格缩略图改为 HDR，方向与原图一致；Android、iOS 和鸿蒙上使用 10-bit 编码。
- 每张照片单独计算风格色调曲线，不再套用固定曲线。
- 已在 macOS 27.2「照片」和 iPhone 16e 上实测。

## JPEG HDR

- 修复 OPPO Find N5 大师模式等照片报错「MPF gain-map size missing」、无法转换的问题：没有增益图的这类 JPEG 现在按普通照片转换。
- 写入 HDR 元数据时拒绝异常数值，避免 Apple 不识别 HDR、OPPO 相册亮度显示不对。

## iPhone Duo

- 横屏时系统竖栏在左侧，内容会自动让开，不再被竖栏盖住。
- 浮动的开始/取消按钮不再压到 Home 指示条；队列为空时开始按钮显示为不可用。
- 折叠、展开或旋转后布局即时更新，无需重启 App。
- 以上基于模拟器测试，折叠屏真机尚未验证。

## 安装说明

### macOS（Apple Silicon）

1. 下载 `XDRemux-macOS-0.4.6.dmg`，打开后将 `XDRemux.app` 拖入「应用程序」。
2. 本包未做 Developer ID 签名与公证。确认从本项目官方发布页下载后，在 **Mac 的「终端」** 执行以下授权命令，再打开应用：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/XDRemux.app"
```

按提示输入 Mac 登录密码（输入时终端不会显示字符）。命令只清除这个 App 的下载隔离标记，不需要全局关闭 Gatekeeper 或 SIP；如果安装到其他目录，请将路径改成实际的 `XDRemux.app` 路径。若仍提示文件损坏，请先重新下载，不要反复降低系统安全设置。

也可在尝试打开后，到「系统设置 → 隐私与安全性」点击「仍要打开」。照片、文件等访问权限与上述启动授权不同，使用对应功能时再按系统提示授予。当前 DMG 仅支持 Apple Silicon，不支持 Intel Mac 转换。

### iOS（需签名侧载）

下载 `XDRemux-iOS-0.4.6-unsigned.ipa`。这是**未签名 IPA**，不能在「文件」App 中直接点开安装，也不是 App Store / TestFlight 安装包。

请使用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名并安装；按所用方式完成系统要求的开发者模式或证书信任设置。签名有效期、设备范围和刷新要求由所用账号、证书及工具决定，过期后需重新签名或刷新。最低系统为 iOS 15，Duo 新功能需相应新系统；使用相册导入或保存时仍需单独允许照片权限。

### HarmonyOS（需开发签名侧载）

- **Flutter 版 0.4.6**：`XDRemux-HarmonyOS-0.4.6-unsigned.hap`，包名 `io.github.beetman.xdremux`；profile AOT 包，保留开发签名所需的 `debug:true`。
- **原生版 0.5.3**：同步发布，使用相同的 0.4.6 内核，包含本页的 Live Photo 与摄影风格修复，另有 `.pvt` 导出/分享、转换单张保留实况等原生版改进。安装包与说明见 [鸿蒙原生版 0.5.3 发布页](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.3)，包名 `io.github.beetman.xdremux.arkui`。

两版可共存，应用身份和签名配置不同，不能直接互换。Flutter 版 HAP 是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与包名、开发证书和目标设备范围匹配的 Development Profile，完成签名后再安装。覆盖升级时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。
