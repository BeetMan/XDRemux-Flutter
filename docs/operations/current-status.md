# 当前开发状态（2026-11-24）

> 读者：接手项目的开发者 / agent。用途：给出**可提交、可审计**的现状快照，替代只存在于本机的 `docs/plans/current-handoff.md`。
> 更新时机：发版后、主线合并后、方向决策后。每次更新在标题保留日期，历史版本进 `docs/archive/`（上一版：[`archive/current-status-20261115.md`](../archive/current-status-20261115.md)）。
> 断言遵循 `docs/style-guide.md` §3：已实测 / 推断 / 未验证。
> 2026-11-24：按 `origin/main` = `034684a`（PR #123 的合并提交，2026-11-22 23:37）重写。与上一版基准 `256aad7` 之间 first-parent 共 8 个合并（PR #116、#120、#121、#122、#123、#124、#125、#126，`git log --first-parent 256aad7..origin/main`）。本次 GitHub API 被限流：PR 开合状态只从 PR 页面读到 #127、#128 为 open；CI 只读 shields 徽章（§4.10）；发布附件没有重新核对。

## 1. 版本与发布

| 项 | 状态 | 依据 |
|---|---|---|
| Flutter 跨平台版 | **0.4.7（0.4.7+41）已发布**（2026-11-06，GitHub Latest）；`main` 上的版本号未动，0.4.8 未切 | `apps/flutter/pubspec.yaml:5`、标签 `v0.4.7` → `7dd8c8b`、`tools/installer/RELEASE_NOTES_v0.4.7.md` |
| 鸿蒙原生版（ArkUI） | **0.5.4 已发布**（独立标签 `harmony-v0.5.4` → `aca3bc0`；内核 0.4.7）。工程已随 PR #126 并入 `main` 的 `apps/harmony/`，远端 `feat/harmony-native` 分支已删 | `apps/harmony/AppScope/app.json5:5-6`、`apps/harmony/README.md`、`docs/plans/harmony-native.md` |
| 原生 Apple 版（SwiftUI） | **`apple-v0.1.1` 预发布**（→ `3838330`，PR #97）；`apple-v0.1.0` 预发布（→ `555b882`，PR #90）。不接管 Latest；bundle ID `io.github.beetman.xdremux.swiftui`，与 Flutter 版并存 | `tools/installer/RELEASE_NOTES_apple-v0.1.1.md`、`apps/apple/project.yml:89` |
| TestFlight（SwiftUI iOS） | 0.1.1 构建 3–7 的上传记录在上一版；构建 8 的记录（`c9d8e1f`、`5bec16e`）已随 PR #120 进 `main`，`main` 上构建号为 8 | `apps/apple/project.yml:22`、`docs/plans/apple-native.md` 11-15 条目 |
| `main` 上尚未发布的改动 | 自 `v0.4.7` 起 first-parent 共 40 个合并（`git log --first-parent v0.4.7..origin/main`）。内核：人像校验（#99）、delta map 尺寸（#100）、HEVC 后端拆分与 VideoToolbox 后端（#107、#108）、Live Photo 事务发布（#123）；Flutter：新图标（#102）、导入探测与整理扫描移出 UI isolate（#103、#105）、Flutter 3.50（#104）、macOS / iOS 内核改走 VideoToolbox（#116）；SwiftUI：#98、#106、#109–#115、#118、#120；鸿蒙原生并入（#126）；CI：#101、#124；研究与对拍：#117、#119、#122 | 同上 |
| 0.4.7 内容 | 局域网互传（兼容 LocalSend，Flutter 全平台）、开启摄影风格时部分实况转换失败的修复（#86）、设置页「开源许可」与安装包附带 `LICENSE` / `LICENSING.md` | `tools/installer/RELEASE_NOTES_v0.4.7.md` |
| 平台范围 | Flutter：Windows x64、macOS Apple Silicon、Android arm64、iOS（未签名）、Linux x64（预览）、HarmonyOS（未签名）；SwiftUI：macOS 14+ Apple Silicon（ad-hoc 签名）、iOS / iPadOS 17+（未签名 IPA）；鸿蒙原生（未签名 HAP，需 HarmonyOS 7 / API 26） | `README.md` 下载表、`apps/harmony/build-profile.json5` |
| 明确不提供 | Windows ARM64 安装包（`release.yml` 中 `continue-on-error` 实验构建）、Intel Mac 转换、Flutter Linux 托盘；SwiftUI 版自 11-14 起不再构建 x86_64 切片 | `README.md`、`docs/operations/ci.md` §3、`docs/plans/apple-native.md` 11-14 条目 |
| 许可 | **GPL-3.0-only**（PR #54）；历史标签另授 GPL-3.0-only，原 MIT 授权不撤回。带 x265 的构建经 TestFlight / App Store 分发是否与 GPL 相容**未决**；解决方案的计划稿见 `docs/plans/apple-drop-x265.md`（只做了调研，未改产品代码） | `LICENSE`、`LICENSING.md`、`docs/plans/apple-drop-x265.md` |

