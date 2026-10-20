# P3.2：真实系统与网络边界验证

日期：2026-10-21。隔离分支 `codex/local-transfer`，接续 `03c04a21`。本轮先准备 Android 生命周期切片；完整 P3.2 尚未完成，鸿蒙继续延后。

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

## 当前结果

- 独立测试 APK release 构建通过，包名 `.transferdev`、target SDK 36，未覆盖原 XDRemux。
- 新 Dart 入口 analyze 无问题；Python 脚本语法解析通过。
- 普通 `lib/main.dart` 生产 APK 已重新构建并核对生产包名；未安装到手机。
- 真机当前锁屏，已请求解锁。上述完整文件／部分上传／Home／终止／锁屏序列 **尚未执行**，不能标为通过。
- 等待期间已恢复普通 main 测试 APK 并确认测试包进程停止；解锁后可直接重新安装已归档入口运行。

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

真实断网／切网、VPN／多网卡、AP 隔离、权限拒绝／撤销、Windows 窗口退出、锁屏恢复、Android 大批次以及旧版／同机官方客户端仍待验。当前通过的是 P3.1 的受控故障与恢复，不能用其替代这些真实系统场景。
