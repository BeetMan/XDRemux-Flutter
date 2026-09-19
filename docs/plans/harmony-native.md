# 原生 HarmonyOS 前端开发计划

状态：2026-09-19 code40007 Motion Photo 按需识别与信息展示已完成主机验证和 unsigned 构建，详情见 §14。code40004 设置和 code40005 队列恢复保留待真机验收状态；主 Agent 规划审查，Luna Max 实施。
当前基线：`e30721b`（含 code40004 设置）。开发分支 `feat/harmony-native`，独立工作目录 `C:/Users/Beet/Documents/XDRemux-Harmony-Native`；原目录当前为 main，不在原目录修改鸿蒙代码。

## 1. 目标与范围

在现有仓库新增 ArkTS / ArkUI 原生鸿蒙应用，继续使用同一份 Rust 转换核心。
不复制 Rust 算法、不替换现有 Flutter 前端，不回改已发布的 v0.4.0 标签。
原生版成熟后合入 main，以独立应用目录及构建流程维护，不长期分叉核心。

第一阶段交付范围：
- 系统文件导入、分类、照片详情、任务队列与进度。
- OPPO 兼容 / Apple 标准输出；摄影风格、人像等现有 Rust 能力。
- 输出文件导出与失败重试；在系统能力允许时保存相册。
- 保持清晰底图、HDR、方向一致与拍摄 EXIF 保留等现有行为。

后续范围：Motion Photo / Live Photo、多文件导出、分享接收、任务恢复、后台执行。
暂不纳入：分割模型、新摄影风格算法、Swift/Vision 后端、跨设备同步。
原生前端不代表具备 Apple 照片编辑器；实际人像/风格编辑仍在 Apple 设备验收。

## 2. 建议目录与调用链（仅规划，不在本次创建）

```text
apps/harmony/              原生应用，ArkTS / ArkUI
  entry/src/main/ets/       页面、状态、任务、系统文件服务
  entry/src/main/cpp/       N-API / C++ 薄桥接层与 CMake
xdremux/rust/              唯一转换核心
 tools/ohos/               复用或扩展现有 OHOS 构建工具
```

```text
ArkUI → ArkTS 服务 → N-API 异步桥接 → Rust C ABI
                 ↘ 系统文件/媒体/分享 API
```

算法、容器处理和 EXIF 策略留在 Rust；平台 URI 授权、文件物化、相册写入留在鸿蒙层。
N-API 负责类型与生命周期转换，不承载另一套转换算法。

## 3. 阶段与验收

### P0：接口与工具链验证
- 核对现有 OHOS Rust 编译脚本、DevEco SDK、目标 API 与设备支持范围。
- 从 Rust 定义梳理 C ABI：结构体布局、布尔值/枚举、返回值释放、错误与进度句柄。
- 验证共享库及依赖加载，记录 SDK/工具链版本；不以“未见错误日志”代替调用证据。
- 明确 HarmonyOS 与 OpenHarmony API 差异，确定最低版本；不以单台 API 26 设备代表全部兼容性。

验收：最小原生应用通过 N-API 获取核心版本并分类一个测试文件；连续调用无泄漏或崩溃。

### P1：单文件闭环
- 使用系统选择器获得用户授权，将输入复制到应用工作目录，不假定 URI 是文件路径。
- 串行工作线程执行分类、详情读取、转换，避免阻塞 UI。
- 输出写入独立临时位置，成功后发布；失败不留下伪成功文件，不覆盖原图。
- 导出走系统授权路径；应用报告成功与用户可见保存成功分别验证。

验收：已知 HEIC/JPEG 样本导入 → 分类 → 转换 → 导出成功，原图哈希不变。

### P2：页面与队列
- 首页队列、设置、照片详情、进度、错误提示、重试与移除。
- 与 Flutter 现有设置语义对齐，明确区分“转换时写入人像数据”与“照片默认开启人像效果”。
- 参数在任务开始时快照固定；运行中修改设置不影响已启动任务。
- 初期默认串行；用进度句柄隔离任务。取消支持须先核查 ABI：没有安全取消能力时，仅停止后续任务，不强杀正在执行的 Rust 调用。
- 队列持有输入期间不清理其物化文件；重试和重新转换复用可读输入。

验收：转换期间 UI 可交互，错误可定位，设置变更后可重新转换，重启恢复行为明确。

### P3：实况、分享与系统集成
- 复用 Rust Motion Photo 识别/拆分与 Live Photo 配对能力。
- HEIC + MOV 成对导出；任一文件失败都不得报告配对保存完成。
- 验证系统相册是否接受/如何展示配对，不能假设鸿蒙相册与 Apple 相册语义相同。
- 逐步加入分享导入、批量导出、权限撤销/过期处理。
- 调查后台任务 API、资格与限制；若不可持续运行，明确提示前台要求并保存任务状态，不承诺无限后台转换。

验收：普通图、Motion Photo 与无效文件混合队列行为正确；iPhone 验证 Live Photo 播放和声音。

### P4：跨端回归与发布
- 相同输入、相同配置对比原生鸿蒙与 Flutter/Rust 基线输出。
- 优先对比容器结构、有效 EXIF、主图/增益图/辅助图尺寸与方向；存在动态 UUID/时间戳时不要求整文件哈希一致。
- 实测 OPPO、鸿蒙、iOS 图库方向；Apple 设备复测 HDR、人像光圈、摄影风格保存后再编辑。
- 覆盖大图、低内存、存储不足、权限拒绝、导出中断、重复文件名与重试。
- 建立独立原生鸿蒙 CI/构建文档；不把已有 OHOS Rust 编译 CI 当作完整 HAP 构建。

