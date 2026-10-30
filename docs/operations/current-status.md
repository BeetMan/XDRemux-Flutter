# 当前开发状态（2026-10-29）

> 读者：接手项目的开发者 / agent。用途：给出**可提交、可审计**的现状快照，替代只存在于本机、被 gitignore 的 `docs/plans/current-handoff.md`。
> 更新时机：发版后、主线合并后、方向决策后。每次更新在标题保留日期，历史版本进 `docs/archive/`。
> 断言遵循 `docs/style-guide.md` §3：已实测 / 推断 / 未验证。
> 2026-10-28：开发机迁移后按最新 `origin/main` 复核并重写；版本号与分支计数以 git 为准。同日按 `fetch --prune` 后的远端重排 §2 分支地图。
> 2026-10-29：清理已合并 / 已替代分支（替代者先打 `archive/*` 标签），记录 M9 / OPPO 滤镜与 `research/iphone-next` 的方向决策，并刷新 §2 计数。

## 1. 版本与发布

| 项 | 状态 | 依据 |
|---|---|---|
| Flutter 跨平台版 | **0.4.5（0.4.5+39）已发布** | `README.md:13`、`apps/flutter/pubspec.yaml:5`、`tools/installer/RELEASE_NOTES_v0.4.5.md` |
| 鸿蒙原生版（ArkUI） | **0.5.2 已发布**（独立标签 `harmony-v0.5.2`、独立 HAP） | `README.md:13-19`；详细过程见 `docs/plans/harmony-native.md`（本地文件） |
| 0.4.5 内容 | JPEG HDR / ICC 色彩修复、iPhone Duo 布局、Apple HDR 缩略图黑图修复、Linux 桌面预览 | `tools/installer/RELEASE_NOTES_v0.4.5.md` |
| 平台范围 | Windows x64、macOS Apple Silicon、Android arm64、iOS（未签名）、Linux x64（预览）、HarmonyOS Flutter（未签名） | `README.md:19-30` |
| 明确不提供 | Windows ARM64 安装包、Intel Mac 转换、Flutter Linux 托盘 | `README.md` 对应段落 |

> 六平台候选包的验收发生在 2026-10-24~25 的发版流程中（提交 `7484f018`、`c0cf1228`、`408fd3ce`）。**本文未复核发版原始日志**，属于「推断」；需要百分百确认时查对应 release 的 CI run 与安装记录。

> 0.4.5 之后、尚未发版的主线增量（2026-10-25~26，`63cf3d2..ca11edd` 共 23 提交）：Apple Log 线性缩略图、可选 x265 Main10、HDR 增益图缩略图与方向对齐、ISO 21496-1 写入校验（PR #15）。能力与缺口见 §3、§4.2。

## 2. 分支地图

> 2026-10-29 按 `git fetch --prune` 后的远端重排（基准 `origin/main` = `fea47f9`）。「ahead / behind」相对该基准；「冲突」是 `git merge-tree --write-tree origin/main <分支>` 模拟合并的冲突文件数（已实测）。

### 2.1 可合

（无。PR #25 Styles HDR 真机验收清单已于 10-28 合并，清单在 `docs/testing/styles-hdr-device-checklist.md`。）

### 2.2 在飞（大改）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `codex/local-transfer`（PR #29 open） | +39 / −4 | 10-29 | 0 | 设备间互传（vendor LocalSend），独立 crate `crates/xdremux-transfer*`（各自 `[workspace]`，Rust 1.97.1）+ Flutter UI + Windows CI 门禁。10-28 rebase 到 main：丢弃已被 main `00a0068`/`074a634` 覆盖的 codec 提交 `3cd3fa7`，跳过与 main 等价的 `877047b`；rebase 后**不改 `xdremux/rust` 核心与 FFI**。macOS 本机：`flutter test` 233 passed / 10 skipped；`xdremux-transfer` 28/28。macOS/BSD 上 `SO_REUSEADDR` 允许在别人占用 `0.0.0.0:P` 时绑定 `127.0.0.1:P`（服务不报 `PortInUse`），已在 `50d5668` 用通配地址探测修复。10-29 按 review 修复上传 / 会话超时、启动时异物阻塞、取消幂等、提交阶段 watchdog、Android 导出空文件等问题（`73f96c1..985b2a1`），`985b2a1` 上 CI 全平台通过；Android Kotlin 改动未在本机编译，设备互通未实测 |
| `feat/harmony-native` | +98 / −44 | 10-25 | 1 文件（`README.md`） | 鸿蒙 ArkUI 原生工程，0.5.2 已发（独立标签）。长期分支，定期 merge main 同步，不并回 main；与 Flutter 共用 Rust 核心，同步后需重建 `.so` 并复测。建议等 PR #29 与 Styles P1 进主线后再同步一次 |

