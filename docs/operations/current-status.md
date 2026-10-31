# 当前开发状态（2026-10-31）

> 读者：接手项目的开发者 / agent。用途：给出**可提交、可审计**的现状快照，替代只存在于本机、被 gitignore 的 `docs/plans/current-handoff.md`。
> 更新时机：发版后、主线合并后、方向决策后。每次更新在标题保留日期，历史版本进 `docs/archive/`（上一版：[`archive/current-status-20261029.md`](../archive/current-status-20261029.md)）。
> 断言遵循 `docs/style-guide.md` §3：已实测 / 推断 / 未验证。
> 2026-10-31：v0.4.6 与鸿蒙原生 0.5.3 发版、GPL-3.0-only 改授权（PR #54）、原生 SwiftUI Apple 前端进入主线（PR #52）后重写。分支计数基准 `origin/main` = `8385138`。

## 1. 版本与发布

| 项 | 状态 | 依据 |
|---|---|---|
| Flutter 跨平台版 | **0.4.6（0.4.6+40）已发布**（2026-10-31，GitHub Latest） | `apps/flutter/pubspec.yaml:5`、标签 `v0.4.6`、`tools/installer/RELEASE_NOTES_v0.4.6.md` |
| 鸿蒙原生版（ArkUI） | **0.5.3 已发布**（2026-10-31，独立标签 `harmony-v0.5.3`、独立 HAP） | `README.md:13`；过程记录在 `feat/harmony-native` 分支的 `docs/plans/harmony-native.md` |
| 原生 Apple 版（SwiftUI） | **未发布**，在 `main` 的 `apps/apple/` 开发，P0–P2 与 P3 三批已完成 | `apps/apple/README.md`、`docs/plans/apple-native.md` |
| 0.4.6 内容 | Live Photo `.pvt` 包（默认开启）、摄影风格 2/3 与实况同时使用的编辑修复（MOV 风格伴随轨道）、安卓 AAC 实况音频修复、风格 HDR 缩略图（Log + 增益图，Android/iOS/鸿蒙 10-bit）、每图 GTC 拟合 + Standard key 1 identity、MPF 无增益图 JPEG 按 SDR、iPhone Duo 安全区 | `tools/installer/RELEASE_NOTES_v0.4.6.md` |
| 平台范围 | Windows x64、macOS Apple Silicon、Android arm64、iOS（未签名）、Linux x64（预览）、HarmonyOS Flutter（未签名） | `README.md` 下载表 |
| 明确不提供 | Windows ARM64 安装包（`release.yml` 中 `continue-on-error` 实验构建）、Intel Mac 转换、Flutter Linux 托盘 | `README.md`、`docs/operations/ci.md` §3 |
| 许可 | **GPL-3.0-only**（PR #54，10-31）；对 v0.1.0–v0.4.6 与 `harmony-v*` 历史标签额外授予 GPL-3.0-only，原 MIT 授权不撤回 | `LICENSE`、`LICENSING.md` |

> 0.4.6 真机验收：维护者在 macOS 27.2「照片」与 iPhone 16e 上确认摄影风格、摄影风格 3 + 实况编辑（`b81dbbc`）；iPhone Duo 折叠屏只在模拟器验证（**未验证**真机）。本文未复核各平台 release CI run，六平台产物齐全属于「推断」。

## 2. 分支地图

> 基准 `origin/main` = `8385138`（2026-10-31）。「ahead / behind」相对该基准；「冲突」为 `git merge-tree --write-tree --name-only origin/main <分支>` 的冲突文件（已实测）。

### 2.1 可合

| 分支 | ahead / behind | 冲突 | 说明 |
|---|---|---|---|
| `feat/license-notices`（PR #55 open） | +1 / −0 | 0 | #54 的后续：设置页「开源许可」入口（`LicenseRegistry` 注册 GPL-3.0 与 x265 GPL-2.0 文本）、Windows / macOS / Linux 安装包附带 `LICENSE` 与 `LICENSING.md`。PR CI（Rust、Flutter、Linux、conformance）通过；安装包改动只在 `release.yml` 中运行，需一次预检 |

### 2.2 在飞（大改）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `codex/local-transfer`（PR #29 open） | +40 / −54 | 10-30 | 0 | 设备间互传（vendor LocalSend），独立 crate `crates/xdremux-transfer*` + Flutter UI + Windows CI 门禁，不改 `xdremux/rust` 核心与 FFI。GitHub 显示 MERGEABLE；落后 main 54 个提交（含 0.4.6 全部改动），合并前应再 merge main 并重跑 CI。剩 Android 导出与 macOS/iOS 设备互通真机实测（**未验证**） |
| `feat/harmony-native` | +112 / −8 | 10-31 | 1 文件（`README.md`） | 鸿蒙 ArkUI 原生工程，0.5.3 已发。长期分支，定期 merge main，不并回 main；与 Flutter 共用 Rust 核心，同步后需重建 `.so` 并复测 |