验收：回归清单无阻断问题，已知限制写入说明，经用户批准后发布。

## 4. ABI 与资源安全清单

优先复用：
- `xdremux_version`、`xdremux_classify`、`xdremux_inspect_photo_details`。
- `xdremux_convert_with_progress` 及 progress begin/read/end。
- Motion Photo inspect/split、Live Photo 合成及校验入口（P3）。

实施时必须确认：
- UTF-8 路径、字符串及结构体的跨语言类型宽度、对齐和所有权。
- Rust 返回对象使用对应释放函数；复制结果后释放，失败分支同样清理。
- 不允许 C++ 异常/Rust panic 穿越语言边界；与既有 ABI 错误策略一致。
- N-API 对象仅在允许的线程访问；工作线程使用独立的数据快照。
- 日志默认不输出 GPS、完整 EXIF 或用户照片；诊断导出须用户主动操作。

## 5. 构建、签名与应用标识

- 复用 `build_ohos.sh` 生成核心；构建记录源码提交、工具链和共享库哈希。
- 初期使用区别于 Flutter 版的 bundle ID（具体值待开发时确认），避免覆盖已安装稳定版。
- 统一版本来源，明确映射 versionName / versionCode；检查成品 HAP 内实际元数据。
- 发布产物要求为 **unsigned HAP**；设备测试签名仅用于本地安装，不上传签名凭据。
- 对“签名阶段失败但生成 unsigned 文件”必须检查新鲜度、版本及核心来源，避免误传旧包。
- 调试产物统一放 `C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/`，不放桌面或提交到源码仓库。

## 6. 实施前仍需确认

- 原生版先与 Flutter 鸿蒙版并行，还是最终替代；替代前另行设计应用标识与数据迁移。
- 支持的最低系统版本、手机/平板适配范围。
- 后台能力与相册写入权限的实际可用性。
- 发行渠道和签名流程；本计划不等于上架许可。

以上为建分支时的原始规划。2026-09-12 起按以下执行安排推进。

## 7. 当前执行安排（2026-09-12）

- 分工：主 Agent 维护计划、审查接口和验收证据；`gpt-5.6-luna` / `max` 子 Agent 实施。
- 当前批次仅 P0：原生工程、版本读取、分类、文件选择并物化到沙箱，以及 unsigned HAP 构建验证。
- 原生 bundle ID 采用 `io.github.beetman.xdremux.native`，区别于 Flutter 的 `io.github.beetman.xdremux`；本地测试签名必须匹配新应用标识。
- `xdremux_version` 返回字符串复制后调用 `xdremux_free_string`；`xdremux_classify` 按值返回的 `ClassificationResult` 必须按 Rust `repr(C)` 布局接收，并由 `xdremux_free_classification_result` 按值释放，不逐个手工释放成员。
- URI 授权读取及实际字节复制完成后，才允许向 Rust 传沙箱路径。复制失败清理半成品；异步调用结束前保留文件。
- 核心只使用现有 `xdremux/rust/build_ohos.sh` 产物；核对依赖、来源及哈希。无法证实来源的旧库不认定为当前源码的验证证据。
- DevEco 本地签名用于设备测试；交付发布包仍为 unsigned HAP。不发布、不提交签名凭据。

P0 验收分别记录，禁止混淆：
1. 静态检查：ABI 字段与偏移、所有权释放、异步线程边界、URI 物化流程。
2. 构建检查：生成新鲜 unsigned HAP，核对 bundle ID、版本及打包的核心库。
3. 运行检查：实际读取版本，分类已知样本，重复调用及错误路径无崩溃；泄漏结论必须有相应测量。
4. 设备签名或环境阻塞时明确列出未完成项，不能以编译通过宣告 P0 全部完成。

P0 审查后按原有 P1–P4 顺序推进；本批次不提前扩展转换参数、完整队列、后台或实况功能。

### 下一批次拆分（尚未派发）

- P1a 详情与转换桥接：`xdremux_inspect_photo_details` 的字符串由 `xdremux_free_string` 释放；`ConversionResult` 由 `xdremux_free_result` 按值释放；`ConvertConfig` 按当前源码的五个 `u8` 字段快照。
- P1b 进度及输出事务：使用独立 handle 调用 `xdremux_convert_with_progress`，完成并停止轮询后才释放 handle；`xdremux_read_progress_for` 实际写入三个 `u32`（stage/current/total），以源码为准。转换输出与输入分离，导出完成另行确认。
- P1c 验收：真实 HEIC/JPEG 样本完整闭环、原图哈希不变、无效文件与不可写目标错误可见、运行时 UI 可交互。先验证这些，再进入 P2 队列扩展。

### P0 当前结果（2026-09-13）

