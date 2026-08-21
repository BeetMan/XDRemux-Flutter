# XDRemux v0.3.1

## 本版本

- 完善 Apple/OPPO 回传照片写回流程。
- Apple 标准输出使用 Rust 生成新的 Apple Photographic Styles graph。
- OPPO 兼容输出恢复原始完整水印 canvas、HDR/UHDR graph 和 OPPO 尾部数据。
- Apple/OPPO 工作流的编辑副本和最终输出统一提供保存、打开、分享三个文件操作。
- 桌面端支持“另存为”，Android/iOS 支持保存到照片图库。

## 验收重点

1. Apple 标准输出的 HDR、Apple Styles 入口和原始水印。
2. OPPO 兼容输出的水印颜色、HDR 和 OPPO Gallery 兼容性。
3. Windows、Android、macOS 文件保存、打开和分享流程。

## 已知限制

- Apple Photographic Styles 的旧 Photos 编辑状态不写回；Apple 标准输出生成新的 Styles recipe。
- Apple/OPPO 输出仍需在真实 Photos 和 OPPO Gallery 设备上验证。
- macOS / iOS 分发为 unsigned 构建，未纳入 GitHub Actions 签名发布。

## macOS 首次打开（unsigned 版必读）

本 DMG 未签名，首次打开会提示「已损坏，无法打开」或「无法验证开发者」。文件本身没有损坏，这是 Gatekeeper 对未签名 app 的隔离机制。请先将 `XDRemux.app` 拖入「应用程序」文件夹，然后任选一种方式：

**方式一：终端命令（推荐）**

```bash
xattr -cr /Applications/XDRemux.app
```

执行后再双击打开即可。

**方式二：系统设置放行**

1. 双击 app，出现提示后点「完成」。
2. 打开 **系统设置 → 隐私与安全性**，在页面底部找到「已阻止使用 XDRemux」，点击 **仍要打开**。
3. 弹窗中再点「打开」。

## Android 安装说明

安装包使用正式 release 签名。如果手机上装过本地 debug 构建的旧版本，覆盖安装会因签名不一致被拒，请先卸载旧版再安装（会丢失应用内数据）。
