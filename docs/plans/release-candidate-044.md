# 0.4.4 候选整合与 Flutter 升级

日期：2026-10-15。用户授权：整合候选代码、将本次修复提交主线，再升级 Flutter，交付验收；不创建 tag、不发布 Release。

## 范围

- 基于远端 main `6e6a184b`，在独立工作区整合；不重置本地历史分叉的 main，不改原工作区未提交文件。
- 整合此前 JPEG HDR 元数据、可选 libheif 解码、Rust 主图预览、codec 诊断、Apple MakerNote 保留、Windows 测试工具，以及本次 Live Photo 完整导出、手机布局和安全区修复。
- 不包含电影模式、鸿蒙原生应用改动、签名配置、私有样片、预编译 DLL 和构建产物。libheif 仍为可选功能，不默认为所有平台启用。
- 功能整合与 Flutter 升级分别提交，方便回退。升级采用独立 SDK 路径，保留现有 C:/flutter 3.44.5，避免影响其他工作区及鸿蒙适配工具链。

## 任务

- [x] 核对远端 main 与各候选工作区；保留原工作区状态。
- [x] 汇入候选源码，合并 main.dart 的导出/UI 与 codec 诊断接入。
- [x] Flutter 3.44.5 下整合回归：141 passed；完整 analyze 无问题。Rust 默认核心 226 passed / 3 ignored，可选 libheif 核心 227 passed / 3 ignored。
- [x] 功能修复提交 `00a0068f`（59 个文件）已快进推送 origin/main；未改本地历史分叉的 main。
- [x] Flutter 3.47.7 / Dart 3.13.5 独立 SDK（C:/Users/Beet/.codex/sdks/flutter-3.47.7），提交指纹 abaf9c5237；6 处 CI/release 版本固定同步，apps/flutter/.fvmrc 记录版本。仅 SDK 需要的 matcher/meta/test_api/vector_math 4 个锁定依赖变化，业务插件不批量升级，镜像配置保留。
- [x] 新 SDK 下 141 项测试及完整静态分析通过，Android ARM64 debug 与 Windows x64 release 编译通过。测试宿主适配补丁后另行复测并记录；Windows 本地验收包显式开启 libheif，正式 CI 默认 feature 未改。
- [x] 框架升级单独提交，准备 Android 同证书签名测试 APK 与 Windows 完整便携包；验收清单见下文，未自动安装新包或发布 Release。

## 验收边界

### 最新验收状态（2026-10-17）

- [x] Android：用户明确反馈“安卓版验证 OK 了”，本轮 Flutter 3.47.7 候选整体验收通过。对应 2026-10-16 覆盖安装且已核对 SHA256 的 APK；记录为用户人工验收，不冒充代理逐项实测，也不据此新增未提供的机型、导航模式或权限异常分支覆盖。
- [ ] Windows：已有自动测试与两轮包内 FFI 回归，尚无本轮用户人工验收结论。
- [ ] macOS/iOS：本次应用原生编译与 iOS PhotoKit 直接保存仍需验收；之前单组文件经 Mac 投送正常单独保留，不替代应用内保存验证。
- [x] 鸿蒙 Flutter 编译：2026-10-17 同一主线候选 Profile/AOT ARM64 未签名 HAP 已生成并校验，使用独立 OHOS Flutter 3.41.10-ohos-1.0.1 / Dart 3.11.5，不混用官方 Flutter 3.47.7。
- [x] 鸿蒙 Flutter 启动修复：2026-10-17 用独立干净 SDK 平台内核全新编译，签名覆盖安装后启动 smoke 通过；进程持续约 2 分钟、主页可见且没有新增崩溃记录。原启动闪退包已被替代。
- [ ] 鸿蒙 Flutter 完整功能验收：相册保存统一入口目前排除 OHOS、双文件分享尚未实现；本次只解决启动，不将其记为完整功能通过。
- [ ] 鸿蒙原生：本轮候选改动尚未同步，原生 0.5.1 未作为已验收版本。