- Luna Max 已建立 `apps/harmony`，实现版本/分类异步 N-API、arm64 ABI 布局断言、对应 Rust free 函数释放及系统文件选择导入。
- 主 Agent 已完成本批次代码审查；异常边界、N-API 结果检查与复制失败清理已修正。导入使用源 URI 打开 FD，再通过 `copyFile` 复制到沙箱，finally 关闭 FD；已复核最终构建。
- DevEco CLI 构建成功，unsigned HAP 内确认独立 bundle ID、版本 `0.4.0` / code `40000`、API 18 兼容/目标声明，以及核心库、桥接库、C++ 运行库；实际编译 SDK 为 `26.0.0.105`。
- 首次自动部署曾被 DevEco CLI 拒绝：新 bundle 未配置测试签名，unsigned HAP 无法直接安装到真实设备。之后用户手动安装并完成了下述基础冒烟；不要把首次阻塞当作当前无法运行。
- 仍待完成：真实文件导入字节一致性、连续调用与内存行为、错误分支及最低系统兼容性。基础版本/分类调用已验证，但不宣告 P0 全部通过。
- 未修改 Rust 转换算法或现有 Flutter 应用，未提交 Git、未发布。
- 最终构建日志：`C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/build-debug-4.log`。产物 `entry-default-unsigned.hap` 位于同目录，4,737,626 字节，SHA-256 `998910CAF249356D8C7FCBA1D4C9FDDE3CFEC13327CFEE8786F55BDA878BE0B1`。
- 库链路核验：现有 target 产物、暂存库、未剥离中间库 SHA-256 均为 `D2C6BBA679846718124FE77BDDDD0276367B9EFB810A789C97714F273B828A80`；工具链剥离后的库与 HAP 内库均为 `659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7`。记录见同目录 `core-provenance.txt`。这确认复用及打包链路，不单独证明既有核心产物的原始源码提交。

### 用户手动安装后的真机检查（2026-09-13 00:26–00:27）

- 用户已手动安装、打开原生应用；Pura X View / API 26 通过 USB 连接可见。本次未安装或替换手机应用。
- 页面显示 `xdremux 0.4.0` / `Core version loaded`，确认实际库加载、N-API 版本调用和结果回传成功。截图：外部日志目录 `device-current.jpeg`。
- 用户通过系统文件选择器选择测试图片后，页面显示沙箱 `files/inputs/*.photo` 路径、`Classification complete: categorized`、`modeKey: portrait`、`folderName: 人像`。确认单次物化与分类链路成功；截图：`device-classified.jpeg`。
- 00:28 点击一次“Classify the sandbox copy again”，同一路径仍返回 categorized/portrait，页面正常响应；截图 `device-repeat.jpeg`。这只是一次重复冒烟，不是压力或泄漏测试。
- 发现分类结果行未指定字体颜色，在系统深色主题与固定浅色背景组合下出现白色文字；Luna Max 已为结果行指定 `#18202A` 并构建通过。修复包为外部日志目录 `entry-default-unsigned-colorfix.hap`，SHA-256 `D15738F4886BEC1ED1B74F9503196D3846D680BFF992D44D12F4CB2EF3EAC6FE`。未覆盖手机当前安装，修复版视觉效果待安装后验证。
- bundle 范围运行日志中观察到 Ability 启动及文件选择成功；本次采集未返回 crash/fatal 条目，未见 xdremux 核心/桥接失败。存在系统窗口与 picker 清理等框架警告，不能把无日志当作无泄漏结论。摘要 `runtime-summary-usb.txt`，颜色修复构建日志 `build-colorfix.log`。
- 本次用户手动安装已解除该设备的启动验证阻塞，不代表仓库已配置本地签名。原始文件与沙箱副本哈希、连续重复调用/内存测量、错误分支和最低系统兼容性仍待验证。

### 当日收工状态（2026-09-13）

- 用户明确确认已安装最新版（上述 colorfix 包），并要求今天到此为止。安装情况为用户报告，本轮不再操作手机或复测修复版视觉效果。
- 当前为 P0 基础冒烟已通过、完整验收未完成；P1 转换/详情/导出、P2 队列及后续系统集成都尚未实施。
- 代码和文档保留在 `feat/harmony-native` 工作区，未提交、未发布。新增 `apps/harmony/` 与 `tools/ohos/prepare_harmony_native.ps1` 仍未跟踪；`.gitignore` 和本计划已修改。
- 下次先确认最新包文字可读性并补齐 P0 验收，再按“下一批次拆分”推进 P1。保持主 Agent 规划/审查、Luna Max 具体实施的分工。
- 今天仅保存交接状态后停止，不启动新的开发、构建、设备测试或后台任务。

### 云端同步（2026-09-13）

- 收工记录后用户追加要求将进度推到云端。本次提交包含原生工程、核心库暂存脚本、忽略规则和本计划；上述“未提交/未跟踪”为提交前收工快照。
- 同步目标：`origin/feat/harmony-native`。最新状态仍为用户已安装颜色修复版、P0 基础冒烟通过，完整验收与 P1 尚待继续。
- HAP、共享库、日志、截图与签名资料保留本地；本计划已包含下次接续所需状态。通用本地交接 `current-handoff.md` 继续遵循仓库现有忽略规则。

## 8. 恢复开发：P1 单文件闭环（2026-09-13 上午）

用户要求“继续下一步”，解除上次收工暂停。基线为已推送的 `76634dd`，启动时工作区干净；继续由主 Agent 规划/审查、Luna Max 实施。

本批实现范围：
- 照片详情异步读取并显示，保留现有分类和沙箱输入。
- OPPO 兼容 / Apple 标准两种输出；转换参数开始时固定快照，串行执行，UI 保持响应。
- 独立进度句柄与三个 u32 进度值，转换结果按值释放；照片详情字符串对应 free_string。
- 转换先写独立临时输出，成功后发布到沙箱结果位置；失败不影响原图，不展示伪成功结果。
- 通过系统文件保存选择器导出；用户可见导出成功必须以实际复制完成为准，失败保留沙箱结果以供重试。
- 中文操作界面和明确的转换/导出状态；不扩展批量队列、后台、实况或相册权限。

