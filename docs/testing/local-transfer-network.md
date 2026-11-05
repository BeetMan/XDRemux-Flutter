# 真实断网／切网脚本准备

日期：2026-10-24。基线：`1b4baac543d3ec9cc434b12c9c9ccdbdeb963c5d`。分支 `codex/local-transfer`。当前状态：**脚本已准备，本机演练通过，真机网络变化未执行**。机器记录见 [准备报告](local-transfer-network-report.json)。用户本轮不方便测试，未连接或操作手机，未更改网络／防火墙。

## 覆盖范围

`apps/flutter/tool/transfer_network_host.py` 提供 `prepare`、`run` 和 `answer` 三个入口。先覆盖 Windows 原生发送端 → Android 独立接收端；Android → Windows、官方 LocalSend 共存、多网卡／VPN／AP 隔离仍需后续单独验收。

主机使用真实 ABI 1.3，不模拟原生发送／重试。初次发送经过仅绑定 loopback 的不解密 TLS relay，用低速转发和显式暂停，固定“一件获 ACK、另一件已有真实部分落盘”的操作窗口；重试直接连接恢复后的接收地址。手机始终验证真实 TLS 证书，没有证书替换或 HTTP 降级。此窗口用于减少文件体积和人工操作时间，不是纯直连性能测试。

Windows sender 的 runtime 始终保留；断网期间不依赖 ADB 读取手机，也不重放未确认命令。重连后显式启动接收、检查同一证书身份、确认残件清理与已提交回执保留，再调用原生 `retry_send`。最终要求只补发未 ACK 文件、两件回执各一份，并用受管读取租约和主机独立读回核对 SHA-256。

Android 测试入口仍为 `tool/transfer_lifecycle_app.dart`，只安装 `.transferdev`。新增 `network_start` 仅允许当前实际分配的 IPv4；`accept_network` 只接受明确指定的 sender 指纹、会话、`pnet-one.bin`／`pnet-two.bin`、各 2 MiB 及匹配哈希。没有自动接受普通设备的路径。界面／runtime 退后台停止仍遵循生产 controller。

## 本轮检查

- 7 项离线检查通过：旧 checkpoint、错误动作、错误指纹、无效重连地址／缺失设备、扩大文件集合／改变长度或哈希、已有目录覆盖均被拒绝；合法确认及准备标记检查通过。
- 真实 DLL 回环演练通过：两件各 2 MiB，取得一件 ACK 和另一件部分字节后主动切断自有 relay，显式重开同一根目录、改变端口、仅补发未 ACK 文件，两件独立哈希一致、源文件不变。
- 演练报告为 `mode=self-test`、`realNetworkValidation=not_run`、`relayCutInjected=true`，不将模拟断开记为真机切网通过。
- Dart analyze、格式及 Python 语法检查通过；独立 arm64 release APK 和普通 main 生产 APK 构建、包名、许可及库哈希核对通过，均未安装。未修改生产 controller／核心／ABI，未重复此前 Flutter 108 项或规模测试计数。

## 准备一次新运行（不操作手机）

在 `apps/flutter` 下，使用 Python 3.11+，无额外 Python 依赖。目录必须是 `pnet-<16位小写hex>` 且尚不存在；脚本生成的总源数据为 4 MiB。

```powershell
$pnetRun = [guid]::NewGuid().ToString('N').Substring(0,16)
$pnetParent = (Resolve-Path ../../crates/xdremux-transfer-ffi/target).Path
$pnetDirectory = Join-Path $pnetParent "pnet-$pnetRun"
python tool/transfer_network_host.py prepare --directory $pnetDirectory
# 只演练本机逻辑。演练过的目录不能再用于真机，应另 prepare 一个新 run。
python tool/transfer_network_host.py run --directory $pnetDirectory --library ../../tools/local-transfer-poc/target/windows/release/xdremux_transfer.dll --mode self-test --require-new-endpoint
```

`prepare` 的 manifest 明确为 `deviceValidation=not_run`；最终结果以 `result.json` 为准。实际执行必须使用全新准备目录，不能重启主机进程后沿用原生 retry 计划，也不能把上一次未知结果当作失败自动重发。

## 将来测试时安装独立入口

先为另一个新 run 准备文件，再以同一 `$pnetRun` 编译／归档测试 APK。`P32_INTERFACE=127.0.0.1` 仅是未启用接收时的占位；`network_start` 会校验并选用实际手机 IP，切换网络后无需仅为 IP 变化重编译。