> 发布核对沿用上一版（2026-11-15，`gh release view` / `gh run view`）：`v0.4.7` 发布 run `42266554910` 成功，8 个附件；`apple-v0.1.1` 附 DMG、未签名 IPA、`BUILD_RECORD.txt` 与 `SHA256SUMS.txt`；`harmony-v0.5.4` 附 HAP 与 `SHA256SUMS.txt`。本版没有重新核对。TestFlight 构建 5–8 在 App Store Connect 的处理结果与安装后表现**未验证**。

## 2. 分支地图

> 基准 `origin/main` = `034684a`（2026-11-24 `git fetch --prune` 后）。远端共 12 个分支（含 `main`，`git ls-remote --heads origin` 已实测）。「ahead / behind」相对该基准；「冲突」为 `git merge-tree --write-tree --name-only origin/main <分支>` 列出的冲突文件（已实测）。只列远端分支。

### 2.1 在飞（有 PR）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `feat/apple-live-styles-per-frame`（PR #130） | +1 / −0 | 11-23 | 0 | Apple 端按视频帧生成 Live Photo 摄影风格的线性缩略图与色调曲线，取代「每帧都用静帧」的做法（§4.4）。单提交 `602e3f0`，13 个文件 +631 / −98：`live_photo_styles.rs`、`live_photo_styles_apple.rs`、`apple_live_style_video.m`、`hevc/`，测试 +66 行；`build.rs`、`module.modulemap` 与 iOS `Podfile` 的符号表同步。基于最新 `main`。PR 开合状态未查到；真机表现**未验证** |
| `fix/oppo-17.24-portrait-container-motion`（PR #127，open） | +3 / −7 | 11-22 | 0 | ColorOS 17.24 人像：读横屏帧、配置里的镜像标志、深度值低者为近（`577c028`、`ba0ace6`）；拆分 MP4 裁掉厂商尾字节并刷新 `private.emptyspace`（`8a89706`）。依据 `docs/research/oppo-gallery-17.24.12-20261114.md` |
| `feat/watermark-frame-restore`（PR #128，open；基于 #127） | +4 / −7 | 11-22 | 0 | 按尾部里存的画面矩形（四角）还原大师水印画框（`a09e3c9`）。三个 OPPO 分支是堆叠关系，按 #127 → #128 → #129 顺序合；都落后 `main` 7 个提交（#123 之后），合并前先同步 |
| `feat/photo-details-oppo-tail`（PR #129；基于 #128） | +5 / −7 | 11-22 | 0 | 详情页检查并展示 OPPO 私有尾部数据（`be31ef1`）。PR 开合状态未查到 |