审查补充：
- `ConversionResult` arm64 布局为 48 字节，`ConvertConfig` 为五个 u8；对应当前 Rust 源码核对，不依赖旧 FFI 文档。
- 当前 `convert_with_progress` 返回前调用 `progress::end_progress()`，实际会清除槽位；最终成功依据转换结果，不能依赖最后一次轮询保留完成值。
- 轮询不得等待贯穿转换全程的 C++ 核心互斥锁；页面离开不意味着 Rust 已停止，不能提前清理输入、输出或运行中的句柄。
- P0 的颜色修复现场复核、输入字节一致性和压力/错误分支继续列为待验收；P1 实现与构建不等于补齐这些证据。最低系统兼容和既有核心源码来源仍不作已验证声明。
- P1 产物和日志放 `C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/p1/`；不自动提交、推送或发布。

P0 补充检查（本批并行进行）：
- 手机通过 USB 可见，但首次检查为锁屏，已请求用户方便时解锁打开应用；颜色修复版页面尚待现场复核。
- 独立 OHOS C++ ABI 冒烟程序的 72 字节结构体断言编译通过，核心从 target 到测试暂存及设备副本的 SHA-256 一致。
- 普通 HDC shell 执行测试程序返回 `Permission denied`，程序未进入 main；本次新增运行调用数为 0，没有取得重复调用或内存测量结果。未尝试改变设备权限或替换已安装应用。
- 证据保留于外部 `harmony-native/p0-validation/P0_VALIDATION.md`。后续重复调用/内存验证应通过正常签名的应用进行，不把编译或复制哈希当成运行验收。

### P1 实现与构建结果

- 已实现照片详情、两种模式转换、250ms 进度读取、临时输出成功后重命名、系统保存选择器 FD 导出及失败后保留沙箱结果。
- 代码审查已修正：配置值需有限整数且符合枚举范围；进度句柄创建回传失败时释放；新选图取消/准备失败保留旧任务；导出命名使用已转换模式快照；路径生成纳入异常处理；整页滚动及中文进度/曝光信息展示。
- 配置映射：OPPO 为 `2/255/0/0/0`，Apple 为 `0/0/0/0/0`。本批暂未开放摄影风格/人像开关，未实现队列、后台或实况。
- DevEco CLI 最终构建通过，主 Agent 独立核对 HAP 元数据和库条目。原生 versionCode 升至 `40001`，versionName 和核心版本仍为 `0.4.0`，bundle 仍为 `io.github.beetman.xdremux.native`。
- 产物：外部 `harmony-native/p1/entry-default-unsigned-p1-final.hap`，4,802,790 字节，SHA-256 `E405E294809C55CC3F738B4050309F6BC29B487C9FD0B03CD3B23D2BFA6572F7`。最终构建日志 `build-p1-final.log`。
- 已请求用户按原有方式安装并解锁打开应用；尚未收到本 P1 包的安装/运行确认。不得把 P0 版本/分类截图作为 P1 详情、转换、进度或导出的验收证据。
- 下一步真机验收：同一已知 HEIC/JPEG 分别执行 OPPO/Apple 转换并导出，检查原图/沙箱副本/导出文件字节或结构；观察进度与界面响应；检查选图取消、无效输入、转换失败和导出重试。完整 P1 验收仍未完成。

## 9. P2 首批：多文件与串行队列（2026-09-14）

用户报告“这几个基础功能 OK”，记录为 P1 基础功能用户实测通过，不替代完整异常/稳定性证据。用户随后明确要求主 Agent 指导 Agent 开发下一步。

- 当前实际基线为 `f5970da`，工作区干净；它已包含 P1。不要按旧交接把 P1 再次当作未提交修改。
- Luna Max 实现多文件导入、串行队列、重试、重新转换、移除；主 Agent 审查模型、资源所有权和验收证据。
- 保持 `io.github.beetman.xdremux.native`，本批构建号 `40002`，versionName `0.4.0`；复用原 Rust 核心和 N-API 释放契约。

任务状态与行为约束：
1. 每项有稳定 ID，独立输入、详情、状态、错误、进度与输出；一个导入/转换失败不丢弃其他有效文件。
2. 同一时刻只运行一项转换；开始/继续按钮重复点击不得产生第二个执行循环。
3. “停止后续任务”只阻止下一项启动，正在执行的 Rust 调用自然结束；不强杀、不提前释放其输入或进度句柄。
4. 失败可重试，成功可按新设置重新转换；在实际启动时固定参数，输出标签及导出命名取该次快照。
5. 移除仅作用于非运行、无文件操作占用的任务；输入保留供重试，仅清理该任务拥有的沙箱文件，不能碰原始 URI 或其他任务。
6. 已有成功输出在重新转换失败后尽量保留，并明确标示是上次结果。导出失败不把成功转换变成伪失败或丢失结果。
7. 保留单项详情与导出；本批不做批量导出、完整设置页、后台、相册或实况。
8. 首批允许仅内存队列，但必须在界面和说明中明示重启不恢复；不承诺后台持续处理或虚构恢复能力。

验收：
- 确定性测试覆盖串行执行、失败继续、停止后续、配置快照、重试及移除边界；用可控操作替身验证状态机，不以构建代替行为测试。
- DevEco CLI 构建 unsigned HAP，核对包元数据和既有核心库链路；代码审查后再交用户实机验证。
- 产物/日志：`C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/p2/`。本次不自动提交、推送或发布，不更改签名配置。