验收反馈本身不代表授权创建标签或发布 Release；保留 0.4.4 / 原生 0.5.1 的其余发布门槛。2026-10-17 用户随后明确授权同步 GitHub main，供 Mac 验证；下文“未提交/未推送”为各阶段当时状态，不表示本轮继续保留在本地。Mac 交接见 [mac-acceptance-044.md](mac-acceptance-044.md)。

iOS PhotoKit 的单资产双资源保存、macOS/iOS 原生编译需 Mac/iPhone 验收。Android 独立保存 HEIF/MOV 不等于原生系统实况。Flutter OHOS 多文件分享尚未实现；鸿蒙原生已有独立的成对文档导出，不把本次 Flutter 修改当作原生已同步。

本次暂不升级正式应用版本号，不将主线提交等同于 0.4.4 / 原生 0.5.1 已发布。用户验收前保留正式发布门槛。

## 整合验证记录

- 采用现有主线/Live Photo 测试分支的镜像 lockfile，新增测试 dev dependency 仅将 path_provider_platform_interface 2.1.3 标为直接测试依赖。未纳入原 Windows 候选中与本轮无关的批量插件升级和 pub.dev 源切换。`pub get --enforce-lockfile` 通过。
- x265 复用本机已构建的目标静态库；新建候选工作区重新构建 Rust 默认 DLL 并用于实际 FFI 测试，不提交 DLL。libheif 回归使用此前已构建的固定版本 prefix，不改变默认发行 feature。
- 完整日志位于忽略的 target 下：flutter-baseline-tests.log、flutter-baseline-analyze.log、rust-default-tests.log、rust-libheif-tests.log。
- 初次主线 CI 的 Conformance 与 OHOS Rust smoke 通过；Flutter Linux job 发现 2 项缩略图测试假定 Windows 原生通道。补丁 e062d2ff 添加仅供测试注入的 renderer，让缓存/队列测试跨宿主执行；生产默认 native/FFI 路径不变，不以跳过测试规避。
- Flutter 自动迁移 analysis_options.yaml，排除 build 与各原生平台生成目录；现有 lib/test/integration_test 仍分析。未升级 AGP/Kotlin；Android 构建存在 Kotlin 2.3.10 未来需至少 2.3.20 与 Java 8 源/目标兼容的预警，不使用跳过验证开关。
- e062d2ff 后新 SDK 完整回归仍为 141 passed，Android ARM64 与 Windows release 已重新增量编译。Windows 包内 FFI smoke：11/11 输入的转换、Styles 图结构、PNG 主图预览及原图哈希通过（合成 4:2:0/4:2:2/4:4:4/高位深/旋转和两个公开 Apple gain-map JPEG）。这是程序化包内调用，不冒充真实选择器或 Photos 编辑验收。

## 本地验收产物

- 代码提交 83307381 的云端 [CI](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/38766699401) 与 [Conformance](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/38766699226) 全部通过；Flutter 139 passed / 2 fixture-dependent skipped。此前 2 项 Linux 队列测试失败已修复，不再跳过。
- 首轮云端 pub get 因默认 pub.dev 与已提交镜像 lockfile 不一致，重新解析 115 依赖。补充固定 PUB_HOSTED_URL 并在 1 处 CI、5 处主流平台发布构建使用 --enforce-lockfile，禁止无意改变插件版本；本地新 SDK 下同锁强制检查已通过。
- 锁定依赖补丁 59e493e3 的[云端 CI](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/38767430211)已成功：Rust tests 与 Flutter analyze/test 均通过，Flutter 139 passed / 2 fixture-dependent skipped，强制 lockfile 安装成功且不再报告重新解析 115 依赖。本轮 Conformance 等待 runner，之前 83307381 的同一产品源码已通过 Conformance；不把队列状态记为已通过。
- Windows ZIP 解压到新目录后 37 个 manifest 文件哈希全部相符；从解压包再执行 11/11 真实 FFI 转换、预览、Styles 和原图不变检查通过。

