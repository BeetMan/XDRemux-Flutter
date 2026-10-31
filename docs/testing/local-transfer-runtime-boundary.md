# 互传服务重启后的异步回调归属

日期：2026-10-24（UTC+8）。基线：`27c1cdeff43325feafd08384110755c2bc468563`；隔离分支 `codex/local-transfer`。机器结果见 [JSON 报告](local-transfer-runtime-boundary-report.json)。

## 问题与行为

接收停止后重新开启时，旧 runtime 的 `discovery_start` 失败回调仍会清空新设备列表并释放多播锁；旧事件轮询或 `discovery_status` 的 `closed`／`worker_stopped` 错误还能停止新 runtime，普通网络错误则覆盖其错误状态。旧轮询未完成也会占住新 runtime 的轮询入口。

现在发现、轮询和查询结果同时检查 service 实例与停止代次，过期成功／失败均不能修改新 runtime。停止时撤销旧轮询占位，新轮询使用独立 token；旧回调的 finally 不能清掉新占位。每次启动重新计算发现轮询时点。

快照与收件箱查询也按 runtime 隔离：停止会撤销共享查询槽，新启动加载自己的状态；旧完成只能释放自己仍拥有的槽。已排队的旧收件箱读取不会在等待结束后查询新 service，多次分页请求逐个等待当前读取。实际文件读取／导出仍等待租约清理，不提前销毁使用中的 native。

Android 多播锁的 acquire／release 按序执行，停止清理会等较早的待完成 acquire 后再 release。发现等待锁返回后重新检查归属，不再向已停止的 native 发起发现。旧发现失败不释放新接收服务的锁，单次平台异常不阻断后续释放／重新获取。测试注入锁操作仅控制异步顺序；实际 Android 路径继续调用现有 MethodChannel。

## 本地验证

| 检查 | 结果 |
|---|---|
| 修复前 | 首批 10 项中 8 项失败；旧成功发现与旧停止事件两项原本已被保护 |
| 新增回归 | 17 项通过：发现成功／失败、事件／发现状态的三种延迟错误、旧停止事件、轮询交接、快照成功／失败及槽归属、排队收件箱成功／失败、等待 acquire 时停止的成功／失败、release 异常后恢复 |
| 完整 Flutter | 125 项通过，启用既有 2 项真实 DLL 确认检查、2 项真实 DLL 启动／端口恢复检查，以及 classifier／home queue fixture |
| 静态检查 | Dart 格式及完整 Flutter analyze 通过 |
| 普通发布构建 | Windows／Android `lib/main.dart` release 构建及包内库／许可核对通过；APK 未安装 |

新增用例位于 `apps/flutter/test/transfer_runtime_boundary_test.dart`，使用可控异步回复与锁操作，独立安排旧回复晚于停止／显式重启，并验证新服务继续接收、保留新设备、错误不被污染、锁仍归新服务及查询不跨 runtime。没有用固定睡眠猜测旧回复先后；重启检查有 5 秒失败上限。

```powershell
# apps/flutter 下
flutter test --no-pub test/transfer_runtime_boundary_test.dart --reporter expanded
# 完整回归使用现有可选真实 DLL 与 HEIC fixture 环境变量
flutter test --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib/services/transfer/transfer_controller.dart test/transfer_runtime_boundary_test.dart
```

本轮只修复 Dart controller 的服务交接，未修改 Rust 核心、ABI、协议、锁文件或 Android 原生桥接。真实 DLL 检查使用本机 loopback；新增延迟回复与多播锁顺序检查是受控测试，不是新的真机或真实网络结果。没有操作手机、网络或防火墙。

新版 Android 生命周期与多播锁真机复验、真实断网／切网、VPN／多网卡、AP 隔离、权限撤销、反向及官方客户端共存仍待执行。此前 Android 生命周期记录保持其原有版本与边界；不把本次修复当作早先后台快照等待问题的已确认原因。网络脚本见 [准备记录](local-transfer-network.md)，完整 P3.2 未完成；鸿蒙验证继续延后。