### P2 首批实现与构建结果

- 多文件选择、逐项沙箱复制与详情/分类、串行转换、停止后续任务、失败重试、重新转换、单项导出和移除已实现。导入失败重试会重新物理拷贝；转换前复制完整配置，失败不阻塞下一项。
- 审查修正了同一 tick 启动竞态、参数对象别名、列表状态刷新、清理部分失败后的错误重入队，以及失败重转换后旧结果无法导出的问题。每项记录所有自身分配的沙箱路径，移除时包括旧成功输出和临时文件；清理失败仅允许重试移除。
- 队列实际为当前页面会话内存对象：onPageHide 停止后续排程，onPageShow 只重新挂接，不自动继续。重启或页面销毁重建不恢复；沙箱文件也没有跨会话回收功能。旧成功输出保留至任务移除，需留意大批量使用的磁盘占用。
- 10 组确定性控制器测试通过，覆盖串行/失败继续、同 tick 空启动和双启动、停止/继续、配置防御复制、清理失败、detach、缺少输入重新准备及重试/移除边界。操作使用替身，不能当作 picker、Rust 或导出真机证据。
- DevEco CLI 构建通过；修复过一次 ArkUI DSL 中局部变量声明错误，失败日志单独保留。最终 unsigned HAP：`harmony-native/p2/entry-default-unsigned-p2-final.hap`，4,867,000 字节，SHA-256 `A2605552573A6C9000D6C6667091A28C9067BE6E6D9DEBF245CDDA07431B05E9`。
- 主 Agent 独立核对包元数据：bundle `io.github.beetman.xdremux.native`，versionName `0.4.0` / versionCode `40002`，兼容/目标 API18，编译 SDK `26.0.0.105`。HAP 内核心为 3,243,576 字节，SHA-256 `659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7`，与既有剥离核心一致；Rust 和 C++ 桥接未修改。
- `git diff --check` 通过。最终日志、测试日志、哈希记录和 `DEVICE_CHECKLIST.md` 在外部 p2 目录。未安装或运行 P2，未签名、提交、推送或发布。
- 下一步按原规矩 DevEco 本地签名实测：多图串行、切换模式快照、停止/继续、失败后导出旧结果、删除隔离与前后台恢复。全量设置、持久化/跨会话清理、批量导出与 P3 后续另做。

## 10. P2 导出按钮故障（2026-09-14 晚）

- 用户报告“导出功能无法导出图片”，进一步确认按钮点不了或没有反应。当前 Git 基线为 `b8341a6`，工作区初始干净，P2 已包含于该提交。
- USB 设备截图显示两项 OPPO 转换均完成；列表选中 job-2，详情仍显示 job-1、沙箱输入为空及灰色操作按钮。日志只见文件选择 select，没有 save 调用。证据：外部 `harmony-native/p2-export-fix/before.jpeg`、`before-device.log`。
- 根因定位为详情 `@Builder` 接收函数返回的按值快照，状态更新与选中切换没有更新详情区域；控制器替身测试和编译无法覆盖此 ArkUI 实际刷新问题。修复由 Luna Max 实施，主 Agent 审查。限定修复详情响应式绑定与操作项一致性，不改变 Rust 或文件复制策略。
- 已将详情改为无参数私有 Builder，直接读取页面当前状态；空任务安全值与可选字段访问保护删除最后一项时的刷新。文件写入、Rust 与签名配置未修改。
- DevEco CLI 构建成功，10 组控制器回归通过，静态检查确认旧按值 Builder 调用已移除；这些检查不能代替 ArkUI 真机行为验证。主 Agent 独立运行回归、检查 diff 并核对 HAP 哈希。
- 修复包：外部 `harmony-native/p2-export-fix/entry-default-unsigned-code40003.hap`，4,869,856 字节，SHA-256 `6DA0651ADB341EEC47E422F0D0C2AFE8463957C2779B5F395B925C484B72542A`。独立 bundle 与 versionName 不变，code `40003`；继续 unsigned。验证记录与构建日志在同目录。
- 尚未安装/运行修复包；需用户 DevEco 本地签名复测：选中第二项时详情对应第二项，完成后按钮启用，点击进入 save 并实际写入；取消后能再次导出，删除最后一项无异常。未提交或推送本次修复。
- 后续确认：用户误删交付文件后已重新执行 DevEco CLI 构建并恢复 code40003 HAP，哈希与上述一致。用户随后确认现在可以导出所选图片，记录为本次导出按钮故障真机复测通过（用户反馈）。取消导出后重试、删除最后一项及完整队列异常验收仍未单独确认；不据此标记全部 P2 验收完成。

## 11. P2 设置页（用户授权：先做设置）

