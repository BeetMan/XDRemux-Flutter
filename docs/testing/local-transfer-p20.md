# P2.0 模型与独立 C ABI 验证

日期：2026-10-18。分支：`codex/local-transfer`。范围：native 核心和 Windows / Android 动态库；尚未接入 Flutter。结构化结果见 [evidence](local-transfer-p20-evidence.json)，调用契约见 [adapter README](../../crates/xdremux-transfer-ffi/README.md)。

## 已实现

- 发送文件 ID 贯穿 Prepared / Progress / FileSent / SendReport；新增按传输 ID 取消和恢复最终发送报告。
- 新实例 ID；活动传输和最近 32 项终态的分页快照，包含待确认、已接受接收、逐文件进度/错误/回执 ID；序号与快照在同一锁内发布，终态淘汰有计数。接收回执继续持久化；发送历史仍限本次 runtime。
- 按回执 ID 获取读取租约，读取期间删除返回 Busy；删除采用原子搬入受管事务目录再清理；未知文件/链接拒绝删除。核心停服等待读取结束。
- 独立 `xdremux-transfer-ffi` workspace、C header、ABI 1.0、专用后台 runtime、数字 handle 和成对字符串分配/释放。队列、事件字节数、输出分配及并发有上限，取消使用保留队列，stop 独立于队列容量。
- stop 后等待 runtime 和工作线程结束，才允许释放 handle；调用方必须先结束外部读取。默认 loopback 随机端口；LAN 绑定由调用者显式指定。

## 验证结果

| 检查 | 结果 |
|---|---|
| 核心 Rust 测试 | 17/17 通过；含既有 HTTPS/文件安全回归、事件溢出快照恢复、ID 关联、读取租约/删除/停服协调 |
| Adapter Rust 测试 | 2/2 通过；真实服务启停、TooSmall 不丢记录、事件溢出计数、输入长度/空指针、重复 stop/release、优先队列、端口/目录释放 |
| fmt / Clippy | 两个自有 crate 通过；Clippy `--all-targets --no-deps --locked -- -D warnings` |
| Windows x64 release DLL | 构建通过；Python ctypes 调用导出的实际 C 符号完成 HTTPS 回环传输 |
| Windows ABI 文件验证 | 中文/emoji 文件名、空文件、2 MiB 二进制，共 3 个文件、2,097,178 bytes；独立读取落盘长度/SHA-256 全一致 |
| Windows ABI 生命周期 | 分页/发送报告恢复、operation 查询、读取时 Busy、释放后删除、64 个未释放输出 buffer 上限、未知/重复 free、等候接受时 stop、旧 handle 拒绝、原目录和端口重开均通过 |
| Android ARM64 release `.so` | NDK 28.2、API 24 构建；无线 ADB 部署，C 程序 `dlopen` 实际库并执行 ABI |
| Android 真机生命周期 | PKJ110 / Android 17(API 37)，3 次在同目录/同端口启停成功；证书保持、实例更新、快照、参数/handle 错误及成对 free 通过；部署前后库哈希一致 |

Windows smoke 的单次调用最大耗时本次均低于 1 ms，具体值见 JSON；这是一次本机观测，不是实时性保证或性能门槛。发布库体积：Windows 6,817,280 bytes，Android 6,633,792 bytes。没有测量 APK 增量体积、峰值内存或应用启动开销。

构建使用独立 target 缓存 `tools/local-transfer-poc/target/{windows,android}`。验证脚本为 `crates/xdremux-transfer-ffi/scripts/smoke.py` 和 `scripts/android_smoke.c`；命令/前置条件记录于 adapter README。本机日志、输出与远端测试目录留在 ignored target / `/data/local/tmp/xdremux-p20-*`，未提交私有路径、证书、PIN 或测试内容。Windows linker 输出生成 import library 的提示，不是编译错误；严格 Clippy 已通过。

## 边界与下一步

P2.0 的 Android 验证以 ADB shell 身份加载 `.so`，Windows 验证用 Python ctypes。它们不证明 Flutter EXE 的防火墙、APK 的 INTERNET/LAN 授权、SAF 文件读取、退后台或图库流程已通过。P1 原有 Windows ↔ Android LAN 双向记录仍单独保留，本轮没有把 ABI 回环测试算作跨设备应用互传。

下一步 P2.1：长期 Dart worker、缺库/ABI 不兼容的功能降级、接收箱到 checkpoint 的流式文件副本、原始扩展名与输出目录、明确队列 ACK 和幂等导入记录。首次证书确认、页面与正式应用双向验收安排在 P2.2；发现与完整体验在 P2.3。Apple 与鸿蒙验证仍待后续安排。
