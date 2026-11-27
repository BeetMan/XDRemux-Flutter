# CI 剖析

> 九个 workflow：`.github/workflows/ci.yml`（日常）、`conformance.yml`（一致性）、`apple-ci.yml`（原生 SwiftUI 应用）、`apple-vt-core.yml`（VideoToolbox 后端内核测试）、`ohos-ci.yml`（鸿蒙 Rust 冒烟）、`harmony-native-ci.yml`（鸿蒙原生宿主回归）、`transfer-ci.yml`（局域网互传库）、`linux.yml`（Linux PR / 可复用构建）、`release.yml`（发版及只构建预检，见 `operations/releasing.md`）。
> 只有 `ci.yml` 对每个 PR 都跑；其余都带路径过滤，改到相关目录才触发。改了 FFI 导出的 Rust PR，合并前在 Mac 上跑 `tools/apple/verify_local.sh`，因为 `apple-ci.yml` 在 PR 上只认 Apple 路径（PR #101 为省 macOS runner 定的规则）。

## 1. ci.yml（push/PR 日常）

- 触发：push 到 `main` 与所有 PR，无路径过滤。
- Rust 核心：Ubuntu 上构建 x265 并执行 workspace tests；不等同于全平台安装包验证。
- Flutter analyze（容忍既有的 info 级 lint）
- Flutter job 的 FFI 冒烟库显式使用 FFmpeg fallback；Rust job 和各平台正式构建仍使用 x265。合成自动测试不替代私有原图或目标图库的色彩验收。
- Apple SDK 守卫的模拟工具回归测试在 Ubuntu 执行；真正的 Duo SDK/API typecheck 在 iOS 构建 runner 上执行。
- Android APK ABI/ELF/CRC 门禁有合成包回归测试；发包 job 另检查真实 APK，必须只有 ARM64 且包含匹配架构的 Rust、Flutter、AOT 和 C++ 运行库。
- 已提交的 `xdremux_core.h` 与 cbindgen 输出的一致性也在这里校验；改导出没重新生成头文件会在这一步失败。

## 2. conformance.yml

- 触发：push 到 `main` 或 PR 到 `main`，路径限定 `xdremux/rust/**`、`tests/conformance/**`、`Cargo.toml`、`Cargo.lock`；可手动 dispatch。
- `tests/conformance` crate 构建 + 合成样本对拍（bplist / scaffold / styles 常量等纯逻辑）
- 金样语料不入库，CI 只跑无样本路径（见 `testing/conformance-suite.md`）
- fixture 门禁测试（14 个上游 Motion Photo fixture 对拍）在 fixtures 缺失时优雅跳过（`require_fixtures()` 守卫，2026-09 修）

## 2.4 apple-ci.yml（原生 Apple 应用）

- 触发：push 到 `main` 只看 `xdremux/rust/**`；PR 看 `apps/apple/**`、`tools/apple/**`、`xdremux/rust/build_apple.sh`、`xdremux/rust/include/**` 或本 workflow；也可手动 dispatch。
- 单 job，`macos-latest`：构建 x265（按 `X265_TAG` 缓存）→ `tools/apple/check_header.sh` 校验已提交的 `xdremux_core.h` 与 cbindgen 输出一致 → `XDREMUX_APPLE_SLICES=macos xdremux/rust/build_apple.sh` 只构建 macOS 切片的 `XDRemuxCore.xcframework` → `apps/apple/Packages/XDRemuxKit` 下 `swift test` → 构建 `xdremux` CLI 并冒烟（`--version`、`capabilities`、随机字节 `inspect` 必须失败）→ `xcodegen generate` + `xcodebuild` 构建未签名的 macOS Debug App。
- **不覆盖**：iOS 切片与 iOS 模拟器（本地用 `build_apple.sh` 的 `ios-sim` 切片，见 `apps/apple/README.md`）、签名、真机照片 App 验收。原生 Apple 应用尚未进入 `release.yml`。
- 改了 FFI 导出却没重新生成头文件时，本 workflow 在 header 检查一步失败。

## 2.5 ohos-ci.yml（鸿蒙）

- 触发：任意分支 push，路径限定 `xdremux/rust/**`、`tools/ohos/**` 或本 workflow；可手动 dispatch。
- 范围**只做 Rust 核心冒烟**：公开 SDK 上 `build_ohos.sh` 构建 `libxdremux_core.so`，`file` 核对产物（`ubuntu-latest`）
- 完整 hap 出包不上 CI：hvigor 工具链为 DevEco 环境设计，公开 SDK 走不通；签名也是本地 DevEco 的事
- 真机验证靠本地（hdc + uitest 自动化）