- 在 `b8341a6` 加现有未提交 code40003 导出修复基础上继续；保留已有修改。主 Agent 规划/审查，Luna Max 实施。本批只做转换设置和设置持久化，不扩展队列恢复、缓存清理或 P3。
- 选项对齐 Flutter `models/app_models.dart` 和设置页：输出模式，OPPO 兼容值 0..6，相机附加信息值 0..9/255，严格 ISO 开关，Apple 可编辑摄影风格与人像数据开关。首次默认仍为 OPPO `2/255/0/0/0`。
- Apple 输出强制兼容/尾部 0；切回 OPPO 关闭 Apple 两项，恢复兼容2/尾部255（原为关闭时）。开启任一 Apple 数据开关自动选 Apple，两项允许同时开启。strictTmap 独立保留。界面解释人像数据需要原图具有可用景深，不能承诺默认虚化或新增 ABI 不支持的默认效果开关。
- 设置用独立草稿编辑，成功保存后发布到全局；取消不影响实际配置，恢复默认可预览后保存。启动时先完成持久化加载，读写异常明确反馈；数据损坏和非法枚举不得直接传 Rust。
- 每项实际启动前捕获完整设置，运行中保存只影响后续任务。设置页关闭返回保留当前队列，保留 code40003 详情直接读取状态的修复。不同模式与配置的结果标签应反映实际执行快照。
- 测试重点：枚举值、模式依赖、默认值、序列化/非法保存数据、保存失败和取消、实际队列运行快照。DevEco CLI 构建 code40004 unsigned；复用现有 `.so`，不改签名、Rust，不自动安装、提交或推送。产物/证据放外部 `harmony-native/p2-settings/`。

### 设置页实现与交付

- 已实现同页设置面板、OPPO 两组精确枚举、严格 ISO、Apple 实验性风格/人像数据、草稿取消和恢复默认、保存后主页摘要。设置面板没有销毁队列；详情保留 code40003 响应式修复。
- ArkData Preferences 以带 schema 的单条 JSON 保存配置，加载完成前禁导入/启动/编辑；保存 await flush 成功后才更新已生效设置。失败保留草稿，事务尝试恢复精确原记录（含损坏原文或原来缺失的 key），回退失败单独提示。保存成功后同进程再次加载返回新值。
- 每个任务从已生效设置复制完整五字段，结果标签记录实际兼容/附加信息或 Apple 风格/人像与严格 ISO 摘要；改变草稿不影响任务，改变已保存设置不改写既有结果标签。
- 父 Agent 独立运行设置模型/生产持久化事务替身测试及 10 组队列回归，均通过。覆盖默认/枚举、类型/schema/坏 JSON、串行写入快照、损坏记录和缺失 key 的失败回退、保存后归一化读取。取消/控件联动通过代码审查；这些不是 ArkUI 或 Preferences 框架的真机测试。
- DevEco CLI 最终构建成功，`git diff --check` 通过。修正过 Preferences 上下文类型导致的首次编译错误；日志已保留。
- HAP：外部 `harmony-native/p2-settings/entry-default-unsigned-code40004.hap`，4,972,132 字节，SHA-256 `291784E5383DAC191C120D937B63C1D769B654FF1A9658DEE1C5B1C5915792F5`。父 Agent 从 HAP 独立读取元数据确认 bundle `io.github.beetman.xdremux.native`、0.4.0 / 40004、兼容/目标 API18、compile SDK26.0.0.105；包内核心哈希仍 `659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7`。
- 新版尚未签名、安装或运行，未提交/推送。本地签名后按外部 `p2-settings/DEVICE_CHECKLIST.md` 复测设置保存/取消、重启保留、运行中保存不改当前任务、Apple 功能和导出回归。队列重启恢复与跨会话清理仍未实现。

## 12. P2 队列恢复与沙箱清理（2026-09-16）

- 用户无暇真机验证但明确授权继续；不等待重复确认，也不把设置/异常场景记为已验收。使用 `e30721b` 的新 worktree，保留原 main 工作区。
- 队列记录持久化：保存稳定 ID、输入、结果与当次模式摘要、文件归属、任务状态。bigint 用字符串编码并严格解码；启动先校验 schema、重复 ID、路径边界和文件存在性。中断项不自动重跑，明确等待用户重试/继续；缺失结果不可显示为有效可导出。
- 关键状态与文件分配/发布变更保存；250ms 进度不逐帧落盘。必要状态持久化失败应显错并停止后续任务，不能悄悄继续到无法恢复的状态。
- 提供沙箱文件占用与清理未被任务引用文件入口。删除范围限独立应用自有 inputs/outputs，严格验证路径；不删除源 URI、系统导出文件或其他任务文件。存在转换、导入、导出、恢复或保存操作时禁止清理；损坏恢复数据不得触发自动清理或静默覆盖。
- 删除与持久化考虑部分失败和中断，保留明确错误及重试入口；当前结果和输入仍归相应任务所有。已存在无队列记录的旧版沙箱文件仅作为可显式清理的孤儿文件。
- 测试覆盖记录往返/非法数据、ID 冲突、文件缺失、中断恢复、持久化失败、删除隔离和活动任务清理保护。保留设置与导出回归，DevEco CLI unsigned 构建 code40005，不自动签名安装、提交或推送。
- `.so` 固定复用此前暂存产物：原目录 `apps/harmony/entry/libs/arm64-v8a/libxdremux_core.so`，未剥离 hash `D2C6BBA679846718124FE77BDDDD0276367B9EFB810A789C97714F273B828A80`；原 main 的 target 核心已变化，本批不采用。新 worktree 通过既有 prepare_harmony_native.ps1 显式 CorePath 暂存，不重新构建 Rust。
- 产物/日志保留外部 `C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/p2-recovery/`。

### 本批实现与主机验证