- Android：`dist/XDRemux-Android-candidate-Flutter-3.47.7.apk`，SHA256 `8A337A401AAE66F4B07D2EDD5A3BBA25B9C475BE992B3C0C69A04502F0C6B38A`。发布证书与现有安装一致，debuggable，版本仍为 0.4.3+37；可保留数据覆盖安装，但会重启并可能丢失未开始转换的内存队列。本次未自动安装。
- Windows：`dist/XDRemux-Windows-x64-0.4.3-candidate-flutter3.47.7.zip`，16,508,770 bytes，SHA256 `174a0fcfaa5477ed9022f8675bd8f888f0119d059c3b04582e5f6c11be827223`。包含 libheif 1.23.4 / libde265 1.1.3 与本地 MSVC runtime、许可说明和候选验收说明，manifest 记录 37 个文件。不可只取 exe。
- 鸿蒙 Flutter：`dist/XDRemux-HarmonyOS-Flutter-0.4.3-candidate-arm64-profile-unsigned.hap`，37,343,565 bytes，SHA256 `B0AA685B69DA2DB790ED00FFE02A650450A2546D0629CAEA04D6D60FC5C5D5AB`。同一主线业务代码，OHOS 专用 SDK、Profile/AOT、仅 ARM64、未签名，需要匹配设备的签名后才能安装；不是鸿蒙原生 0.5.1。
- 鸿蒙 Flutter 最新启动修复包：`dist/XDRemux-HarmonyOS-Flutter-0.4.3-candidate-arm64-profile-startup-fixed-signed.hap`，37,711,347 bytes，SHA256 `2B8A705622CED3A98AF2854BAB725319BB9181FD8611A257D6CDC1D5CD39C1A5`。含本机开发签名，已覆盖安装；此前两个未修复启动的 HAP 仅保留作历史对照，不再用于验收，不发布本机签名包。
- SDK 升级不改应用正式版本号；不以本地 Windows feature-on 包替代所有平台的正式默认 decoder 构建。

## 用户验收清单

### 鸿蒙 Flutter 编译记录（2026-10-17）

- 只编译 Flutter OHOS 应用，不修改鸿蒙原生分支，不安装、不签名、不发布。版本标识保持 0.4.3+37。
- 在忽略的 `target/ohos-flutter-candidate-20261017` 隔离目录复制主线业务代码，使用 OHOS pubspec 和本机插件源码；不替换工作区正式 pubspec、lockfile 或签名配置。
- 当前 Rust 核心已用 `aarch64-unknown-linux-ohos` release 目标重新构建，复用 x265 静态库；未启用可选 libheif。动态符号确认包含 codec 诊断、主图缩略图、Live Photo 合成及配对校验入口，打包对应 OHOS libc++_shared。
- 工程旧配置显式依赖 Hvigor OHOS 插件 6.24.4，npm 拉取返回 404；仅隔离目录移除该显式依赖，改用本机 DevEco 自带 6.26.4 工具链。通过 `devecocli build --product default --build-mode profile` 构建 Profile/AOT 未签名测试包。
- 两轮 `devecocli` 构建成功；第二轮仅隔离目录用 `nativeLib.filter.excludes` 排除默认混入的 x64 `.so`，避免缺少 x64 Rust 核心却被当作模拟器可用包。未修改共享 SDK 或正式工程构建配置。
- 校验 HAP bundle 为 `io.github.beetman.xdremux`，0.4.3+37，`debug: true`，最低 API 18，当前工具链目标 API 26；包含 ARM64 AOT libapp、Flutter 引擎、Rust 核心和 libc++。Hvigor 对 profile 的模块清单仍标记 `buildMode: debug`，Dart 构建日志和实际 libapp.so 确认走 profile AOT，不混称正式 release。
- HAP 内 Rust 库哈希匹配 Hvigor strip 后产物，strip 前输入与本次 Cargo 重编核心哈希一致；strip 后关键 FFI 导出仍存在。libc++ 包内哈希与 SDK 来源一致；所有跟踪的 Dart lib 源文件与候选工作区一致。
- 仍有现有 OHOS 插件/宿主 ArkTS 弃用与异常处理提示、未显式设置 targetSdkVersion 的构建警告，本轮未批量修改插件。Flutter OHOS 双文件分享仍未实现，编译通过不等于 Live Photo 完整导出或实机验收通过。
- 日志：忽略的 `target/ohos-candidate-core-build.log`、`target/ohos-candidate-pub.log`、`target/ohos-candidate-deveco-build.log`、`target/ohos-candidate-deveco-build-arm64.log`；未提交或推送本轮文档/产物。

