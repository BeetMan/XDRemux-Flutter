# 当前开发状态（2026-10-25）

> 读者：接手项目的开发者 / agent。用途：给出**可提交、可审计**的现状快照，替代只存在于本机、被 gitignore 的 `docs/plans/current-handoff.md`。
> 更新时机：发版后、主线合并后、方向决策后。每次更新在标题保留日期，历史版本进 `docs/archive/`。
> 断言遵循 `docs/style-guide.md` §3：已实测 / 推断 / 未验证。

## 1. 版本与发布

| 项 | 状态 | 依据 |
|---|---|---|
| Flutter 跨平台版 | **0.4.5（0.4.5+39）已发布** | `README.md:13`、`apps/flutter/pubspec.yaml:5`、`tools/installer/RELEASE_NOTES_v0.4.5.md` |
| 鸿蒙原生版（ArkUI） | **0.5.2 已发布**（独立标签 `harmony-v0.5.2`、独立 HAP） | `README.md:13-19`；详细过程见 `docs/plans/harmony-native.md`（本地文件） |
| 0.4.5 内容 | JPEG HDR / ICC 色彩修复、iPhone Duo 布局、Apple HDR 缩略图黑图修复、Linux 桌面预览 | `tools/installer/RELEASE_NOTES_v0.4.5.md` |
| 平台范围 | Windows x64、macOS Apple Silicon、Android arm64、iOS（未签名）、Linux x64（预览）、HarmonyOS Flutter（未签名） | `README.md:19-30` |
| 明确不提供 | Windows ARM64 安装包、Intel Mac 转换、Flutter Linux 托盘 | `README.md` 对应段落 |

> 六平台候选包的验收发生在 2026-10-24~25 的发版流程中（提交 `7484f018`、`c0cf1228`、`408fd3ce`）。**本文未复核发版原始日志**，属于「推断」；需要百分百确认时查对应 release 的 CI run 与安装记录。

## 2. 分支地图

| 分支 | 相对 `origin/main` | 状态 | 说明 |
|---|---|---|---|
| `main` | — | 稳定 | 0.4.5 发版后基线 |
| `codex/local-transfer` | +24 提交 | **在飞（大改）** | 设备间互传；新增 `crates/xdremux-transfer/`（vendor LocalSend）、改 17 个 Rust 文件与 `apps/flutter/lib/services/transfer/`。合并前不要动 `lib.rs` FFI 与 `services/` |
| `feat/harmony-native` | +98 提交 | **在飞** | 鸿蒙 ArkUI 原生工程，独立 bundle；与 Flutter 共用 Rust 核心（`.so` 需重建） |
| `codex/iso21496-write-validation` | +1 提交（PR #15） | 待合并 | ISO 21496-1 写入端逐通道增益范围校验 |
| `codex/docs-style-guide-and-styles-gap` | +2 提交 | 文档（PR） | 本快照、写作规范 `docs/style-guide.md`、Styles 上游差距分析 |
| `codex/apple-cinematic` | 停在 2026-10-11 | 冻结 | 需要决策：复活或废弃（当前只写待处理元数据，非完整电影效果） |
| `research/oppo-gallery-17.10` | +4 提交（文档） | 归档级 | OPPO 相册 17.10 机制研究记录 |
| 其余 `codex/*`、`release/*` | ahead=0 | 已合并 | 可清理 |

## 3. 能力现状（主线）

| 能力 | 状态 | 备注 |
|---|---|---|
| ProXDR → ISO 21496-1 HDR HEIC（UHDR/LHDR） | 可用 | 两种输出模式：OPPO 兼容 / Apple 标准 |
| OPPO / 华为人像转换 | 可用（条件受限） | 依赖源文件深度数据与系统版本 |
| Photographic Styles 写入 | **实验性** | native 路径的 `styleData` 为 identity、缩略图为真实生成（失败回退黑帧）、天空蒙版为零值占位；见 `docs/modules/styles-pipeline.md`、`styles_native.rs` |
| Texture Styles（Standard 注入） | 可用 | `texture_styles.rs`；与上游 `#70` 同行但更早落地 |
| Motion Photo → Live Photo | 可用 | 配对谓词 `existing_pair_is_valid`（`live_photo.rs:1790`）、FFI `xdremux_live_photo_pair_valid`、恢复时校验（`main.dart:440`） |
| 队列 / 检查点恢复 / 分类输出 | 可用 | 见 `docs/app/workflow-design.md` |
| Cinematic 元数据 | 实验性/冻结 | `codex/apple-cinematic` 两周未动 |

## 4. 已知风险与未验证项

1. **Styles native 路径不是逐像素等价**：`styleData` 为 identity，天空分割待 R4；目标只是"Apple 照片可继续编辑"，不是原生画质。**未验证**：全量样本在最新 iOS 上的编辑入口一致性。
2. **线性缩略图为 8-bit 4:2:0**（`linear_thumbnail.rs` 头注释），原生为 10-bit；上游 10-15 起改用 Apple Log 编码 + 全分辨率线性重建，我们尚未跟（待决策，成本含 10-bit x265 五平台构建）。
3. **Live Photo 发布校验只在检查点恢复路径**；转换成功当次没有"立即校验 + 半成品回滚 + 独立恢复副本"（上游 #76/#78 的后半段）。
4. **本机 Windows 无法跑全量 Rust 测试**：`zstd-sys` 的 C 构建把 GNU 风格参数传给 MSVC（`cc 1.4.0` + VS 18 / MSVC 14.51），属既有环境问题；本地验证只能依赖 CI 或模块级独立工程。
5. **CI 只覆盖 Ubuntu + Flutter**（`.github/workflows/ci.yml`）：Windows/macOS 原生行为、真机 Photos 验收不在 CI 内。
6. **鸿蒙原生版与 Flutter 版共用 Rust 核心**：任何 `xdremux/rust` 改动合入后需要重建鸿蒙 `.so` 并复测。

## 5. 下一步优先级

1. 合并 PR #15（ISO 写入端校验），确认 Linux CI 全绿。
2. `codex/local-transfer` 合并前做一次独立 review：FFI 边界、断网/中断/跨平台路径、与现有 checkpoint 的交互。
3. 决定 Styles 方向：读 `docs/research/styles-upstream-20261024-gap.md` 后选「跟 / 只跟缩略图 / 暂不跟」。
4. 决定 cinematic 分支去留。
5. 修好本机 Rust 工具链（或固化"用 CI 验证"的流程），降低后续每项改动的验证成本。

## 6. 常用验证命令

```bash
# Rust 单元/集成测试（需可用的 C 工具链与 x265）
cargo test -p xdremux-core --lib
# 全仓（CI 同款）
cargo test --workspace
# Flutter
cd apps/flutter && flutter analyze && flutter test
# 对拍
cargo run -p xdremux-conformance -- --help   # 见 docs/testing/conformance-suite.md
```

## 7. 相关文档

- 写作与证据规范：`docs/style-guide.md`
- 仓库布局与数据流：`docs/architecture/overview.md`、`docs/architecture/data-flow.md`
- 平台行为矩阵：`docs/validation/platform-behavior-matrix.md`
- 发版流程：`docs/operations/releasing.md`
- 上游对比（Styles）：`docs/research/styles-upstream-20261024-gap.md`

## 8. 不适用条件

- 本文是**时间点快照**：分支领先数、CI 状态、版本号会变化，超过约两周即应重写而不是续改。
- 本文不替代真机验收记录：平台行为以 `docs/validation/` 与 release 记录为准。
- 本文不包含任何会话内隐私信息（本机绝对路径、账号、令牌）。