- 已接入启动恢复、关键状态串行保存、读写失败重试、损坏记录备份后新建空队列，以及输入/输出占用和显式未引用产物清理。恢复完成并成功保存校正状态之前禁用文件操作；中断任务不自动继续。
- 保存失败会锁存错误、停止后续调度并保留内存中的成功结果；重试保存成功后方可继续。删除意图先落盘，再清理归属文件，最后删除记录；部分失败保留可重试删除记录。导出图片成功但记录失败有独立提示。
- 路径清理校验直接父目录及叶子，拒绝符号链接、越界、重复归属和临时结果冒充成功；清理期间锁住文件操作，保留所有当前任务引用。损坏记录不会触发自动清理。
- 父 Agent 独立运行五份主机测试全部通过：settings_model_test.mjs、p2_queue_controller_test.mjs、p2_queue_controller_persistence_test.mjs、queue_persistence_test.mjs、queue_sandbox_test.mjs。覆盖保存错误锁存/显式重试、结果保留、删除前保存、进度不逐帧写入、恢复等待旧写入，以及 bigint/schema/路径/文件缺失/部分删除等。证据为外部 p2-recovery/parent-*.log。
- 这些是生产控制器与模型使用 IO/执行替身的主机测试，不代表真实 Harmony FileIO、ArkUI 或 Rust 转换的设备验证。code40004 设置和本批恢复/清理真机验收均保持待办。
- DevEco CLI 最终构建成功（build-p2-recovery-final2.log）；编译中修正了平台 TextEncoder 导入和适配器语法，失败日志保留。git diff --check 通过。unsigned HAP 为 p2-recovery/entry-default-unsigned-code40005-p2-recovery.hap，5,142,596 字节，SHA-256 E5470CB6D1C75E373310406AD78CB020A40060C74A3C9ECA76459D2AAABCA9DF。
- 父 Agent 独立读取 HAP：bundle io.github.beetman.xdremux.native，versionName 0.4.0 / code40005，兼容/目标 API18、compile SDK26.0.0.105；核心 3,243,576 字节 / hash659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7，与旧验证核心一致。Rust/C++ 未修改，原 main 工作区状态仍仅未跟踪 apps/harmony/。
- 本批未签名、安装、运行设备、提交或推送。后续真机验收按外部 p2-recovery/DEVICE_CHECKLIST.md；开发下一批可规划批量导出，后台与实况仍另行分阶段处理。

## 13. P3 首批：批量导出（2026-09-18 启动，2026-09-19 完成构建）

- 在 feat/harmony-native worktree 的既有 code40005 未提交修改上继续，保留所有恢复和清理实现。工作目录仍为 C:/Users/Beet/Documents/XDRemux-Harmony-Native；不写原 main 工作区。
- 本批只扩展已有图片结果批量导出；系统选择器一次授权、逐项串行写入、逐项结果与最终摘要。实施前通过 devecocli docs 核实 API18 多文件保存、返回 URI 对应关系和平台限制。
- 固定本批任务/结果/命名快照，排除运行、清理失败和被文件操作占用项。未导出结果优先；失败重转换保留的有效旧输出允许导出，不能把当前失败误报为新结果成功。
- 所有返回 URI 在写入前验证数量与唯一性，保护源文件、沙箱文件与非空既有目标；重名使用唯一导出名。单项写入失败可继续后项，取消和停止后续有明确统计。文件写入关闭成功与队列状态保存成功分别报告，持久化失败立即停止后续且保留结果。
- 选择器和批量期间锁住相冲突的转换/导入/删除/清理；停止只阻止后续，当前文件自然完成。批次不自动在重启后继续，不承诺后台能力；需要处理选择器生命周期而非误判为主动离开。
- 主机测试覆盖快照/顺序、双启动、取消/停止、URI 数量与重复、写入失败隔离、保存失败保留、锁释放和计数。保留现有五套回归，devecocli 构建 code40006 unsigned。
- 不改 Rust/C++/签名；继续使用已有暂存核心（HAP 剥离 hash659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7）。不自动安装、提交或推送。产物/日志放外部 harmony-native/p3-batch-export/；旧版及本版真机验收仍待办。

### P3 批量导出实现说明

- 以唯一 ASCII 文件名和 URI 解码后的叶名匹配目标，不依赖保存选择器返回顺序。数量、重复、未知文件名或源/沙箱路径冲突在任何写入前拒绝；平台自动改名而无法准确对应时提示使用单项导出。
- 单项和批量共用注入式文件复制逻辑：目标仅以 WRITE_ONLY 打开，已有非空内容拒绝写入；校验输入/复制后大小并关闭 FD 后才计作已写入。系统在 API18 预创建空文件，失败或停止可能留下空/部分目标，应用不会自动删除系统目标文件。
- BatchExportEntry 区分物理复制完成和队列记录保存，后者失败保留已写入事实并停止后续。批次只在当前前台会话执行；重启保留成功转换和记录，但不自动重跑批次。图片写入与队列 JSON 不构成跨系统原子事务，进程恰在两者之间退出时，需要核对目标，未记录的已写入图片可能再次被导出。
- 批量 external 锁预校验全部 ID 后一次变更/保存；解除锁也统一保存。导出中的成功转换在重启恢复时保留成功状态和结果，只有缺失/不安全结果、转换中断或清理中断按相应失败处理。
- picker 引起的暂时隐藏不会立即停止批次；返回后等待 onPageShow 才写入，真实离开/销毁页面停止后续，正在写入项自然收尾。UI 刷新异常不跳过文件复制后的记录保存。

### P3 主机验证与构建结果（2026-09-19）