### 鸿蒙 Flutter 覆盖安装记录（2026-10-17）

- 用户授权“装我手机上，不用打开先”。通过 DevEco CLI 确认 HUAWEI Pura X View（`192.168.31.242:5555`）；仅隔离构建目录注入原 Flutter 工程已有本地签名材料，`devecocli build --product default --build-mode profile` 签名构建成功，未重新生成签名或修改原工作区。
- `hap-sign-tool verify-app` 签名及 native codesign 校验通过；开发证书指纹与手机原安装一致。对比此前未签名候选，ZIP 内只有 `ets/sourceMaps.map` 变化，Dart AOT、Flutter 引擎、Rust 核心、libc++ 和其他业务内容不变。
- 已签名包：`dist/XDRemux-HarmonyOS-Flutter-0.4.3-candidate-arm64-profile-local-signed.hap`，37,694,963 bytes，SHA256 `83BFE7BC353416CB3BDC74BCC205811D81F551AFE30D7831CB7835EAF6CB210A`。此包含本机开发签名，不作为通用发行包发布。
- DevEco CLI 的 run 会同时启动应用，因此此处仅使用底层 HDC `install -r` 安装，返回 `install bundle successfully`；未卸载、未清除数据、未执行启动命令。安装后 `bm dump` 确认 bundle、0.4.3+37、ARM64、证书指纹正确，firstInstallTime 保持不变，updateTime 已更新；`pidof` 确认应用未运行。
- 系统不允许直接回读已安装的 entry.hap，未冒充完成设备端包哈希校验；本轮只确认签名、覆盖安装及未启动，不替代功能人工验收。私有签名配置、材料和产物均未提交或推送。

### 鸿蒙 Flutter 启动闪退诊断（2026-10-17）

- 用户反馈本轮已安装包闪退。通过 `devecocli log --crash` 取得 22:58:56 的 cppcrash，进程生命周期约 4 秒，主线程 `SIGSEGV(SEGV_MAPERR)@0xffffffffe29cfee4`。本次仅读取日志及本机构建诊断，未重启应用、未卸载或清数据。
- 用同一 gen_snapshot、同一 app.dill 重新生成带独立符号的诊断产物，libapp.so SHA256 与已打包 AOT 完全一致（`720CE2E1DE947A930C25827A5AD3D4D1AF1E637B602505C76431FC06FEF74FA4`），因此可对现有崩溃进行精确符号化，不依赖猜测相似版本地址。
- 调用链为 `main → runApp/ServicesBinding.initInstances → SchedulerBinding.initInstances/addTimingsCallback → PlatformDispatcher.onReportTimings → __nativeSetNeedsReportTimings → CallNativeThroughSafepoint`。发生在主页初始化和照片转换之前；不是已知相册导出平台拦截导致的崩溃。
- 跳转地址呈现原生函数指针低 32 位符号扩展特征，疑似本机 OHOS SDK 的 FFI ABI 映射/AOT 组件兼容问题；确切责任组件仍需干净 SDK 或最小样例对照，尚不宣称是上游普遍缺陷或已经修复。现有引擎版本 stamp 一致不能排除组件内容不匹配。
- 日志及诊断符号保存在忽略的 `target/ohos-candidate-crash.log`、`target/ohos-diagnostic-app.symbols`；未将崩溃日志或签名材料提交。先解决启动，再验证相册保存（统一入口目前排除 OHOS）及双文件分享（尚未实现）。

