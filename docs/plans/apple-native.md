# 原生 Apple（iOS / macOS）前端开发计划

> 状态：2026-10-30 起草，仅规划，未创建任何代码。模板沿用 `feat/harmony-native` 分支的
> `docs/plans/harmony-native.md`；鸿蒙原生版已证明"同一 Rust 内核 + 第二个原生前端"可行，
> 本计划吸收其做法并修正其暴露的问题。

## 1. 目标与范围

在现有仓库新增 SwiftUI 原生 iOS / macOS 应用，继续使用同一份 Rust 转换核心
（`xdremux/rust`，C ABI 见 `architecture/ffi-contract.md`）。
不复制 Rust 算法、不替换 Windows / Android / Linux / 鸿蒙的 Flutter 前端、不回改已发布标签。
原生版直接在 `main` 上以独立目录推进，不开长期分支（鸿蒙分支与 main 周期性合并的成本是教训）。

与 Flutter 版的关系：先以独立 bundle ID 并行发布；达到 §3 P4 对等验收后，由维护者决定是否在
Apple 平台替换 Flutter 版。`apps/flutter/ios`、`apps/flutter/macos` 在此之前保持可构建。

为什么做原生（Flutter 做不到的部分）：

- **HDR 预览**。Flutter 不能渲染 HDR 图像；SwiftUI `Image.allowedDynamicRange(.high)`
  （iOS 17 / macOS 14）可直接显示转换后的 ISO 21496-1 HEIC。这是本产品最核心的体验差距。
- 照片库直接写入（`PHAssetCreationRequest` 正确配对 Live Photo 的 HEIC + MOV）。
- Quick Look、从 Apple 照片拖入、App Intents / 快捷指令、Mac 菜单栏、Share / Action Extension。
- Mac 沙盒内的安全作用域书签（持久化输出目录授权）。

第一阶段交付范围（P0–P2）：

- 文件 / 相册导入、分类、详情优先的单张流程（§8）、任务队列与进度、设置持久化。
- OPPO 兼容 / Apple 标准输出；摄影风格、摄影风格 3、人像等现有 Rust 能力。
- 输出导出、失败重试、检查点恢复；HDR 预览。

后续范围（P3）：Motion Photo 识别 / 拆分、Live Photo 配对与相册写入、Share Extension 接收、
批量导出、VideoToolbox 硬件编码分块路径。

暂不纳入：Swift/Vision 研究后端（`apps/flutter/ios/SwiftBackend`、`macos/XDremuxMacBackend`
保持研究路径，不接入产品）、Apple 私有框架侧载、分割模型、跨设备同步。
原生前端不代表具备 Apple 照片编辑器；人像 / 风格编辑效果仍在 Apple 照片真机验收。

## 2. 建议目录与调用链（仅规划）

```text
apps/apple/                      原生应用与 Swift 包
  XDRemux.xcodeproj / project.yml  xcodegen 生成（沿用上游 apps/macos 的 project.yml 习惯）
  App/                           多平台 SwiftUI target（#if os(iOS)/os(macOS) 分流）
  Packages/
    XDRemuxCore/                 SPM binaryTarget → XDRemuxCore.xcframework（Rust 产物，不入 Git）
    XDRemuxKit/                  C ABI 的 Swift 包装：异步执行器、Codable 报告、RAII 释放、进度流
    XDRemuxModel/                纯 Swift 业务模型：配置、队列、检查点、动态照片、输出事务（无 UIKit/AppKit 依赖）
  ShareExtension/                从 apps/flutter/ios/Share Extension 迁移
  Tests/                         XDRemuxKit / XDRemuxModel 的 swift test（CI 在 macOS runner 跑，不需要模拟器）
xdremux/rust/
  cbindgen.toml                  生成 include/xdremux_core.h（新增）
  include/module.modulemap       Swift 导入用（新增）
  build_apple.sh                 新增：ios-arm64 / ios-simulator-arm64 / macos-universal → XCFramework
tools/apple/
  verify_apple_bundle.py         核对 .app / .ipa 内版本、最低系统、嵌入 Rust 核心哈希（对应鸿蒙 verify_harmony_hap.py）
```

```text
SwiftUI View → ViewModel（@Observable）→ XDRemuxModel（队列/事务/策略）
                                         ↘ XDRemuxKit（async 包装）→ XDRemuxCore.xcframework（Rust C ABI）
                                         ↘ 平台服务：PhotoKit / FileImporter / NSOpenPanel / Share / QuickLook
```

分层规则（与鸿蒙版一致，并加一条）：

- 算法、容器处理、EXIF 策略留在 Rust；URI 授权、文件物化、相册写入留在平台层。
- `XDRemuxKit` 只做类型与生命周期转换，不承载转换算法，也**不承载编排流程**。
- **新增：跨端共享的决策逻辑下沉到 Rust**。鸿蒙分支把摄影风格 3 的编排写进了桥接层
  `ps3_pipeline.h`，Flutter 在 Dart 里又有一份；Swift 版动手前先把这类逻辑做成 Rust 导出，
  三端共用。候选清单见 §4.2。

## 3. 阶段与验收

### P0：工具链与 ABI 验证

- Rust 侧加 `cbindgen` 生成 C 头文件；鸿蒙桥接靠手抄结构体 + `static_assert` 兜底，Swift 不重复这条路。
- 新增 `build_apple.sh`：复用 `build_ios.sh` 的 x265（含 Main10）静态库构建，增加
  `aarch64-apple-ios-sim` 与 `aarch64-apple-darwin` / `x86_64-apple-darwin`（macOS universal），
  产出 `XDRemuxCore.xcframework`；记录 Rust 提交、工具链、各 slice 哈希。
