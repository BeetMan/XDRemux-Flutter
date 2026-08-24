# 一致性测试套件（conformance）

> 代码：`tests/conformance/`（独立 crate，不进发布产物）。CI：`.github/workflows/conformance.yml`。
> 原则：**用户照片与金样永不入库**；本地样本驱动的测试在 `xdremux/rust/tests/local_samples.rs`（样本缺失时自动跳过）。

## 1. 套件定位

跨实现对拍（cross-implementation conformance）：Rust 移植行为 vs Swift 上游参照（XDRemux）。用途：

1. 移植正确性回归（数值容差 1e-6 级）
2. 输出结构合法性（box 级 diff）
3. 新样张的格式逆向辅助

## 2. 子命令（main.rs）

| 命令 | 输入 -> 输出 | 作用 |
|---|---|---|
| `inspect <input.heic> <out.json>` | 源文件 -> 规范 JSON | LHDR/UHDR 元数据 + 将产出的 tmap 载荷描述 |
| `compare <a.json> <b.json> [--tolerance 1e-6]` | 两份 inspect | Markdown 差异报告（数值带容差） |
| `dump <output.heic> <out.json>` | 输出文件 -> 规范 JSON | ISOBMFF box 结构（Tier 3） |
| `compare-dump <a.json> <b.json>` | 两份 dump | 结构差异报告 |

内部模块：`convert` / `scaffold` / `styles_native` / `styles_graft` / `portrait` / `portrait_depth` / `seg` / `bplist` / `json` --与 Rust 核心同名模块一一对应的对拍逻辑，另有 `*_consts.rs` 共享常量。

## 3. 金样语料（golden corpus）

`tools/golden_corpus.sh <sample-dir> <out-dir>` 从本地样本目录再生成参照输出：

```
standard/<name>.heic        Swift 标准 HDR 输出
styles/<name>.heic          风格输出（约束求解）
styles-identity/<name>.heic 风格输出（identity 回退）
debug/<name>/...            每样本调试转储（scene bundle、mattes、styleData、bplist）
inventory/<name>.{std,styles}.json  conformance dump
```

依赖：上游 XDRemux 构建（自动从 Xcode SPM 缓存探测）、zstd CLI。金样不入 git，按需重建。

## 4. CI 集成

- conformance workflow 跑无样本路径：编译检查 + 合成样本测试（bplist/scaffold 等纯逻辑对拍）
- 注意过的历史坑：CI 上 `drop_parameter_nals` cfg、`CommandExt`（Windows only import）、`-D warnings`、未使用 import

## 5. 加用例的流程

1. 纯逻辑（容器/bplist/常量）：直接在 conformance 加对拍模块
2. 需要真实样本：先跑 `golden_corpus.sh` 生成参照，测试代码走 `local_samples.rs` 的"样本缺失即跳过"模式
3. 探针先行：复杂行为先写 `xdremux/rust/examples/` 探针（styles_diag 等），验证后再固化为测试