```powershell
$env:XDREMUX_TRANSFER_TEST_APP = 'true'
$env:XDREMUX_ANDROID_TRANSFER_SO = (Resolve-Path ../../tools/local-transfer-poc/target/android/aarch64-linux-android/release/libxdremux_transfer.so).Path
flutter build apk --release --no-pub --target-platform android-arm64 -t tool/transfer_lifecycle_app.dart "--dart-define=P32_RUN=$pnetRun" --dart-define=P32_INTERFACE=127.0.0.1 --dart-define=P32_PORT=53326
Copy-Item build/app/outputs/flutter-apk/app-release.apk (Join-Path $pnetDirectory 'android-network.apk')
# 以下两条仅在用户方便并明确开始真机测试时执行；本轮未执行。
android run --apks=TEST_APK --device=CONNECTED_DEVICE --activity=com.example.xdremux.MainActivity
python tool/transfer_network_host.py run --directory $pnetDirectory --library ABSOLUTE_DLL --mode manual --adb ABSOLUTE_ADB --device CONNECTED_DEVICE --host PHONE_IPV4
```

要测试“地址确实改变”，额外传 `--require-new-endpoint`；否则允许同 IP 的断开／重连，但报告的 `endpointChanged=false` 不能记作换地址通过。主机脚本需要持续运行，重试计划随该 native runtime 消失。

## 四个显式 checkpoint

主机每阶段写入本轮目录的 `checkpoint.json`，包含新的 `checkpoint_id`、动作和说明。另一终端运行 `answer` 原子写入响应；旧 ID、错误动作及错误指纹会被拒绝，不因超时自动视作同意。

| 动作 | 人工步骤与限制 |
|---|---|
| `confirm-initial` | 在独立应用核对完整证书指纹，再用完整指纹确认；确认之前不发送文件元数据 |
| `network-down` | 出现提示后 **20 秒内**手动断开手机 Wi-Fi，并确认该动作；暂勿重连。脚本检查旧端点连续两次 TCP 不可达，再恢复转发，等待原生自然失败，最长约 330 秒；不主动断开 relay 或自动取消来伪造网络错误 |
| `reconnect` | 收到此提示后才手动重连网络和 ADB，解锁并打开独立测试应用；提供当前手机 IPv4 和已经连好的 ADB device ID。无线调试端口变更时，操作人先自行连接，不自动扫描或猜测设备 |
| `confirm-retry` | 再次核对当前端点完整指纹；必须与原身份一致才允许补发 |

```powershell
# ID 和 FP 均取当前 checkpoint，并亲自核对设备显示；不要复用旧响应。
python tool/transfer_network_host.py answer --directory $pnetDirectory --checkpoint-id CURRENT_ID --action confirm-initial --fingerprint FULL_CONFIRMED_FP
python tool/transfer_network_host.py answer --directory $pnetDirectory --checkpoint-id CURRENT_ID --action network-down
python tool/transfer_network_host.py answer --directory $pnetDirectory --checkpoint-id CURRENT_ID --action reconnect --host CURRENT_PHONE_IPV4 --device CONNECTED_DEVICE
python tool/transfer_network_host.py answer --directory $pnetDirectory --checkpoint-id CURRENT_ID --action confirm-retry --fingerprint FULL_CONFIRMED_FP
```

若未赶上部分上传窗口、端点仍可达、传输没有失败、证书变化、命令结果未知、回执重复／缺失或哈希错误，脚本会保留失败／未完成记录，不自动重新提交原 mutation。失败后先检查接收记录；不要以新一轮发送代替未知结果核对。

## 收尾与限制

脚本仅停止自己创建的 native handle、relay 和显式测试接收服务，不安装、启动或强停原 XDRemux，不操作系统网络。无法确认清理时，全局结果标记失败。原生测试身份、合成文件和本地 checkpoint 保存在本轮目录供检查，不提交仓库。真机结束后按既有流程恢复普通 main 独立测试 APK 并停止 `.transferdev`；最后移除 `XDREMUX_TRANSFER_TEST_APP`，恢复普通生产构建。

manual 模式的证据是人工动作声明、旧端点不可达及原生失败／重试记录，不能单凭这些隔离 Wi-Fi、路由、防火墙或 Android 退后台停止策略各自的原因。测试通过也只覆盖该方向和该次流程；普通 Flutter 发送页面、反向发送、官方客户端共存及完整网络矩阵继续独立验收。
