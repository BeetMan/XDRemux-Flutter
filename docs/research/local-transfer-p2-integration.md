# P2 接入研究：Flutter 文件互传

日期：2026-10-18，进展更新：2026-10-19。本文保留研究阶段的选型与问题记录。后续 P2.0/P2.1 已实现模型、独立 ABI/runtime、读取租约与受管删除、Dart worker 与队列交接；**P2.2 又补齐 Windows/Android 手动直连页面、独立动态库打包、显式身份/接收确认及通用导出**。最新结果以 [P2.2 验证](../testing/local-transfer-p22.md)、[ABI 契约](../../crates/xdremux-transfer-ffi/README.md)、[Dart 契约](../../apps/flutter/lib/services/transfer/README.md) 为准。工作分支 `codex/local-transfer`，应用基线 `877047b8`。自动发现和完整权限/生命周期矩阵仍待验收。

## 结论与顺序

Windows/Android 首轮采用独立的传输 C ABI 库，Dart 用长期 worker isolate 持有绑定，通过命令和有界事件轮询与 Rust 后台 runtime 通信。接收箱与转换队列之间增加显式、流式的导入交接；通用文件导出使用独立服务。先完成这两个边界，再添加手动直连、接收确认、接收箱和发送入口。

本轮没有修改主线工作区。主线仍停在同一提交，但 `xdremux_ffi.dart`、`xdremux_service.dart`、`main.dart`、原生库打包等有未提交的 codec/preview/thumbnail 开发。接入时先核对这些改动最终合入的位置；不把当前未提交内容复制进传输分支，不重构整个 `main.dart`。

## 现有代码对应的接入问题

| 位置 | 实际行为 | 接入决定 |
|---|---|---|
| `main.dart:isSupportedInputPath` / `_enqueuePaths` | 先按 `.heic/.heif/.jpg/.jpeg` 筛选；接收箱路径是无扩展名的 `data` | 不能直接把 `received_path` 丢给现有队列；建立带原始名称的私有输入副本 |
| `app_models.dart:QueueItem.fileName` / `ConversionConfig.outputPathFor` | 名称及输出位置来自输入路径，默认可能写回输入父目录 | 输入副本保留已校验 basename；转换输出写独立 output 目录，不能写入 Rust 接收箱 |
| `CheckpointService.materializeTemporaryInput` | 只对 OS 临时目录中的输入做持久化；非临时的接收箱路径会原样返回 | 明确新输入副本归 checkpoint 管理；不能假设调用现有 materialize 就获得独立副本 |
| `FileActionService.saveFile` | 移动端直接走图库；桌面读入全部 bytes，且强制 HEIC 文件名/MIME | 新建通用流式文件导出，不用它导出 MOV/任意大文件 |
| `FileActionService.shareFile` | 打开系统分享面板，已有平台分支 | “局域网发送”单独调用 TransferService；系统分享保留为独立操作 |
| `DropFileService` | 活跃页面的临时广播，无持久 ACK | 接收箱导入使用显式请求/返回结果；不能发布一次 drop 事件后就认为已导入 |
| `main.dart` 的导入/重转换日志 | 部分 `debugPrint` 会包含输入完整路径 | 传输导入必须经过脱敏日志边界，不能把路径、PIN、token 或含凭据的命令完整打印 |
| `main.dart` 托盘退出 | `onExit: () => exit(0)`，没有传输停服交接 | 增加统一的退出协调，先 stop 并等 Stopped，再结束进程 |
| `XdRemuxFFI` / `XdRemuxService` | 同步 C ABI + 多处 `Isolate.run`，适合单次转换 | 新建绑定与长期 worker；不反复创建 isolate 承载长生命周期传输 |
| Android manifest / Gradle | 源码中 INTERNET 在 debug/profile 声明，main 未显式声明；targetSdk 来自 Flutter | 正式接入前显式声明并检查 release 合并 manifest、实际 targetSdk；不能用 shell 测试代替 |