### 2.3 研究分支（不直接合并）

| 分支 | ahead / behind | 最后提交 | 说明 |
|---|---|---|---|
| `research/iphone-next` | +31 / −119 | 10-28 | 皮肤 / Texture Style person 数据（`face_matte`、instance mask、FSINC 布局）。断点：9-25 注入 instance mask 后容器损坏（已排除 10 个假设），9-26 `c630b93` 修了 mime infe，**未验证**是否根治；见 `docs/plans/skin-pipeline-handoff.md`。10-28 两个提交是工具与配置（`dump_item`/`faceloc` probe、pub 源改 `pub.dev`），与 main 冲突 3 文件（`pubspec.lock`、`analysis_options.yaml`、`macos_e2e_test.dart`）。**10-29 决定继续研究**（Apple 照片格式），长期分支、不并回 main；另开会话先撤销 pub.dev 锁文件、同步 main，再验证 `c630b93` |

### 2.4 已定进产品、暂缓接入（单提交、无冲突）

10-29 决定：两者都**进产品**，但现阶段先不动，分支原样保留。接入时各自另开会话，先 merge main，再定包体（M9 带 MB 级二进制 assets）与法务处理。

| 分支 | ahead / behind | 说明 |
|---|---|---|
| `feat/oppo-filter-ecosystem` | +1 / −28 | `.MS-LUT`↔`.cube` 编解码 + ColorOS `filter.info` 注入 + Hasselblad Master/SoftLight/M3 管线归档，29 文件 +6109 |
| `feat/m9-moment` | +1 / −28 | 小米 17 Ultra 徕卡 Moment M9 引擎 + QNN/Chromatix RE 工具链，57 文件 +6517，带 MB 级二进制 assets |

### 2.5 已归档（10-29 删除分支，保留标签）

被主线替代的分支先打注释标签再删除远端分支；恢复用 `git push origin archive/<name>:refs/heads/<name>`。

| 标签 | 最后提交 | 依据 |
|---|---|---|
| `archive/integrate/find-next` | 09-12 | 照片检查 / 单卡转换策略；主线已有详情对话框与双流检查（不同提交实现） |
| `archive/research/find-next` | 09-11 | 停在 v0.4.0-pre.6；10 个提交中 3 个在 main 有 patch 等价提交 |
| `archive/integrate/huawei-portrait-live` | 10-05 | PR #2 已于 09-30 合并；之后的 `3cd3fa7` 已由 main 的 `00a0068` 覆盖 |

### 2.6 已合并 / 已删除

- `codex/prepare-045`、`research/huawei-xmage`：ahead=0，10-29 已删除远端分支。
- `research/oppo-gallery-17.10`：3 个研究文档提交已 cherry-pick 进主线（`docs/research/oppo-gallery-17.10.5.md`）；剩下的 `3cd3fa7` 已由 `00a0068` 覆盖。本 PR 合并后删除该分支。
- `codex/ios-main10`（PR #30）：10-28 已合并。
- `codex/apple-cinematic`：远端已不存在（10-28 `fetch --prune` 后），原「冻结待决策」状态作废。
- `codex/iso21496-write-validation`（PR #15）、`codex/docs-style-guide-and-styles-gap` 已并入 `main`。

### 2.7 pub 源（已定：镜像）

主线统一使用 `pub.flutter-io.cn` 镜像 + 锁文件：`apps/flutter/pubspec.lock` 的 hosted url 全部是镜像；`ci.yml`、`linux.yml`、`release.yml` 都设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 并执行 `flutter pub get --enforce-lockfile`（`59e493e`，2026-10-16）。本地同样设置该变量（`tools/env.sh` 已默认），否则默认的 `pub.dev` 会改写全部 hosted url 并升级依赖。

例外只在未合并分支上：`research/iphone-next` 的 `283bff5`（10-28）把锁文件改成 `pub.dev`，同步 main 前需先撤销。（`research/find-next` 的 `ea340db` 去掉过 CI 镜像，该分支已归档为 `archive/research/find-next`。）

## 3. 能力现状（主线）

