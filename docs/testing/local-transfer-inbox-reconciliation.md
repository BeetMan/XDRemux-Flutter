# 收件箱删除与旧查询结果同步

日期：2026-10-25（UTC+8）。基线：`8eb554f3605911c581159e50ae1849c83b21bb8b`，隔离分支 `codex/local-transfer`。结果见 [JSON 报告](local-transfer-inbox-reconciliation-report.json)。

## 修复行为

删除成功或消费 `receipt_deleted` 事件后，先前发出的分页查询仍可能返回已删除记录；排队中的旧 `committed` 事件也可能重新加入该记录。原 controller 会把它放回列表。停止／重启还会沿用旧的新增回执缓存，即使磁盘记录已经删除，也可能覆盖新服务的空结果。

现在，成功删除和删除事件统一记录当前 runtime 的已移除 ID，从列表和新增回执缓存移除；后续旧分页及旧提交事件不能重新加入它。删除失败不记录移除标记。删除回复也检查 service 实例和停止代次，不能修改替换后的服务。

分页游标和“还有更多”仍来自原始查询页；过滤已删除的最后一行不会提前结束分页。停止时清空当前 runtime 的新增／移除标记，新服务以磁盘收件箱重新载入分页窗口，窗口外的记录仍可加载更多。移除标记仅在当前 runtime 内保留，不写入磁盘。既有接收箱、已加入队列的副本和源文件的所有权规则未改变。

## 本轮验证

| 检查 | 结果 |
|---|---|
| 旧 controller | 6 项新增受控用例中 5 项失败，删除被拒绝时保留原件的控制用例通过 |
| 新增受控回归 | 刷新／加载更多期间删除、排队的旧提交、删除事件与旧查询交错、删除失败后重试、重启不沿用旧新增缓存，共 6 项通过 |
| 真实 DLL／worker | 旧 controller 复现“磁盘已删除、旧查询仍将记录放回列表”；修复后，同一夹具下读取租约使删除返回 `busy` 且哈希不变，释放租约后磁盘与 native 回执均为空，旧查询不能恢复列表记录，同根显式重启仍为空 |
| 文件校验 | 一份 65,536 bytes 合成文件经本机 loopback HTTPS 接收，租约下独立读取哈希一致；原发送文件保持不变 |
| 完整 Flutter | 140 项通过，包括上述 7 项、既有 4 项真实 DLL 回归及 classifier／home queue fixture |
| 静态与打包 | Dart 格式、完整 Flutter analyze、Windows／Android 普通 `lib/main.dart` release 构建及包内库／许可核对通过；APK 未安装 |

真实 DLL 夹具位于 `test/transfer_inbox_native_test.dart`：只延迟已返回的真实收件箱查询结果；删除、租约、磁盘检查、HTTPS 传输和重启均调用实际 worker／DLL。夹具显式调度 controller 的 poll，native worker 的轮询保持正常，避免定时刷新抢占预定的查询页。最初未控制 controller 轮询的一次夹具超时单独保留，不计作生产故障或修复前断言失败证据；上表对比采用调整后的同一夹具。

```powershell
# apps/flutter 下
flutter test --no-pub test/transfer_inbox_reconciliation_test.dart --reporter expanded
$env:XDREMUX_TRANSFER_TEST_DLL = 'ABSOLUTE_DLL_PATH'
$env:XDREMUX_TRANSFER_INBOX_REPORT = 'OWNED_REPORT_PATH'
flutter test --no-pub test/transfer_inbox_native_test.dart --reporter expanded
# 完整回归另外启用现有真实 DLL 确认／启动报告和 HEIC fixture 环境变量
flutter test --no-pub --reporter expanded
flutter analyze --no-pub
```

本轮未修改 Rust 核心、ABI、Android 原生桥接、协议或锁文件，没有操作手机、网络或防火墙。新增真实检查是受控 loopback 收件箱验证，使用 raw service 接收合成文件，controller 保持仅本机收件箱模式；不代表最终页面收发、LAN 发现、Android 生命周期或真实断网通过。新版真机与网络／平台矩阵继续待验，P3.2 未完成，鸿蒙验证继续延后。