上表是源代码观察。没有在本轮构建 release APK，不能仅凭 main manifest 判断最终合并产物是否已由依赖带入 INTERNET。

## P1 在桥接前还要补的模型

P1 网络与磁盘路径已经可用，但当前公开模型不足以直接支撑完整 UI，建议列为 P2.0：

1. **发送文件 ID 映射**：发送 `Progress.file_id` 是内部生成的 UUID；`Prepared.files` 和 `SendReport.files` 的 `SentFile` 只有名称、长度、哈希，没有 ID。界面无法把每个进度归到对应文件。补齐 Prepared / Progress / 文件终态中一致的 file ID，不通过 HashMap 顺序或文件名猜关联。
2. **主动状态快照**：现有 `pending_offers` 只返回尚未决策的 offer；`recent_events` 有界且不包含进度；接收回执只能说明已经提交。新增可分页读取的活动发送、已接受接收、逐文件状态与最终发送报告，便于事件溢出或 Dart worker 重连后恢复。
3. **运行实例 ID**：P1 事件序号在服务重启后重新计数。桥接事件同时携带 instance ID，跨实例不比较 sequence 大小。
4. **持久历史边界**：接收成功回执已持久化；发送中的任务、失败详情和“已导入转换队列”状态尚未持久化。初版可明确重启后发送任务中断；应用自己的导入记录和终态历史必须独立保存。
5. **删除与导出 API**：P1 没有接收箱删除/租约接口。UI 不直接递归删除 Rust 的私有目录。P2.0 需提供按 receipt ID 的清理操作及处理中拒绝删除规则；导出失败保留原回执。

## C ABI 和线程方案

首选新增独立 adapter crate，例如 `crates/xdremux-transfer-ffi/`，与现有 image workspace 隔离。Windows 打包 `xdremux_transfer.dll`，Android 打包 `libxdremux_transfer.so`；库只在用户进入互传流程时加载/启动。现有图像库默认构建仍不依赖 Tokio、TLS 或 LocalSend。这里是待实施选型，不代表独立库已经构建或测得新增体积。

| 方案 | 对现有开发的影响 | 本阶段判断 |
|---|---|---|
| 传输导出加到图像动态库，默认关闭 feature | 需要修改 root/core manifests、lockfile、发布脚本及当前正在变化的 FFI；工具链一起升级 | 可作为后续收敛选项，当前不优先 |
| 独立 C ABI 库 | 多一份平台打包和加载检查；应用只传 C ABI 数据，不跨库传 Rust 类型 | Windows/Android 优先验证 |
| 另起常驻 CLI 子进程 | 增加 IPC/子进程管理；不能直接作为移动端应用的统一嵌入方案 | 只保留为测试 harness |

Apple 的静态链接/符号保留、签名、多个 Rust archive 的组合尚未验证，不能从 Windows/Android 动态库方案推断。Apple/HarmonyOS 本轮不作支持承诺，鸿蒙运行继续延后。

候选 ABI（下列名称和签名尚未冻结）：

- `xdremux_transfer_abi_version()`：整数 major/minor，不能只靠包版本判断 ABI 兼容。
- `create(config)`：创建 opaque 数字 handle，返回 starting；RSA 身份加载/生成、目录恢复和监听启动在后台完成。
- `submit(handle, request_json, request_len)`：有界复制参数后返回 operation ID；probe、发送、决策、导入准备、分页查询异步完成。
- `poll(handle, limits)`：非阻塞拉取有界事件批次，包含序号、实例 ID、丢失标记与后续 cursor；单事件不得被截断。
- `stop(handle)`：幂等请求，优先于普通查询/发送；Stopped 意味着任务、监听和存储租约均已释放。
- `release(handle)`：Stopped 后回收 handle；重复释放/旧 handle 返回明确错误，禁止解引用失效裸指针。
- `xdremux_transfer_free_string(ptr)`：只释放此库返回的缓冲；不能借用图像库的 `xdremux_free_string`。