### 2.3 研究分支（不直接合并）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `research/iphone-next` | +35 / −85 | 10-29 | 1 文件（`styles_bplist.rs`） | 皮肤 / Texture Style person 数据。10-29 `cdf13b7` 把 FSINC instance mask 按 Apple 做法链接为辅助图，`1910576` 记录 `c630b93` 已验证为容器损坏的修复。长期分支，不并回 main（锁文件已回到镜像源） |

### 2.4 已定进产品、暂缓接入

10-29 决定：两者都**进产品**，现阶段不动。接入时各自另开会话，先 merge main，再定包体（M9 带 MB 级二进制 assets）与法务处理（注意：项目已改 GPL-3.0-only，接入前需确认 assets 与工具链的许可兼容）。

| 分支 | ahead / behind | 冲突 | 说明 |
|---|---|---|---|
| `feat/oppo-filter-ecosystem` | +1 / −113 | 1 文件（`.gitignore`） | `.MS-LUT`↔`.cube` 编解码 + ColorOS `filter.info` 注入 + Hasselblad 管线归档 |
| `feat/m9-moment` | +1 / −113 | 5 文件（`main.dart`、`app_models.dart`、`xdremux_service.dart`、`docs/README.md`、`lib.rs`） | 小米 17 Ultra 徕卡 Moment M9 引擎 + QNN/Chromatix RE 工具链 |

### 2.5 已合并、远端分支待删（ahead = 0）

`chore/license-gpl3`、`docs/release-046`、`release/0.4.6-prep`、`feat/apple-native-ios`、`feat/pvt-default`、`feat/styles2-live`、`feat/live-photo-styles-mov`、`fix/live-photo-aac-qt`、`fix/main10-stride`、`chore/styles-toggle-copy`。全部已并入 `main`，可删除远端分支（本机对应 `wt-*` worktree 一并清理）。

### 2.6 已归档

10-29 已删分支保留的 `archive/*` 标签（`archive/integrate/find-next`、`archive/research/find-next`、`archive/integrate/huawei-portrait-live`）见上一版 §2.5。恢复：`git push origin archive/<name>:refs/heads/<name>`。

### 2.7 pub 源（已定：镜像）

主线统一使用 `pub.flutter-io.cn` 镜像 + 锁文件；CI 设置 `PUB_HOSTED_URL` 并 `flutter pub get --enforce-lockfile`（`59e493e`）。本地同样设置该变量（`tools/env.sh` 已默认），否则默认的 `pub.dev` 会改写全部 hosted url。

## 3. 能力现状（主线）

| 能力 | 状态 | 备注 |
|---|---|---|
| ProXDR → ISO 21496-1 HDR HEIC（UHDR/LHDR） | 可用 | 两种输出模式：OPPO 兼容 / Apple 标准；ISO 写入端校验拒绝反向增益范围（`69b80d5`） |
| UHDR JPEG（MPF） | 可用 | 单图 MPF 无增益图按 SDR 处理（`4461e40`） |
| 线性缩略图（Apple Log + 原生几何 + HDR 增益图 + 可选 Main10） | 可用 | Android / iOS / 鸿蒙发布包为 10-bit；macOS 发布包仍 8-bit。Main10 行步长 bug（`7721321`，未进入任何发布）已修，`xdremux_encode_10bit_planes_checked` 回读 PSNR 防回归；见 `docs/modules/styles-pipeline.md` §4 |
| Photographic Styles 写入 | **实验性**（0.4.6 已真机验收可编辑） | key 3（GTC）每图拟合；Standard key 1 固定 identity（PR #38，避免 Photos 色格）；key 4/h、统计、天空蒙版仍为参考值/零值占位 |
| Texture Styles（摄影风格 3） | 可用 | `texture_styles.rs` |
| OPPO / 华为人像转换 | 可用（条件受限） | 依赖源文件深度数据与系统版本 |
| Motion Photo → Live Photo | 可用 | 配对谓词 `existing_pair_is_valid`、FFI `xdremux_live_photo_pair_valid`；安卓 AAC 音频写为 QuickTime 声音描述（`879c67e`） |
| 风格 + 实况 | 可用（0.4.6 起） | 静帧带风格 plist 时 `make_live_photo` 调 `live_photo_styles::attach_style_tracks`，向 MOV 追加线性缩略图 auxv、smartstyle-info、live-photo-info 与 matte 伴随轨道（`fba61cb`、`2ea4963`）；摄影风格 2 不再在实况上被剥离（`52399b6`）。`XDREMUX_LIVE_STYLE_TRACKS` 可切级别做消融 |
| Live Photo `.pvt` 包输出 | 可用（**默认开启**，0.4.6） | `live_photo_bundle.rs`；iOS/macOS 直接分享 `.pvt`，其他平台分享 `.pvt.zip`；见 `docs/formats/live-photo-pvt.md` |
| 队列 / 检查点恢复 / 分类输出 | 可用 | 见 `docs/app/workflow-design.md` |
| 原生 Apple 前端（SwiftUI） | 开发中（未发布） | 导入、详情优先转换、HDR 预览、队列 journal 恢复、Motion Photo → Live Photo、OPPO ↔ Apple 往返、真正取消（`xdremux_progress_cancel`）、摄影风格 3 后处理、英文本地化、macOS CLI `xdremux`；iOS 只在模拟器实跑。待做：Share Extension、批量导出、P4 跨端回归与发布 |
| Cinematic 元数据 | 已放弃 | 主线无相关能力 |

