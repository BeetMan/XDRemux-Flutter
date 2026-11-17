# 当前开发状态（2026-11-15）

> 读者：接手项目的开发者 / agent。用途：给出**可提交、可审计**的现状快照，替代只存在于本机、被 gitignore 的 `docs/plans/current-handoff.md`。
> 更新时机：发版后、主线合并后、方向决策后。每次更新在标题保留日期，历史版本进 `docs/archive/`（上一版：[`archive/current-status-20261031.md`](../archive/current-status-20261031.md)）。
> 断言遵循 `docs/style-guide.md` §3：已实测 / 推断 / 未验证。
> 2026-11-15：v0.4.7、鸿蒙原生 0.5.4、SwiftUI `apple-v0.1.0` / `apple-v0.1.1` 预发布与 TestFlight、VideoToolbox HEVC 后端（PR #107–#109）、Flutter 3.50（PR #104）合入后重写。基准 `origin/main` = `256aad7`（PR #118 的合并提交，2026-11-15）；与上一版基准 `8385138` 之间 first-parent 共 64 个合并（PR #55–#115 与 #117–#119，`git log --first-parent 8385138..origin/main`）。
> 2026-11-16：PR #124 合并、`main` 预检通过后只改了 §4.1 和 §5.1，并把 PR #124 挪动的三处 `release.yml` 行号各加 4；其余仍是 11-15 的快照。

## 1. 版本与发布

> 发布日期取 `gh release list -R BeetMan/XDRemux-Flutter` 的 UTC 时间（已实测，2026-11-15）。

| 项 | 状态 | 依据 |
|---|---|---|
| Flutter 跨平台版 | **0.4.7（0.4.7+41）已发布**（2026-11-06，GitHub Latest） | `apps/flutter/pubspec.yaml:5`、标签 `v0.4.7` → `7dd8c8b`（PR #84）、`tools/installer/RELEASE_NOTES_v0.4.7.md` |
| 鸿蒙原生版（ArkUI） | **0.5.4 已发布**（2026-11-07，独立标签 `harmony-v0.5.4` → `aca3bc0`，在 `feat/harmony-native` 上、不在 `main`；内核 0.4.7） | `README.md:13`；过程记录在该分支的 `docs/plans/harmony-native.md` |
| 原生 Apple 版（SwiftUI） | **`apple-v0.1.1` 预发布**（2026-11-10，→ `3838330`，PR #97）；`apple-v0.1.0` 预发布（2026-11-07，→ `555b882`，PR #90）。不接管 Latest；bundle ID `io.github.beetman.xdremux.swiftui`，与 Flutter 版并存 | `tools/installer/RELEASE_NOTES_apple-v0.1.1.md`、`apps/apple/project.yml:50` |
| TestFlight（SwiftUI iOS） | 0.1.1 构建 3（11-14）与构建 4–7（11-15）已上传，均带 `vt+x265` 两个编码器；`main` 上构建号为 7（构建 8 的记录在 PR #120 分支上） | `apps/apple/project.yml:22`、`docs/plans/apple-native.md` 11-14 / 11-15 条目 |
| `main` 上尚未发布的改动 | 内核：人像校验修复（#99）、delta map（差值图）尺寸（#100）、HEVC 后端拆分与 VideoToolbox 后端（#107、#108）；Flutter：HDR 增益映射设计的应用图标（#102）、导入探测与整理扫描移出 UI isolate（#103、#105）、Flutter 3.50（#104）；SwiftUI：#98、#106、#109–#115、#118；测试：LibLivePhoto 解析器差分（#119） | `git log --first-parent v0.4.7..origin/main` |
| 0.4.7 内容 | 局域网互传（兼容 LocalSend，Flutter 全平台）、开启摄影风格时部分实况转换失败的修复（#86）、设置页「开源许可」与安装包附带 `LICENSE` / `LICENSING.md` | `tools/installer/RELEASE_NOTES_v0.4.7.md` |
| 平台范围 | Flutter：Windows x64、macOS Apple Silicon、Android arm64、iOS（未签名）、Linux x64（预览）、HarmonyOS（未签名）；SwiftUI：macOS 14+ Apple Silicon（ad-hoc 签名）、iOS / iPadOS 17+（未签名 IPA）；鸿蒙原生（未签名 HAP） | `README.md` 下载表 |
| 明确不提供 | Windows ARM64 安装包（`release.yml` 中 `continue-on-error` 实验构建）、Intel Mac 转换、Flutter Linux 托盘；SwiftUI 版自 11-14 起不再构建 x86_64 切片 | `README.md`、`docs/operations/ci.md` §3、`docs/plans/apple-native.md` 11-14 条目 |
| 许可 | **GPL-3.0-only**（PR #54）；历史标签另授 GPL-3.0-only，原 MIT 授权不撤回。带 x265 的构建经 TestFlight / App Store 分发是否与 GPL 相容**未决** | `LICENSE`、`LICENSING.md`、`docs/plans/apple-native.md` 11-14 条目 |