- `XDRemuxKit` 最小实现：`version()`、`classify(path:)`，对应 free 函数在 `deinit`/`defer` 调用。
- 阻塞调用放在专用执行器（actor 或 `DispatchQueue`），绝不在 MainActor 上调 Rust。
  Rust 内部 x265 自带多线程，Swift 侧默认串行化调用；并发度交给 `maxConcurrentJobs` 配置，
  先验证两路并发时内存峰值再放开。
- 核对 release profile `panic = "abort"`：Swift 侧无法捕获 Rust panic，依赖 Rust 入口全部
  包闭包转 `Result` 的既有纪律；P0 用故意损坏的输入验证不崩溃。
- iOS 静态链接时，Swift 直接引用符号，不再需要 Dart `DynamicLibrary.process()` 的 `-u` 符号保留
  （`apps/flutter/test/ios_ffi_contract_test.dart` 守护的那类问题在原生版天然消失），但仍要在
  Release 配置实测 dead-strip 后可用。

验收：最小 macOS 与 iOS（模拟器 + 真机）应用取得核心版本并分类一个测试文件；
Instruments Leaks 连续调用 1000 次无泄漏；损坏输入返回错误 JSON 而非崩溃。

**P0 执行记录（2026-10-30，分支 `feat/apple-native-p0`）**

- 已落地：`xdremux/rust/cbindgen.toml` + 生成并提交的 `include/xdremux_core.h`（38 个导出，与 lib.rs 一致，
  排除 x265 内部导入块）、`include/module.modulemap`（模块名 `XDRemuxCoreC`）、`tools/apple/check_header.sh`
  头文件新鲜度检查；`xdremux/rust/build_apple.sh` 产出 macOS arm64 / iOS arm64 / iOS 模拟器 arm64 三切片的
  `apps/apple/Frameworks/XDRemuxCore.xcframework`（每切片 = Rust staticlib + libx265.a 用 libtool 合并，
  附 BUILD_RECORD.txt 记录 Rust 提交、工具链与各切片哈希）。
- `apps/apple/Packages/XDRemuxKit`：`XDRemuxCore` binaryTarget、`XDRemuxKit`（后台串行队列、RAII 释放、
  Codable 报告、进度轮询）、`XDRemuxModel`（`ConversionConfig` 与 Dart 同 JSON 键）。`swift test` 17 项通过
  （含 500 次分配 / 释放 soak、损坏与缺失输入不崩溃）；设置 `XDREMUX_SAMPLE_DIR` 后，一张真实 OPPO ProXDR 样本经
  Swift 包转换并通过 `xdremux_verify_output`，进度回调被观察到。
- `apps/apple/project.yml`（xcodegen）生成单一多平台 target，macOS arm64 与 iOS 模拟器 arm64 均编译链接通过。
  探针页展示内核版本、编码能力，并对导入文件做分类与结构检查。
- 未完成：Instruments Leaks 实测、iOS 真机安装（需本机签名）、x86_64 切片（宿主无对应 Rust 目标与 x265 构建，
  当前仅 Apple Silicon）。

### P1：单文件闭环

- 导入：iOS 用 `PhotosPicker`（请求 HEIC 原始资源，拒绝被转码的 JPEG）与 `fileImporter`；
  macOS 用 `NSOpenPanel` 与拖放。所有输入先复制到应用私有输入目录再交给 Rust，不把安全作用域 URL
  直接传给 Rust。
- 输出写任务私有临时路径，`xdremux_verify_output` 通过后才发布；失败不留伪成功文件，不覆盖原图。
- HDR 预览：用 `allowedDynamicRange(.high)` 显示输出；输入预览沿用 ImageIO 缩略图
  （迁移 `HeicThumbnailRenderer.swift`，去掉 MethodChannel 包装）。
- 导出：iOS 走分享面板与 `PHAssetCreationRequest`；macOS 走 `NSSavePanel` / 在访达中显示。
  应用报告成功与用户可见保存成功分别验证。

验收：已知 HEIC / JPEG 样本导入 → 分类 → 转换 → 导出成功；原图哈希不变；
输出与同配置 Flutter 版输出按 `tests/conformance` 的规范化结构摘要一致（不要求整文件哈希）。

**P1 执行记录（2026-10-30，分支 `feat/apple-native-p1`）**

- `XDRemuxModel` 新增 `ConversionJob`（临时路径 → `verify_output` → 发布，失败不留文件、不碰输入；
  `skipExisting` 决定覆盖还是追加 ` (2)`）、`OutputPlanner`（`<stem><suffix>.heic`、按模式分目录）、
  `SettingsStore`（与 Dart 同键的 JSON 记录）；`ConversionBackend` 协议让 Job 可用假引擎测试，`XDRemuxEngine` 实现之。
  模型测试 19 项，全部不依赖 XCFramework。
- `XDRemuxKit` 新增 `PhotoDetails` 解码、`ImageLoading`（ImageIO 缩略图、`kCGImageSourceDecodeToHDR` 全图解码）。
- App：`LibraryModel` + 列表 / 详情 / 设置三视图。macOS 为 `NavigationSplitView` + 拖放；iOS 为 `NavigationStack` +
  `PhotosPicker`（`preferredItemEncoding: .current` 取 HEIC 原图）。详情优先：导入即 classify / inspect / details，
  转换选项按输出模式裁剪，"转换这张" 与工具栏 "全部转换" 分离；输出用 `allowedDynamicRange(.high)` 预览。
  导出：iOS `PHAssetCreationRequest`（add-only 权限）与 `ShareLink`；macOS `NSSavePanel`、在访达中显示、`ShareLink`。
  设置改动即持久化，运行中任务保留开始时快照。`--import <files> [--convert-all]` 启动参数用于脚本与冒烟。
