# Android 启动取消与解锁恢复补验

日期：2026-10-24（UTC+8）。基线：`4379cf81f454ecd632474383911f585240e5211a`，分支 `codex/local-transfer`。设备 PKJ110，Android 17／SDK 37，应用 target SDK 36。机器结果见 [JSON](local-transfer-startup-android-report.json)。

本轮只扩展独立 release 测试入口及主机脚本，未修改生产 controller、传输核心或 ABI。使用生产页面、controller、worker、Android runner 和已验证 ARM64 库；ADB 传递显式控制／状态和合成导出件，文件内容经真实局域网 mTLS HTTPS 传输，无端口转发或网络设置修改。

## 五项完整序列

| 用例 | 观察与结果 |
|---|---|
| 目录等待时按 Home | 显式等待点尚未调用 native start。实际 Home／返回前台后记录到 pause/resume，停止已发出；再释放等待点，启动以 `closed` 结束，native start 计数未增加，无接收端口／多播锁。后续显式开启及基线哈希通过 |
| native ready 等待时按 Home | 先独立确认真实 HTTPS 端口已监听，controller 尚未发布 ready、未启动发现。Home／返回前台后停止仍等待初始化；释放等待点后以 `closed` 结束，端口关闭。显式重启后 runtime 更新、身份保持、基线哈希通过 |
| 部分上传中按 Home | 已写入 262,144／声明 2,097,152 bytes，未发布；TCP 关闭、多播锁释放。返回后不自动接收，显式重启后暂存清空、基线不变 |
| 部分上传中强停 | 同样存在 256 KiB 真实残件；终止独立测试包后 TCP／多播锁释放。新进程在 native 启动前观察残件，显式开启时清理，身份与基线保留 |
| 部分上传中锁屏，再手动解锁 | 系统休眠、keyguard 显示且输入受限；TCP 关闭、多播锁释放，controller pause／停止、暂存清空、仅基线发布。用户手动解锁，恢复同一进程且不自动接收；显式开启后 runtime 更新、身份及独立哈希不变 |

基线 65,536 bytes，应用租约内流式读取及 ADB 拉回后的主机独立 SHA-256 均为 `7daca2095d0438260fa849183dfc67faa459fdf4936e1bc91eec6b281b27e4c2`。五项成功序列在一次脚本执行中连续完成；此前失败尝试和单独诊断不计入这次通过。

## 启动等待点的边界

等待点是测试主动加入的异步等待，分别位于目录返回前、真实 native ready 返回后；生产 controller 没有替换或手动模拟生命周期事件。主机先执行真实 Home，再返回前台，要求真实 pause/resume 和停止状态均在释放等待点前出现。因此证明的是停止撤销待完成启动，以及释放后的正常清理和显式恢复。

早期三次尝试要求后台快照及时更新／在后台释放后立即记录完成，均遇到观察截止，未计通过。实际状态采集曾停留在 `inactive`，也曾停留在等待中的 `paused`；后台快照停止更新的具体原因未定位。最终流程在前台释放等待点，不能据此声称后台即时完成初始化清理、自然慢启动耗时有界或不存在 OEM 冻结影响。native 等待点被持有期间，已创建的监听端口可以保留；报告中启动用例的“未自动重开”是在等待点释放、取消完成后检查的。

## 工具和收尾

- 新入口增加两种显式启动等待点、生命周期序号、native start 计数及可供主机检查的状态；仅接受本轮控制文件，仍不自动接受普通设备的文件。
- 主机新增 `--cases startup-directory startup-native home kill lock --unlock-recovery`。锁屏证据先保存，再等待人手解锁，不发送自动唤醒／解锁指令；失败时保留未执行标记。即使设备停止命令失败，也进入测试身份及报告清理。
- Flutter analyze 和 Dart 格式检查通过，Python 语法解析通过。此轮未修改生产实现，未重复上一切片的 Flutter 108 项计数。
- 生命周期、恢复用普通 main 独立 APK 和生产 APK 均为 arm64 release、target SDK 36，包内库与既有已验证版本一致、含许可、无 IntegrationTestPlugin。生产 APK 仅构建，未安装。
- 结束后安装普通 main `.transferdev` APK 并停止测试进程；原 XDRemux 的版本和更新时间不变。测试私钥／证书已删除，APK 与本地身份不提交。

真实断网／切网、VPN／多网卡、AP 隔离、权限撤销、其他 OEM 回收方式、Android 大批次、旧版／同机官方客户端、Apple 和后续鸿蒙验证仍保持待验；完整 P3.2 未完成。