> 发布核对（已实测，2026-11-15，`gh release view` / `gh run view`）：`v0.4.7` 的发布 run `42266554910`（tag push，`7dd8c8b`）成功，发布页 8 个附件（Windows Setup、macOS DMG、Android APK、iOS IPA、HarmonyOS HAP、Linux AppImage / tar.gz / sha256）；`apple-v0.1.1` 附 DMG、未签名 IPA、`BUILD_RECORD.txt` 与 `SHA256SUMS.txt`；`harmony-v0.5.4` 附 HAP 与 `SHA256SUMS.txt`。本文没有下载附件核对内容。TestFlight 构建 3–7 的上传只有上传脚本输出的成功信息，App Store Connect 的处理结果与安装后表现**未验证**。

## 2. 分支地图

> 基准 `origin/main` = `256aad7`（2026-11-15，`git fetch --prune` 后）。远端共 9 个分支（含 `main`，`git ls-remote --heads origin` 实测）。「ahead / behind」相对该基准；「冲突」为 `git merge-tree --write-tree --name-only origin/main <分支>` 的冲突文件（已实测）。只列远端分支，本机未推送的分支不计入。

### 2.1 可合

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `feat/apple-viewer-return-and-preview`（PR #120 open） | +3 / −5 | 11-15 | 0 | SwiftUI 全屏查看器：关闭后停在最后看的那张照片；翻到某张照片时开始渲染它的 HDR 预览。另含构建号 8 及其 TestFlight 上传记录（`c9d8e1f`、`5bec16e`）。GitHub 显示 MERGEABLE，PR 检查在写作时仍在运行；只在 iPhone Duo 模拟器上验证，真机**未验证**。合并需用户同意 |
| `feat/flutter-core-videotoolbox`（PR #116 open） | +1 / −15 | 11-15 | 0 | Flutter macOS / iOS 的内核改为 `videotoolbox+x265`，GPU 开关改调 `xdremux_set_hevc_encoder`（开 = VideoToolbox，默认关 = x265），删除两个 Runner 里的 `xdremux/hw-encode` 通道；macOS / iOS 开 GPU 不再强制 OPPO 输出。GitHub 显示 MERGEABLE，PR 上的检查（Rust、Flutter、Linux、Transfer、OHOS）全部通过；iPhone 真机上的 VideoToolbox 转换**未验证**。合并需用户同意 |

### 2.2 在飞（长期分支）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `feat/harmony-native` | +122 / −79 | 11-06 | 1 文件（`README.md`） | 鸿蒙 ArkUI 原生工程，0.5.4 已发（内核 0.4.7，含「互传」页）。与 `main` 的 merge-base 是 `ce35efd`（PR #89），之后 `main` 的内核改动 #99、#100、#107、#108 尚未同步。长期分支，定期 merge main，不并回 main；同步后需重建 `.so` 并复测 |