### 鸿蒙 Flutter 启动修复与防回归（2026-10-17）

- 用户授权修复后，在 `C:/Users/Beet/.codex/sdks/flutter-ohos-3.41.9-1.0.2-clean` 从同一框架提交 `62357a93` 建立独立 SDK，全部重新下载 Dart/工具/引擎缓存。目录名对应当前稳定标签，工具自身仍显示旧命名 `3.41.10-ohos-1.0.1`；本轮不升级框架源码。旧 `C:/flutter-ohos` 未修改。
- 对照确认 Dart frontend server、OHOS ARM64 gen_snapshot、profile 引擎 HAR 及 sky_engine UI 源文件哈希相同，只有平台内核缓存不同。旧 profile `platform_strong.dill` 为 `B2B4077BE7D95C7A1CE32055EBCE5B5A34CEB2DE6A780E387D952668A26B1DB6`，干净下载为 `6BB2231472FC399BD1BC75E6344D4380CFB94B1DB21705A7B1A36F1EA1C914B8`；release 缓存也不匹配。更换干净 SDK 后启动恢复，支持旧 SDK 平台内核缓存不兼容这一诊断，未将其误称为 Rust 转换崩溃或上游普遍缺陷。
- `target/ohos-flutter-fixed-20261017` 全新隔离编译（不复用原 app 的 build/.dart_tool/oh_modules），业务 Dart 源文件逐个哈希与候选主线一致。`devecocli build --product default --build-mode profile` 成功；包内引擎、Rust 核心与 libc++ 和上轮相同，重新生成的 AOT 为 `9ADF65E6767F5670C0D554FD828A4BA945081A683EEC7D0299532049BD3CB542`。签名及 native codesign 验证通过。
- `devecocli run --skip-build --product default --build-mode profile --device 192.168.31.242:5555` 覆盖安装并启动，返回 `Smoke: PASS`。未卸载、未清数据；bm dump 的 firstInstallTime 保持 `1788966490859`，证书指纹不变，版本仍为 0.4.3+37。PID 34113 自 23:14:07 至约 23:16 持续存在；只做启动验证，没有代理选择或转换用户照片。
- 通过 `devecocli ui layout` 确认界面包含 XDRemux、就绪和开始转换；最近崩溃记录仍为旧包的 23:06:51，早于修复包启动。日志仍有平台字体、系统能力与可选资源等非致命错误，未冒充“所有错误日志均为空”。
- 构建脚本增加 `-FlutterSdk` / `XDREMUX_OHOS_FLUTTER_SDK`，避免依赖固定旧 SDK；新增 `tools/ohos/check_sdk.ps1` 对本轮固定源码版本的平台内核进行兼容性校验，在交换 pubspec 前失败即停。干净 SDK 的 debug/profile/release 校验通过、旧 profile/release 缓存拒绝、冲突构建参数拒绝、pubspec/lock 未被失败预检修改，两个脚本语法校验通过。该校验不替代实机启动 smoke。
- 构建与安装日志：`target/ohos-clean-sdk-bootstrap.log`、`target/ohos-clean-sdk-precache.log`、`target/ohos-fixed-build.log`、`target/ohos-fixed-device-run.log`、`target/ohos-fixed-verify.log`。对应构建指南和本计划已更新；未推送、打标签或发布。相册保存和双文件分享仍是独立待办。

### 手机覆盖安装记录（2026-10-16）

用户授权覆盖安装后，通过无线 ADB 在 PKJ110 上执行 `install -r -t`，返回 Success；未卸载应用、未清除数据。安装后启动/前台恢复成功，进程 PID 30542，应用限定的 flutter/AndroidRuntime 错误日志未发现报错。

从手机重新拉取已安装 base.apk 校验，SHA256 与交付候选包完全一致：`8A337A401AAE66F4B07D2EDD5A3BBA25B9C475BE992B3C0C69A04502F0C6B38A`；签名证书仍与原版一致。确认手机运行的是 Flutter 3.47.7 候选，不是先前的安全区补丁包。应用版本标识仍为 0.4.3+37。以上只确认安装、包身份和启动，不代替下方功能人工验收。