- 父 Agent 独立运行七份测试通过：原有设置、队列、队列持久化、恢复记录、沙箱五份，加 batch_export_edge_test.mjs 和 p3_batch_export_test.mjs。覆盖 URI 乱序/编码/数量/重复/全队列保护、批量锁原子性与单次保存、复制串行/失败隔离、停止、已写入但记录失败、UI 回调异常隔离、成功结果中断恢复、共享 FD 复制及关闭。主机证据为外部 p3-batch-export/parent-*.log。
- devecocli 最终构建通过（build-p3-final.log），git diff --check 通过。首次编译发现并修复了 ArkTS 内联对象类型限制；失败日志保留。
- unsigned HAP：p3-batch-export/entry-default-unsigned-code40006-p3-batch-export.hap，5,216,822 字节，SHA256 1B46028F3BAAC3448D588630FD7BFBA29FEBDE046E9367B98436B5289D7317D2。
- 父从交付 HAP 独立核对：bundle io.github.beetman.xdremux.native，0.4.0/code40006，兼容/目标 API18，compile SDK26.0.0.105。包内 Rust 核心 3,243,576 字节，hash659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7，与原验证核心一致。证据 parent-artifact-verification.json。
- 未签名、安装、执行设备验证、提交或推送。真实 picker 多文件返回/改名、前后台时序、ArkUI 状态和实际用户目录写入仍按 DEVICE_CHECKLIST.md 待验收；host IO 替身测试不覆盖平台实现。原 main 工作区仍仅有未跟踪 apps/harmony/，未受本批修改。

- 独立 Luna 只读复核生命周期、全批锁释放、picker 先返回后 onPageShow、销毁中断与新批次刷新，未发现新增确定性问题；该审查不替代真实设备事件时序验证。

## 14. P3 小批：Motion Photo 识别与信息展示（2026-09-19，构建完成）

- 用户要求下一步“先推进一部分”，本批只做按需识别当前任务的沙箱输入及展示结果，不做拆分、视频写出、Live Photo配对、系统相册或后台。
- 继续原生worktree/feat/harmony-native，保留40005/40006未提交修改；Luna Max实现，父规划审查和独立验证。
- 核验现有.so的xdremux_motion_photo_inspect导出；仅新增既有ABI的异步N-API桥接，返回char*通过xdremux_free_string恰当释放，复用核心互斥和异常/Promise资源回收。Rust源和.so保持不变，绝不传picker URI。
- 按需按钮操作，不在每项导入时额外全文件读取；使用已物化inputPath和文件操作锁，禁止与转换、导入、导出、清理冲突。错误独立于转换状态，保留成功结果。缓存只在当前会话、绑定任务ID和inputPath，切换选中/重新导入不能串项，重启需重新识别。
- 显示未检测、检测中、未识别出支持的Motion Photo结构、已识别实况和识别失败。false且含errorMessage属于错误，不可当作普通图。可选音频信息缺省属于未知，不得当作无音频；无证据时不宣称图库Live Photo兼容。
- 展示来源类型、静态/视频字节范围或大小、可用的视频尺寸/时长/帧率/音频信息。严格校验对象、布尔/字符串类型、有限安全整数、区间及实际沙箱文件大小；超JS整数精度拒绝而非舍入。未知来源保留可读原值，媒体扩展字段缺省兼容旧核心。
- 新模型边界测试与异步状态/缓存隔离审查，加既有七套回归、devecocli unsigned40007构建。产物/日志外部harmony-native/p3-motion-inspect/；未签名安装、提交或推送。识别与既有功能真机验收继续待办。
### Motion Photo 实现与验证结果

- 已实现异步 motionInspect、按需按钮、会话缓存和信息展示。仅读取已物化且经沙箱校验的输入；external 锁阻止冲突文件操作，结束释放并保存。返回只更新对应任务和输入的缓存，切换选中不会串项；识别错误保留转换状态和结果。
- N-API 在既有核心互斥下调用 xdremux_motion_photo_inspect，使用 RustStringDeleter/xdremux_free_string 释放返回字符串。父核对现有核心确有该导出，未重建或替换 Rust。
- 父独立运行九份主机测试全部通过：既有七份加 p3_motion_photo_model_test.mjs、motion_inspect_edge_test.mjs。覆盖真实 JSON 字段、普通/错误报告、未知来源、缺省音频、区间/文件大小、safe integer、u32/u16、零值/null、双流字节限制。缓存隔离、异步锁及 ArkUI 刷新仅完成代码审查；这些测试不替代 N-API 实际运行或设备时序验证。
- devecocli 最终构建成功，证据 build-motion-final.log；git diff --check 通过。交付 p3-motion-inspect/entry-default-unsigned-code40007-p3-motion-inspect.hap，5,272,818 字节，SHA256 60D5C0EE5A312FAA81A9B4D97271C3F1CEF4C82C1390941A3CAEED8ECD95B4F6。
- 父独立核对 HAP：bundle io.github.beetman.xdremux.native，0.4.0/code40007，兼容/目标 API18。包内 Rust 核心 3,243,576 字节，SHA256 659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7，与此前产物一致。证据 parent-artifact-verification.json、parent-core-symbols.log、parent-*.log。
- 未签名、安装、设备运行、提交或推送；原 main 工作区仍仅有未跟踪 apps/harmony/。按本批 DEVICE_CHECKLIST.md 后续本地签名验收，40004–40006 待验项继续保留。下一开发小批可推进 Motion Photo 拆分，实况配对与系统相册仍另行分阶段处理。

- 用户已确认 code40007 的基础流程可用；该反馈只覆盖基础功能，不代表异常分支、边界、缓存/生命周期或设备兼容性已全部验收。
