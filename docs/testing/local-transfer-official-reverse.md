# P3 官方 Windows 旧版双向互传补验

日期：2026-10-25（UTC+8）。基线：`fb2e5130b63045bac3689604efb4921dfc60d993`，分支 `codex/local-transfer`。用户完成此前的 Windows 授权弹窗后，继续自动操作官方窗口，完成此前阻塞的反向发送。机器结果见 [JSON 报告](local-transfer-official-reverse-report.json)；此前未通过的尝试保留在 [上一轮记录](local-transfer-p3-auto.md)。

## 已执行

使用既有安装的 **Windows LocalSend 1.17.0+58，协议 2.1**，与真实 DLL／Dart worker 在同机互传。双方均使用本轮独立测试身份与目录，官方程序仅在子进程中使用独立 `APPDATA`／`LOCALAPPDATA`。

| 方向／检查 | 实际结果 |
|---|---|
| native → 官方 | 4 个合成文件，官方接收目录逐文件长度与独立 SHA-256 一致 |
| 官方 → native | 官方发送页选择本轮固定收藏接收端，4 件全部 `Done`，`Finished` 为 100%；native 的 4 份回执对应实际落盘文件，长度与独立 SHA-256 一致 |
| 收件约束 | 只接受本轮已核验证书的官方发送者及固定的 4 个唯一文件名／长度；附带哈希时还须与 fixture 匹配 |
| 拒绝与共存回归 | 错误指纹、错误 PIN 均拒绝且未产生收件文件；默认端口冲突、替代监听端口及同机多播发现通过 |
| 默认脚本模式 | 另用新目录、不传 `--bidirectional` 再运行，官方接收方向 4 文件独立核验通过，反向仍明确记录 `not_run` |

双向主运行共 **8 次文件交付**，每方向 **1,114,144 bytes**；默认模式回归另核验 4 次。载荷包含空文件、中文／emoji 文件名和不透明的 `.heic`／`.mov` 合成字节。没有使用用户照片；不涉及媒体解码、图库或 Live Photo 验证。

旧版发送者未携带文件源哈希，实际回执为 `peer_hash_present=false`。本轮使用 Python `hashlib` 对源 fixture、官方收件文件及 native 回执的真实 `data` 文件重新计算 SHA-256，与发送前固定的期望值核对；这项独立验收不依赖对方提供哈希。

## 可复用入口与发送端确认

```powershell
# apps/flutter 下；官方程序须未运行，ROOT 必须是全新绝对目录
dart run tool/transfer_official_coexist.dart ABSOLUTE_DLL NEW_ROOT 'C:/Program Files/LocalSend/localsend_app.exe' LOCAL_IPV4 --bidirectional
```

原四参数调用仍为接收方向自动验收。新选项预选本轮 4 个 fixture，关闭自动结束页面，在 `status.json` 写入 `reverse_ready` 后等待外部观察者操作官方发送页。选择 `XDRemux P3 automated fixture` 的固定收藏端点；具体地址及身份见本轮 `ready.json`。窗口初始隐藏，须通过本轮官方实例的 show API 显示，不能重新启动一个使用用户配置的普通实例。

native 独立核验反向收件数据后才写入 `reverse_committed`。外部观察者必须实际查看官方 **Sending files** 页面，确认四行均 `Done`、`Finished` 为 **100%**，随后才能在本轮根目录写入 `ui-finished.json`：

```json
{
  "status": "finished",
  "officialFingerprint": "本轮 status.json 的 officialFingerprint",
  "nativeInstanceId": "本轮 status.json 的 nativeInstanceId",
  "fileCount": 4
}
```

本轮由 computer-use 观察实际窗口及辅助功能树后写入，原始树保留在忽略的 `ui-observation.txt`。脚本检查身份和 runtime ID 与本轮一致，并设有等待期限；仅有接收端 committed 不足以通过发送端页面验收。测试设置含私钥／PIN，只保留在忽略的本地结果目录，不提交。

## 异常、清理与范围

官方 1.17 的日志出现一次 `Unsupported operation: Infinity or NaN toInt`，栈位于其 `progress_page.dart:170`。随后实际页面四行全部 `Done`、`Finished` 100%，发送日志记录成功，落盘数据均一致。异常原因尚未定位，完整日志保留在本地结果目录；该旧版的进度显示仍有此已观察到的问题。

双向和默认模式均完成后，独立核对用户原 LocalSend 配置与任务开始前的 SHA-256 一致；自有官方进程已退出，三个相关 TCP 端口及 UDP 53317 均通过独占重绑定。测试没有自动操作权限弹窗、修改系统网络设置或操作手机。

格式检查及完整 `flutter analyze --no-pub` 通过。仅扩展开发验收工具及记录，生产 controller、native 核心、ABI、页面和锁文件未改动；DLL 与当前 Windows release 包内版本一致。本轮未重跑此前 140 项应用回归或重建 release 包。

本记录覆盖 **Windows 同机 native／worker 与官方旧版真实窗口**。普通 XDRemux 页面、跨设备 LAN、真实断网／切网、VPN 路由变化、AP 隔离、权限撤销和剩余 Android 平台矩阵仍按各自记录验收。Apple 未验，鸿蒙按用户安排延后，完整 P3.2 保持待验。
