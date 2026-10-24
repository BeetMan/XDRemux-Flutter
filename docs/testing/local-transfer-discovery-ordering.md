# 设备发现刷新与定时状态回复顺序

日期：2026-10-25（UTC+8）。基线：`440fd5f6fb6f400d67ab3b2bfdc81461a96673ad`，分支 `codex/local-transfer`。结果见 [JSON 报告](local-transfer-discovery-ordering-report.json)。

## 修复行为

此前已阻止跨 runtime 的旧回调污染新服务，但同一 runtime 内仍可能发生：定时 `discovery_status` 先查询，用户随后完成“重新发现”，较早的状态回复再返回。旧的禁用状态会清空刚刷新的设备并释放多播锁；旧的成功回复会覆盖新设备列表；旧的普通网络错误会污染最新错误状态。重复 `discover()` 也会并行发送多次公告。

现在，每次显式发现为状态回复建立新的归属版本。较早的发现状态和非终止错误不能覆盖之后的手动刷新。`closed`／`worker_stopped` 仍表示 runtime 不可用，继续走停服与显式重启流程，不因刷新操作而隐藏。

同一 runtime 的重复发现请求共享待完成操作，只获取一次多播锁、提交一次公告；完成后下次显式请求仍会重新公告。发现等待期间暂停额外的发现状态查询，事件、已提交回执和快照刷新继续处理。停止会撤销旧发现操作的共享槽，旧操作完成不能清空新操作的槽。原有指纹确认、直接连接和接收确认规则保持不变。

## 本轮证据

| 检查 | 结果 |
|---|---|
| 修复前 | 8 个新增用例中 6 个失败，2 个 runtime 终止控制用例原本已通过 |
| 新增受控回归 | 旧的启用／禁用状态、旧普通网络错误、两种终止错误、重复刷新合并、发现等待时回执处理、跨 runtime 发现槽交接，共 8 项通过 |
| 相关测试 | controller 与异步归属文件共 61 项通过 |
| 完整 Flutter | 133 项通过，包括既有 4 项真实 DLL 测试及 classifier／home queue fixture |
| 静态与发布构建 | Dart 格式、完整 Flutter analyze、Windows／Android 普通 `lib/main.dart` release 构建及库／许可核对通过；APK 未安装 |

新增用例位于 `apps/flutter/test/transfer_runtime_boundary_test.dart`，以 `discovery ordering:` 开头。通过显式 completer 安排状态查询、刷新与回复的先后，检查设备列表、错误、锁状态、公告次数、回执及停止状态；并非通过实际断网制造的延迟。

```powershell
# apps/flutter 下
flutter test --no-pub test/transfer_runtime_boundary_test.dart --plain-name 'discovery ordering:' --reporter expanded
# 完整回归启用现有可选真实 DLL 与 HEIC fixture 环境变量
flutter test --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib/services/transfer/transfer_controller.dart test/transfer_runtime_boundary_test.dart
```

本轮未修改 Rust 核心、ABI、Android 原生桥接或锁文件。新增发现顺序检查使用可控回复与注入锁操作；既有真实 DLL 回归为本机 loopback 的确认和启动／端口恢复检查，不是新增 LAN 发现或 Android 真机证据。没有操作手机、网络或防火墙。

新版 Android 生命周期／发现复验、真实断网／切网、VPN／多网卡、AP 隔离、权限撤销和完整平台／客户端矩阵继续待验；不把这次修复视为早先 Android 后台快照等待问题的已确认原因。网络脚本仍见 [准备记录](local-transfer-network.md)。P3.2 未完成，鸿蒙验证继续延后。
