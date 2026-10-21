# P3.2：真实系统与网络边界验证

日期：2026-10-21；Android 结果更新于 2026-10-22。隔离分支 `codex/local-transfer`。Android 入口准备接续 `03c04a21`；桌面退出切片接续 `b6859457`。下述 Windows 退出和 Android Home／强停／锁屏覆盖项已通过。完整 P3.2 尚未完成，鸿蒙继续延后。机器结果见 [local-transfer-p32-report.json](local-transfer-p32-report.json)。

## Windows 退出切片

真实 release 窗口复现了关闭锁死：第一次 Dart 清理返回错误后，原生 `transfer_close_requested_` 一直为 true，第二次关闭既不退出也不重新请求清理。修复为接收 `requestClose` 的成功／错误／未实现回复，未获关闭批准时释放该标记；清理仍在进行时继续合并重复请求，不提前关闭。

生产 main 的窗口／托盘清理现在共用 `TransferDesktopLifecycle`。它只合并正在等待的 stop；如果清理或批准关闭失败，下次显式关闭会重新清理，防止窗口留存期间新启动的接收服务被跳过。仍需完整等待读取租约和 native dispose，没有新增强制超时或退出回退。

`tool/transfer_desktop_close_app.dart` 使用相同生产页面、controller、桌面退出 owner、worker、打包 DLL 和真实 Win32 runner，所有目录与 loopback socket 属于单次测试。没有操作手机或修改系统网络。使用 computer-use 的实际标题栏关闭／Alt+F4，未通过直接调用 approveClose 代替窗口消息。

| 验证 | 结果 |
|---|---|
| 修复前错误回复 | 第一次注入自有清理失败后，第二次标题栏关闭仍为 stopCalls=1；保留失败记录，再终止该自有测试进程 |
| 修复后显式重试 | 第一次安全保留窗口；第二次 Alt+F4 使 stopCalls=2，完成清理并退出；主机独占重绑定接收端口成功 |
| 真实部分上传与读取租约 | 基线文件 65,536 bytes 已 ACK；第二件声明 2,097,152 bytes。opaque TLS relay 保留部分请求，关闭等待期间主机独立观察到 `.incoming` 有 180,217 bytes，且租约仍持有 |
| 重复关闭 | 在读取尚未释放时再次 Alt+F4，窗口仍在，stopCalls=1，部分字节仍存在，没有第二份清理 |
| 读取释放后退出 | 仅通过测试文件释放自有读取：复制完成，租约释放，停服及 worker 结束后窗口退出；主机核对暂存为空、端口可独占重用 |
| 同根重启 | native 打开之前暂存即为空；只存在一个已完成基线回执，证书身份保持、runtime ID 更新、接收保持关闭。应用租约读取及主机独立磁盘 SHA-256 均正确 |

基线、读取副本及接收落盘件 SHA-256 均为 `4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2`。首轮读取等待试验中，部分上传在窗口操作前已超时；该次只证明读取等待，不计作“关闭清理活跃残件”。随后使用新目录连续操作，单独确认两次关闭等待期间残件均存在，以上表格采用后一次证据。

读取阻塞由测试主动持有真实 lease，并在释放后复制自有基线文件；不是模拟磁盘损坏。TLS relay 不解密，仅用于固定部分上传状态；这不是实际断网／切网。窗口关闭真实经过 OS 消息与生产退出 owner，但入口为隔离 fixture，不代表普通 main 全部交互、系统关机／注销、进程强杀或托盘菜单 UI 已验收；托盘并发／失败分支由单元测试覆盖。

Flutter **84** 项通过，包含真实 classifier／首页 checkpoint ACK 与新增四项桌面退出测试；完整 analyze 无问题。Windows／Android 普通 `lib/main.dart` release 重新构建通过，许可及库哈希核对通过；生产 APK 不含 integration-test 插件，未安装到手机。Rust core／ABI 及传输动态库未改动，沿用 P3.1 已验证库。

复现时创建空的绝对 `p32-desktop-<16位hex>` 目录，设置 `scenario.json` 为 `{"case":"retry-after"}`，以 `--dart-define=P32_DESKTOP_ROOT=ABSOLUTE_DIRECTORY` 构建该 tool release 入口。第一次关闭故意失败，第二次应退出。使用新子目录的 `drain` 场景时，等待 status 的 ready-to-close，连续关闭两次；确认 close-requested／leaseHeld／stopCalls=1 后再创建根下的 `release-read` 文件。退出后将场景改为 `recover` 并重启同一二进制，它会校验并自行退出。工具启动应使用精确进程路径，避免同名已安装应用被匹配。

## Android 生命周期切片

新增独立 release 入口 `apps/flutter/tool/transfer_lifecycle_app.dart`，使用生产 TransferPage、controller、Dart worker 和既有 ARM64 动态库。它使用全新的 `p32-<run>` 私有目录，启动时不开放 LAN；测试控制文件必须显式请求开启接收。接收决策只接受控制文件指定的会话、真实客户端证书指纹及单件 `p32-*.bin` 合成文件，不自动接受普通设备的请求。