- `xdremux` CLI（swift-argument-parser）：`convert`（默认）/ `inspect` / `classify` / `details` / `verify` / `capabilities`，
  `--json`、退出码、`--no-overwrite`、`--categorize`、`-v` 显示 x265 日志；与 App 共用 `ConversionJob`。
- 验证：`swift test` 30 项通过（含 opt-in 真实样本：`ConversionJob` 端到端、输入字节不变）；macOS arm64 与 iOS 模拟器
  arm64 构建通过；macOS 上以 `--import --convert-all` 启动，两张 OPPO 样本（X6 LHDR、X7 UHDR）导入、转换、HDR 预览
  与详情显示正常；CLI 对同两张样本 OPPO / Apple 两种模式转换并 `verify` 通过，损坏输入退出码 1。
- 未完成 / 待真机：iOS 模拟器未安装运行时，iOS 界面未实际运行；照片库保存与 PhotosPicker 需真机；HDR 预览在
  `Image(decorative:)` 路径上是否真正以 HDR 亮度显示待在 HDR 显示器上确认；双语 String Catalog 未做（当前中文文案）；
  Live Photo / Motion Photo / Share Extension 属 P3。

### P2：队列、设置、检查点

- 移植 `apps/flutter/lib/models/app_models.dart` 的 `ConversionConfig`（约 20 个字段）、
  `QueueItem`、`MotionPhotoSummary` 与 `checkpoint_model.dart`，**保持相同 JSON 键名与枚举 name**，
  让设置和检查点文件可与 Flutter 版互通。
- 设置采用鸿蒙版的草稿 / 提交分离：保存成功后才成为后续任务使用的快照；运行中任务使用开始时快照，
  设置变更不影响已启动任务。
- 队列状态机沿用五端统一的 pending / running / succeeded / failed 与重试 / 移出 / 清除已完成；
  journal 原子写（临时文件 + rename），启动时校验 schema 与输入文件存在性，缺失输入变为可见失败项。
- 取消语义：现有 ABI 没有安全取消，只能"当前任务结束后停止"。真正的取消需要 Rust 加取消标志
  检查，列为内核改动（§4.3），P2 不承诺。
- 主工作流页（"一帧影像，动用两台手机"四步）与批量整理页移植；人像实验室仍隐藏。
- 文案：Swift String Catalog 双语，术语沿用 `docs/app/flutter-app.md` §6（Apple 照片 / OPPO 原始照片 /
  OPPO 兼容 / Apple 标准）。与 Dart 内联 `t(zh, en)` 不共享，接受这一处分叉。

验收：转换期间 UI 可交互；错误可定位到单项；设置变更后可重新转换；杀进程重启后队列按检查点恢复；
Flutter 版生成的检查点文件可被原生版读取。

**P2 执行记录（2026-10-30，分支 `feat/apple-native-p2`）**

- `QueueJournal` / `QueueJournalStore`：队列 journal（`queue.json`，schema 1）原子写入（临时文件 + replace），
  加载时校验 schema、损坏文件隔离为 `.corrupt-<ts>`；恢复规则与鸿蒙版一致：`running` 回到待处理不自动续跑，
  输出丢失的成功项变为失败，输入副本丢失的项变为失败并提示重新导入。5 项测试。
- `XDRemuxEngine` 并发度可配置（并发队列 + 可调上限门），`convertAll` 用 TaskGroup 按 `maxConcurrentJobs` 限宽；
  设置页加 Stepper。
- macOS 输出目录：`OutputLocation` 用安全作用域书签持久化用户选择的目录，设置页可选择 / 恢复默认。
- `LibraryModel` 每次 items 变化即写 journal，启动时恢复并重新读取缩略图与分类。
- 验证：`swift test` 35 项通过；macOS 上带两张样本启动转换后退出，空参数重开，两项以已完成状态恢复，HDR 预览与
  详情完整，输出文件名不再带沙盒副本前缀。
- 未做：Flutter 检查点文件（`checkpoint_model.dart`，donor 与回传配对）互读；批量整理页；运行中任务的 config 快照
  已由 `ConversionJob` 复制保证。

**P2 补充：主工作流"一帧影像，动用两台手机"（2026-10-30，分支 `feat/apple-native-p2`）**

- `RoundTrip`（Model）：`editCopyConfig` 强制 Apple 标准 + 摄影风格、后缀 `.apple-edit`；`createEditCopy` 复用
  `ConversionJob`（单次转换，不产生 OPPO 中间文件）；`writeback` 经 `WritebackBackend` 调 Rust
  `xdremux_writeback_returned_photo`（模式字节 0=Apple、1=OPPO，与 Dart 一致），报告 `success && outputValid != false`
  才从暂存路径发布为 `<回传 stem>.<mode>-final.heic`；OPPO 输出或恢复水印缺 donor 直接拒绝。5 项假引擎测试。
- App：工具栏入口打开四步 sheet（选 OPPO 原图 → 生成编辑副本 → 选回传照片 → 写回），macOS 支持拖入；
  导出按钮通用化为 `FileExportButtons`，编辑副本与最终文件都可保存 / 分享 / 定位。
- CLI：`xdremux edit-copy <oppo.heic>` 与 `xdremux writeback <returned.heic> --donor <oppo.heic> -m oppo|apple
  [--no-restore-watermark]`。
- 验证：`swift test` 46 项通过；X7 UHDR 样本经 CLI edit-copy → 以编辑副本充当回传 → OPPO 与 Apple 两种写回均成功，
  OPPO 模式恢复 9 个 OPPO 私有条目，Apple 模式恢复画布水印并移植 EXIF，两个输出 `verify` 通过；
  X6 LHDR 样本作为 donor 被 Rust 拒绝（"donor photo has no UHDR gain-map payload"），与 Flutter 行为一致。