本候选仍使用 0.4.3+37 的应用版本标识，以包名和 Flutter 3.47.7 区分，尚未打正式 0.4.4 标签。Windows 便携版请完整解压到新目录，可能与已安装版共享设置；原图保留，选择独立输出目录。

1. Android：添加原始 OPPO/华为实况，三种模式往返切换时卡片不跳、不溢出；主页和照片详情按钮与系统导航条有留白；手势导航和三键导航分别验收。
2. Android：Live Photo 单项/全部/自动保存都能找到 HEIF 和 MOV；分享配对原文件有两个附件；静帧模式不附带无关 MOV；权限拒绝或部分失败不提示完整成功。
3. Windows：单选/多选/中文路径/拖放、彩色预览与方向、摄影风格开关、codec 诊断复制/导出、批量取消重试；转换实况后输出同 stem HEIF/MOV，两文件一起传输。
4. Apple：在 Mac 编译本次 main；iPhone 应用内直接保存后在照片中是一个可播放、有声音的 Live Photo；权限拒绝与再次保存、原件仍在；macOS Photos 导入和投送分别验收。此前一组产物经 Mac 投送到 iPhone 正常不替代这一步。
5. 鸿蒙原生 0.5.1 暂未同步本次源码，Flutter OHOS 多文件分享暂不支持，不计入本次两个本地验收包完成范围。

### Mac / iPhone 验收记录（2026-10-18）

环境：macOS 27.0.1 (26A434)、Xcode 27.1 (27A9275)、Flutter 3.47.7 (framework `abaf9c5237`, Dart 3.13.5)、cargo 1.97.0；目标机 iPhone 16e (iPhone17,5)，iOS 27.2 (24B5099f)，开发者模式已启用。签名使用免费个人团队 `V4LA2Z97CJ`，描述文件有效期 7 天（本次至 2026-10-24）。

源码：主线 `5d61576`（本次同步最新），叠加 macOS dylib 打包修复分支；iOS 侧源码与主线一致，该分支只改 macOS 工程、CI 和文档。

自动检查：
- Rust 核心 `cargo test --release -p xdremux-core`：226 passed / 3 ignored，其余套件 6+6+7+1 通过，合计 **246 passed / 5 ignored**，与上一轮记录一致。
- `flutter analyze`：No issues found。
- `flutter pub get --enforce-lockfile`：通过，未重新解析插件版本。

构建：
- macOS `flutter build macos --release` 成功，产物 61.1MB；`Contents/Frameworks/libxdremux_core.dylib` 存在且由 `Bundle Framework` 拷贝阶段随构建产出，`codesign -v --deep --strict` 通过（sealed files 29→30），经该 dylib 调用 `xdremux_version()` 返回 `0.4.3`。修复前该包 54.9MB 且不含 dylib、签名封印无效。
- iOS `flutter build ipa --release --no-codesign` 归档成功；归档内 37/37 个 Dart 侧运行时 FFI 符号在 dead_strip 后仍导出。

iPhone 实机（应用内转换，用户操作）：
- 用户手动导入两张 **OPPO 实况原图**（单文件内嵌视频，`mp_probe` 判定 `oppoLivePhoto`、双码流），应用队列显示 `UHDR / 实况·双码流 / 1728×1296 / Live Photo 合成`，开始转换后输出到 `Documents/output/`。
- 取回产物核对（两对）：HEIC 5.1MB / 4.6MB，MOV 8.2MB / 9.3MB，**同 stem 成对**；HEIC 解码 5888×4416、4416×5888；HEIC `[Apple] ContentIdentifier` 与同名 MOV 的 `ContentIdentifier` **逐对相同且两对互异**（`006DDDDA-…4BF07E` / `…0A34C9E6`）；MOV 含 audio+video 轨，时长 3.15s / 2.37s；HEIC 含 `hdrgm` XMP（Version 1.0、GainMapMin）与 tmap。
- 用户确认：**保存到相册后在 iOS 上验证通过**（对应清单第 4 项“应用内保存后是可播放、有声音的 Live Photo”）。

