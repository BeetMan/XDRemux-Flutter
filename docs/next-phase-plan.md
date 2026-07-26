# 下一阶段开发计划（v1.3 同步之后）

> 整理日期：2026-07-25
> 前置状态：上游 v1.3 同步已全部完成（见 `v1.3-sync-plan.md`），Windows / macOS / Android 三端可运行，120 个 Rust 测试 + 7 个 Flutter 测试通过。
> 状态更新：2026-07-26 — **第 1 项（砍 ffmpeg）已完成**：Windows 与 Android 统一走 x265 静态链接（`build_windows/Release/x265-static.lib`，MSVC Release），缩略图/预览全平台切换为 Rust FFI（EXIF 内嵌 JPEG 提取），`tools/ffmpeg/windows`（195MB）与 CMake install 块已移除；ffmpeg 子进程保留为编译期回退（`XDREMUX_USE_FFMPEG=1`）。116 Rust 测试通过，Flutter analyze/test/build 全绿，真实 OPPO 样本端到端转换验证通过。
> 状态更新：2026-07-26 — **第 2、3 项已完成**：MSIX 打包（`msix` dev 依赖 + pubspec `msix_config`，`dart run msix:create`，产物 95MB；注意 msix 包自带 Redist makeappx 侧加载失败，用 Windows SDK `makeappx.exe` 成功）；自动更新检查（`update_service.dart` 查询 GitHub Releases API + SnackBar 提示，`package_info_plus` 比对版本号）；`Runner.rc` 的 `com.example` 占位符改为 BeetMan/XDRemux。

## 优先级总览

| 批次 | 目标 | 关键项 |
|------|------|--------|
| 第一批 | 分发与减负 | 砍 ffmpeg 捆绑、Windows 安装程序、自动更新 |
| 第二批 | 体验完善 | 转换结果预览、非 HEIC 提示、CI/CD |
| 第三批 | 平台扩展 | iOS 适配、Linux 支持 |
| 暂缓 | — | GPU 编码、增量转换、Apple 特性 |

---

## 第一批：分发与减负

### 1. 砍掉 195MB 的 ffmpeg 捆绑 ⭐ 最高优先级

**现状问题**

- Windows 包捆绑完整 Gyan.dev ffmpeg（`tools/ffmpeg/windows/`，195MB），仅用于 JPEG 解码和 HEVC 编码两个功能
- 安装包体积 ~200MB，下载/分发成本高
- ffmpeg 子进程在 Windows 上引入了一系列特有问题：`CREATE_NO_WINDOW` 标志、pipe 缓冲区死锁（需后台 stdin 线程 + 先 drain stdout）、绝对路径解析（`where` 查找）——这些都记录在 `memory/windows-ffmpeg-*.md`

**方案**

Android 端已验证可行：`26487c5 feat(android): x265 static-linked HEVC encoder + pure-Rust JPEG decode`

- `xdremux/rust/src/hevc.rs`：`encode_hevc_tile_gray` / `encode_hevc_tile_rgb` 从 ffmpeg subprocess 换成直接调 x265 C API（FFI 静态链接）
- `xdremux/rust/src/jpeg_decode.rs`：Android 已是纯 Rust JPEG 解码，直接复用到 Windows
- 桌面端保留 ffmpeg 作为可选回退（环境变量控制），默认走 x265

**预期收益**

- 安装包从 ~200MB 降到 ~30MB
- 消除 ffmpeg 子进程相关的全部 Windows 特有问题
- 启动更快（无需 spawn 外部进程）
- 三端代码路径统一（都是 x265 FFI + Rust JPEG）

**涉及文件**

- `xdremux/rust/src/hevc.rs`（重写编码路径）
- `xdremux/rust/src/jpeg_decode.rs`（复用 Android 实现）
- `xdremux/rust/Cargo.toml`（x265 链接配置）
- `apps/flutter/windows/CMakeLists.txt`（移除 ffmpeg install 块）
- `tools/ffmpeg/windows/`（删除）
- `.gitignore`、`README.md`

### 2. Windows 安装程序（MSIX）

- `flutter build windows` 产物用 MSIX 打包
- 一键安装、开始菜单项、可选商店分发
- 比 NSIS 更现代，微软官方方向
- 前置依赖：第 1 项完成后包体积才合理

### 3. 自动更新检查

- 启动时查询 GitHub Releases API，比对当前版本
- 有新版本时 SnackBar 提示 + 跳转下载页
- 配合 MSIX 可走商店自动更新通道
- 实现量小：`package:http` + `package:version` 对比

---

## 第二批：体验完善

### 4. 转换结果预览（源 ↔ 输出对比）

- 转换完成后可并排查看源文件与输出文件
- 对比内容：缩略图、mode（LHDR/UHDR）、edr_scale、gainMapMax、文件大小
- 入口：队列项详情页 / `_ItemDetailSheet` 增加"对比"标签
- 用户价值：直接确认"转完到底对不对"

### 5. 拖入非 HEIC 文件给出提示

- 当前静默丢弃，用户不知道文件没进去
- 加 SnackBar："已忽略 N 个非 HEIC 文件"
- 实现量极小，体验提升明显

### 6. CI/CD（GitHub Actions）

- 每次 push：`cargo test --workspace` + `flutter test` + `flutter analyze`
- Release tag：自动构建 Windows（x265 静态链接后）+ Android APK + macOS
- 前置建议放在第二批但越早越好——没有 CI 兜底，后续改动容易出回归

---

## 第三批：平台扩展

### 7. iOS 适配

- `flutter create --platforms=ios .`
- FFI 静态链接（`DynamicLibrary.process()` 已在 FFI 层预留）
- 缩略图/保存走 iOS 原生 API（`gal` 插件已支持 iOS）
- x265 静态链接方案在 iOS ARM64 上同样适用

### 8. Linux 支持

- Flutter Linux 桌面端
- ffmpeg 用系统包（`apt install ffmpeg`），不捆绑
- 优先级最低：Linux 用户可直接用 Python CLI

---

## 暂缓项（明确不做或推迟）

| 项 | 原因 |
|----|------|
| GPU 加速 HEVC（nvenc/amf） | x265 软编码在 512×512 tile 上已够快（单文件几秒）；GPU 编码器对 tiny tile 增益有限，且引入平台特定复杂度 |
| 增量转换（只重编变化的 tile） | 收益场景窄（仅重复转换同批文件时有意义），实现复杂度高 |
| Apple 摄影风格 / 人像 | v1.3 已明确跳过：~12,000 行依赖 Vision/CoreImage/VideoToolbox，macOS 专属，Rust 重写不可行 |
| 转换后回退 OPPO 相册编辑再保存不丢 Gain Map | 依赖 OPPO 相册自身行为，非我们能控制 |

---

## 建议执行顺序

```
1. 砍 ffmpeg（x265 静态链接 Windows 化）
   ↓ 包体积合理化后
2. MSIX 安装程序 + 自动更新检查
   ↓ 分发链路打通后
3. CI/CD（防止后续改动出回归）
   ↓
4. 转换结果预览 + 非 HEIC 提示（体验完善）
   ↓
5. iOS 适配 → Linux（平台扩展）
```

第一步从 **砍 ffmpeg** 开始——它是目前最大的分发障碍，Android 端已趟过路，且能顺带消除一整类 Windows 特有 bug。
