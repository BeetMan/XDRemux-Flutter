# 互传启动取消与停止顺序验证

日期：2026-10-24（UTC+8）。基线：`5f5c0ea053ed86500ff5f94713a53f0e96c47d77`。隔离分支 `codex/local-transfer`。机器结果见 [JSON 报告](local-transfer-startup-report.json)。

## 行为与修复

原 controller 在等待目录或原生初始化完成后，可以继续发布已被停止请求撤销的运行状态；`enableReceiving()` 等旧读取清理时，第二次停止也无法阻止其随后开启接收。因此，退出／退后台等停止操作可能与较早的启动请求交错。

每次 `stop()` 现在都会使更早的启动请求失效，即使它复用同一个清理 future。启动在目录返回、原生初始化返回、初始快照恢复及准备发现前检查是否被撤销。旧请求以 `closed` 结束，不启动发现或继续发送命令；后续显式操作仍可正常开启新 runtime。

停止会等已经开始的原生初始化完成并正常 dispose；没有强杀 worker、强制清理期限或自动重新接收。若停止发生在目录选择阶段，目录返回后不会再调用 native start。本轮未修改 Rust 核心、ABI、协议、受管文件或已有读取清理规则。

## 本轮证据

| 检查 | 结果 |
|---|---|
| 修复前 | 5 个新增 controller 竞态用例全部失败 |
| 等待目录时停止 | 本地／接收两种入口均返回 `closed`，无 native start、无后续命令，接收状态保持关闭 |
| 等待 native start 时停止 | 两种入口均等待初始化完成、释放 native，返回 `closed`，不进入快照／发现查询 |
| 等读取清理时再次停止 | 受控读取仍等待完成并释放租约，较早的启用接收请求被撤销，不开启第二个 native runtime |
| 真实 DLL／worker | 两种入口在实际 loopback HTTPS 已监听、controller 尚未发布 ready 的时点暂停；停止等待初始化，恢复后端口可重绑，同根存储租约可重开、身份保持、runtime ID 更新；需后续显式操作 |
| Flutter | 完整 108 项通过，含上述 5 项、2 项新增真实 DLL 用例、既有 2 项真实 DLL 确认回归及 classifier／home queue fixture |
| 静态检查 | 相关 Dart 格式检查及完整 Flutter analyze 通过 |
| 打包 | Windows／Android 普通 `lib/main.dart` release 构建通过，包内库与已验证版本一致；保留 LocalSend 许可，生产 APK 不含 IntegrationTestPlugin，未安装 |

真实 DLL 测试使用 `test/transfer_startup_native_test.dart`，只在本机 loopback 监听；可控等待加在实际 native ready 返回之后，不模拟 DLL 成功或资源释放。单元测试的等待点分别位于目录、native start 与读取清理，均独立控制释放顺序。

## 复现

```powershell
# apps/flutter 下；真实 DLL 与 HEIC fixture 使用现有可选测试环境变量。
$env:XDREMUX_TRANSFER_TEST_DLL = 'ABSOLUTE_DLL_PATH'
$env:XDREMUX_TRANSFER_STARTUP_REPORT = 'OWNED_REPORT_PATH'
flutter test --no-pub test/transfer_controller_test.dart --plain-name 'startup boundary:'
flutter test --no-pub test/transfer_startup_native_test.dart
flutter test --no-pub
flutter analyze --no-pub
```

本轮没有操作手机或系统网络／防火墙，未将 loopback 结果视为新的 Android 真机生命周期通过。Android 启动中退后台的新版真机复验、解锁恢复、真实断网／切网、VPN／多网卡、AP 隔离和权限撤销继续待验；完整 P3.2 未完成。此前规模和性能测试未重跑，不从本轮状态修复推断新性能结论。

同日后续：用户手机恢复可用后，基于此处提交版本完成 Android 启动取消与手动解锁恢复补验，见 [真机记录](local-transfer-startup-android.md)。其中启动等待点在实际 Home、返回前台并确认 pause/resume 后才释放，不替代后台即时初始化清理或真实网络变化验证。上段为本次本机检查完成时的历史边界。