本轮未覆盖、不据此宣称通过：相册权限拒绝→允许→重试、原 HEIF/MOV 不被移动或删除、静帧/拆分模式不带残留 MOV、批量与自动保存、macOS Photos 导入与投送、以及清单第 4 项之外的其他平台项。

环境问题与处理（供后续复用）：
- `xcrun devicectl` 一度无输出卡死：包装脚本 `/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl` 比对 CoreDevice 期望版本 `651.13.5` 与实装 `642.16`，不一致即执行 `xcodebuild -runFirstLaunch` 阻塞。执行 `sudo xcodebuild -runFirstLaunch` 更新组件后恢复；紧急时可直接调用 `/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl`。
- Xcode 27 起 `Devices and Simulators` 更名为 `Xcode → Open Developer Tool → Device Hub`；免费个人团队的设备只有经 Xcode GUI 运行一次（⌘R）才会注册并生成描述文件，`-allowProvisioningDeviceRegistration` 命令行路径始终返回“Your team has no devices”。
- macOS 上 `flutter test` 有 4 项既有失败（`ffi_smoke_test` ×3：裸文件名打开 dylib 但无步骤暂存到可搜索路径；`widget_test` 的 Settings bottom sheet ×1）。已在干净 main 上 stash 对照确认先于本轮改动存在；CI 的 Flutter 测试跑在 Linux（拷贝 `.so`），因此长期未暴露。按 `mac-acceptance-044.md` 的要求，应修正测试宿主加载路径而不是跳过。

后续修复（承接上条，不属于本轮实机验收结论）：
- `ffi_smoke_test` 的 3 项失败：新增 `apps/flutter/test/native_library.dart`，按「CI 拷贝到 Flutter 工程内 → Cargo `target/release|debug` → 已构建的 macOS bundle」顺序探测核心库并返回绝对路径，找不到时打印全部搜索路径；不再依赖 dlopen 的默认搜索（不含 target 目录）。
- `widget_test` 的 Settings 失败：`6e6a184` 已退休 Swift「转换引擎」选择器，测试仍按 `Platform.isMacOS || isIOS` 断言其存在，Linux 上因断言 `findsNothing` 而长期掩盖。改为在所有平台断言该段落不存在。
- 结果：macOS `flutter test` = **139 passed / 2 skipped / 0 failed**，`flutter analyze` 无问题。提交 `d642e31`（分支 `fix/macos-flutter-test-hosts`）。

## 发版准备（2026-10-18）

上述记录描述的是 0.4.3+37 候选状态。本轮按维护者要求做发布准备，**未打 tag、未创建 Release**：

- 版本号提升：`apps/flutter/pubspec.yaml` → `0.4.4+38`，`xdremux/rust/Cargo.toml` → `0.4.4`（`Cargo.lock` 同步），`tools/installer/xdremux.iss` 默认 `AppVersion` → `0.4.4`。tag 必须为 `v0.4.4`：`release.yml` 的 Windows job 会校验 tag 与 pubspec 名一致，`ffi_smoke_test` 会校验核心版本与 pubspec 一致。
- 新增 `tools/installer/RELEASE_NOTES_v0.4.4.md`（`publish` 的 `body_path` 指向它，缺文件会导致发布步骤失败）。
- macOS DMG 打包改为先暂存 `XDRemux.app` + `/Applications` 软链再 `hdiutil create`，让镜像支持拖拽安装（此前只有 app 本体）。
- 发布门槛提醒：`publish` 的 `if` 只要求 `windows` + `android` 成功，macOS/iOS job 失败不会阻塞发布，因此发布后必须逐项核对资产（v0.4.3 就缺少 Windows ARM64 包，对应 job 在 “Stage and validate ARM64 output” 失败）。