输入 JSON、命令队列、事件队列、输出字节数及 handle 数都设上限。普通队列满返回 Busy；取消和 stop 保留优先通道。字符串所有权必须成对释放，调用方传入的内存不得被异步任务借用。JSON 报告只包含稳定错误码与数据，不透出 OS/reqwest 原始异常。每个 FFI 入口处理 panic，adapter 构建需核对 panic 策略，不能把 abort 构建下的 catch_unwind 当作保证。

Rust runtime 与服务线程由库管理；Dart worker 负责 ABI 加载、发命令、批量读取事件和转成可发送的普通数据。UI 只保存 Flutter 状态，不做文件 I/O、不接收 payload bytes。`DynamicLibrary` 不通过 isolate port 传递，而是在 worker 内加载；Dart 官方 [SendPort 文档](https://api.dart.dev/dart-isolate/SendPort/send.html) 明确列出它不可发送。

本阶段优先有界轮询（例如活跃时 100–250 ms，并在空闲时降低频率），避免先引入跨线程回调生命周期。Dart 的 [NativeCallable.listener](https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.listener.html) 可供后续改为“有事件可读”通知；回调必须在 isolate 存活期间保留并最终 close，不能发出通知后立即释放指针。

先订阅事件，再读取初始快照及分页回执，按 receipt ID 去重。回执 UUID 排序不是时间排序，不能把扫描 cursor 当增量时间水位；扫描期间的新提交通过事件补齐，溢出则重新扫描。native 聚合状态负责 snapshot 与 observed sequence 的一致性。

## 接收箱到转换队列的交接

使用 `getApplicationSupportDirectory()/transfer/` 作为 Rust 私有根，不能复用 OS cache、图库目录或 Android 的 app-specific external output。只有 Committed 文件能展示“导入转换队列/导出”。MOV、普通不支持转换的文件仍能留在收件箱和导出；不自动解码、不自动入图库。

推荐初版流程：

1. 用户选择一条回执；应用通过 receipt ID 请求导入，校验支持的文件扩展与实际内容，传输成功不代表能转换。
2. 流式复制到 checkpoint 可管理的、按 receipt ID 隔离的私有输入 bucket；文件名使用回执中已校验的原名。副本完成后核对长度/哈希并原子发布，不能调用 `readAsBytes` 把整文件放入 Dart 内存。
3. 显式调用队列 intake，返回 added / duplicate / unsupported / rejected / failed 状态；复用已有分类、人像与输出冲突检查，不能把“完成复制”等同于“已进入队列”。
4. 成功加入后，持久保存 receipt ID 与 checkpoint 输入的对应关系；重复点击可识别。同名不同 receipt ID 保留不同 bucket，不自动合并。
5. 转换输出使用独立 output 根，失败不污染接收箱。接收箱清理与 checkpoint 清理分开；清理前确认复制/导出任务已结束，导入失败保留接收回执。

这样先付出一次磁盘副本，换取明确的所有权与重启语义；后续有证据再优化为受管文件租约。Windows 用户选定目录的导出可流式复制；Android SAF 使用文档 URI/文件描述符桥接，不能把任意 `content://` 当作路径交给 Rust。图库保存始终是单独、明确的动作。

空间估算需要包括接收箱原件、checkpoint 输入副本、发送快照和转换输出；不能只检查一份源文件体积。每次复制/导出预检空间，失败清理自己的临时文件并保留已提交原件，界面说明额外空间需求。

## 界面与运行边界

新建独立 `TransferService`、`TransferController`、模型和页面，避免往 `XdRemuxService` 塞会话状态。入口可在工具栏增加“局域网互传”，原图操作提供“发送原文件”，成功输出操作提供“发送转换结果”。二者明确展示来源，不能通过文件名后缀猜测。

首个闭环：用户开启接收 → 显示本机实际地址/端口 → 对端手动直连与证书身份确认 → 文件清单确认 → 流式进度 → 接收箱 → 手动导入队列或导出。缺失动态库/ABI 不匹配时禁用互传入口，图像转换仍可使用。现有普通“分享”继续调用系统分享，互传不隐藏在其中。

首次 probe 本身没有独立身份认证。显示真实证书指纹及对端核对入口；用户确认前不发送文件元数据或内容，不能仅凭同名设备宣称已经配对。信任记录以指纹为键，地址只作可变连接信息；已知地址出现新指纹时重新确认，提供忘记设备操作。记住设备不意味着自动接受其文件，测试用 `discover-test-only` 不进入产品流程。

手机初版限定前台；pause/退出时停止新接收、取消未决 offer 及进行中的传输，并保留已提交文件。再次前台由用户重新开启接收，不自动恢复无限期监听。不沿用现有“后台转换 specialUse 前台服务”承诺文件传输后台能力。桌面是否保持接收由明确状态控制，托盘退出要 await 停服；单纯隐藏窗口不等于停止，也不能悄悄启动监听。

手动直连先验收，设备列表保留扩展接口；P1 的 multicast 依赖已编译并不意味着自动发现已经实现。完整 P2 退出前再做公告/发现并验证失败兜底，不能从首个手动直连切片宣称 P2 整体完成。

## Android 应用权限与打包检查

源码 main manifest 应显式声明 INTERNET，检查 release 合并 manifest 与实际 Gradle targetSdk；当前 `compileSdk=36` 不能替代实际 targetSdk 的核对。针对 SDK 36 及以下目标，不机械添加新的 LAN 运行时权限；目标升到 SDK 37 时，再实现 Android 17 的 ACCESS_LOCAL_NETWORK 声明、请求及拒绝/撤销处理。Rust socket 同样受这些限制，手动 IP 也不绕过。依据：[Android 官方局域网权限文档](https://developer.android.com/privacy-and-security/local-network-permission)，本轮核对日期 2026-10-18。

以上是正式应用验证项，本轮未改设备的权限/兼容开关，未构建或安装 P2 APK。P1 harness 以 ADB shell 身份运行的成功，不证明应用沙箱有权访问 LAN、SAF 文件或后台网络。Windows 的放行记录也只对应 harness，不能证明最终 Flutter EXE 的防火墙状态；最终应用需要按程序路径验证。

## 可执行的开发切片与退出条件

| 切片 | 交付 | 验证 |
|---|---|---|
| P2.0：模型及 native adapter | 文件 ID、活动状态快照、实例 ID、受管清理；独立 ABI/runtime、命令/事件上限、短调用 | 真实 DLL/.so ABI 冒烟；错误 handle/重复 stop/release/参数上限/内存释放；事件溢出能恢复；停服后端口/租约释放 |
| P2.1：Dart worker 与收件箱交接 | 长期 isolate、缺库/版本降级、流式输入副本、明确队列 ACK 与所有权 | 缺库不影响转换；按 Prepared 映射逐文件进度；重启、重名、重复导入、空间不足、清理期间保护 |
| P2.2：Windows/Android 手动直连 | 接收开关、身份/文件清单确认、原图/结果发送、进度、取消、接收箱、通用导出 | release 应用 ↔ 官方 LocalSend / 另一应用双向；独立核对文件；权限拒绝/撤销、后台/恢复、防火墙、未知格式 |
| P2.3：发现及完整退出验收 | 自动发现、地址可达性、端口冲突提示、失败文件重试和本地化 | 与 LocalSend 同机共存、多网卡/多播失败退回直连、输入/输出/转换回归；按平台记录支持范围 |

P2.0/P2.1/P2.2 已在后续开发实现；下一切片是 **P2.3：发现、失败兜底与完整退出验收**。主线合并与发布仍独立安排，合并时继续核对主线正在变化的 UI/打包接口。上文候选 ABI 以实际实现契约为准，例如 `release` 会等待已停止线程的收尾，`stop` 会撤销 adapter 持有的读取租约，因此应用必须先结束外部读取。Dart worker/controller 会先等待正在进行的复制结束，再请求 native stop。