## 4. 已知风险与未验证项

1. **Styles native 路径不是逐像素等价**：仅 key 3 按图拟合，key 1 为 identity，key 4/h、统计为参考值，天空分割待 R4。目标是"Apple 照片可继续编辑"，不是原生画质。**未验证**：全量样本在最新 iOS 上的编辑入口一致性。
2. **线性缩略图**：baseline exposure 绝对亮度与「4:2:0 增益图 + Main10 缩略图」组合的 Photos 接受度只在 iPhone 16e 与 macOS 27.2 上做过维护者验收，未按 `docs/testing/styles-hdr-device-checklist.md` 跑完整 S1/S2/S3（orientation 6/3/8）/S7 A/B；旋转样本真实 E2E **未验证**；原生 Apple tmap 文件重编码仍需解 HEVC 增益图（`rust_h265` 仅支持 4:2:0）。
3. **风格实况的 MOV 伴随轨道是按原生 iOS 27 MOV 复刻的**：静帧代替每一帧（不解视频），matte 轨道为空；只验证了 macOS 27.2 / iPhone 16e 编辑不崩溃、保存后实况与颜色保留。其他 iOS / macOS 版本的照片 App 行为**未验证**。
4. **Live Photo 发布校验只在检查点恢复路径**；转换成功当次没有"立即校验 + 半成品回滚 + 独立恢复副本"（上游 #76/#78 的后半段）。
5. **CI 覆盖**：`ci.yml` 只跑 Ubuntu + Flutter；`apple-ci.yml` 只跑原生 Apple 的 macOS 切片（不含 iOS）；Windows/macOS 原生行为、真机照片验收不在 CI 内。见 `docs/operations/ci.md`。
6. **三个前端共用 Rust 核心**（Flutter、鸿蒙原生、原生 Apple）：`xdremux/rust` 的 FFI 改动需重新生成 `xdremux_core.h`（`apple-ci.yml` 会校验），并重建鸿蒙 `.so` 复测。
7. **许可**：改 GPL-3.0-only 后，应用内与安装包尚未附带许可文本（PR #55 待合）；下一次发版前必须合入。

## 5. 下一步优先级

1. 合并 PR #55（GPL 通知进应用与安装包），并跑一次 `release.yml` `workflow_dispatch` 预检，确认三类安装包里有 `LICENSE` / `LICENSING.md`。
2. 清理 §2.5 已合并分支与对应本机 worktree。
3. PR #29（`codex/local-transfer`）：merge main（落后 54）→ CI → Android 导出与 Apple 设备互通真机实测 → 合并。
4. 原生 Apple 前端：P3 剩余（Share Extension、批量导出）→ iOS 真机签名安装与 Live Photo 声音 / HDR 亮度验收 → P4 跨端回归。
5. 按 `docs/testing/styles-hdr-device-checklist.md` 跑完整真机 A/B（覆盖 §4.2）；之后是 per-image key 4/h（`linear_metadata`）与 P1-3 统计。
6. 评估 macOS 发布包是否启用 10-bit x265。
7. `feat/harmony-native` 同步 main（0.4.6 之后的 Rust 改动）并重建 `.so`。

## 6. 常用验证命令

```bash
# Rust 单元/集成测试（需可用的 C 工具链与 x265）
cargo test -p xdremux-core --lib
# 全仓（CI 同款）
cargo test --workspace
# Flutter
cd apps/flutter && flutter analyze && flutter test
# 原生 Apple（macOS；先构建 xcframework）
XDREMUX_APPLE_SLICES=macos xdremux/rust/build_apple.sh
cd apps/apple/Packages/XDRemuxKit && swift test
# FFI 头文件是否与导出一致
tools/apple/check_header.sh
# 对拍
cargo run -p xdremux-conformance -- --help   # 见 docs/testing/conformance-suite.md
```

## 7. 相关文档

- 写作与证据规范：`docs/style-guide.md`
- 仓库布局与数据流：`docs/architecture/overview.md`、`docs/architecture/data-flow.md`
- 平台行为矩阵：`docs/validation/platform-behavior-matrix.md`
- 发版流程：`docs/operations/releasing.md`；CI：`docs/operations/ci.md`
- Styles 管线：`docs/modules/styles-pipeline.md`；Live Photo 包：`docs/formats/live-photo-pvt.md`
- 原生 Apple 前端：`docs/plans/apple-native.md`、`apps/apple/README.md`
- 上游动向：`docs/research/upstream-20261030.md`

## 8. 不适用条件

- 本文是**时间点快照**：分支领先数、CI 状态、版本号会变化，超过约两周即应重写而不是续改。
- 本文不替代真机验收记录：平台行为以 `docs/validation/` 与 release 记录为准。
- 本文不包含任何会话内隐私信息（本机绝对路径、账号、令牌）。