主机脚本 `apps/flutter/tool/transfer_lifecycle_host.py` 使用 Python cryptography 生成一次性 mTLS 客户端证书，每次 HTTPS 连接都核对测试接收端证书。控制文件和状态通过 ADB 传递，文件内容通过真实 LAN HTTPS 发送，没有 ADB 转发、TLS relay 或 Wi-Fi 设置修改。这是接收端生命周期验证，不代表生产发送端的重试流程验收。

计划连续执行：

1. 完整发送 64 KiB 基线文件，核对 ACK、应用租约内流式哈希和 ADB 拉回后的主机独立哈希。
2. 另一件声明 2 MiB 的文件只发送 256 KiB，确认 `.incoming` 中有真实部分字节、尚未发布。
3. 分别执行实际 Home、`am force-stop` 独立测试包和屏幕休眠／锁屏，观察 TCP 监听关闭及系统 `Multicast Locks held` 中本应用锁释放。
4. Home 返回、进程重启时确认不会自动重新接收；显式开启后校验证书身份保持、runtime 更新、暂存清理、基线文件字节不变。强制终止用例还会在 native 启动清理之前记录真实残件。
5. 锁屏安排在最后，读取系统屏幕与 keyguard 状态；不自动解锁。锁屏后的前台恢复单独列为待验；若后台状态快照不可用，仅报告独立 TCP／系统锁观察，不推断 controller 或暂存状态。

`am force-stop` 不代表低内存回收、滑走最近任务或全部 OEM 杀后台方式。该入口直接调用生产 controller 的显式操作，不替代普通 main 页面的完整人工体验；原入口 Home 行为已有 P2.3 记录。

## Android 当前结果（2026-10-22 更新）

- 独立测试 APK release 构建通过，包名 `.transferdev`、target SDK 36，未覆盖原 XDRemux。
- 新 Dart 入口 analyze 无问题；Python 脚本语法解析通过。
- 普通 `lib/main.dart` 生产 APK 已重新构建并核对生产包名；未安装到手机。
- 此前因用户无法配合而延后的完整文件／部分上传／Home／终止／锁屏序列，现已在 PKJ110、Android 17／SDK 37 真机完成。每个用例先实传 256 KiB／声明 2 MiB，确认尚未发布；实际系统操作后 TCP 关闭、多播锁释放。Home 和强停后同根重启、显式接收、基线哈希及身份保留通过；锁屏时记录到实际 keyguard／休眠、controller 停止、暂存已清理且仅有基线发布。详见 [Android 真机记录](local-transfer-p32-android.md) 和 [JSON](local-transfer-p32-android-report.json)。
- 首次执行因测试导出副本保留 0600 权限而无法 ADB 拉回，未计通过。修复仅涉及测试入口的合成导出副本写法，不改变生产收件箱权限；随后三项完整序列通过。
- 测试结束恢复普通 main 独立测试 APK 并停止 `.transferdev`；原 XDRemux 未覆盖。锁屏后的解锁恢复仍未执行，不能从 Home／强停恢复推断。

运行前使用 `android layout` 检查解锁和前台状态，再以 Android CLI 启动已归档测试 APK。脚本需要明确的 ADB 路径、设备 ID、16 位十六进制 run、已存在的 `p32-app-<run>` 主机目录、手机私网 IPv4 和端口：

```powershell
# apps/flutter，使用 Pub 镜像并保留 lockfile。
flutter pub get --enforce-lockfile
# 设置 XDREMUX_TRANSFER_TEST_APP=true 和 XDREMUX_ANDROID_TRANSFER_SO。
flutter build apk --release --no-pub --target-platform android-arm64 -t tool/transfer_lifecycle_app.dart --dart-define=P32_RUN=RUN --dart-define=P32_INTERFACE=PHONE_IPV4 --dart-define=P32_PORT=53326
# 先归档此 APK；普通构建恢复 lib/main.dart 和生产环境变量。
android run --apks=TEST_APK --device=DEVICE --activity=com.example.xdremux.MainActivity
python tool/transfer_lifecycle_host.py --adb ADB --device DEVICE --run RUN --directory OWNED_RUN_DIRECTORY --host PHONE_IPV4 --port 53326
```

运行报告保存在自有主机目录的 `host-result.json`。私钥仅用于测试，脚本退出时删除；不提交 APK、个人文件或测试身份。结束后安装归档的普通 main 测试 APK，再停止 `.transferdev`；不安装生产包。

## 后续边界

真实断网／切网、VPN／多网卡、AP 隔离、权限拒绝／撤销、Windows 普通 main／托盘菜单完整体验及系统关机／注销、Android 解锁恢复／其他 OEM 回收方式与大批次、旧版／同机官方客户端仍待验。桌面窗口退出、Android 本轮覆盖项及 P3.1 受控故障不能替代其余真实系统场景。