## 2.6 apple-vt-core.yml（VideoToolbox 后端内核）

- 触发：push 到 `main` 只看 `xdremux/rust/**`；PR 只看 `xdremux/rust/src/hevc/vt.rs`、`xdremux/rust/src/vt_hevc.c` 或本 workflow；可手动 dispatch。
- 单 job，`macos-latest`，`XDREMUX_HEVC_BACKEND=videotoolbox` 下跑内核测试；另一步确认只编 VideoToolbox 的库里没有 x265 的痕迹（静态链接的 x265 目标代码不得混入）。
- 只在 Apple 目标上存在这个后端（`hevc/mod.rs` 模块注释），其他平台的 VideoToolbox 路径由 Flutter / SwiftUI 的真机验收覆盖，不在 CI 内。

## 2.7 harmony-native-ci.yml（鸿蒙原生宿主回归）

- 触发：push 或 PR，路径限定 `apps/harmony/**` 或本 workflow；可手动 dispatch。PR #126 把原生工程并入 `main` 时新增。
- 单 job，`ubuntu-latest`，不碰 DevEco / hvigor：
  - Node 24 以 `--experimental-strip-types` 逐个跑 `apps/harmony/tests/*.mjs`（队列控制器、持久化、设置、互传收件箱、动态照片与 Live Photo 配对模型等确定性回归）；
  - `python -m unittest apps.harmony.tests.hap_verifier_test` 校验 HAP 检查工具；
  - `g++ -std=c++20 -Wall -Wextra -Werror` 编译并运行 `apps/harmony/tests/ps3_pipeline_test.cpp`。
- **不覆盖**：ArkTS 编译、N-API 桥、真机 picker / 导出 / 相册行为，这些仍是 `apps/harmony/BUILDING.md` 里的本地签名机清单。

## 2.8 transfer-ci.yml（局域网互传库）

- 触发：push 到 `main` 或 `codex/local-transfer`、PR、手动 dispatch；路径限定两个传输 crate（`crates/xdremux-transfer/**`、`crates/xdremux-transfer-ffi/**`）、`tools/native/build-transfer.*`、`tools/apple/embed_transfer.sh`、`.github/scripts/transfer-ci.ps1`、`apps/flutter/lib/**`、`apps/flutter/test/**`、`apps/flutter/tool/transfer*`、`apps/flutter/pubspec*` 与本 workflow。
- `windows`（`windows-latest`）：跑 `.github/scripts/transfer-ci.ps1` 的传输门禁，保留报告与诊断日志（Windows ↔ 安卓 / 官方 LocalSend 互通的真机记录见 `testing/local-transfer-*.md`，不在这里）。
- `unix`（矩阵 `ubuntu-22.04`、`macos-latest`）：Rust 测试、format、clippy；构建本平台库；macOS 另构建 iOS framework；用回环 HTTPS 跑 worker 冒烟。
- `ohos`（`ubuntu-latest`）：公开 OpenHarmony SDK 下构建 OHOS 传输库。
- 传输 crate 固定 Rust 1.97.1（`crates/*/rust-toolchain.toml`），与内核的 workspace 测试分开。

## 2.9 linux.yml（Linux 桌面）

- 两种身份：`workflow_call` 供 `release.yml` 复用（输入 `version`）；PR 到 `main` 时按路径（`apps/flutter/**`、`xdremux/rust/**`、`Cargo.*`、`tools/linux/**`、本 workflow）独立构建；也可手动 dispatch（输入 `version`、`attach_release_tag`）。
- 构建在 `ubuntu-22.04`（AppImage / tar.gz，见 `operations/building.md` 的 Linux 小节）；独立上传 job 只在带 `attach_release_tag` 的 dispatch 下运行，被 Release 调用时不跑。
- Linux 仍是预览平台：通过构建不等于桌面功能完整验收。

## 3. release.yml（tag 触发）

Job 结构与缓存策略：