| 能力 | 状态 | 备注 |
|---|---|---|
| ProXDR → ISO 21496-1 HDR HEIC（UHDR/LHDR） | 可用 | 两种输出模式：OPPO 兼容 / Apple 标准 |
| 线性缩略图（Apple Log + Main10 + HDR 增益图） | 可用（iOS 10-bit 已接入构建，未上机） | 几何 1024/双偶数契约、Log 曲线、可选 10-bit、内存增益图乘入 scene-linear；见 `docs/modules/styles-pipeline.md` §4 |
| OPPO / 华为人像转换 | 可用（条件受限） | 依赖源文件深度数据与系统版本 |
| Photographic Styles 写入 | **实验性** | 缩略图已按 Log/Main10/HDR 生成；`styleData` key 1 / key 3 已按图拟合（P1-1/P1-2；10-30 macOS 照片实测可导入、风格编辑器正常），key 4/h、统计与天空蒙版仍为参考值/零值占位；见 `docs/modules/styles-pipeline.md` §4.1、`styles_fit.rs` |
| Texture Styles（Standard 注入） | 可用 | `texture_styles.rs`；与上游 `#70` 同行但更早落地 |
| Motion Photo → Live Photo | 可用 | 配对谓词 `existing_pair_is_valid`（`live_photo.rs:1790`）、FFI `xdremux_live_photo_pair_valid`、恢复时校验（`main.dart:440`） |
| Live Photo `.pvt` 包输出 | 可用（默认关闭） | 设置「Live Photo 打包为 .pvt」；`live_photo_bundle.rs`、FFI `xdremux_make_live_photo_bundle` / `xdremux_live_photo_bundle_valid`；10-30 在 macOS「照片」用 AppleScript 导入为单个资产；界面效果和 iPhone/Android 实机待确认，见 `docs/formats/live-photo-pvt.md` |
| 队列 / 检查点恢复 / 分类输出 | 可用 | 见 `docs/app/workflow-design.md` |
| Cinematic 元数据 | 已放弃（分支已删） | `codex/apple-cinematic` 远端已不存在，主线无相关能力 |

## 4. 已知风险与未验证项

1. **Styles native 路径不是逐像素等价**：`styleData` 仅 key 1 / key 3 按图拟合，key 4/h、统计仍为参考值，天空分割待 R4；目标只是"Apple 照片可继续编辑"，不是原生画质。**未验证**：全量样本在最新 iOS 上的编辑入口一致性。
2. **线性缩略图已改为 Apple Log + 原生几何 + 可选 Main10 + HDR 增益（2026-10-25）**：构建期链接了 10-bit x265 静态库时走 16-bit codes → Main10（hvcC bitDepth=10、SPS profile_idc=2，本机与真实样本均已断言）；库缺失时自动回退 8-bit 4:2:0 过渡路径。10-bit 归档已验证：Windows（真实样本 E2E）、Linux（CI 双库构建）、Android arm64（NDK 27 + cargo ndk）、鸿蒙 arm64（DevEco SDK + `build_ohos.sh`）；iOS（真机 + 模拟器）与 macOS 本机的 10-bit 归档于 2026-10-28 构建通过：`build_ios.sh`/`build_ios_sim.sh` 默认构建 10-bit，`build.rs` 把它打包进 `libxdremux_core.a`（staticlib 不吃 link-arg），按 Podfile 参数模拟链接通过；**未在 iOS 真机或模拟器上运行**，macOS 发布包尚未启用 10-bit。**HDR 增益图（路径 3）已落地**：转换管线把内存里的重建增益图直接乘进 scene-linear base，真实样张缩略图 16-bit luma max 35610→46159、mean 21401→26070；增益图方向按写路径规则对齐（EXIF 非 Normal 且主图 `irot==0` 时做同一变换，Normal 样本回归数值不变）。**仍缺**：① 原生 Apple tmap 文件的重编码场景仍需解 HEVC 增益图（`rust_h265` 仅支持 4:2:0）；② baseline exposure 绝对亮度与 HDR 缩略图接受度**未在真机与原生 A/B 验证**（验收清单见 `docs/testing/styles-hdr-device-checklist.md`，PR #25）；③ 旋转样本的真实 E2E 未验证（现有样本 orientation 均为 Normal）。详见 `docs/modules/styles-pipeline.md` §4。
3. **Live Photo 发布校验只在检查点恢复路径**；转换成功当次没有"立即校验 + 半成品回滚 + 独立恢复副本"（上游 #76/#78 的后半段）。
4. **本机 Windows 跑 Rust 测试的两个坑（已解决，2026-10-25）**：① worktree 缺 gitignored 的 `vendor/x265`（`build.rs` 找不到头文件）；② 多 worktree 共用 `target/` 时 `zstd-sys` 的旧 C 产物污染。处理：vendor 用目录联接 + 独立 `CARGO_TARGET_DIR` + vcvars 环境，配方见 `docs/operations/building.md` §1「Windows 本地开发」。**已实测**：`cargo test -p xdremux-core --lib` = 248 passed / 0 failed / 3 ignored。
5. **CI 只覆盖 Ubuntu + Flutter**（`.github/workflows/ci.yml`）：Windows/macOS 原生行为、真机 Photos 验收不在 CI 内。
6. **鸿蒙原生版与 Flutter 版共用 Rust 核心**：任何 `xdremux/rust` 改动合入后需要重建鸿蒙 `.so` 并复测。

