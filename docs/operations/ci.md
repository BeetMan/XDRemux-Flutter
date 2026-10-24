# CI 剖析

> 五个 workflow：`.github/workflows/ci.yml`（日常）、`conformance.yml`（一致性）、`ohos-ci.yml`（鸿蒙 Rust 冒烟）、`linux.yml`（Linux PR/可复用构建）、`release.yml`（发版及只构建预检，见 `operations/releasing.md`）。

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
- **publish job**：汇集 dist/ 下各产物挂到 Release；不生成/覆盖 Release 文案；`needs` 必须包含全部构建 job（含 windows-arm64——曾因漏 needs 导致 pre.2 缺 ARM64 包，`0eb097b` 修）
- 鸿蒙 hap 不进 release.yml：本地 `build_hap.ps1` 构建（profile 模式）后手动挂资产
- iOS 使用 `xcode-27`，显式选择 Xcode 27.1，先检查 SDK/API，再构建归档和校验 FFI；不降级 Duo 功能来适配旧 SDK。
- Linux 通过 `linux.yml` 的 `workflow_call` 构建，与四个既有平台一起参与 publish 成功和附件存在性门禁；保持预览平台标记。独立 Linux 上传 job 不在被 Release 调用时运行。
- `workflow_dispatch` 只构建候选产物；无 tag ref 不执行 publish，也不创建 Release。

## 4. runner 说明

| Runner | 用途 | 备注 |
|---|---|---|
| windows-2022 | x64 构建 | - |
| windows-11-arm | ARM64 构建 | 公开仓库免费原生 ARM runner |
| ubuntu-latest | Android + publish | - |

macOS DMG 使用 `macos-latest`；iOS 使用 `xcode-27` + 显式 Xcode 27.1；Linux 使用 `ubuntu-22.04`。Xcode 预览 runner 的容量/排队问题需要单独记录，不用旧 SDK 构建替代 Duo 版本。

## 5. 修改 workflow 的纪律

- release.yml 改动先在 fork/手动 dispatch 验证再上主分支（每次失败都烧 runner 时间）
- 资产 path 声明与命名拼接必须同步改
- 承诺交付的平台必须参与 publish gate；Windows ARM64 是非阻塞实验例外，不应把该例外扩展到 iOS 或 Linux。
- 但 publish 的 `needs` 必须列全（否则产物可能缺席，见上）