### 2.2 已被替代、待删（远端仍在）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `fix/oppo-17.24-container-motion-portrait` | +1 / −151 | 11-18 | 0 | PR #127 的前身（单提交 `2ff67e7`，把三件事合在一起），已在 #127 / #128 重做 |
| `research/oppo-gallery-17.24` | +2 / −151 | 11-18 | 0 | 两篇研究记录（`docs/research/oppo-gallery-17.24.76.md`，Find X8 Ultra 样本与 ColorOS 17.24 核对）加一行索引；没有 PR。是否入库待定，与 `oppo-gallery-17.24.12-20261114.md` 不是同一份 |
| `codex/local-transfer`（PR #29，11-02 关闭） | +1 / −349 | 11-01 | 2 文件（`transfer_controller.dart`、`transfer_page.dart`） | PR #29 没有合并：内容经 PR #68（基于 `rebase/local-transfer-20261028`）进入 `main`。唯一领先的提交 `843ea06` 已在 PR #79 中以 `15680b2` 重做 |
| `rebase/local-transfer-20261028` | +1 / −349 | 11-01 | 同上 | 与 `codex/local-transfer` 指向同一提交 `843ea06` |

删除前按 10-29 的做法先打 `archive/*` 标签；删除远端分支需用户同意。

### 2.3 研究分支（不直接合并）

| 分支 | ahead / behind | 最后提交 | 冲突 | 说明 |
|---|---|---|---|---|
| `research/iphone-next` | +35 / −495 | 10-29 | 3 文件（`Cargo.lock`、`xdremux/rust/Cargo.toml`、`styles_bplist.rs`） | 皮肤 / Texture Style person 数据，10-29 后无推送；上游 #85 尚未吸收（`docs/research/upstream-20261115.md`）。长期分支，不并回 main。`Cargo.*` 的冲突来自 #123 新增的 `sha2` / `libc` 依赖 |

### 2.4 已定进产品、暂缓接入

10-29 的决定不变：两者都**进产品**，现阶段不动。接入时各自另开会话，先 merge main，再定包体（M9 带 MB 级二进制 assets）与法务处理（项目已是 GPL-3.0-only，接入前需确认 assets 与工具链的许可兼容）。

| 分支 | ahead / behind | 冲突 | 说明 |
|---|---|---|---|
| `feat/oppo-filter-ecosystem` | +1 / −523 | 1 文件（`.gitignore`） | `.MS-LUT`↔`.cube` 编解码 + ColorOS `filter.info` 注入 + Hasselblad 管线归档 |
| `feat/m9-moment` | +1 / −523 | 5 文件（`main.dart`、`app_models.dart`、`xdremux_service.dart`、`docs/README.md`、`lib.rs`） | 小米 17 Ultra 徕卡 Moment M9 引擎 + QNN/Chromatix RE 工具链 |

### 2.5 已归档

`archive/integrate/find-next`、`archive/research/find-next`、`archive/integrate/huawei-portrait-live` 三个标签仍在（`git tag -l 'archive/*'`），来历见 `archive/current-status-20261029.md` §2.5。恢复：`git push origin archive/<name>:refs/heads/<name>`。

### 2.6 pub 源与 Flutter 版本