- 未验证：真实 iPhone 回传文件（需要真机往返）；GUI 四步页仅编译与渲染，未人工点击走完。

**P2 补充：双语与系统集成（2026-10-30）**

- String Catalog `App/Localizable.xcstrings`：源语言 zh-Hans，158 条英文译文；非 View 层文案（状态、错误、设置枚举标题、
  面板按钮）统一改走 `String(localized:)`，`InfoRow` / `StepCard` 标签改为 `LocalizedStringKey`。
  `-AppleLanguages (en)` 启动实测列表与四步页全部英文。术语与 Flutter `l10n` 一致（Apple Standard / OPPO Compatible）。
- `CFBundleDocumentTypes` 声明 HEIC / HEIF / JPEG（Viewer，Alternate），`onOpenURL` 接入导入：访达"打开方式"、Dock 拖入、
  iOS"用 XDRemux 打开"均走同一导入路径。`--round-trip` 启动参数直接打开四步页，供冒烟。

### P3：实况、分享与系统集成

- Motion Photo 识别 / 拆分、Live Photo 配对复用 Rust 导出（`xdremux_motion_photo_*`、
  `xdremux_make_live_photo`、`xdremux_live_photo_pair_valid`）；配对校验通过才写相册，
  任一文件失败不得报告配对保存完成。
- Share Extension 从 `apps/flutter/ios/Share Extension` 迁移，保留"优先取 `public.heic` 原始表示"
  的逻辑，去掉 `receive_sharing_intent` 的 app-group 契约，改为直接写入应用私有收件箱。
- 硬件编码分块路径：`xdremux_prepare_tiles` → `VideoToolboxHevcEncoder.swift` → `xdremux_assemble_tiles`，
  两份 Swift 编码器（iOS / macOS Runner 各一份）合并为一份。
- macOS：沙盒下输出目录用安全作用域书签持久化；菜单栏 / 托盘替代品按需评估。
- 后台：iOS 不承诺后台持续转换（与 Flutter 版口径一致）；用 `BGProcessingTask` 做可选续跑，
  不可用时提示前台要求并保存状态。

验收：普通图、Motion Photo、无效文件混合队列行为正确；iPhone 照片中 Live Photo 可播放有声音；
分享面板导入保留 HEIC 原始字节。

**P3 执行记录（第一批：动态照片 / Live Photo，2026-10-30，分支 `feat/apple-native-p2`）**

- `MotionPhotoBackend` 协议（inspect / make_live_photo / pair_valid / split）；`ConversionJob` 在校验通过的静帧上按
  `MotionPhotoMode` 处理：`livePhotoPair` 用 Rust 合成带 content identifier 的静帧 + MOV，配对校验通过才发布为
  `<stem><suffix>.heic` + `.mov`；`stillAndVideo` 拆出 `.motion.mp4` / `.primary.mp4`；`still` 忽略视频。
  5 项假引擎测试覆盖配对失败不发布、非动态照片忽略模式。
- Kit：`MotionPhotoReport` 解码、`makeLivePhotoFiles`、`livePhotoPairValid`、`splitMotionPhoto`。
- App：导入即识别动态照片（列表摘要与详情显示时长 / 尺寸 / 双流 / 声音），详情页按张选择处理方式（默认取全局设置），
  结果区列出配对视频；iOS 保存到照片库时以 `.photo` + `.pairedVideo` 写入同一 asset；macOS 多文件时选文件夹整组存储，
  访达定位与分享同时带上 MOV；journal 记录 `pairedVideoPath` / `extraVideoPaths` / `motionMode`，视频丢失视为失败。
- 验证：opt-in 真实 OPPO 动态照片（`XDREMUX_MOTION_SAMPLE_DIR`）端到端：Live Photo 配对校验通过、静帧 verify 通过、
  拆分有产物；macOS GUI 导入一张动态照片默认 Live Photo 合成，输出 `motion-master_iso.heic` + `.mov`。
- 未验证：iPhone 照片中 Live Photo 播放与声音（需真机）；Share Extension、批量导出仍待做。

**P3 执行记录（第二批：真正取消、摄影风格 3、按选项校验，2026-10-30，分支 `feat/apple-native-p3b`）**

- 内核（§4.3 取消项落地）：`progress` 注册表的槽位加 `cancelled` 标志，新导出 `xdremux_progress_cancel(handle)`；
  增益图瓦片构建与 x265 批量编码循环（含并行 worker 线程，句柄在派发前捕获）检查标志，命中即返回
  `"conversion cancelled"` 失败报告。UI 先申请句柄再派发 worker，因此取消早于认领也会保留。头文件重生成，
  `extern "C"` 导出 39 个。2 项 Rust 单测。
- Kit：`convert` 用 `withTaskCancellationHandler` 把 Swift 任务取消映射为 `xdremux_progress_cancel`，返回后抛
  `CancellationError`；新增 `verifyStylesOutput` / `verifyPortraitOutput` / `injectStyles3`。
- Model：`ConversionBackend.verifyOutput(path:styles:portrait:)` 与 Flutter `conversion_backend.dart` 一致，
  按 Rust 配置字节决定是否追加风格 / 人像结构检查；`Styles3Backend` 协议，校验通过后在暂存文件上注入
  texture_styles + 语义 matte，失败即 `styles3Failed` 且不发布；grain seed 与 Dart `_grainSeedFor` 同一哈希
  （UTF-16 单元 ×31，31 位掩码），同名文件跨端颗粒一致。取消后暂存目录随 defer 删除，不发布任何文件。
  5 项新假引擎测试（校验标志、PS3 注入 / 跳过 / 失败、取消清理）。
