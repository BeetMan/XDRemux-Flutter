# CI 剖析

> 六个 workflow：`.github/workflows/ci.yml`（日常）、`conformance.yml`（一致性）、`apple-ci.yml`（原生 SwiftUI 应用）、`ohos-ci.yml`（鸿蒙 Rust 冒烟）、`linux.yml`（Linux PR/可复用构建）、`release.yml`（发版及只构建预检，见 `operations/releasing.md`）。

## 1. ci.yml（push/PR 日常）

- Rust 核心：Ubuntu 上构建 x265 并执行 workspace tests；不等同于全平台安装包验证。
- Flutter analyze（容忍既有的 info 级 lint）
- Flutter job 的 FFI 冒烟库显式使用 FFmpeg fallback；Rust job 和各平台正式构建仍使用 x265。合成自动测试不替代私有原图或目标图库的色彩验收。
- Apple SDK 守卫的模拟工具回归测试在 Ubuntu 执行；真正的 Duo SDK/API typecheck 在 iOS 构建 runner 上执行。
- Android APK ABI/ELF/CRC 门禁有合成包回归测试；发包 job 另检查真实 APK，必须只有 ARM64 且包含匹配架构的 Rust、Flutter、AOT 和 C++ 运行库。

## 2. conformance.yml

- `tests/conformance` crate 构建 + 合成样本对拍（bplist / scaffold / styles 常量等纯逻辑）
- 金样语料不入库，CI 只跑无样本路径（见 `testing/conformance-suite.md`）
- fixture 门禁测试（14 个上游 Motion Photo fixture 对拍）在 fixtures 缺失时优雅跳过（`require_fixtures()` 守卫，2026-09 修）

## 2.4 apple-ci.yml（原生 Apple 应用）

- 触发：push 到 `main` 或 PR，且改动落在 `apps/apple/**`、`xdremux/rust/**`、`tools/apple/**` 或本 workflow；也可手动 dispatch。
- 单 job，`macos-latest`：构建 x265（按 `X265_TAG` 缓存）→ `tools/apple/check_header.sh` 校验已提交的 `xdremux_core.h` 与 cbindgen 输出一致 → `XDREMUX_APPLE_SLICES=macos xdremux/rust/build_apple.sh` 只构建 macOS 切片的 `XDRemuxCore.xcframework` → `apps/apple/Packages/XDRemuxKit` 下 `swift test` → 构建 `xdremux` CLI 并冒烟（`--version`、`capabilities`、随机字节 `inspect` 必须失败）→ `xcodegen generate` + `xcodebuild` 构建未签名的 macOS Debug App。
- **不覆盖**：iOS 切片与 iOS 模拟器（本地用 `build_apple.sh` 的 `ios-sim` 切片，见 `apps/apple/README.md`）、签名、真机照片 App 验收。原生 Apple 应用尚未进入 `release.yml`。
- 改了 FFI 导出却没重新生成头文件时，本 workflow 在 header 检查一步失败。

## 2.5 ohos-ci.yml（鸿蒙）

- 范围**只做 Rust 核心冒烟**：公开 SDK 上 `build_ohos.sh` 构建 `libxdremux_core.so`
- 完整 hap 出包不上 CI：hvigor 工具链为 DevEco 环境设计，公开 SDK 走不通；签名也是本地 DevEco 的事
- 真机验证靠本地（hdc + uitest 自动化）

## 3. release.yml（tag 触发）

Job 结构与缓存策略：

- **x265 缓存**：`x265-windows-<tag>-asm` 按 ref 作用域缓存；ref 缓存 miss 时回退 main 分支缓存（避免每次 release 重编 x265）
- **版本解析**：pubspec `^version:` 正则 -> TAG_VERSION -> 资产命名
- **Windows**：NASM 安装 -> x265 -> Rust -> Flutter -> Inno Setup（`BuildArch` 参数）
- **Android**：SDK 36 约束（runner 无 API 37）+ JVM target 分插件对齐已固化在构建脚本
- **publish job**：汇集 dist/ 下各产物挂到 Release；不生成/覆盖 Release 文案；`needs` 必须包含全部构建 job（`[windows, windows-arm64, android, macos, ios, linux]`；曾因漏 needs 导致 pre.2 缺 ARM64 包，`0eb097b` 修）
- **windows-arm64**：`continue-on-error: true`，只做实验性构建、不出安装包，失败不阻断 publish（与 README「不提供 Windows ARM64 安装包」一致）
- 鸿蒙 hap 不进 release.yml：本地构建（Windows `tools/ohos/build_hap.ps1`，macOS `tools/ohos/build_hap.sh`，见 `operations/building.md`）后手动挂资产
- iOS 使用 `xcode-27`，显式选择 Xcode 27.1，先检查 SDK/API，再构建归档和校验 FFI；不降级 Duo 功能来适配旧 SDK。
- Linux 通过 `linux.yml` 的 `workflow_call` 构建，与四个既有平台一起参与 publish 成功和附件存在性门禁；保持预览平台标记。独立 Linux 上传 job 不在被 Release 调用时运行。
- `workflow_dispatch` 只构建候选产物；无 tag ref 不执行 publish，也不创建 Release。

## 4. runner 说明

| Runner | 用途 | 备注 |
|---|---|---|
| windows-2022 | x64 构建 | - |
| windows-11-arm | ARM64 构建 | 公开仓库免费原生 ARM runner |
| ubuntu-latest | Android + publish、ci.yml、conformance.yml、ohos-ci.yml | - |
| macos-latest | macOS DMG、apple-ci.yml | arm64；x265 NASM 汇编仅 x86，arm64 上关闭 |

iOS 使用 `xcode-27` + 显式 Xcode 27.1；Linux 使用 `ubuntu-22.04`。Xcode 预览 runner 的容量/排队问题需要单独记录，不用旧 SDK 构建替代 Duo 版本。

## 5. 修改 workflow 的纪律

- release.yml 改动先在 fork/手动 dispatch 验证再上主分支（每次失败都烧 runner 时间）
- 资产 path 声明与命名拼接必须同步改
- 承诺交付的平台必须参与 publish gate；Windows ARM64 是非阻塞实验例外，不应把该例外扩展到 iOS 或 Linux。
- 但 publish 的 `needs` 必须列全（否则产物可能缺席，见上）