## 5. 下一步优先级

1. ~~合并 PR #25~~ **已完成**；按 `docs/testing/styles-hdr-device-checklist.md` 跑 S1/S2/S3（orientation 6/3/8）/S7 真机 A/B —— 这是覆盖 §4.2 的 ②③ 未验证项的唯一闭环手段。
2. Styles 画质下一步（缩略图 P0-1/P0-2 已完成；P1-1 每图 key1 拟合、P1-2 GTC 单调拟合已实现，见 `docs/modules/styles-pipeline.md` §4.1）：macOS 照片已确认接受拟合值（10-30，3 张 OPPO 样张），剩滑块观感与原生的主观 A/B；之后是 per-image key 4/h（`linear_metadata`）与 P1-3 统计。
3. iOS Main10 上机验证：真机或模拟器跑一次 Styles 转换，确认缩略图 hvcC bitDepth=10（构建与链接已完成，见 `docs/operations/building.md` §1）；评估 macOS 发布包是否也启用 10-bit。
4. PR #29（`codex/local-transfer`）：review 发现的问题已于 10-29 修完、CI 全绿；剩 Android 导出与 macOS/iOS 设备互通真机实测，然后合并。
5. 真机确认 baseline exposure 绝对亮度与 Photos 对「4:2:0 增益图 + Main10 缩略图」组合的接受度。
6. ~~决策 M9 / OPPO 滤镜是否进主线~~ **已定（10-29）**：都进产品，暂缓接入，见 §2.4。
7. ~~合并 PR #15（ISO 写入端校验）~~ **已完成**（`69b80d5`）；~~修好本机 Rust 工具链~~ **已完成**：本地可跑全量 `cargo test -p xdremux-core --lib`，配方见 `docs/operations/building.md` §1。

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
- Styles 管线：`docs/modules/styles-pipeline.md`；上游对比：`docs/research/styles-upstream-20261024-gap.md`
- Styles HDR 真机验收：`docs/testing/styles-hdr-device-checklist.md`

## 8. 不适用条件

- 本文是**时间点快照**：分支领先数、CI 状态、版本号会变化，超过约两周即应重写而不是续改。
- 本文不替代真机验收记录：平台行为以 `docs/validation/` 与 release 记录为准。
- 本文不包含任何会话内隐私信息（本机绝对路径、账号、令牌）。

## 附录：上游动向（2026-10-28 观察，只读参考）

项目策略是**只看不并**（上游重构过仓库布局，merge 不可能；见 `docs/plans/roadmap-2026-09-25.md`）。当前上游 `origin/main` 已到 `7aa35f3`（2026-10-27），要点：

- **PR #79 已合**（`72b8302`）：`Sources/XDStylesNative/Styles.m`、`scene_reconstruction.rs`、`scene_guidance.rs`、`display_family.rs`、`reconstruct_styles.rs`、`hdr_look.rs` 进入上游主线，`STYLE_RECONSTRUCTION_METADATA_VERSIONS=[8,9,15,16]` 与 guidance 参数**已固化**。→ 契约可引用，实现仍依赖 dlopen `NeutrinoCore` 私有选择器与 macOS/Metal，不移植。
- **新分支 `codex/hdr-color-management`**（`d300f33`，2026-10-28）：gain map 色彩学与 managed float 重建，与本项目刚落地的 HDR 增益图缩略图同题，保持观察。
- PR #77 cinematic camera estimation 已合；依赖 bump（uuid、rustix）；10-24 起文档双语重写与 CLI 指南。