- App：每张照片的转换任务可单独取消（列表右键菜单、详情页进度条旁"取消"），工具栏在转换中变为"停止转换"
  （停止队列并取消正在进行的任务）；取消的照片回到"可转换"。
- CLI：Ctrl-C 取消当前任务，清理暂存后以 130 退出；JSON 模式输出 `cancelled: true`。
- 验证：`swift test` 56 项通过（含 opt-in 真实样本：最大样本 40 ms 后取消在 0.24 s 内抛出 `CancellationError`；
  Apple 标准 + 摄影风格 3 端到端后 `xdremux_verify_styles_output` 通过）；CLI 对 X7 样本 `--styles3` 转换并
  verify 通过，`kill -INT` 后退出码 130 且输出目录为空；macOS App 构建并以 `--import --convert-all` 冒烟通过。
- 未验证：GUI 中点击取消（样本转换 1 s 内完成，未人工命中）；摄影风格 3 输出在 Apple 照片里的纹理编辑入口（需真机）。

**P3 执行记录（第三批：iOS 模拟器首次实跑，2026-10-31，分支 `feat/apple-native-ios`）**

- iOS 27.2 模拟器运行时已可用。`build_apple.sh` 构建 `ios-sim` 切片，App 装入 iPhone 18 Pro 模拟器，以 `--import … --convert-all`
  启动：X7 UHDR 样本与 OPPO 动态照片均转换完成。
- 修掉三处 iOS 特有问题：
  1. 工具栏挂在 `NavigationStack` 之外，iOS 上整条工具栏不显示（macOS 由窗口工具栏接住所以没暴露）→ 移到栈内。
  2. HDR 预览黑图：`kCGImageSourceDecodeToHDR` 的 CGImage 在 iOS 上 `Image(decorative:)` 渲染全黑；改用 `UIImageReader`，
     并仅在 `UIScreen.potentialEDRHeadroom > 1` 时请求 HDR（模拟器与无 EDR 面板会把 HDR UIImage 画成黑图）。
  3. journal 绝对路径：iOS（和 macOS 沙盒）容器目录每次安装 / 更新换 UUID，重装后所有项变成"输入副本已不存在"。
     `QueueJournal.portable/resolved` 把容器内路径存为 `~/…`，容器外（macOS 自选输出目录）保持绝对；schema 不变，
     旧的绝对路径按原样读取。2 项测试。重装后两项以"已完成"恢复并有 HDR 预览。
- 验收项达成：详情页"保存到照片"→ 权限 → 以 `.photo + .pairedVideo` 写入一个 asset；模拟器 Photos.sqlite 中
  `ZKINDSUBTYPE = 2`（Live Photo），DCIM 出现 `IMG_0007.HEIC + .MOV`，"照片"App 显示 LIVE 标记。
  `PhotosPicker(.current)` 从相册导入 OPPO HEIC 后识别为 X7 UHDR（原始字节未被转码）。
- 未验证：Live Photo 声音（模拟器无法听）、HDR 亮度（模拟器无 EDR）、真机签名安装。CI 仍只跑 macOS 切片。

**§8 补充：工具栏与布局按 HIG 收敛（2026-11-01，分支 `feat/apple-toolbar`）**

- 布局不再按平台硬编码：`horizontalSizeClass == .compact` 走 `NavigationStack`，其余（Mac、iPad、展开的折叠屏）走
  `NavigationSplitView`；`PhotoListView` 由父视图指定"推入详情"还是"侧栏选中"。
- 工具栏从五个同级图标收成三组：**导入**（iOS 为菜单：从照片 / 从文件，macOS 直接选文件）、**主动作**（全部转换 /
  停止转换，`.borderedProminent`，紧凑宽度放 `.bottomBar` 并显示数量）、**更多**（一帧影像、设置，`.secondaryAction`，
  iOS 折叠成 ⋯ 菜单）。`PhotosPicker` 改为 `.photosPicker(isPresented:)` 修饰器，因为 picker 按钮不能放进 `Menu`。
- 实测：iPhone 18 Pro 顶部"+ ⋯"胶囊、底部"全部转换（1）"玻璃主按钮；iPhone Duo 侧栏只剩两项，主动作在底部；
  macOS 窗口工具栏"导入 + 主动作"与次级项。iOS 26 底部栏会把 `Label` 画成纯图标，紧凑宽度用纯文字按钮。
- 未验证：折叠屏展开到 regular 宽度时的分栏（模拟器当前状态为 compact）。

**P3 执行记录（第四批：iOS Share Extension，2026-11-01，分支 `feat/apple-share-extension`）**

- 新 target `XDRemuxShare`（iOS app-extension，`platformFilter: iOS` 只嵌入 iOS 包）。`ShareViewController` 移植 Flutter
  运行器的要点：先请求 `public.heic` 文件表示（"自动"格式下 `public.image` 会被转成 JPEG），再退到 heif / jpeg / image /
  fileURL；文件名按真实类型修正后缀；不做转换（扩展内存上限远低于 8K ProXDR 解码）。
- 交接改为 App Group 收件箱 `group.io.github.beetman.xdremux.swiftui/Inbox`，去掉 receive_sharing_intent 的 manifest
  契约；宿主在启动与回到前台（`scenePhase == .active`）时导入并清空收件箱。`SharedInbox.swift` 由两个 target 共用。
- xcodegen 注意事项：`info.properties` 会重新生成 Info.plist，手写的 `NSExtension` 字典会被覆盖，必须写在 project.yml；
  macOS 的 App Group 权限需要开发证书签名，所以 macOS 用单独的 `App/XDRemux-macOS.entitlements`
  （`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`）。
