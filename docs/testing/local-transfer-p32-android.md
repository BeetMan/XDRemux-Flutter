# P3.2 Android 生命周期真机验证

日期：2026-10-22（UTC+8）。基线：`5e1dec99ef50a624f92ead79d3d76ce057802066`。隔离分支 `codex/local-transfer`。设备 PKJ110，Android 17／SDK 37，应用 target SDK 36。机器结果见 [JSON 报告](local-transfer-p32-android-report.json)，操作及复现入口见 [P3.2 记录](local-transfer-p32.md)。

用户恢复手机可用并解锁后，通过 Android CLI 安装独立 `.transferdev` release 入口，使用生产 TransferPage、controller、Dart worker、Android runner 及上一轮终态修复后的 ARM64 库。文件内容通过真实局域网 mTLS HTTPS 发送，ADB 仅传递测试控制、读取状态及拉回合成导出件；无端口转发、TLS relay 或系统网络设置变更。

## 真机结果

64 KiB 基线文件成功接收，应用在受管读取租约内计算哈希并流式导出；ADB 拉回后主机独立计算 SHA-256：`7daca2095d0438260fa849183dfc67faa459fdf4936e1bc91eec6b281b27e4c2`。Home／强停恢复后的再次读取均一致。

三项用例均先声明 2 MiB 文件，只上传 256 KiB；应用观察到暂存中有 262,144 bytes，收件箱仍仅有基线。随后执行真实系统操作：

| 用例 | 观察与恢复 |
|---|---|
| 按 Home | 接收 TCP 关闭，系统多播锁释放；返回后接收保持关闭。显式重新开启后，runtime 更新、证书身份保持、暂存为空、基线哈希一致 |
| `am force-stop` 独立包 | 进程消失，TCP 关闭，多播锁释放；重启入口在 native 启动前观察到真实残件。显式开启后残件被清理，runtime 更新、身份与基线保留，未自动接收 |
| 锁屏 | 系统确认为休眠、keyguard 显示且输入受限；TCP 关闭，多播锁释放。测试进程仍运行时已观察到 pause、controller 停止、暂存清空，且仅基线发布。之后停止独立测试包；未自动解锁，未验证解锁恢复 |

首次尝试在基线独立校验阶段失败：`File.copy` 保留了受管源文件的 0600 权限，ADB 无法读取测试导出副本，该次未计通过。测试入口现对明确白名单的合成文件创建独立导出件，用流式写入和显式关闭替代复制；未更改生产收件箱权限。修复后以上三项完整执行通过。

## 打包与收尾

- Flutter analyze 无问题；主机 Python 脚本语法检查通过。此轮只修改测试入口，未修改传输核心／ABI／生产 controller；未重复上一轮 29／2／101 项测试计数。
- 本轮生命周期 APK、恢复用普通 main 独立 APK、普通生产 APK 均为 arm64 release、target SDK 36，包内传输库均与上一轮最新构建经 NDK 去符号后的 SHA-256 一致：`89fd03b8a09b4ce03db799455693417b5a69d4911e92ef49439098cef37bb62a`。均含 LocalSend 许可，无 IntegrationTestPlugin。
- 结束后重新安装普通 main 的 `.transferdev` APK，不启动并确认进程停止；生产 APK 仅构建，未安装。原 XDRemux 的版本及最后更新时间与操作前一致，未被覆盖。
- 测试临时 mTLS 私钥／证书已删除；APK、个人路径及身份不提交仓库。合成测试文件保留在独立测试包的本轮目录中。

## 尚未覆盖

锁屏后的解锁恢复、低内存回收／最近任务滑走等其他终止方式、真实断网切网、VPN／多网卡、AP 隔离、权限撤销和 Android 大批次仍待验。独立入口使用显式测试控制，不代表普通 main 全部 UI 流程完成。旧版／同机官方客户端、Apple 和后续鸿蒙验证保持原计划；完整 P3.2 仍未完成。
