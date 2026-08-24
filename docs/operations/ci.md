# CI 剖析

> 三个 workflow：`.github/workflows/ci.yml`（日常）、`conformance.yml`（一致性）、`release.yml`（发版，见 `operations/releasing.md`）。

## 1. ci.yml（push/PR 日常）

- Rust 核心：`cargo build` + `cargo test`（Windows/Linux 矩阵；`-D warnings` 严格模式）
- Flutter analyze（容忍既有的 info 级 lint）
- 关键点：CI 无 x265 vendor 时走 ffmpeg fallback cfg（`drop_parameter_nals` 等条件编译是为无 x265 环境准备的）；**CI 上不能验证色彩行为**（fallback 无范围控制）

## 2. conformance.yml

- `tests/conformance` crate 构建 + 合成样本对拍（bplist / scaffold / styles 常量等纯逻辑）
- 金样语料不入库，CI 只跑无样本路径（见 `testing/conformance-suite.md`）

## 3. release.yml（tag 触发）

Job 结构与缓存策略：

- **x265 缓存**：`x265-windows-<tag>-asm` 按 ref 作用域缓存；ref 缓存 miss 时回退 main 分支缓存（避免每次 release 重编 x265）
- **版本解析**：pubspec `^version:` 正则 -> TAG_VERSION -> 资产命名
- **Windows**：NASM 安装 -> x265 -> Rust -> Flutter -> Inno Setup（`BuildArch` 参数）
- **Android**：SDK 36 约束（runner 无 API 37）+ JVM target 分插件对齐已固化在构建脚本
- **publish job**：汇集 dist/ 下各产物挂到 Release；不生成/覆盖 Release 文案

## 4. runner 说明

| Runner | 用途 | 备注 |
|---|---|---|
| windows-2022 | x64 构建 | - |
| windows-11-arm | ARM64 构建 | 公开仓库免费原生 ARM runner |
| ubuntu-latest | Android + publish | - |

macOS runner 待用（DMG 纳入 CI 的 backlog）。

## 5. 修改 workflow 的纪律

- release.yml 改动先在 fork/手动 dispatch 验证再上主分支（每次失败都烧 runner 时间）
- 资产 path 声明与命名拼接必须同步改
- 新增 job 默认不阻塞 publish（参考 `d85ffea`：Windows ARM 失败不应卡住其他平台发布）