- 验证：iPhone 18 Pro 模拟器从"照片"分享 OPPO HEIC → 分享面板出现 XDRemux → 提示"已加入 XDRemux：1 张" →
  收件箱出现原名 `.HEIC` 文件（23.4 MB，原始字节）→ 启动 App 后识别为 X7 UHDR 并清空收件箱；macOS 构建不含扩展。
- 未验证：真机上的 App Group 签名；从"文件"App 分享多个文件。

**P2 遗留：批量整理页（2026-11-01，分支 `feat/apple-organize`）**

- Model `OrganizePlanner`：与 Flutter `organize_page.dart` / 上游 `categorize` 同一布局
  `<根>/<静态照片|实况照片>/<拍摄模式文件夹>/<原名>`，实况照片的 MOV 同目录同名；冲突规避"(n)"同时考虑本批已规划的名字
  （大小写不敏感）与磁盘已有文件，整理进自己所在目录视为重复而不是冲突；`execute` 跳过重复、配对 MOV 只在位置变化时复制、
  失败逐项记录。5 项测试（含真实临时目录端到端）。
- App `OrganizeView`（"更多"菜单 → 批量整理）：选文件夹（安全作用域在页面存续期内保持）→ 递归扫描 HEIC/HEIF/JPEG →
  `xdremux_classify` 取拍摄模式文件夹 → 同名 MOV 经 `xdremux_live_photo_pair_valid` 确认才视为配对 → 按模式分组预览
  目标目录 → 开始整理。输出目录默认与照片文件夹相同。macOS / iOS 同一视图（iOS 通过"文件"选择文件夹）。
- 未验证：GUI 走完一遍（只做了编译与 Model 层测试）；iOS 上对"文件"目录的递归枚举是否受安全作用域限制。


**P2 遗留：华为照片准入策略（2026-11-01，分支 `feat/apple-huawei-policy`）**

- `HuaweiPhotoPolicy.admission(huaweiHdr:portraitReady:stylesRequested:motionPhoto:)` 与 Flutter
  `huawei_photo_policy.dart` 同一规则：普通华为 HDR 跳过（"华为 HDR 原生兼容 Apple 照片，无需转换"），开了摄影风格、
  人像可转换或动态照片时放行。`HuaweiPhotoInfo`（isHdr / hasXtstyle / portraitReady）由 Kit 从
  `xdremux_huawei_inspect` 解码，只对 HEIC/HEIF 调用。4 项策略单测 + 1 项只读冒烟（垃圾输入不抛错、OPPO 样本不命中、输入字节不变）。
- App：导入时记录 `huawei` 与 `policyReason`，`isConvertible` 排除被策略跳过的项，状态行显示原因，摘要显示"华为 HDR" /
  "华为人像 → Apple 人像"；设置变化（摄影风格开关）后对所有空闲项重新评估，与 Flutter `_syncHuaweiHdrPolicy` 一致。
- 未验证：本地没有华为样本，真实华为 HDR / 人像文件的识别只靠 Rust 侧已有测试；人像转换路径（Flutter 的
  `huaweiPortrait` 流程）未移植，portraitReady 的文件目前按普通输入进入队列。


**基础设施（2026-11-01，分支 `feat/apple-universal`）：x86_64 切片与 CI 模拟器构建**

- `build_apple.sh` 按架构构建：每个切片对 `XDREMUX_APPLE_ARCHS`（默认 `arm64 x86_64`）各构建 x265（8-bit + Main10，
  x86_64 用 `_x86_64` 后缀目录）与 Rust staticlib，`libtool` 合并后 `lipo -create` 成胖归档；切片目录名沿用 xcodebuild
  约定（`macos-arm64_x86_64`、`ios-arm64_x86_64-simulator`）。iOS 真机仍只有 arm64。
- `build.rs` 新增 `XDREMUX_X265_DIR` / `XDREMUX_X265_MAIN10_DIR` 覆盖，并把 `x86_64-apple-ios`（env 为空）识别为模拟器。
- `project.yml` 去掉 `EXCLUDED_ARCHS[sdk=iphonesimulator*]`，模拟器包与 Share Extension 都是双架构。
- CI：Rust 目标加 x86_64 与模拟器，x265 缓存键改为 `…-universal-sim`，构建 `macos ios-sim` 两个切片并用 `lipo -info`
  断言双架构；新增 `generic/platform=iOS Simulator` 的 App + 扩展构建。
- 验证：本机 `lipo -info` 两个切片均为 `x86_64 arm64`；`generic/platform=iOS Simulator` 构建出的 App 与 appex 均为胖二进制；
  Rosetta 下 x86_64 CLI 对 X7 样本转换并 verify 通过；`swift test` 通过。

### P4：跨端回归与发布

- 相同输入、相同配置，对比原生 Apple、Flutter macOS / iOS 与 Rust CLI 基线输出的容器结构、有效 EXIF、
  主图 / 增益图 / 辅助图尺寸与方向；存在动态 UUID / 时间戳时不要求整文件哈希一致。
- 对照 `docs/validation/platform-behavior-matrix.md` 逐项核对 macOS / iOS 两列；差异要么修掉，
  要么写入矩阵。
- Apple 照片复测 HDR、人像光圈、摄影风格保存后再编辑；覆盖大图、低内存、存储不足、权限拒绝、
  导出中断、重名与重试。
- CI：macOS runner 跑 `swift test`（Kit / Model）与 xcodebuild；发布包用 `verify_apple_bundle.py`
  核对版本与嵌入核心哈希。签名 / TestFlight / 公证仍是独立卡点，与 UI 框架无关。

验收：回归清单无阻断项；已知限制写入说明；经维护者批准后发布。

## 4. ABI、内核改动与资源安全清单

### 4.1 优先复用（无需改 Rust）

