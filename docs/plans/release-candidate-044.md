# 0.4.4 候选整合与 Flutter 升级

## 2026-10-25：0.4.5 六平台发版准备

最新状态单独维护于 [0.4.5 六平台预检](release-045-preflight.md)。用户要求保留 iPhone Duo 新 SDK 适配，采用 Xcode 27.1 构建，不以旧 SDK 兼容为由降级功能；当前仅准备和构建验证，暂不发布。下文保留各阶段历史记录。

## 2026-10-24：Linux PR #12 审查整合（0.4.5，不发布）

- 用户授权审查并合并 Linux 适配 PR #12；保留主线 JPEG HDR/ICC 修复和 Flutter `0.4.5+39` / Rust `0.4.5`，不创建标签、发布版本或改动已有 Release 资产。
- [x] 同步最新 main 到候选，审查 Linux runner、GTK 拖放/命令行导入、FFI、插件筛选、glibc 兼容 shim、AppImage/tar.gz 与用户级安装。Linux 仍标注为预览平台，不将作者的 Arch 验证扩展为本轮全发行版验收。
- [x] 修复 FFI 从 `apps/flutter` 查找 Cargo 产物时多一级父目录；libnuma 改用 HTTPS，固定并核对 Ubuntu 原始 deb 与提取库的 SHA256，拒绝旧缓存污染和错误下载。
- [x] 修复桌面入口路径的空格、引号、反斜杠、美元符、反引号、百分号及 `&` / `|` 转义；以真实 GLib 桌面入口启动临时目录中的测试应用。所有测试安装仅在临时目录，不触及实际用户安装。
- [x] Linux CI 新增相关 PR 自动构建，Ubuntu 22.04 专属 x265 缓存，Rust locked 构建；构建 job 只读，Release 上传拆成仅手动执行的独立写权限 job，并校验附件版本与标签一致。未运行发布任务。
- [x] WSL Ubuntu 上 Bash 语法、两项回归套件（共 7 个子场景）通过；Windows 宿主 Rust 258 passed / 7 ignored。实际 Ubuntu 22.04 桌面构建由新增 CI 检查，完整 GUI/图库和多发行版验收仍需后续进行。
- [x] Flutter 本地 analyze 无问题，143 tests 全部通过；暂存测试用核心 DLL 后已按哈希恢复。候选 `54b26a72` 的全部 GitHub 检查通过：Rust、Flutter、Conformance、OHOS smoke，以及新增 Ubuntu 22.04 Linux 构建/打包（3m50s）。核心最高 GLIBC 需求为 `GLIBC_2.35`，生成 `0.4.5` AppImage/tar.gz/sha256 workflow artifact；Release 上传 job 为 skipped。
- [x] [PR #12](https://github.com/BeetMan/XDRemux-Flutter/pull/12) 已于 2026-10-24 合入 main，合并提交 `0a2b5079`。本地候选快进同步，保留未跟踪 dist 与其他工作区的改动。仍无 `v0.4.5` 标签，正式 Latest Release 仍为 `v0.4.4`，原生版本仍为独立 `harmony-v0.5.1`。

## 2026-10-24：JPEG 修复合入主线并准备 0.4.5（不发布）

- 用户授权把 Issue #11 HDR 识别修复与 JPEG RGB ICC 保真修复合回 main，版本提升为 0.4.5，暂不发版。
- [x] Flutter `pubspec.yaml` → `0.4.5+39`；Rust crate 与 Cargo.lock → `0.4.5`；Windows Inno Setup 默认版本 → `0.4.5`。Android/Apple 构建读取主 pubspec；OHOS 构建脚本也已自动从主 pubspec 同步版本，不更改模板清单或独立原生 0.5.1 的版本。
- [x] 将暂存更新说明整理为 `tools/installer/RELEASE_NOTES_v0.4.5.md`，显式标注尚未发布；README 区分主线开发版本 0.4.5 与已发布 v0.4.4，保留已有下载链接。
- [x] 升版后重新验证：Rust 258 passed / 7 ignored；两项原图测试显式启用通过；Flutter 完整 143 tests 通过，其中 FFI 核心版本实读 `0.4.5` 与 pubspec 匹配。测试暂存 DLL 已按哈希恢复，不提交生成二进制。日志 `target/issue-11/045-*.log`。
- [x] 修复提交 `074a6348`；版本与文档单独提交，整合方式为基于 main `953a2737` 的线性快进，推送仅限 `HEAD:main`（显式禁止 follow-tags）。只含本轮源码/测试/文档/版本，保留 dist 和其他工作区未提交内容。
- 发布约束：不创建任何 tag，不运行 release workflow，不创建/修改 GitHub Release 或安装附件，不关闭 issue。Release workflow 仅由 `v*` tag push 或显式 dispatch 触发；本次只有常规 main CI。

下面两项修复的“未提交/未推送”状态是实现阶段历史记录，以本节整合状态为准；旧 `RELEASE_NOTES_UNRELEASED.md` 已整理为上述 0.4.5 待发布说明。

## 2026-10-24：JPEG RGB ICC 保真修复（未发布）

- 用户授权修复共享 JPEG 管线的 ICC 丢失，继续在 `codex/fix-jpeg-hdr-iso-fallback` 工作，保留上轮 Issue #11 修复。未修改其他工作区、原图、版本号或发布资产。
- [x] 新增有界 `jpeg_color`：重组 JPEG APP2 ICC（支持乱序分段），检查序号/缺段/重复、16 MiB 上限、ICC RGB v2/v4 头部/设备类/PCS 与 tag 范围。非 RGB、坏 profile 明确失败，不静默丢弃或将原配置附给已变换的 RGB。
- [x] HDR JPEG 主图和现有 SDR JPEG Styles 源重建保留设备 RGB 值，原 ICC 写入主图和主瓦片 `colr/prof`；配套 nclx=(2,2,1,full)，主图 HEVC VUI 同样为 unspecified primaries/TRC、BT.709 matrix/full range。质量预设/CRF不变，无 ICC 输入及非 JPEG 源仍沿用原路径。保留 OPPO 原机 HEIF / 水印写回已有特例，不泛改编码器默认值。
- [x] 自动覆盖分段 ICC 重组、坏序号/缺段/重复/截断/非 RGB/tag 范围、主图/瓦片 ICC 关联、无 ICC 行为、SDR Styles 源及 RGB 数值读回。独立色块测试使用完整 512×512 平坦瓦片，避免将 16px 小图紧邻黑色 padding 的 4:2:0 边界滤波误判为色域错误；完整瓦片读回误差阈值仍为 3/255。
- [x] Rust `cargo +1.96.1 test --locked -p xdremux-core` 共 258 passed / 7 ignored；两项 opt-in 原图测试显式运行均通过（两张 JPEG × Apple/OPPO 两种输出，原图 SHA256 不变）。FFmpeg fallback 另目录编译及两项 ICC 合成/数值回归通过。
- [x] MIX Flip 2 原图（SHA256 `B5D0DCF287DF4D2D9085B246A017CDFCD3A04E81081A4C6371AD31C3291F8CAA`）：Apple 输出 3,326,652 bytes，SHA256 `6D14EF4AE71E5C3AC097B3749B923E95B4FD8016A4A41371A97CDD908A045EBC`；OPPO 输出 3,321,474 bytes，SHA256 `324C6EB9B29548343B098D82D3A4D3737DB32A6FFD9B0EE63EBC3D0EE2969254`。632 bytes ICC 与源一致，主图 3072×4572、增益图 1536×2286，包含水印画布，FFI 与 HDR 图结构检查通过。源 MPF 主图长度过短未造成截断。
- [x] 独立 libheif 1.23.4 C API 读回原图输出及 P3/sRGB 平坦色块（两种模式；色块走实际 SDR Styles 转换），ICC 逐字节相同。色块中心最大通道误差 1/255、平均 0.167/255；LittleCMS 按同一 profile 转 sRGB 后各通道整图 MAE 最大 0.501/255，未做像素无损承诺。FFprobe 从主图瓦片码流核对 full-range / BT.709 matrix、无冲突的 primaries/TRC。
- [x] Flutter 完整 143 tests 再次通过；使用本次核心暂存运行后按哈希恢复旧测试宿主 DLL，不提交二进制。`git diff --check` 通过。更新未发布 Release 说明；未提交、推送、打包手机安装版或更改 GitHub issue。
- 验收边界：本轮是 JPEG 转换文件级色彩保真，不扩展至通用 SDR 模式、CMYK/灰阶 CMS、非 JPEG 输入的 profile 管理或全平台预览/目标相册实际显示验收。照片原件不纳入 Git；独立解码、FFprobe 日志及输出留在忽略的 `target/issue-11`。

## 2026-10-24：Issue #11 JPEG HDR 识别回归热修（未发布）

- 用户授权先修回归，不扩展通用 SDR JPG → HEIC。复用此干净工作区，从 main `953a2737` 新建 `codex/fix-jpeg-hdr-iso-fallback`；保留原目录未提交改动和 dist，不移动标签、不更新安装包、不自动回复或关闭 issue。
- [x] 同一红米原图（SHA256 `3F1E942F63799A3045EFAC8A7AFD542C0258634FD63285D6D9CCE43CBBCB0747`）对照两个 tag 的解析器复现：0.4.3 可读 1,215,977 bytes 增益图；0.4.4 拒绝 ISO minimum version 2。文件同时有有效 Adobe XMP，原图及增益图结构完整。
- [x] ISO 解析新增类型化错误，仅 UnsupportedVersion 可走严格 Adobe XMP 回退。支持 ISO 继续优先；支持版本的截断、非法数值/flags、重复段等不允许回退。Adobe 回退校验命名空间、Version 1.0、标量、重复属性、有限数值与范围，拒绝 HDR 底图，不使用身份增益图假装成功。
- [x] JPEG 详情报告增加 `hdrParseError`，与 EXIF 的 success 独立；Flutter 格式行、摘要与复制信息显示“HDR 解析失败”及原因，不再吞错显示 SDR。普通 JPEG 的身份增益图不作为原生详情报告中的 HDR 依据。
- [x] 自动覆盖版本不支持 + 有效/无效/缺失 XMP、合法 ISO 优先、截断/坏数据不回退、命名空间伪造、数值/范围/重复/非标量、普通 SDR 及详情错误序列化。Rust `cargo +1.96.1 test --locked -p xdremux-core` 共 252 passed / 6 ignored（其中含新增 opt-in 原图测试，已另行显式运行通过）。
- [x] opt-in `jpeg_hdr_regression` 用用户原图经过真实 x265 转换：Apple 标准 4,933,917 bytes，SHA256 `8473CFC7C94F564A66D6EF0C34DD003D12A26C6453B6A217078C6EF49D56553F`；OPPO 兼容 4,933,219 bytes，SHA256 `89F7074E1527C7924A36860140E0141901A6FB5E0B05DD78B0FF1397E0B9F25A`。两份输出的公共 FFI 校验及 HDR 增益图结构校验通过（增益图 1536×2048），输出参数约 2.17938× / 1.12392 EV；输入哈希不变。源照片不提交 Git，合成测试可公开，原图实测通过环境变量显式启用。
- [x] Flutter 3.47.7：详情相关 14 tests、完整 143 tests 通过；改动 Dart 文件 analyze 无问题。首次完整测试因工程内遗留 0.4.3 DLL 缺少 codec 符号/版本不匹配有 2 项失败，换用本次编译的 0.4.4 核心后完整重跑通过；测试后按哈希恢复原 DLL，不提交二进制。
- [x] 未发布更新写入 `tools/installer/RELEASE_NOTES_UNRELEASED.md`，`git diff --check` 通过。未提交或推送修复，未打包手机安装版，未进行目标图库的显示/编辑或真机验收。

日志、前后版本诊断和两种 HEIC 输出保存在忽略的 `target/issue-11`。主线 v0.4.4 的既有发布记录如下，不能将本节误解为新包已经发布。

## 2026-10-22：主 README 发布后更新

- [x] 首页增加官网 `https://xdremux.app`，HTTP HEAD 返回 200；跨平台/原生版本更新为 `0.4.4` / `0.5.1`，六个平台下载入口逐一与 GitHub 实际 Release 附件 URL 核对通过。
- [x] 新增本轮更新摘要，更正已退役的 Swift 产品后端切换说明、OPPO 前摄支持、Live Photo 跨平台保存与传输机制、鸿蒙两种 HAP 的开发自签方式，以及 macOS Apple Silicon 限制。
- [x] 明确 Flutter OHOS 当前统一图库保存和配对双文件分享未接入，不以共享核心替代各平台实际验收；保留原有产品介绍、截图和研究边界。
- [x] README 本地链接存在性与 `git diff --check` 通过。用户随后授权提交并推送 main；本提交仅含 README 和此完成记录，不重编应用、不改动发布资产或其他本地文件。

## 2026-10-22：原生 0.5.1 自签分发更正

- 用户要求直接替换原生同名 HAP。使用 `harmony-v0.5.1` / `67ff09cd` 业务源码执行 DevEco debug 构建，确认 `app.debug:true`、`app.buildMode:debug`，供匹配包名、证书和设备的开发 Profile 自签；Rust 保持 Release 优化，核心 SHA256 与此前包相同。
- 新原生 HAP 6,811,477 bytes，SHA256 `61E2F0B5667B2B668E1AE3772AAE9825EDE62E3A2DC4D05EF1940B4621856BBC`。原 Release HAP 与校验和已本地备份；包身份、`0.5.1+50100`、标签均不变。此节替代下方“原生仍为 release/debug:false”的当前状态描述，早先数字仅作历史记录。
- 完整 debug 编译、24 个桥接符号、版本/API/身份/核心一致性、CRC、无 HAP Signing Block、16 组模型/队列测试及 5 项 HAP verifier 测试通过。本轮未执行实际自签安装或照片实机验收；unsigned 不是免签安装，开发签名仍受设备范围与有效期约束。
- 原生 `BUILDING.md` 和发布说明已补充 GitHub 默认 debug unsigned、Rust release 优化的规则；Flutter OHOS 0.4.4 附件与其他平台资产不变。
- 已替换 `harmony-v0.5.1` 同名 HAP 与 SHA256SUMS，更新 Release 正文；重新下载验证 HAP 哈希、校验文件、GitHub 服务器 digest/大小及正文全部匹配。旧附件可从原生工作区 target 备份恢复。

## 2026-10-22：正式标签鸿蒙资产补编

用户已在 Mac 发布 `v0.4.4`，并明确要求同时补齐 Flutter OHOS 0.4.4 与鸿蒙原生 0.5.1。以下构建使用各自正式标签，不移动标签，不混用两条分支的 Rust 核心，也不将本机签名上传。

- [x] 主线快进到 `v0.4.4` / `6c34ed42`（Flutter `0.4.4+38`，Rust `0.4.4`）。原生按 `harmony-v0.5.1` / `67ff09cd`（app `0.5.1+50100`）构建，保留原生专用静帧提取等 API。
- [x] 两份 Rust 核心分别执行 locked、release、aarch64-unknown-linux-ohos 构建，默认 x265，未启用 libheif 或 FFmpeg fallback；复用相同 OHOS 目标 x265 静态库和 SDK libc++。
- [x] Flutter 使用之前校验通过的独立干净 OHOS SDK，profile 平台内核 SHA256 `6BB2231472FC399BD1BC75E6344D4380CFB94B1DB21705A7B1A36F1EA1C914B8`。隔离目录使用 OHOS pubspec 变体并只同步版本行；业务 Dart 源自 tag，不更改官方主线 pubspec/lock。
- [x] 首次 Flutter 打包遇到路径长度超过 259 的限制，改用短隔离目录 `target/oh044-1022` 后 `devecocli build --product default --build-mode profile` 成功；原生在独立目录执行 release 构建成功。Flutter 仅隔离构建移除不可拉取的 Hvigor 6.24.4 显式依赖，并过滤 x64 库，使用 DevEco 自带工具链。
- [x] Flutter HAP：`XDRemux-HarmonyOS-0.4.4-unsigned.hap`，37,359,949 bytes，SHA256 `E33FCF692C3B7810579A065E2B627E4BB5AE16EA93697E3EE32037CA60BFBE96`；37 个运行时 FFI 符号、ARM64 AOT/引擎/核心/运行库、包名/版本与 ZIP CRC 校验通过，签名工具确认无 HAP Signing Block。
- [x] 原生 HAP：`XDRemux-HarmonyOS-Native-0.5.1-unsigned.hap`，5,903,559 bytes，SHA256 `0DF31311F3EEC6D743BBBF51007D63AF34FCD863BD2A4835B7512D5AA31E8648`；24 个桥接符号、包身份/API/版本、ZIP CRC 与无签名块检查通过。16 组模型/队列测试和 5 项 HAP 校验器测试再次通过。
- 独立快速 ArkTS 检查存在错误（Flutter 22 项类型推导/any 等，原生 1 项 `@Available` 导出），但两份完整 DevEco 构建的 CompileArkTS 与打包均通过；不冒称独立快速检查已通过，也不为本轮资产补编改写发布标签业务源码。
- [x] 两条 Release 的 HAP 与校验文件均已上传，GitHub 服务器 SHA256 与本地一致。原生旧 HAP（SHA256 `7E39C8B5B288ADE0E11D4A5573E87B409658F2D688D1E4B19C6B4EE2B1DB7BC1`）和旧 SHA256SUMS 已先下载留存；仅替换指定原生 HAP 和对应校验文件。两条发布页保留手写正文，只追加重编信息、校验值、签名要求和限制；未覆盖其他平台资产。
- 本轮不自动安装手机、不使用用户照片、不声称完成新的图库或 Apple Photos 实机验收。Flutter Profile/`debug:true` 可开发自签；原生仍是 Release/`debug:false`，需发布签名或从源码构建 debug 包，不混用安装说明。
- Flutter OHOS 统一相册保存入口仍排除 OHOS，双文件分享尚未接入；本轮只补发布资产，不扩展为功能修复或完整验收通过。原生配对文档导出仍是独立实现。

日志与可恢复产物保存在各工作区忽略的 target，以及 `dist/harmony-release-20261022`；不提交 HAP、签名配置、SDK 缓存或本机原始日志。后续各段为当时的候选整合历史记录。

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

### `release.yml` 预演结果（workflow_dispatch，run [39061015513](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/39061015513)）

在分支 `release/0.4.4-prep` 上手动触发（`publish` 因无 tag 被跳过，未发布任何东西）：

| Job | 结果 |
|---|---|
| Windows installer (x64) | ✅ 通过 |
| Android APK | ✅ 通过（4 个签名 secret 有效） |
| macOS DMG | ✅ 通过（含新的暂存 + 软链步骤与 dylib 断言） |
| iOS unsigned IPA | ✅ 通过（FFI 符号检查通过） |
| Windows ARM64 (experimental) | ❌ 失败，同 v0.4.3 的 “Stage and validate ARM64 output” |

产物核对（直接取 CI artifact 校验，非本地构建）：

- macOS DMG 25,889,533 B：含 `Applications -> /Applications` 软链；包内 app `codesign -v --deep --strict` 通过（sealed files 30）；包内核心 `xdremux_version()` = `0.4.4`。
- iOS IPA：`CFBundleShortVersionString 0.4.4` / `CFBundleVersion 38` / `io.github.beetman.xdremux`，无 `embedded.mobileprovision`（未签名）。
- Android APK：manifest 内含 `0.4.4`、无 `debuggable` 标记，存在 APK Signing Block（v2/v3 已签名）。
- Windows 安装器 12,443,522 B：PE 文件，内含 `0.4.4` / `XDRemux` / `Inno Setup`。

ARM64 失败原因（日志实证）：runner 上的 Flutter 是 `stable-3.47.7-x64`（`FLUTTER_ROOT` 可见），因此 `flutter build windows` 产出的是 x64 runner，校验按设计拒绝打 ARM64 包：`Refusing mixed ARM64 installer: xdremux.exe is PE machine 0x8664`。这不是本次改动引入的，v0.4.3 同样失败。要真正出 ARM64 包需要 ARM64 的 Flutter 工具链（待验证上游是否提供），否则应明确 ARM64 用户使用 x64 安装器（模拟运行）。

### 未决：macOS 包在 Intel Mac 上不可用（本轮新发现）

CI（`macos-latest`，arm64 主机）产出的 app 主体是 universal，但 Rust 核心只有 arm64：

```
XDRemux                x86_64 arm64
FlutterMacOS           x86_64 arm64
App.framework          x86_64 arm64
libxdremux_core.dylib  arm64            <-- 仅此一项
```

在 Intel Mac 上 app 能启动，但 `_openMacOS()` 的 4 条加载路径都会失败（架构不兼容），转换不可用。已核对 **v0.4.3 的已发布 DMG 同样如此**（app universal、dylib 仅 arm64），属既有缺陷，不是本轮引入。

处理方式待维护者决定：(a) 明确只支持 Apple Silicon 并写进发布说明；(b) macOS job 增加 `x86_64-apple-darwin` 构建 + universal `libx265.a`（`-DCMAKE_OSX_ARCHITECTURES="x86_64;arm64"`）+ `lipo -create`，把 dylib 做成 universal（本机无 Rosetta，x86_64 侧只能靠 CI/Intel 机器验证）；(c) 把 macOS 构建限制为 arm64，让不支持变成明确的“无法打开”。

**决定（2026-10-21，维护者）：选 (a)** —— 0.4.4 明确只支持 Apple Silicon，构建流水线不变，限制写进 `RELEASE_NOTES_v0.4.4.md` 的「使用说明与边界」。后续如要支持 Intel，按 (b) 另开改动。

### Windows ARM64：尝试 ARM64 工具链的结论（2026-10-21）

维护者决定先试一次 ARM64 Flutter 工具链。在该 job 的 `flutter-action` 上显式指定 `architecture: arm64` 后（run [39628385537](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/39628385537)）：

- 失败发生在 `Set up Flutter`，耗时约 **4 秒**，错误为 `Unable to determine Flutter version for channel: stable version: 3.47.7 architecture: arm64` —— Flutter 没有为这个版本发布 Windows ARM64 SDK。
- 相比原来（x64 SDK 跑满约 12 分钟 Windows 构建后才在 “Stage and validate ARM64 output” 被守卫拒绝），现在是快速失败，且日志直接说明原因。
- 该 job 原本就有 `continue-on-error: true`，所以不阻塞发布；保留混合架构守卫，等上游将来发布 ARM64 SDK 时自动生效。
- 结论：**0.4.4 不提供 Windows ARM64 安装器**，ARM64 用户使用 x64 安装器（模拟运行），发布说明已写明。

### 第二次预演的 runner 容量问题（2026-10-21）

同一次预演里 macOS DMG 与 iOS IPA 两个 job 被取消，check-run annotation 原文：`The job was not acquired by Runner of type hosted even after multiple attempts`，并附 `Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.` —— 这是 GitHub 托管 macOS 队列容量问题，不是代码问题。macOS/iOS 的构建与产物验证以第一次预演（run 39061015513）为准，其后分支改动只涉及文档、ARM64 job 的 Flutter 架构与注释，不触及 macOS/iOS job。



