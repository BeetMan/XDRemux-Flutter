# 第三批前置：分享接收 + 小项打磨（目标 v0.1.7）

> 整理日期：2026-07-27
> 前置状态：第一、二批全部完成，v0.1.6 已发布；iOS 适配（第三批 #7）由用户在 Mac 上稍后自行推进。
> 本批次完成后发布 **v0.1.7**。

## 批次总览

| 项 | 内容 | 平台 |
|----|------|------|
| A | Android 分享接收（相册/文件管理器 → 分享 → XDRemux） | Android |
| B1 | 确认 Windows exe / 快捷方式图标为 XD 图标 | Windows |
| B2 | 批量转换完成后的系统通知 | Windows + Android |
| B3 | README 补 Android 截图 | 文档 |

---

## A. Android 分享接收

**现状问题**

手机用户的自然路径是"相册里看到一张 ProXDR 照片 → 分享 → XDRemux"，当前必须先打开 App 再通过文件选择器找文件，路径是反的。

**方案**

- 插件：`receive_sharing_intent: ^1.8.0`（支持 content URI 流式读取，正好复用 v0.1.5 的字节缓存兜底链路；已停止维护但 API 稳定，替代方案 share_handler 更重）
- `AndroidManifest.xml`：MainActivity 增加 intent-filter
  - `ACTION_SEND` + `ACTION_SEND_MULTIPLE`
  - mimeType：`image/heic`、`image/heif`、`image/*`（部分 OEM 相册把 HEIC 报成通用 image）
- `main.dart`：
  - 冷启动：`ReceiveSharingIntent.instance.getInitialMedia()`
  - 热接收（App 已在前台/后台）：`ReceiveSharingIntent.instance.getMediaStream().listen(...)`
  - 收到 `SharedMediaFile` 后按扩展名/MIME 过滤 `.heic/.heif`，其余计入 ignored
  - 入队逻辑复用 `_resolvePickedFile` 的缓存物化思路：插件给的 path 若是 content URI 或不可读，用 `getThumbnail`/`readAsBytes` 落到 `picked_files` 缓存目录
  - 提示文案与拖放一致：`已接收 N 个文件` / `已接收 N 个文件，已忽略 M 个非 HEIC 文件` / `未添加：都不是 HEIC`
- 重构：`_addFiles` / `_handleDrop` / 分享接收三处入队逻辑高度重复，抽一个 `_enqueuePaths(List<String> paths, {required String sourceVerb})`（"拖入/添加/接收"）

**涉及文件**

- `apps/flutter/pubspec.yaml`（+receive_sharing_intent）
- `apps/flutter/android/app/src/main/AndroidManifest.xml`（intent-filter）
- `apps/flutter/lib/main.dart`（初始化监听 + 入队重构）
- `apps/flutter/test/widget_test.dart`（过滤逻辑单测，如有可测面）

**验证**

- `flutter analyze` / `flutter test` 无回归
- 真机：相册分享单张 HEIC → 队列出现；文件管理器多选分享（混合 jpg）→ 提示忽略数量；App 已打开时分享 → 热接收生效

---

## B1. Windows exe 图标确认

- 安装 v0.1.6 后检查：安装目录 `xdremux.exe` 文件图标、桌面快捷方式、任务栏运行图标是否为 XD 图标
- 若不对：`windows/runner/resources/app_icon.ico` 重新生成（macOS 1024px 源 → 多尺寸 ICO），iss 的 `SetupIconFile` 同步
- 零代码改动则只做目视确认并记录

## B2. 转换完成系统通知

**Windows**：`windows_notifications` 太重，最小方案是批量结束（`_isConverting` 由 true 翻 false 且有成功项）时窗口标题栏闪烁 / 或在状态文本基础上加一声 `SystemSound`。若想要真 toast，评估 `local_notifier`（轻量、纯 WinRT 包装）。
**Android**：`flutter_local_notifications`（需 POST_NOTIFICATIONS 运行时权限，Android 13+）。

收敛方案（控制范围）：两端都用最轻实现——
- 桌面：`local_notifier`（若引入成本超预期则降级为窗口闪烁 + 提示音）
- Android：`flutter_local_notifications`，仅在批量完成且 App 在后台时发通知（前台仍走现有状态文本）

**涉及文件**：`pubspec.yaml`、`main.dart`（转换完成回调处）、`AndroidManifest.xml`（POST_NOTIFICATIONS 权限）

## B3. README Android 截图

- 现有截图技术：pyautogui 截真机 screencap 或模拟器窗口，裁边
- 加一张手机主界面（队列页）截图到 README"截图"小节，与 Windows 图并排
- 顺带把 README 功能清单补"分享接收"

---

## 版本号

- `apps/flutter/pubspec.yaml`：`0.1.6+8` → `0.1.7+9`
- `xdremux/rust/Cargo.toml` 与 FFI 版本：`0.1.6` → `0.1.7`（保持一致，尽管 Rust 核心无改动）
- `tools/installer/xdremux.iss`：默认 `AppVersion` → `0.1.7`
- 新增 `tools/installer/RELEASE_NOTES_v0.1.7.md`
- 打 `v0.1.7` tag → release.yml 自动构建发版

## 执行顺序

```
A. 分享接收（功能主体，先做）
   ↓ 提交
B1. exe 图标确认（顺手）
B2. 完成通知
B3. README 截图
   ↓ 提交
版本号 bump → RELEASE_NOTES → 打 v0.1.7 tag 实战发版
```