`xdremux_version`、`xdremux_classify`、`xdremux_inspect`、`xdremux_inspect_photo_details`、
`xdremux_convert_with_progress` 与 progress begin / read_for / end、`xdremux_verify_*`、
`xdremux_extract_thumbnail` / `xdremux_render_thumbnail`、Motion Photo / Live Photo 全套、
`xdremux_prepare_tiles` / `xdremux_assemble_tiles`、`xdremux_attach_style_layers`、
`xdremux_inject_texture_styles` / `xdremux_inject_semantic_mattes`。
鸿蒙分支复用了其中 23 个符号、只新增 1 个，说明现有 ABI 对第二个前端已经够用。

### 4.2 建议下沉到 Rust 的决策逻辑（新增导出，三端共用）

| 当前位置 | 内容 | 建议导出 |
|---|---|---|
| Dart `main.dart` + `conversion_backend.dart` / 鸿蒙 `ps3_pipeline.h` | 摄影风格 3 编排：注入 texture styles → 注入语义 matte → 验证 | `xdremux_convert_pipeline(input, output, config_json) -> report_json`，一次调用完成转换 + 后处理 + 验证 |
| Dart `huawei_photo_policy` / 鸿蒙 `HuaweiPhotoModel` | 华为 HDR / 人像 / 动态照片的处理策略 | 并入上面的 config_json 决策，或 `xdremux_plan_output(input, config_json) -> plan_json` |
| Dart `main.dart` 预检查 | 预检查告警 / 阻断判定 | 并入 `plan_output` |
| Dart `organize_page` | 按模式分目录、文件名后缀、跳过已存在 | 并入 `plan_output`（返回建议输出路径与原因） |

鸿蒙 `xdremux_motion_photo_extract_still` 已在该分支，合入 main 后原生 Apple 直接用。

### 4.3 需要的内核改动（可选，按阶段决定）

- 取消：转换循环内检查取消标志（`xdremux_progress_cancel(handle)`），P2 若要真正取消才做。
- 回调式进度：目前只有轮询；Swift 端轮询可用，不急。
- cbindgen 配置与 `include/` 目录：P0 必做，对鸿蒙桥接也有益。

### 4.4 实施时必须确认

- UTF-8 路径、`bool` 一字节、`u64` 对齐与所有权；Rust 返回对象使用对应释放函数，失败分支同样清理。
- 不允许 Rust panic 穿越边界；Swift 侧不要依赖"捕获崩溃"。
- 结构体返回值视为不透明句柄，复制字段后立即释放，不在 Swift 侧长期持有裸指针。
- 日志默认不输出 GPS、完整 EXIF 或用户照片路径以外的内容；诊断导出须用户主动操作。
- Mac 沙盒：输出目录与输入目录授权通过书签持久化；Rust 只收到已解析的 POSIX 路径。

## 5. 构建、签名与应用标识

- 核心由 `build_apple.sh` 产出 XCFramework，不入 Git；构建记录源码提交、Xcode / rustc 版本与各 slice 哈希。
- 初期 bundle ID 与 Flutter 版区分（例如 `io.github.beetman.xdremux.swiftui`），避免覆盖已安装稳定版；
  独立发布标签（例如 `apple-v*`），不接管 Flutter 的 Latest。
- 版本来源统一为 Rust `Cargo.toml`；应用 `CFBundleShortVersionString` 另行映射并写入成品核对。
- 最低系统：iOS 17 / macOS 14（HDR 预览与 `@Observable` 的要求）。Flutter 版当前 iOS 15，
  两者并行期间以 Flutter 版覆盖旧系统。
- 发布产物：macOS 未签名 .app / DMG，iOS 未签名 IPA 侧载，与现状一致；签名 / TestFlight / 公证
  需要 Apple 开发者账号决策，另行计划。
- 调试产物与验证日志放仓库外目录，不提交。

## 6. 实施前仍需确认

- 原生版最终是否替换 Apple 平台的 Flutter 版；替换前需设计应用标识与数据迁移。
- `maxConcurrentJobs` 在 iPhone 上的安全并发度（x265 多线程 + 多任务并发的内存峰值）。
- 是否在 P2 就做取消标志的内核改动。
- Mac App Store 是否是目标；若是，沙盒与 x265 静态链接的合规性要提前核对。
- `apps/macos/XDRemuxApp/MIGRATION_PLAN.md` 是 Swift 内核时代（2026-05）的残留，随本计划落地后删除。

## 7. 与鸿蒙原生分支的对照

| 项目 | 鸿蒙原生（`feat/harmony-native`） | 本计划 |
|---|---|---|
| 桥接层 | 1400 行 C++ N-API，手抄 C 声明 + `static_assert` | cbindgen 头文件 + Swift 直接导入，无手抄 |
| 异步 | `napi_create_async_work` + 全局互斥锁串行 | actor / 专用队列，并发度可配 |
| 业务逻辑 | ArkTS 全部重写一份 | Swift 重写 UI 与平台层；决策逻辑下沉 Rust |
| PS3 编排 | 桥接层 C++ 头文件 | Rust 导出 |
| 主机测试 | 16 套 Node `.mjs` 纯逻辑回归 | `swift test` 覆盖 Kit / Model，CI 不需模拟器 |
| 分支策略 | 长期分支，周期性 merge main | 直接在 main 的 `apps/apple/` 推进 |
| 应用身份 | `.arkui` 独立 bundle，`harmony-v*` 标签 | 独立 bundle，`apple-v*` 标签 |
| 包校验 | `verify_harmony_hap.py` | `verify_apple_bundle.py` |
| 图库与导出 | 沙箱本地图库，文档保存选择器导出 | 系统照片库即图库，`PHAssetCreationRequest` 直接写入（§8） |

