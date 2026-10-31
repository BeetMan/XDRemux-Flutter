# v0.4.6 — Live Photo `.pvt` 包、Styles HDR 缩略图与 Duo 安全区修复

> 草稿（2026-10-31）：发布前由维护者校对；标注「待验证」的条目在打 tag 前补验或删去。

## Live Photo 打包为 `.pvt`

- 新增可选设置「Live Photo 打包为 .pvt」，默认关闭。打开后，实况照片输出为一个 Apple Live Photo 包（`<名称>.pvt/`，内含配对好的 HEIC、MOV 与 `metadata.plist`），与 AirDrop 传实况时使用的格式一致。HEIC 与 MOV 字节不变，不重新编码。
- 包在隐藏的暂存目录里组装、校验配对后再原子替换同名旧包；转换中断后的检查点恢复能识别已有的 `.pvt`。
- 保存到相册（iOS PhotoKit、Android 相册）使用包内的两个文件，结果仍是一张实况照片。
- 分享：iOS 和 macOS 直接分享 `.pvt` 包；Android、Windows、Linux 和鸿蒙分享为单个 `<名称>.pvt.zip`。
- 已验证：macOS「照片」导入 `.pvt` 为 1 个资产，按原件导出 MOV 逐字节一致；`.pvt` 从 Mac 隔空投送到 iPhone 正常。
- 修复安卓实况转换后，在苹果「照片」里编辑并保存时实况部分丢失的问题：配对后的 MOV 音频改用 iPhone 的 QuickTime AAC 描述，系统可以正常解码、重新渲染和导出视频（0.4.5 起存在；对 `.pvt` 与普通配对都生效）。
- 已知问题：同时开启「摄影风格 3」和实况输出时，在「照片」里点「编辑」会导致「照片」退出。修复正在进行，在此之前请不要对实况同时开启摄影风格。

## Apple 摄影风格（Styles）HDR 缩略图

- 风格缩略图改为线性 HDR：按 Apple Log 码值渲染，并把增益图直接作用在内存像素上，方向与原图显示方向对齐。
- 在 Android、iOS 和鸿蒙上，缩略图用 10-bit（Main10）编码；macOS、Windows、Linux 发布包仍为 8-bit Apple Log。
- 每张图单独拟合全局色调曲线（GTC，单调），取代固定曲线。
- Standard 风格的局部调整（key 1）保持为不调整：测量发现逐图拟合会在「照片」里拉动风格滑块时带来格状偏色（平均 ΔE76 约 2–3），与上游的判断一致，因此只保留 GTC 拟合。
- 已验证：macOS 27.2「照片」可导入转换结果，风格编辑器能打开和调节。
- 待验证：iPhone 真机上的显示、风格滑块观感与绝对亮度。

## JPEG HDR

- 修复 OPPO Find N5 大师模式实况等照片无法转换（报错「MPF gain-map size missing」）的问题：MPF 索引只列出主图、又没有增益图时，按普通 SDR JPEG 处理；若主图声明了 HDR 元数据却缺增益图，仍明确报错。
- 写入 ISO 21496-1 增益图元数据时，拒绝通道上下限颠倒或非有限的数值，避免 Apple 判为无效、OPPO 相册按错误亮度余量显示。

## iPhone Duo

- 横屏时系统竖栏在左侧，内容会自动让开，不再被竖栏盖住。
- 浮动的开始/取消按钮不再压到 Home 指示条。
- 队列为空时，浮动开始按钮显示为禁用状态。
- 折叠、展开或旋转后会重新读取竖栏位置，无需重启 App。
- 待验证：真机折叠/展开与左右横屏。

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
- 原生版本轮不更新，仍为 0.5.2，安装包见 v0.4.5 发布页。

这是 **unsigned HAP**，不是免签安装包，也不是应用市场分发包。请用 DevEco Studio 或兼容的开发签名侧载工具，准备与包名、开发证书和目标设备范围匹配的 Development Profile，完成签名后再安装。覆盖升级时应沿用原有签名；遇到签名冲突先核对证书与包名，不要直接卸载导致数据丢失。
