# 第二批开发计划：体验完善 + CI/CD

> 整理日期：2026-07-27
> 前置状态：第一批（分发与减负）全部完成，v0.1.0 已发布（Windows exe 安装包 + Android APK）。
> 状态更新：2026-07-27 — 第 5 项已完成；第 6 项 CI/CD 与 v0.1.1 工作流已落地，待推送 tag 后完成远端实跑验收。
> 本批次完成后发布 **v0.1.1**。

## 批次总览

| 项 | 内容 | 版本 |
|----|------|------|
| 5 | 拖入非 HEIC 文件给出提示 | v0.1.1 |
| 6 | CI/CD（GitHub Actions）+ 版本号 bump 0.1.1 | v0.1.1 |

---

## 5. 拖入非 HEIC 文件给出提示 ✅ 已完成

**现状问题**

- `_handleDrop` 里 `if (!path.toLowerCase().endsWith('.heic')) continue;` 静默跳过，用户把一堆 jpg/png 拖进来后界面毫无反应，以为应用坏了
- `_addFiles`（file_picker）已经在原生层过滤了 `.heic`，所以这个问题只影响拖放路径

**改动**

- `_handleDrop`：统计被跳过的非 HEIC 数量，和已添加数量一起进状态文本 / SnackBar
  - 全部有效：`已拖入 5 个文件`（现状不变）
  - 部分被忽略：`已拖入 3 个文件，已忽略 2 个非 HEIC 文件`
  - 全部被忽略：`未添加：5 个文件都不是 HEIC`
- 顺带把 `.heif` 也纳入文件选择器与拖放接受扩展名

**完成情况**

- `isSupportedInputPath()` 统一判断 `.heic/.heif`，避免选择器与拖放规则分叉。
- 新增扩展名回归测试；Flutter 测试当前 8 / 8 通过。

**涉及文件**

- `apps/flutter/lib/main.dart`（`_handleDrop` 约 10 行改动）

**验证**

- `flutter analyze` 无新 warning
- 手动：拖入混合文件（2 个 heic + 1 个 jpg）看提示；只拖 jpg 看提示

---

## 6. CI/CD（GitHub Actions）+ 版本号 0.1.1（实现完成，待远端验证）

**现状问题**

- 每次改动靠手动跑 `cargo test` / `flutter test` / `flutter analyze` 兜底，容易漏
- 发布靠手动构建（Windows `flutter build windows --release` + `iscc`；Android `cargo ndk` + `flutter build apk --release`），步骤分散、环境依赖（x265 静态库、China 镜像、Inno Setup）都隐式存在本机

**方案：两个 workflow**

### 6a. CI（每次 push / PR）

`.github/workflows/ci.yml`：

- **job: rust** — `ubuntu-latest`，`cargo test --workspace`（纯 Rust，不依赖 x265 静态库也能跑大部分测试；需要 x265 的 hevc 测试走 `XDREMUX_USE_FFMPEG=1` 回退或在 CI 里先编 x265——见"决策点"）
- **job: flutter** — `ubuntu-latest`，`flutter analyze` + `flutter test`（不构建平台产物，速度快）

### 6b. Release（打 `v*` tag 时）

`.github/workflows/release.yml`：

- **job: windows** — `windows-latest`
  - 编 x265 静态库（cmake，`-DXDREMUX_SKIP_RC=ON`，缓存 `vendor/x265/build_windows/Release/x265-static.lib`）
  - `cargo build -p xdremux-core --release`
  - `flutter build windows --release`
  - Inno Setup 打包（`iscc tools/installer/xdremux.iss`）
  - 上传 `XDRemuxSetup-<version>.exe` 到该 tag 的 Release
- **job: android** — `ubuntu-latest`
  - 编 x265 Android 静态库（`build_android/libx265.a`，缓存）
  - `cargo ndk -t arm64-v8a build --release`
  - `flutter build apk --release`
  - 上传 `app-release.apk`
- 版本号从 tag 提取（`v0.1.1` → `0.1.1`），注入 pubspec / iss / apk 文件名

### 版本号 bump

- `apps/flutter/pubspec.yaml`：`version: 0.1.0+1` → `version: 0.1.1+2`
- `xdremux/rust/Cargo.toml` 与 FFI 版本：`0.1.0` → `0.1.1`
- `tools/installer/xdremux.iss`：默认 `AppVersion` 改为 `0.1.1`，tag 构建时可用 `/DAppVersion` 覆盖
- Release workflow 里改为从 tag 读取，避免以后每次手动改两处

### 决策点（实施时先确认）

| 问题 | 选项 A（推荐） | 选项 B |
|------|----------------|--------|
| CI 里 x265 怎么处理 | 每次从 vendor 源码编（~2 分钟）+ `actions/cache` 按源码 hash 缓存 | CI 跳过 x265，用 `XDREMUX_USE_FFMPEG=1` 回退 + 装 ffmpeg——快但测的不是真实路径 |
| Release 触发方式 | 打 tag 自动跑 | 手动 `workflow_dispatch`——更可控但要记得点 |
| macOS 是否进 release | 暂不进（签名/公证没解决） | 顺手打一个 unsigned dmg 作为 experimental |

**涉及文件**

- `.github/workflows/ci.yml`（新）
- `.github/workflows/release.yml`（新）
- `apps/flutter/pubspec.yaml`（版本号）
- `tools/installer/xdremux.iss`（版本号）
- `tools/installer/RELEASE_NOTES_v0.1.1.md`（新）
- `README.md`（CI badge，可选）

**验证**

- CI：随便一个 push 触发，两个 job 绿
- Release：本地先 `act` 模拟不了（x265/Windows 依赖重），直接打 `v0.1.1` tag 实战验证；失败就删 tag 重来
- 产物：Release 页面自动出现 exe + apk，版本号正确

**当前实现**

- `ci.yml`：Rust 构建真实 x265 静态库后执行 workspace 测试；Flutter 使用项目 pub 镜像、`flutter analyze --no-fatal-infos` 和 `flutter test`。
- `release.yml`：`v*` tag 构建 Windows Inno Setup 安装包与 arm64 Android APK，版本号从 tag 注入，并自动创建 GitHub Release。
- x265 源码和构建产物通过 Actions cache 缓存，避免每次从头编译。

---

## 执行顺序

```
5. 非 HEIC 提示（半小时，先上）
   ↓ 提交
6. pubspec + iss 版本号 bump 0.1.1
   ↓ 提交
6a. ci.yml（push 验证绿）
   ↓
6b. release.yml
   ↓
打 v0.1.1 tag → 实战验证 release 流水线
```

完成后 v0.1.1 即为首个 CI 保障 + 自动构建产物的版本。