## 8. 界面信息架构：从鸿蒙原生版借鉴什么、不借鉴什么

鸿蒙原生版把 Flutter 移动端的"队列优先"单页改成了"图库优先"三 Tab（图库 / 队列 / 设置）：
PhotoViewPicker 选图后把原图物理复制进应用沙箱形成本地图库，三列网格浏览，点开单张进入全屏详情卡，
卡片上同时展示格式、尺寸、EXIF、Rust 分类，并只显示这张照片经检查后支持的转换选项，可"只转这张"
或"加入队列"。视觉上用 HarmonyOS 7 沉浸材质与 HDS 导航，材质仅限小面积导航栏。

### 8.1 借鉴（三端信息架构统一）

| 做法 | 理由 | 实现依赖 |
|---|---|---|
| 详情优先：先看单张的检查结果，再决定怎么转 | 转换选项按这张照片的实际数据裁剪，用户不必自己判断能否开人像 / 风格 | Rust `inspect` / `classify` / `inspect_photo_details`，三端共用；§4.2 的 `plan_output` 导出后可直接返回"这张可用的选项" |
| "转换这张"与"加入队列"分离 | 单张即时反馈和批量处理是两种节奏 | 队列模型增加"单项立即执行、不启动其余待处理项"路径 |
| 浏览 / 队列 / 设置分区 | 浏览与任务管理分离，页面更干净 | iPhone 用 TabView；iPad / macOS 见 §8.3 |

这三点应反向同步给 Flutter 移动端布局，避免三端各走各的。需要统一的是流程
（导入 → 检查 → 决定 → 转换 → 导出）与术语（`docs/app/flutter-app.md` §6），不是视觉。
视觉与导航控件按各平台规范走。

### 8.2 不借鉴：应用沙箱内的第二个图库

鸿蒙版复制原图进沙箱有两个平台原因：不想申请整库读取权限，以及导出只能走文档保存选择器，
需要一个地方存放"处理过的照片"。代价是每张原图多占一份存储、用户多一个要管理的库
（鸿蒙 README 自己也把"选择外部托管目录"列为推迟项）。这是平台约束变成的设计。

Apple 平台两个前提都不成立：`PhotosPicker` 进程外运行、无需相册权限即可拿到 HEIC 原图；
`PHAssetCreationRequest` 可直接把输出写入照片库并建相册、配对 Live Photo。
因此 **系统照片库就是图库**，应用只保留"最近处理"历史（输入引用 + 输出位置 + 结果摘要），
不复制原图作为长期库。队列运行期间的输入物化副本仍按 §3 P1 规则进入应用私有输入目录，
任务完成或移出后清理。

鸿蒙版 UI 代码是单个 8664 行的 `Index.ets`，架构上不可复用；能带走的只有本节的信息架构与交互流程。

### 8.3 Apple 各端页面结构

**iPhone**：三个 Tab。

- **照片**：顶部 `PhotosPicker` / 文件导入入口，下方"最近处理"网格（LazyVGrid）。点开任一张进入详情
  （NavigationStack 推入；大屏可改 sheet + presentationDetents）：ImageIO 缩略图或输出的 HDR 预览
  （`allowedDynamicRange(.high)`）、格式 / 尺寸 / EXIF / 分类、按检查结果裁剪的转换选项、
  "转换这张"与"加入队列"。完成后直接写入照片库 XDRemux 相册并在详情里预览结果。
- **队列**：批量任务、进度、重试 / 移出 / 清除已完成、检查点恢复，语义与五端统一队列模型一致。
- **设置**：全局默认转换选项，草稿 / 提交分离（§3 P2）。

**iPad**：同一套 Tab 用 `TabView(.sidebarAdaptable)` 或 `NavigationSplitView`，详情在右栏常驻。

**macOS**：输入来源是文件夹与拖放，不是相册，"照片"Tab 没有意义。`NavigationSplitView`：
左侧来源与队列，右侧选中照片的详情与 HDR 预览；设置走标准 Settings 窗口；输出目录用安全作用域书签。

**Share / Action Extension**：从系统照片分享面板直接"用 XDRemux 转换"，这是鸿蒙版没有、
也比任何图库入口都更短的路径（§3 P3）。

**材质与导航**：`.ultraThinMaterial`；iOS 26 起可用 Liquid Glass `glassEffect`。
与鸿蒙版一样，材质只用于小面积操作 / 信息区，照片区保持普通背景。

### 8.4 对现有章节的影响

- §1 第一阶段范围中的"照片详情"按本节定义为详情优先流程；"相册导入"不含本地图库。
- §3 P1 的 HDR 预览放在详情卡内；P2 队列模型增加单项立即执行路径。
- §4.2 的 `plan_output` 导出应同时返回该照片可用的转换选项及不可用原因，供详情卡裁剪 UI。
- §7 对照表新增一行：鸿蒙"沙箱本地图库 + 文档保存选择器导出"对应 Apple "系统照片库 + PHAssetCreationRequest 写入"。

## 参考

- `docs/architecture/ffi-contract.md`：Dart ↔ Rust FFI 契约（C ABI 单一来源）
- `docs/architecture/platform-backend.md`、`docs/app/apple-integration.md`：现有 Apple 平台集成与打包
- `docs/validation/platform-behavior-matrix.md`：平台行为矩阵，P4 对等验收依据
- `docs/design/rust_swift_conformance.md`、`tests/conformance`：跨实现结构比对方法
- `feat/harmony-native` 分支 `docs/plans/harmony-native.md`、`apps/harmony/README.md`、`BUILDING.md`
- 上游 `XDRemux-upstream/apps/macos/XDRemuxApp`：SwiftUI 结构参考（内核不复用）
