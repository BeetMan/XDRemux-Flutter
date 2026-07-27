# 第二批开发计划：体验完善 + CI/CD

> 整理日期：2026-07-27
> 前置状态：第一批（分发与减负）全部完成，v0.1.0 已发布（Windows exe 安装包 + Android APK）。
> 状态更新：2026-07-27 — 第 5、6 项已完成；v0.1.4 云端 APK 经真机实际点选 HEIC 仍复现导入失败，正在发布 v0.1.5 修复。
> 当前修复版本：**v0.1.5（待云端 Release 验证）**。

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

## 6. CI/CD（GitHub Actions）+ 版本号 0.1.1 ✅ 已完成

**现状问题**

- 每次改动靠手动跑 `cargo test` / `flutter test` / `flutter analyze` 兜底，容易漏
- 发布靠手动构建（Windows `flutter build windows --release` + `iscc`；Android `cargo ndk` + `flutter build apk --release`），步骤分散、环境依赖（x265 静态库、China 镜像、Inno Setup）都隐式存在本机

**方案：两个 workflow**

### 6a. CI（每次 push / PR）

`.github/workflows/ci.yml`：

- **job: rust** — `ubuntu-latest`，缓存并构建 x265、安装 `libnuma-dev` 后执行 `cargo test --workspace`
- **job: flutter** — `ubuntu-latest`，使用项目 pub 镜像，构建 FFI smoke test 所需的 Linux `.so`，再执行 `flutter analyze` + `flutter test`

### 6b. Release（打 `v*` tag 时）

`.github/workflows/release.yml`：

- **job: windows** — `windows-2022`
  - 编 x265 静态库（cmake，`-DXDREMUX_SKIP_RC=ON`，缓存 `vendor/x265/build_windows/Release/x265-static.lib`）
  - `cargo build -p xdremux-core --release`
  - `flutter build windows --release`
  - Inno Setup 打包（`iscc tools/installer/xdremux.iss`，使用 runner 自带语言资源）
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

- CI：已通过 [CI run 30213489285](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/30213489285)
- Release：已通过 [Release run 30213513064](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/30213513064)
- 产物：[`v0.1.1 Release`](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/v0.1.1) 已出现 Windows exe 与 Android apk

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

---

## 7. Android release 文件导入回归 ✅ 已完成（v0.1.5）

**问题定位**

- 手机上正常的本地 APK 与 GitHub v0.1.2 APK 的签名一致，但 `libapp.so` 与 Rust native library 不同。
- 本地 APK 是临时调试修复后的旧构建产物；GitHub 从 tag 干净构建时重新编译了当前源码。
- v0.1.4 云端 APK 在 OPPO 真机上完成文件选择后仍显示 `0 / 0`；之前的安装、签名和构建检查不足以证明导入链路正常。
- Android OEM 文件选择器的返回结果需要同时兼容本地路径和文件字节；原逻辑对路径/分类异常静默跳过，用户只能看到队列为空。

**修复**

- 将 `classify()` 的 FFI 调用移回 root isolate；`convert()` 继续保留后台 isolate。
- `pickFiles()` 启用 `withData`；路径不可读时将字节写入应用私有缓存，确保 Rust 核心拿到真实文件路径。
- 增加文件选择结果、路径回退和分类失败的状态提示与日志，避免静默丢失。
- 版本升级到 `0.1.5+7`，新增 `RELEASE_NOTES_v0.1.5.md`。
- Android Gradle 仓库改为官方 `google()` / `mavenCentral()` 优先，阿里云仓库仅作为后备，避免 GitHub runner 遇到镜像 502 时整次 release 失败。

**验收**

- `cargo test -p xdremux-core`：116 passed，2 ignored。
- `flutter analyze`：无 error；现有 7 条 `avoid_print` info。
- 首次 v0.1.3 Release run 的 Android 逻辑修复已通过，但构建因阿里云 Maven 502 失败；该失败 tag 不复用。
- CI：[`30261265186`](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/30261265186) 通过。
- Release：[`30261267514`](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/30261267514) 通过；但 v0.1.4 APK 在真机实际点选 HEIC 后仍为 `0 / 0`，该版本不视为导入修复完成。
- 本地 v0.1.5 候选 Release APK 已在解锁的 OPPO 真机上实际选择 `IMG20260711155540_iso.heic`，队列显示 `1 个文件`，分类显示“大师模式 / 待处理”；云端 v0.1.5 Release 验证待完成。