### 2.3 研究分支（不直接合并）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `research/iphone-next` | +35 / −329 | 10-29 | 1 文件（`styles_bplist.rs`） | 皮肤 / Texture Style person 数据，10-29 后无推送；上游 #85 尚未吸收（`docs/research/upstream-20261115.md`）。长期分支，不并回 main |

### 2.4 已定进产品、暂缓接入

10-29 的决定不变：两者都**进产品**，现阶段不动。接入时各自另开会话，先 merge main，再定包体（M9 带 MB 级二进制 assets）与法务处理（项目已是 GPL-3.0-only，接入前需确认 assets 与工具链的许可兼容）。

| 分支 | ahead / behind | 冲突 | 说明 |
|---|---|---|---|
| `feat/oppo-filter-ecosystem` | +1 / −357 | 1 文件（`.gitignore`） | `.MS-LUT`↔`.cube` 编解码 + ColorOS `filter.info` 注入 + Hasselblad 管线归档 |
| `feat/m9-moment` | +1 / −357 | 5 文件（`main.dart`、`app_models.dart`、`xdremux_service.dart`、`docs/README.md`、`lib.rs`） | 小米 17 Ultra 徕卡 Moment M9 引擎 + QNN/Chromatix RE 工具链 |

### 2.5 已被替代、待删

| 分支 | ahead / behind | 冲突 | 说明 |
|---|---|---|---|
| `codex/local-transfer`（PR #29，11-02 关闭） | +1 / −183 | 2 文件（`transfer_controller.dart`、`transfer_page.dart`） | PR #29 没有合并：内容经 PR #68（基于 `rebase/local-transfer-20261028`）进入 `main`。唯一领先的提交 `843ea06`（可修改本机设备名）已在 PR #79 中以 `15680b2` 重做，冲突就来自这两个版本 |
| `rebase/local-transfer-20261028` | +1 / −183 | 同上 | 与 `codex/local-transfer` 指向同一提交 `843ea06` |

删除前按 10-29 的做法先打 `archive/*` 标签；删除远端分支需用户同意。上一版 §2.5 所列 10 个已合并分支已不在远端。

### 2.6 已归档

`archive/integrate/find-next`、`archive/research/find-next`、`archive/integrate/huawei-portrait-live` 三个标签仍在（`git tag -l 'archive/*'`），来历见 [`archive/current-status-20261029.md`](../archive/current-status-20261029.md) §2.5。恢复：`git push origin archive/<name>:refs/heads/<name>`。

### 2.7 pub 源与 Flutter 版本