- **x265 缓存**：`x265-windows-<tag>-asm` 按 ref 作用域缓存；ref 缓存 miss 时回退 main 分支缓存（避免每次 release 重编 x265）
- **版本解析**：pubspec `^version:` 正则 -> TAG_VERSION -> 资产命名
- **Windows**：NASM 安装 -> x265 -> Rust -> Flutter -> Inno Setup（`BuildArch` 参数）
- **Android**：SDK 36 约束（runner 无 API 37）+ JVM target 分插件对齐已固化在构建脚本；JDK 用 Temurin 21（PR #124：AGP 9.3.1 自带的 lint 32.3.1 调用 JDK 21 才有的 `List.removeLast()`，JDK 17 下 `lintVitalAnalyzeRelease` 崩溃；退回 17 需 AGP ≥ 9.3.2，见 `operations/releasing.md` §4）
- **macOS / iOS**：内核以 `XDREMUX_HEVC_BACKEND=videotoolbox+x265` 编入两个 HEVC 后端（PR #116）；构建后分别用 `otool -L` / `strings` 与 `nm` 核对产物同时含 VideoToolbox 与 x265，再用 `grep` 扫 Dart 绑定里的每个 `xdremux_*` 符号（PR #123 把正则放宽到含数字的名字）
- **publish job**：汇集 dist/ 下各产物挂到 Release；不生成/覆盖 Release 文案；`needs` 必须包含全部构建 job（`[windows, windows-arm64, android, macos, ios, linux]`；曾因漏 needs 导致 pre.2 缺 ARM64 包，`0eb097b` 修）
- **windows-arm64**：`continue-on-error: true`，只做实验性构建、不出安装包，失败不阻断 publish（与 README「不提供 Windows ARM64 安装包」一致）
- 鸿蒙 hap 不进 release.yml：本地构建（Windows `tools/ohos/build_hap.ps1`，macOS `tools/ohos/build_hap.sh`，见 `operations/building.md`）后手动挂资产；两个脚本会先核对 `libxdremux_core.so` 导出了 Dart 绑定查到的每个 FFI 符号，核心比绑定旧就直接失败（PR #123）
- iOS 使用 `xcode-27`，显式选择 Xcode 27.1，先检查 SDK/API，再构建归档和校验 FFI；不降级 Duo 功能来适配旧 SDK。
- Linux 通过 `linux.yml` 的 `workflow_call` 构建，与四个既有平台一起参与 publish 成功和附件存在性门禁；保持预览平台标记。独立 Linux 上传 job 不在被 Release 调用时运行。
- `workflow_dispatch` 只构建候选产物（`platforms`：`all` / `ios` / `android`）；无 tag ref 不执行 publish，也不创建 Release。Flutter 发版前的全平台预检就是 `platforms=all` 的 dispatch。

## 4. runner 说明

| Runner | 用途 | 备注 |
|---|---|---|
| windows-2022 | release.yml Windows x64 | - |
| windows-11-arm | release.yml Windows ARM64 实验 | 公开仓库免费原生 ARM runner |
| windows-latest | transfer-ci.yml `windows` | - |
| ubuntu-latest | release.yml Android + publish、ci.yml、conformance.yml、ohos-ci.yml、harmony-native-ci.yml、transfer-ci.yml `ohos`、linux.yml 上传 job | - |
| ubuntu-22.04 | linux.yml 构建、transfer-ci.yml `unix` 的 Linux 项 | README 的 Linux 预览包要求 glibc ≥ 2.35（Ubuntu 22.04+） |
| macos-latest | release.yml macOS DMG、apple-ci.yml、apple-vt-core.yml、transfer-ci.yml `unix` 的 macOS 项 | arm64；x265 NASM 汇编仅 x86，arm64 上关闭 |
| xcode-27 | release.yml iOS | 显式选 Xcode 27.1 |

iOS 使用 `xcode-27` + 显式 Xcode 27.1；Linux 使用 `ubuntu-22.04`。Xcode 预览 runner 的容量/排队问题需要单独记录，不用旧 SDK 构建替代 Duo 版本。macOS runner 紧张是 PR #101 收紧 `apple-ci.yml` / `apple-vt-core.yml` 触发路径的原因；再加需要 macOS 的 job 前先确认是否真能省掉。

## 5. 修改 workflow 的纪律

- release.yml 改动先在 fork/手动 dispatch 验证再上主分支（每次失败都烧 runner 时间）
- 资产 path 声明与命名拼接必须同步改
- 承诺交付的平台必须参与 publish gate；Windows ARM64 是非阻塞实验例外，不应把该例外扩展到 iOS 或 Linux。
- 但 publish 的 `needs` 必须列全（否则产物可能缺席，见上）
- 新增 workflow 时同步更新本页首行的清单与 §4 的 runner 表