- pub 源（已定：镜像）：CI 设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`（`.github/workflows/ci.yml:14`）并用 `flutter pub get --enforce-lockfile`；本地需要自己设置同一变量，否则默认的 `pub.dev` 会改写 `pubspec.lock` 里全部 hosted url。
- Flutter 固定 3.50.0（`apps/flutter/.fvmrc`，PR #104）。

## 3. 能力现状（主线）

| 能力 | 状态 | 备注 |
|---|---|---|
| ProXDR → ISO 21496-1 HDR HEIC（UHDR/LHDR） | 可用 | 两种输出模式：OPPO 兼容 / Apple 标准 |
| UHDR JPEG（MPF） | 可用（只作输入） | HDR 只输出 HEIC；单图 MPF 没有增益映射时按 SDR 处理 |
| HEVC 编码后端 | 可用 | `xdremux/rust/src/hevc/` 拆成 `x265.rs`、`ffmpeg.rs`、`vt.rs`：构建期决定编入哪些，运行期按单次转换或进程级选择（PR #107、#108）。Flutter macOS / iOS 发布包编入 `videotoolbox+x265`，设置里的 GPU 开关经 `xdremux_set_hevc_encoder` 选后端，对所有转换、实况与回传生效（PR #116，`apps/flutter/lib/services/hardware_encoder.dart`）；Android 仍是 MediaCodec 分块路径 + x265；Windows / Linux 只有 x265。SwiftUI 默认构建只编 VideoToolbox，发布包与 TestFlight 用 `vt+x265`。VideoToolbox 下三通道增益映射为 4:2:0，x265 保持 4:4:4（`apps/apple/README.md`） |
| linear thumbnail（线性缩略图：Apple Log + 原生几何 + HDR 增益映射 + 可选 Main10） | 可用 | Android / iOS 发布包链接 10-bit x265；鸿蒙 Flutter 包为 10-bit；macOS / Windows / Linux 发布包为 8-bit（推断：`release.yml` 只在上述两处做 10-bit 构建）。见 `docs/modules/styles-pipeline.md` §4 |
| Photographic Styles 写入 | **实验性** | key 3（GTC）每图拟合，Standard key 1 固定 identity；`"i"`、`"h"`、`"6"`、`"c"` / `"d"` 仍是金样本参考值（`styles_native.rs:23-25`），天空蒙版为零值占位（R4）。PR #100：主图较大时 delta map 取约 5/7 主图尺寸、不再封顶 2880×2560，修复 macOS 照片 App 改风格保存后出现的绿色网格 |
| Texture Styles（摄影风格 3） | 可用 | `texture_styles.rs` |
| OPPO / 华为人像转换 | 可用（条件受限） | 依赖源文件深度数据与系统版本。PR #99 修复 `verify_portrait_graph` 恒为假。ColorOS 17.24 的人像几何与画框修复在 PR #127 / #128（§2.1），尚未进 `main` |
| Motion Photo → Live Photo | 可用 | 配对谓词 `existing_pair_is_valid`（`live_photo.rs`）、FFI `xdremux_live_photo_pair_valid`；PR #86 修复开启摄影风格时的配对失败（0.4.7）。PR #119 与 LibLivePhoto 对拍：21 个真机动态照片识别、静帧范围、视频范围、呈现时间全部一致，174 个普通照片全部判为非动态（`docs/research/motion-photo-liblivephoto-diff-20261115.md`） |
| Live Photo 输出发布 | 可用（新，PR #123） | 写入 → 不覆盖改名 → 回读 → 提交或回滚，HEIC + MOV 平铺配对与 `.pvt` 包共用一套（`xdremux/rust/src/live_photo_publish.rs`，规则见 `docs/architecture/ffi-contract.md` §3）。Flutter 平铺输出改走新 FFI `xdremux_publish_live_photo_pair`，SwiftUI 经 `MotionPhoto.swift` 调同一函数。回滚失败会在 `errorMessage` 里写明 |
| 风格 + 实况 | 可用（0.4.6 起） | `live_photo_styles::attach_style_tracks` 向 MOV 追加 linear thumbnail、smartstyle-info、live-photo-info 与 matte 伴随轨道；目前用静帧代替每一帧、matte 为空（§4.4）。逐帧生成在 PR #130 |
| Live Photo `.pvt` 包输出 | 可用（默认开启） | `live_photo_bundle.rs`；iOS / macOS 分享 `.pvt`，其他平台分享 `.pvt.zip`；见 `docs/formats/live-photo-pvt.md` |
| 统一转换管线 | 可用 | `xdremux_convert_pipeline`（`pipeline.rs`，PR #63）：转换 → 校验（ISO / Styles / 人像）→ 摄影风格 3 后处理 → 再校验。SwiftUI 版经 `Pipeline.swift` 调用；Flutter 版不调用（推断：`apps/flutter/lib` 中无引用） |
| 局域网互传（LocalSend v2） | 可用（0.4.7 起） | 独立 crate `crates/xdremux-transfer`、`crates/xdremux-transfer-ffi`（vendor LocalSend，Rust 固定 1.97.1）；Flutter 全平台、SwiftUI、鸿蒙原生 0.5.4。iPhone 没有多播授权，靠 /24 网段扫描发现对端。Windows ↔ Android 及与官方 LocalSend 互通有真机记录（`docs/testing/local-transfer-*.md`）；Apple 真机扫描到真实对端**未验证** |
| 队列 / 检查点恢复 / 分类输出 | 可用 | 见 `docs/app/workflow-design.md`；PR #103、#105 把导入探测与整理扫描移出 UI isolate |
| 原生 Apple 前端（SwiftUI） | 预发布 0.1.1 + TestFlight 构建 8 | 导入（含 Share Extension）、详情优先转换、逐张转换选项、HDR 预览与按住对比、全屏查看（缩放、翻页，关闭后停在最后看的那张，#118 / #120）、队列与检查点、Motion Photo → Live Photo、摄影风格 2 / 3、人像、批量整理、局域网互传（含收件箱打开即显示、清除全部、存入照片进度）、iOS 自动存入照片、中英双语、macOS CLI `xdremux` |
| 鸿蒙原生前端（ArkUI） | 0.5.4 已发布 | 工程在 `apps/harmony/`（PR #126 并入）：图库、队列、互传、设置四个 Tab；主机侧确定性回归由 `harmony-native-ci.yml` 跑（Node 24 + Python + C++），ArkTS 编译、N-API 与真机行为仍是本地清单（`apps/harmony/BUILDING.md`） |
| Cinematic 元数据 | 已放弃 | 主线无相关能力 |

## 4. 已知风险与未验证项

1. **已解决：Flutter 3.50 之后 `release.yml` 的安卓构建失败**（已实测，11-17）：AGP 9.3.1 自带的 lint 32.3.1 调用 JDK 21 才有的 `List.removeLast()`；PR #124 改用 JDK 21（`release.yml:345-353`）。`main @ b0ed888` 的预检 run `44004132722`（`platforms: all`）Android APK、macOS DMG、Windows x64、iOS、Linux 全部通过。之后 #126、#116、#123 又进了 FFI 与内核改动，**当前 `034684a` 没有新的全平台预检记录**；0.4.8 切版本号前先跑一次（§5.1）。
2. **Styles native 路径不是逐像素等价**：仅 key 3 按图拟合，key 1 为 identity，`"i"` / `"h"` / `"6"` / `"c"` / `"d"` 为参考值，天空分割待 R4。目标是「Apple 照片可继续编辑」，不是原生画质。PR #100 只在 macOS 照片 App 上人工核对了 7 种主图尺寸，iPhone 上**未验证**；Flutter 内的 Swift 研究管线仍是旧的 2880×2560 上限，该管线不在产品路径。
3. **linear thumbnail**：baseline exposure 的绝对亮度与「4:2:0 增益映射 + Main10 缩略图」组合在照片 App 中的接受度只在 iPhone 16e 与 macOS 27.2 上做过维护者验收；`docs/testing/styles-hdr-device-checklist.md` 自 10-26 起没有更新，完整 S1/S2/S3/S7 A/B **未跑**。原生 Apple tmap 文件重编码仍需解 HEVC 增益映射，`rust_h265` 只支持 4:2:0（`heif_decode.rs:6`）。Flutter macOS / iOS 开 GPU 后走 VideoToolbox（#116），三通道增益映射同为 4:2:0，对画质的影响**未验证**。
4. **风格实况的 MOV 伴随轨道按原生 iOS 27 MOV 复刻**：用静帧代替每一帧（不解视频），matte 为空（`live_photo_styles.rs`）；只验证了 macOS 27.2 / iPhone 16e 编辑不崩溃、保存后实况与颜色保留，其他系统版本**未验证**。PR #130 改为逐帧生成，仍在飞。
5. **Live Photo 输出发布已事务化（PR #123，已实测于单元 / 集成测试与两端宿主测试）**，实现在 `xdremux/rust/src/live_photo_publish.rs`：先在内存里用配对谓词校验，写到同目录定长隐藏名 `.xdremux-publish-<run>-<n>.partial` 并刷盘，再以不覆盖改名（Linux / Android `renameat2(RENAME_NOREPLACE)`，Apple `renamex_np(RENAME_EXCL)`，Windows `MoveFileExW` 不带替换标志）放到位，逐字节回读（`.pvt` 另比对结构与 `metadata.plist`），通过才删掉改名留存的旧文件（`.old`）；任一步失败删掉本次写出的条目、把旧文件改回原名，`errorMessage` 写明回滚结果。仍留着的：
   - 不支持原子不改名的文件系统（macOS FAT / exFAT、WebDAV、部分网络共享）回退为先查后改名，只在单进程内按目录排队，跨进程不保证原子（模块注释写明）。
   - 进程在放到位与提交之间被杀会留下 `.partial` / `.old`；一小时以上的 `.partial` 由下一次往同目录发布时清掉，`.old` 永不自动清理（可能是旧输出的唯一副本）。Windows 上点前缀不隐藏，用户在资源管理器里能看到它们。
   - **普通静帧输出没有走这套**（推断，读代码）：主转换管线 `run_with_config` 与 Apple 标准模式的 `xdremux_convert_impl` 仍 `std::fs::write` 直写最终路径（`pipeline.rs:284`、`lib.rs:2119`、`lib.rs:2363`），Flutter 在转换前 `deleteSync()` 旧输出（`main.dart:1980`），转换失败时旧输出已经没了，崩溃会留下截断文件；SwiftUI 非实况路径同样是先删旧再移入（`ConversionJob.swift`）。见 §5.6。
   - OHOS 核心新增 `libc` 依赖（`renameat2` 系统调用），`ohos-ci.yml` 会编译该目标，真机**未验证**。
6. **Motion Photo 解析覆盖**（PR #119 的结论，已实测于样本，设备行为未验证）：只写在三星 SEF 里、没有 Google XMP 的动态照片不识别；`xdremux_motion_photo_split` 写出的 MP4 带厂商尾字节（三星 SEF 116 B、OPPO 约 2.6 KB），照片 App / AVFoundation 的反应**未验证**；Live Photo 转换路径已裁剪，不受影响。OPPO 17.24 的拆分 MP4 裁尾在 PR #127。
7. **SwiftUI 预发布包的人像转换**（推断）：`apple-v0.1.0` / `apple-v0.1.1` 用 0.4.7 内核，早于 PR #99；PR #99 的复现显示修复前 `xdremux_convert_pipeline` 对两张 OPPO 人像样张在 `stage: verify` 失败，而 SwiftUI 走的正是这条管线。预发布包上的实际表现**未验证**，0.1.2 才会带上。
8. **TestFlight / App Store**：App Store Connect 的处理结果、TestFlight 安装后的界面与两种编码器的真机表现**未验证**；`XDRemuxTransferCore.framework` 缺 dSYM（上传警告，只影响崩溃符号化）；带 x265 的构建与 App Store 条款是否相容未决，开放公开测试链接前需要定下来。去 x265 的方案只有计划稿（`docs/plans/apple-drop-x265.md`）。
9. **iPhone Duo**：Flutter 的安全区修复（0.4.6）与 SwiftUI 的两栏布局、侧边栏工具栏只在模拟器上验证，真机**未验证**。
10. **CI 覆盖**：共 9 个 workflow（`docs/operations/ci.md`）。只有 `ci.yml` 对每个 PR 都跑；`apple-ci.yml` 与 `apple-vt-core.yml` 因 macOS runner 紧张只在 Rust 改动合入 `main` 后和改到 Apple 路径的 PR 上运行（PR #101），改 FFI 的 Rust PR 合并前要在 Mac 上跑 `tools/apple/verify_local.sh`；`harmony-native-ci.yml` 只跑宿主侧回归；安卓 APK 只在 `release.yml` 里构建；Windows / macOS 原生行为与真机照片验收不在 CI 内。11-24 读 shields 徽章：`ci`、`conformance`、`apple-ci`、`apple-vt-core`、`ohos-ci`、`harmony-native-ci`、`transfer-ci`、`release` 在 `main` 上最近一次运行均 passing，`linux.yml` 没有独立运行；徽章不区分提交，`034684a` 上实际跑了哪些**未查**（API 限流）。CI 通过不等于真机验收。
11. **三个前端共用 Rust 内核**（Flutter、鸿蒙原生、SwiftUI），另共用传输 crate：FFI 改动需重新生成 `xdremux_core.h`（`ci.yml` 与 `apple-ci.yml` 校验），并重建鸿蒙 `.so` 复测；`tools/ohos/build_hap.*` 会先核对 `.so` 导出了 Dart 绑定查到的每个符号（PR #123）。`xdremux/rust/src/ffi_guard.rs` 的 panic 守卫只在 `panic = "unwind"` 下生效，目前只有 `build_ohos.sh` 这样编；其他平台解析器 panic 仍会杀掉宿主 App（模块注释写明，遗留限制）。
12. **安装包许可文本**：Windows、macOS、Linux 的打包步骤都复制 `LICENSE` / `LICENSING.md`，`v0.4.7` 的发布 run 成功；产物里的文件没有打开核对（**未验证**）。
13. **文档治理**：2026-11-24 之前 `.gitignore` 把 `docs/` 整体忽略、靠 `git add -f` 入库，期间 `docs/research/oppo-gallery-17.24.12-20261114.md`（PR #127 / #128 的依据）和 `docs/plans/apple-drop-x265.md` 只存在于本机；已改为默认跟踪并补入（PR 见 §5.8）。`docs/validation/ios-device-20260816.md` 含设备 UDID，仍未入库，需脱敏后再定。

## 5. 下一步优先级

1. **Flutter 0.4.8**：前置已满足（#116、#124）。先在 `main` 跑一次全平台预检（`gh workflow run release.yml -R BeetMan/XDRemux-Flutter --ref main -f platforms=all`，覆盖 §4.1），通过后切 `pubspec.yaml` 版本号并发版，带上 `v0.4.7` 之后的 40 个合并。
2. SwiftUI：出 0.1.2 预发布，带上 PR #99 的人像修复与 0.1.1 之后的界面改动（§4.7）；确认 TestFlight 构建 5–8 的处理结果与真机安装；开放公开测试链接前按 `docs/plans/apple-drop-x265.md` 定下 x265 与 App Store 条款的问题；补传输框架的 dSYM。`docs/plans/apple-native.md` §3 的 P4 跨端回归仍无记录。
3. OPPO 17.24 堆叠 PR #127 → #128 → #129：三个分支各同步 `main`（落后 7 个提交）后按顺序合；合并后删 §2.2 的两个 11-18 前身分支（先打 `archive/*` 标签）。
4. PR #130（Apple 逐帧实况风格）：合并前在 iPhone / macOS 照片 App 上验证 §4.4 的编辑与颜色保留。
5. 鸿蒙原生版：真机复测后发 0.5.5，带上 PR #99 的人像校验修复、PR #123 的发布原语（OHOS 真机**未验证**）与 NEON 版 x265（`docs/research/ohos-hw-hevc-20261115.md`）。
6. 普通静帧输出事务化（§4.5）：评估把 `live_photo_publish.rs` 的 staging → 改名 → 回读推广到 `xdremux_convert` 系列的输出，并让 Flutter 不再在转换前删旧输出；约 2–3 天。
7. 按 `docs/testing/styles-hdr-device-checklist.md` 跑完整真机 A/B（覆盖 §4.3），并在 iPhone 上复核 PR #100 与 #116 的 VideoToolbox 输出；之后是每图的 key 4 / `"h"`（`linear_metadata`）与 P1-3 统计。
8. `upstream-20261115.md` 的 P2：华为 `it35` 按 GB/T 48347 UWAInfo 逐字段对应（只读解析已随 PR #122 入库，接入未做）；用已链接的 libheif 解增益映射（先探针确认 libde265 能否解 Rext 4:0:0）；对照上游 #83 / #84 加 BT.2020 解码回算断言。
9. PR #119 留下的两项（§4.6）：先找三星只写 SEF 的真机样本；在照片 App / AVFoundation 上测带厂商尾字节的拆分 MP4。
10. 清理 §2.2 的四个被替代分支（先打 `archive/*` 标签，删除需用户同意）；决定 `research/oppo-gallery-17.24` 的研究记录是否入库。
11. 评估 macOS / Windows 发布包是否启用 10-bit x265；Flutter macOS 默认仍是 x265，GPU 开关切 VideoToolbox，需要一起评估。

暂缓 / 观察（不排期）：

- Apple 实况 → 安卓动态照片：暂缓，等上游 #97 合入且 `android-motion-gallery-matrix` 出现实机 PASS 再定（`upstream-20261115.md` 待决策项）。
- 上游 #92（MakerNote tag 25）、#91（双层 HDR JPEG）、研究仓 PR #10：只观察，触发条件见 `upstream-20261115.md`。
- `feat/oppo-filter-ecosystem`、`feat/m9-moment`：维持 10-29 的暂缓接入决定（§2.4）。
- `research/iphone-next` 吸收上游 #85：沿用 `upstream-20261030.md` 的 P1，10-29 之后没有进展。

上一版第 5 节中已完成、本版移除的项：PR #116 合并（§5.2）；PR #120 合并（§5.3）；Live Photo 发布校验的后半段由 PR #123 完成（§5.4，§4.5）；鸿蒙原生并入 `main`（§5.5 的工程部分，0.5.5 仍待发）；华为 `it35` 的字段对应文档（§5.7，接入未做）；`docs/operations/ci.md` 已补齐（§5.9）。

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
# 鸿蒙原生宿主回归（CI 见 harmony-native-ci.yml；需 Node 24、Python 3、g++）
for t in apps/harmony/tests/*.mjs; do node --experimental-strip-types "$t" || break; done
python3 -m unittest apps.harmony.tests.hap_verifier_test
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
- 仓库布局与数据流：`docs/architecture/overview.md`、`docs/architecture/data-flow.md`；FFI 契约与 Live Photo 写出规则：`docs/architecture/ffi-contract.md` §3
- 平台行为矩阵：`docs/validation/platform-behavior-matrix.md`
- 发版流程：`docs/operations/releasing.md`；CI：`docs/operations/ci.md`
- Styles 管线：`docs/modules/styles-pipeline.md`；HEVC 编码：`docs/modules/hevc-x265.md` 与 `xdremux/rust/src/hevc/mod.rs` 的模块注释；Live Photo 包：`docs/formats/live-photo-pvt.md`
- 原生 Apple 前端：`apps/apple/README.md`（构建、编码器变体、TestFlight）、`docs/plans/apple-native.md`（执行记录）、`docs/plans/apple-drop-x265.md`（去 x265 计划稿）
- 鸿蒙原生前端：`apps/harmony/README.md`、`apps/harmony/BUILDING.md`、`docs/plans/harmony-native.md`
- OPPO 尾部与水印：`docs/formats/oppo-watermark.md`、`docs/research/oppo-gallery-17.10.5.md`、`docs/research/oppo-gallery-17.24.12-20261114.md`（附探测脚本 `oppo_gallery_tail_probe.py`）
- 局域网互传：`docs/plans/local-transfer-plan.md`、`docs/testing/local-transfer-*.md`
- Motion Photo 解析对拍：`docs/research/motion-photo-liblivephoto-diff-20261115.md`
- 上游动向与规划：`docs/research/upstream-20261115.md`（上一版 `docs/research/upstream-20261030.md`）
- 历史快照：`docs/archive/current-status-20261115.md`、`docs/archive/current-status-20261031.md`、`docs/archive/current-status-20261029.md`

## 8. 不适用条件

- 本文是**时间点快照**：分支领先数、CI 状态、版本号会变化，超过约两周即应重写而不是续改。
- 本文不替代真机验收记录：平台行为以 `docs/validation/` 与 release 记录为准。
- 本文不包含任何会话内隐私信息（本机绝对路径、账号、令牌）。