- pub 源（已定：镜像）：CI 设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`（`.github/workflows/ci.yml:14`）并 `flutter pub get --enforce-lockfile`；`apps/flutter/pubspec.lock` 的 116 处 hosted url 都指向镜像（已实测，`grep -c`）。本地需要自己设置同一变量，否则默认的 `pub.dev` 会改写全部 hosted url。上一版提到的 `tools/env.sh` 不在仓库内。
- Flutter 固定 3.50.0（Dart 3.14.0）：`apps/flutter/.fvmrc` 与各 workflow（PR #104）。

## 3. 能力现状（主线）

| 能力 | 状态 | 备注 |
|---|---|---|
| ProXDR → ISO 21496-1 HDR HEIC（UHDR/LHDR） | 可用 | 两种输出模式：OPPO 兼容 / Apple 标准 |
| UHDR JPEG（MPF） | 可用（只作输入） | HDR 只输出 HEIC；单图 MPF 没有增益映射时按 SDR 处理 |
| HEVC 编码后端 | 可用（新） | `xdremux/rust/src/hevc/` 拆成 `x265.rs`、`ffmpeg.rs`、`vt.rs`：构建期决定编入哪些，运行期按单次转换或进程级选择（`hevc/mod.rs:1-31`，PR #107、#108）。Flutter 各平台仍只编 x265；SwiftUI 默认构建只编 VideoToolbox（`xdremux/rust/build_apple.sh:50`），GitHub 发布包与 TestFlight 用 `vt+x265`（`tools/apple/package_release.sh:61`、`tools/apple/upload_testflight.sh:53`）。VideoToolbox 下三通道增益映射为 4:2:0，x265 保持 4:4:4（`apps/apple/README.md`） |
| linear thumbnail（线性缩略图：Apple Log + 原生几何 + HDR 增益映射 + 可选 Main10） | 可用 | Android / iOS 发布包链接 10-bit x265（`release.yml:421-438`、`:697-698`），鸿蒙 Flutter 包为 10-bit（上一版记录，本地构建）；macOS / Windows / Linux 发布包为 8-bit（推断：`release.yml` 只有上述两处 10-bit 构建）。见 `docs/modules/styles-pipeline.md` §4 |
| Photographic Styles 写入 | **实验性** | key 3（GTC）每图拟合，Standard key 1 固定 identity；`"i"`、`"h"`、`"6"`、`"c"` / `"d"` 仍是金样本参考值（`styles_native.rs:23-25`），天空蒙版为零值占位（R4）。PR #100：主图较大时 delta map 按 iPhone 的做法取约 5/7 主图尺寸、不再封顶 2880×2560，修复 macOS 照片 App 改风格保存后出现的绿色网格 |
| Texture Styles（摄影风格 3） | 可用 | `texture_styles.rs` |
| OPPO / 华为人像转换 | 可用（条件受限） | 依赖源文件深度数据与系统版本。PR #99：`verify_portrait_graph` 自 `97269d1`（2026-09-10）起恒为假，已修 |
| Motion Photo → Live Photo | 可用 | 配对谓词 `existing_pair_is_valid`（`live_photo.rs:1994`）、FFI `xdremux_live_photo_pair_valid`；PR #86 修复开启摄影风格时的 Live Photo 配对失败（0.4.7）。PR #119 与 LibLivePhoto（`9328a05`）对拍：21 个真机动态照片（OPPO、三星、vivo、小米）的识别、静帧范围、视频范围、呈现时间全部一致，174 个普通照片全部判为非动态（`docs/research/motion-photo-liblivephoto-diff-20261115.md`，`tests/motion-diff` 是独立 workspace，不进 CI） |
| 风格 + 实况 | 可用（0.4.6 起） | `live_photo_styles::attach_style_tracks` 向 MOV 追加 linear thumbnail、smartstyle-info、live-photo-info 与 matte 伴随轨道；`XDREMUX_LIVE_STYLE_TRACKS` 可切级别做消融 |
| Live Photo `.pvt` 包输出 | 可用（默认开启） | `live_photo_bundle.rs`；iOS / macOS 分享 `.pvt`，其他平台分享 `.pvt.zip`；见 `docs/formats/live-photo-pvt.md` |
| 统一转换管线 | 可用（新） | `xdremux_convert_pipeline`（`pipeline.rs`，PR #63）：转换 → 校验（ISO / Styles / 人像）→ 摄影风格 3 后处理 → 再校验。SwiftUI 版经 `Pipeline.swift:77` 调用；Flutter 版不调用（推断：`apps/flutter/lib` 中无引用） |
| 局域网互传（LocalSend v2） | 可用（0.4.7 起） | 独立 crate `crates/xdremux-transfer`、`crates/xdremux-transfer-ffi`（vendor LocalSend，Rust 固定 1.97.1）；Flutter 全平台、SwiftUI（PR #68、#80、#81、#87、#111）、鸿蒙原生 0.5.4。iPhone 没有多播授权，靠 /24 网段扫描发现对端（PR #79、#80）。Windows ↔ Android 及与官方 LocalSend 互通有真机记录（`docs/testing/local-transfer-p30.md` 等）；Apple 真机扫描到真实对端**未验证**（PR #80、`apple-v0.1.1` 说明） |
| 队列 / 检查点恢复 / 分类输出 | 可用 | 见 `docs/app/workflow-design.md`；PR #103、#105 把导入探测与整理扫描移出 UI isolate（安卓多选卡顿） |
| 原生 Apple 前端（SwiftUI） | 预发布 0.1.1 + TestFlight | 导入（含 Share Extension）、详情优先转换、逐张转换选项、HDR 预览与按住对比、队列与检查点、Motion Photo → Live Photo、摄影风格 2 / 3、人像、批量整理、局域网互传、iOS 自动存入照片、中英双语、macOS CLI `xdremux`。0.1.1 之后进入 `main`：编码器选择（#109、#110）、收件箱打开即显示与清除全部（#111、#112）、存入照片进度（#114）、非 ProXDR 源直接显示原文件（#115）、全屏查看（缩放、翻页）与换用 Flutter 版的新图标（#118） |
| Cinematic 元数据 | 已放弃 | 主线无相关能力 |

## 4. 已知风险与未验证项

1. **已解决：Flutter 3.50 之后 `release.yml` 的安卓构建失败**（已实测）：PR #104 合并前在 `ci/flutter-3.50.0 @ bb567fe` 手动触发的预检 run `43480790620`（11-13）中，Android APK 在 `:url_launcher_android:lintVitalAnalyzeRelease` 失败（lint 内部崩溃，报 `'java.lang.Object java.util.List.removeLast()'`），macOS DMG 没拿到 runner、零步骤被取消。原因：AGP 9.3.1 自带的 lint 32.3.1 调用 JDK 21 才有的 `List.removeLast()`（用 `javap` 核对，AGP 9.0.1 的 32.0.1 没有；Google 在 AGP 9.3.2 修了这个崩溃），而 Android job 当时用 Temurin 17。PR #124 改用 JDK 21（`release.yml:345-353`，合并提交 `b0ed888`）。之后在 `main @ b0ed888` 手动触发的预检 run `44004132722`（11-16）中 Android APK、macOS DMG、Windows x64、iOS、Linux 全部通过；Windows ARM64 为实验构建，照旧在 Set up Flutter 失败（允许失败）。以后若退回 JDK 17，AGP 至少要 9.3.2（`docs/operations/releasing.md` §4）。
2. **Styles native 路径不是逐像素等价**：仅 key 3 按图拟合，key 1 为 identity，`"i"` / `"h"` / `"6"` / `"c"` / `"d"` 为参考值，天空分割待 R4。目标是"Apple 照片可继续编辑"，不是原生画质。PR #100 只在 macOS 照片 App 上人工核对了 7 种主图尺寸，iPhone 上**未验证**；Flutter 内的 Swift 研究管线仍是旧的 2880×2560 上限（`ApplePhotographicStylesPipeline.swift:2872-2873`），该管线不在产品路径（`app_models.dart:31-32`）。
3. **linear thumbnail**：baseline exposure 的绝对亮度与「4:2:0 增益映射 + Main10 缩略图」组合在照片 App 中的接受度只在 iPhone 16e 与 macOS 27.2 上做过维护者验收；`docs/testing/styles-hdr-device-checklist.md` 自 10-26 起没有更新，完整 S1/S2/S3/S7 A/B **未跑**。原生 Apple tmap 文件重编码仍需解 HEVC 增益映射，`rust_h265` 只支持 4:2:0（`heif_decode.rs:6`）。VideoToolbox 后端的三通道增益映射同样是 4:2:0，对画质的影响**未验证**。
4. **风格实况的 MOV 伴随轨道按原生 iOS 27 MOV 复刻**：用静帧代替每一帧（不解视频），matte 为空（`live_photo_styles.rs:21-22`、`:727`）；只验证了 macOS 27.2 / iPhone 16e 编辑不崩溃、保存后实况与颜色保留，其他系统版本**未验证**。
5. **Live Photo 发布校验只做了前半**（推断，读代码）：
   - Flutter 在临时目录合成后先校验配对（`motion_photo_service.dart:49-56`）；`.pvt` 由 Rust 先校验、在隐藏的 staging 目录组装后再换入（`live_photo_bundle.rs:129-161`），Flutter 再校验整个包（`motion_photo_service.dart:71-72`）；非 `.pvt` 路径复制到输出目录后立即复核（`:81-84`）。
   - 缺上游 #76/#78 的后半段：复核失败时不删已复制的 MOV 与静帧，只把队列项标为失败（`main.dart:2164-2176`）；没有独立恢复副本。
   - SwiftUI 在 scratch 目录校验配对（`ConversionJob.swift:282`）后先移静帧、再移 MOV（`:301`、`:307`），移入后不再复核，MOV 移动失败时静帧不回滚。
6. **Motion Photo 解析覆盖**（PR #119 的结论，已实测于样本，设备行为未验证）：只写在三星 SEF 里、没有 Google XMP 的动态照片不识别（只有 LibLivePhoto 的合成样本，真机是否仍产生这种文件**未验证**）；`xdremux_motion_photo_split`（「拆分为照片 + 视频」）写出的 MP4 带厂商尾字节（三星 SEF 116 B、OPPO 约 2.6 KB），ffprobe 无告警，照片 App / AVFoundation 的反应**未验证**；Live Photo 转换路径已裁剪，不受影响。
7. **SwiftUI 预发布包的人像转换**（推断）：`apple-v0.1.0` / `apple-v0.1.1` 用 0.4.7 内核，早于 PR #99；PR #99 的复现显示，修复前 `xdremux_convert_pipeline` 对两张 OPPO 人像样张在 `stage: verify` 失败，而 SwiftUI 走的正是这条管线。TestFlight 构建 3、4 晚于 PR #99 合并（11-13）。预发布包上的实际表现**未验证**。Flutter 版只在「跳过已转换」判断里用人像校验（`main.dart:1931-1937`），影响是已转换的人像输出不会被跳过。
8. **TestFlight / App Store**：App Store Connect 的处理结果、TestFlight 安装后的界面与两种编码器的真机表现**未验证**；`XDRemuxTransferCore.framework` 缺 dSYM（上传警告，只影响崩溃符号化）；带 x265 的构建与 App Store 条款是否相容未决，开放公开测试链接前需要定下来。
9. **iPhone Duo**：Flutter 的安全区修复（0.4.6）与 SwiftUI 的两栏布局、侧边栏工具栏只在模拟器上验证，真机**未验证**。
10. **CI 覆盖**：共 8 个 workflow。`ci.yml` 跑 Ubuntu 上的 Rust（同时链接 8-bit 与 10-bit x265）与 Flutter；`apple-ci.yml`（Swift 包、CLI、macOS App、iOS 模拟器构建）与 `apple-vt-core.yml`（VideoToolbox 后端的内核测试）因 macOS runner 紧张，只在 Rust 改动合入 `main` 后和改到 Apple 路径的 PR 上运行（PR #101），改 FFI 的 Rust PR 合并前要在 Mac 上跑 `tools/apple/verify_local.sh`；`transfer-ci.yml` 覆盖 Windows / Linux / macOS / OHOS 的传输库；安卓 APK 只在 `release.yml` 里构建。Windows / macOS 原生行为与真机照片验收不在 CI 内。`main` 最新一次 push（`256aad7`）的 CI 通过，最近一次 Rust 合入（`78df799`）触发的 CI、Conformance、Apple native、Apple VideoToolbox core、OHOS smoke 均通过（已实测，`gh run list --branch main`；CI 通过不等于真机验收）。`docs/operations/ci.md` 仍写"六个 workflow"，没有覆盖 `apple-vt-core.yml`、`transfer-ci.yml` 与 PR #101 的触发规则。
11. **三个前端共用 Rust 内核**（Flutter、鸿蒙原生、SwiftUI），另共用传输 crate：FFI 改动需重新生成 `xdremux_core.h`（`ci.yml` 校验），并重建鸿蒙 `.so` 复测；`feat/harmony-native` 尚未同步 PR #99、#100、#107、#108。
12. **安装包许可文本**：Windows（`tools/installer/xdremux.iss:63-64`）、macOS（`release.yml:660-662`）、Linux（`tools/linux/package_linux.sh:296`、`:369`）的打包步骤都复制 `LICENSE` / `LICENSING.md`，`v0.4.7` 的发布 run 成功；产物里的文件没有打开核对（**未验证**）。

## 5. 下一步优先级

1. **已完成**（11-16，已实测）：修复 `release.yml` 的安卓构建并在 `main` 上预检。PR #124 改用 JDK 21（`b0ed888`）；`main` 预检 run `44004132722`（`platforms: all`）中 Android APK 与 macOS DMG 都通过（§4.1）。Flutter 下一版的这个前置已满足。
2. PR #116（Flutter macOS / iOS 改用内核的 VideoToolbox 后端）：由用户决定是否合并；之后发 Flutter 0.4.8，带上 `main` 上尚未发布的 #99、#100、#102–#105、#107、#108。
3. SwiftUI：PR #120 由用户决定是否合并；出 0.1.2 预发布，带上 PR #99 的人像修复与 0.1.1 之后的界面改动（§4.7）；确认 TestFlight 构建 3–7 的处理结果与真机安装；开放公开测试链接前定下 x265 与 App Store 条款的问题；补传输框架的 dSYM。`docs/plans/apple-native.md` §3 的 P4 跨端回归仍无记录。
4. Live Photo 发布校验补齐（`docs/research/upstream-20261115.md` 的 P1，沿用）：复核失败时回滚已写出的 MOV 与静帧、保留独立恢复副本，Flutter 与 SwiftUI 两端都做（§4.5）；约 2–3 天。
5. `feat/harmony-native` 同步 `main`（PR #99、#100、#107、#108），重建 `.so` 复测后再定鸿蒙原生的下一版。
6. 按 `docs/testing/styles-hdr-device-checklist.md` 跑完整真机 A/B（覆盖 §4.3），并在 iPhone 上复核 PR #100；之后是每图的 key 4 / `"h"`（`linear_metadata`）与 P1-3 统计。
7. `upstream-20261115.md` 的 P2：华为 `it35` 按 GB/T 48347 UWAInfo 逐字段对应（只读解析，约 1–2 天）；用已链接的 libheif 解增益映射（先约 1 小时探针，确认 libde265 能否解 Rext 4:0:0，可行再投入 2–3 天）；对照上游 #83 / #84 加 BT.2020 解码回算断言。
8. PR #119 留下的两项（§4.6）：先找三星只写 SEF 的真机样本，确认后再决定是否识别；在照片 App / AVFoundation 上测带厂商尾字节的拆分 MP4，有问题再让 `xdremux_motion_photo_split` 裁剪。
9. 清理 §2.5 两个被替代的分支（先打 `archive/*` 标签，删除需用户同意）；更新 `docs/operations/ci.md`（§4.10）。
10. 评估 macOS / Windows 发布包是否启用 10-bit x265；PR #116 合并后 Flutter macOS 默认仍是 x265，但多了 VideoToolbox 选项，需要一起评估。

暂缓 / 观察（不排期）：

- Apple 实况 → 安卓动态照片：暂缓，等上游 #97 合入且 `android-motion-gallery-matrix` 出现实机 PASS 再定（`upstream-20261115.md` 待决策项）。
- 上游 #92（MakerNote tag 25）、#91（双层 HDR JPEG）、研究仓 PR #10：只观察，触发条件见 `upstream-20261115.md`。
- `feat/oppo-filter-ecosystem`、`feat/m9-moment`：维持 10-29 的暂缓接入决定（§2.4）。
- `research/iphone-next` 吸收上游 #85：沿用 `upstream-20261030.md` 的 P1，10-29 之后没有进展。

上一版第 5 节中已完成、本版移除的项：合并 PR #55（`35dae91`）；清理上一版 §2.5 的已合并分支（远端已删）；PR #29 互传（经 PR #68 进入 `main`，随 0.4.7 发布）；SwiftUI 的 Share Extension（PR #58）、批量整理（PR #61）与 iOS 真机签名安装（`RELEASE_NOTES_apple-v0.1.1.md`「验证范围」：iPhone 16e 与 iPad mini 上的 0.1.0 基线）。`upstream-20261115.md` 的 P1「LibLivePhoto 作对拍参照」已由 PR #119 完成，不再列入。

## 6. 常用验证命令

```bash
# Rust 单元/集成测试（需可用的 C 工具链与 x265）
cargo test -p xdremux-core --lib
# 全仓（CI 同款）
cargo test --workspace
# 内核走 VideoToolbox 后端（仅 Apple 平台；CI 见 apple-vt-core.yml）
XDREMUX_HEVC_BACKEND=videotoolbox cargo test -p xdremux-core
# 传输 crate（Rust 固定 1.97.1；CI 见 transfer-ci.yml）
cargo +1.97.1 test --manifest-path crates/xdremux-transfer/Cargo.toml --locked
cargo +1.97.1 test --manifest-path crates/xdremux-transfer-ffi/Cargo.toml --locked
# Flutter（镜像源 + 锁文件）
export PUB_HOSTED_URL=https://pub.flutter-io.cn
cd apps/flutter && flutter pub get --enforce-lockfile && flutter analyze --no-fatal-infos && flutter test
# 原生 Apple：在 Mac 上跑与 apple-ci.yml 相同的整套检查（需 Xcode、cbindgen、xcodegen）
tools/apple/verify_local.sh
# 或只构建 macOS 内核（默认只编 VideoToolbox）再跑 Swift 包测试
XDREMUX_APPLE_SLICES=macos xdremux/rust/build_apple.sh
cd apps/apple/Packages/XDRemuxKit && swift test
# FFI 头文件是否与导出一致
tools/apple/check_header.sh
# 对拍
cargo run -p xdremux-conformance -- --help   # 见 docs/testing/conformance-suite.md
# Motion Photo 解析器与 LibLivePhoto 差分（独立 workspace，会拉取 LibLivePhoto）
cargo run --release --manifest-path tests/motion-diff/Cargo.toml -- --json <文件或目录>
# 发版预检：只构建，publish 任务受 tag 保护（见 docs/operations/releasing.md）
gh workflow run release.yml -R BeetMan/XDRemux-Flutter --ref main -f platforms=all
```

## 7. 相关文档

- 写作与证据规范：`docs/style-guide.md`
- 仓库布局与数据流：`docs/architecture/overview.md`、`docs/architecture/data-flow.md`
- 平台行为矩阵：`docs/validation/platform-behavior-matrix.md`
- 发版流程：`docs/operations/releasing.md`；CI：`docs/operations/ci.md`（落后于现状，见 §4.10）
- Styles 管线：`docs/modules/styles-pipeline.md`；HEVC 编码：`docs/modules/hevc-x265.md` 与 `xdremux/rust/src/hevc/mod.rs` 的模块注释；Live Photo 包：`docs/formats/live-photo-pvt.md`
- 原生 Apple 前端：`apps/apple/README.md`（构建、编码器变体、TestFlight）、`docs/plans/apple-native.md`（执行记录）
- 局域网互传：`docs/plans/local-transfer-plan.md`、`docs/testing/local-transfer-*.md`
- Motion Photo 解析对拍：`docs/research/motion-photo-liblivephoto-diff-20261115.md`（上一轮三方差分 `docs/research/motion-photo-parser-differential.md`）
- 上游动向与规划：`docs/research/upstream-20261115.md`（上一版 `docs/research/upstream-20261030.md`）
- 历史快照：`docs/archive/current-status-20261031.md`、`docs/archive/current-status-20261029.md`

## 8. 不适用条件

- 本文是**时间点快照**：分支领先数、CI 状态、版本号会变化，超过约两周即应重写而不是续改。
- 本文不替代真机验收记录：平台行为以 `docs/validation/` 与 release 记录为准。
- 本文不包含任何会话内隐私信息（本机绝对路径、账号、令牌）。
