# 设备确认状态与异步发送边界

日期：2026-10-21。隔离分支 `codex/local-transfer`，接续 `c1c1d282`。继续不依赖手机的开发；Android 真机与鸿蒙运行仍按前述安排延后。机器结果见 [local-transfer-confirmation-report.json](local-transfer-confirmation-report.json)。

## 问题与修复

重新连接没有先清空 `_peer`，取消核对或连接失败后仍显示上次的“已确认”，发送按钮也可用。连接异步进行时 IP／端口还可编辑，可能使显示地址与正在核对的设备不一致。忘记指纹虽已清空 controller 的确认集合，页面仅依赖 `_peer != null`，因此确认标签和发送／重试状态不会同步撤销。

现在重新连接先撤销页面选择；失败、取消均需重新选择并核对。连接／操作期间锁定地址、端口和 PIN。页面的确认标签、发送和重试按钮均查询当前确认集合。记住过的指纹仍只是提示，不能替代本次核对。

`send` 原本在 `await ensureLocal()` 前检查确认，却在启动结束后直接使用调用方传入的可变 Map／List。等待期间撤销确认未被再次检查，调用方修改设备或源路径也会改变即将提交的请求。现在在任何 await 之前复制设备和路径清单，并在提交 native 命令前重新检查确认。字段不完整的指纹统一返回 `identity_mismatch`；retry 也复用该检查和设备快照。

这层约束作用于尚未提交的发送。已经交给 worker 的任务仍需显式取消；没有声称撤销可以收回已发送字节。路径清单的快照不等于文件内容快照，内容固定、源变化检查、TLS 指纹钉扎及 ACK 后失败重试仍由原有 native 实现负责。

## 验证

修复前，七项针对性用例均失败；修复后全部通过：

- 启动等待期间撤销确认，禁止发送命令。
- 启动等待期间修改调用方设备 Map／源路径 List，请求仍保持最初选择。
- 缺失／错误类型的指纹返回稳定错误。
- 再次连接后取消、网络错误，两种情况都不保留旧确认。
- 连接尚未完成时 IP／端口不可编辑。
- 忘记指纹后标签消失，发送与失败重试按钮均禁用。

另有两项真实 Windows DLL／持久 Dart worker 测试，使用独立临时目录、loopback HTTPS 和合成文件：

1. 控制 startup 的支持目录返回时机，在其间撤销确认。真实 runtime 启动后不提交 send/send_batch；接收端 snapshot 与收件箱均为空。
2. 创建两个不同证书的真实接收端。调用发送后、启动完成前，把调用方 Map 改为另一设备，把路径列表改为另一合成文件。只有最初选定的接收端收到原文件 offer；明确接受后，65,536 bytes 落盘并获得成功终态，独立租约回读 SHA-256 与未改动源文件一致；另一接收端无 offer、无回执。

完整 Flutter **93** 项通过，包含两项真实 DLL 测试、原有真实 classifier／首页 checkpoint ACK 和七项新回归；analyze 无问题。Windows／Android 普通 main release 构建、原生库哈希与许可核对通过；生产 APK 不含 integration-test 插件且未安装到手机。传输 core、ABI 1.3、动态库和锁文件未改动。这些结果不替代 Android 真机、真实断网／切网或官方客户端复验；P3.2 完整矩阵继续待验。

## 复现

在 `apps/flutter` 运行：

```powershell
flutter test --no-pub test/transfer_controller_test.dart --name 'confirmation boundary:'
# 为真实 native 测试指定已有的绝对 DLL 路径；缺少时这两项明确跳过。
$env:XDREMUX_TRANSFER_TEST_DLL = 'ABSOLUTE_DLL_PATH'
flutter test --no-pub test/transfer_confirmation_native_test.dart
```

完整测试还需按已有约定设置 `XDREMUX_TRANSFER_QUEUE_FIXTURE` 指向只读 HEIC fixture。`XDREMUX_TRANSFER_CONFIRMATION_REPORT` 可指定已存在父目录中的报告路径。真实测试仅清理自身创建且已核对位于系统 temp 下的 `xdremux-confirmation-*` 目录，不读取或发送用户照片。
