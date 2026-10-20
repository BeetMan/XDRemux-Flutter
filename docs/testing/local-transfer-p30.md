# P3.0：最终传输组件与官方 Android LocalSend

日期：2026-10-21。隔离分支 `codex/local-transfer`，基线 `5e2fa11d`。本轮补充真实客户端验收，没有修改生产协议、图像引擎或主线工作区。机器记录见 [local-transfer-p30-report.json](local-transfer-p30-report.json)。P3 完整平台／网络矩阵仍未完成，鸿蒙继续延后。

## 环境与方法

- Windows x64，Flutter 3.44.5 / Dart 3.12.2，使用 P2.3 最终 DLL，SHA-256 `947f3e3b1302e2ef216fd044b29e4de4995fbbe82121150dc65f532e574cc047`。
- 官方 Android `org.localsend.localsend_app`，实际安装版本 **1.18.2+64**，PKJ110 / Android 17 API 37 / ARM64。APK targetSdk=37、minSdk=24，设备的 ACCESS_LOCAL_NETWORK 已授权；本轮未安装、升级或更改官方客户端权限／设置。
- 新增独立 `integration_test/local_transfer_official_test.dart` release 入口，使用生产 TransferPage、controller、worker 和实际 DLL。生产入口仍为 `lib/main.dart`。Windows 测试调用生产控件回调；Android 通过 android-cli 读取布局、ADB 输入实际点击官方客户端和 OEM 文件选择器。不能代替完整桌面人工体验验收。
- 直接 LAN HTTPS，IPv4 多播端口 53317，Windows 接收端口 53319；没有代理、ADB 转发、防火墙修改或 HTTP 降级。

Windows 通过实际发现列表查找官方客户端，HTTPS 再探测并显示完整指纹后显式确认。预期指纹由另一个主机 TLS 探测读取该端点证书，用于核对发现值和弹窗值。该辅助探测允许自签名证书，属于受控 LAN 首次连接测试，**不是独立于网络的身份认证**，也不宣称双方人工完成了指纹核对。

Windows 发送五件文件，在官方客户端点“接受”。官方界面显示各件完成，保存到 Download。随后从官方“文件”按钮进入系统文件选择器，切换到“文件 → 下载”，只选择本轮五个独有名称；在“附近的设备”列表点 XDRemux 回传。Windows 先核对本轮五件文件清单，再通过生产“接收全部”回调接受；没有按任意来件自动接收。

OEM 选择器的“最近／搜索”视图并未列出本次下载件，切到下载目录后可见。搜索时系统中文输入法还改写了字母输入，因此最终通过目录中的确切名称选择。没有通过 shell 直接代替官方程序发文件，也没有授予全盘访问权限。这个选择器界面显示最多 100 项，不能据此宣称 Android 选择器支持 1000 项。

## 文件与结果

素材为 P0 五件合成 fixture 的新命名副本，统一前缀 `p3-official-428a032d-`。每方向 **18,579,897 bytes**。

| 文件后缀 | 长度 | 双向结果 |
|---|---:|---|
| clip.mov | 2,194 | 通过 |
| empty.bin | 0 | 通过 |
| payload.bin | 16,777,216 | 通过 |
| photo.heic | 1,800,239 | 通过 |
| photo.jpg | 248 | 通过 |

Windows → Android：协议 ACK 后，用独立 Android `sha256sum` 和 `wc -c` 校验官方 Download 中的五件文件，全部匹配。Android → Windows：接收回执、持有租约后的独立流式 SHA-256 及长度全部匹配；五件均有 `peer_hash_present=true`。最后再次校验 Windows 发送源，保持不变。逐件 SHA-256 见机器记录。HEIC 含合成私有尾部，MOV 不是已配对 Live Photo，未涉及图库或解码能力。

Windows 停服后，在测试进程尚存活时，用独占 socket 重新绑定 TCP 53319 和 UDP 53317，均成功，确认 TLS 和发现监听已释放。测试进程随后关闭。测试结束保留自己的 Download 合成文件用于复核，不清理用户其他文件；未修改官方客户端设置。

新增入口已实际编译、运行通过；Flutter analyze 无问题。生产源码未改，因此没有重复运行 P2.3 已通过的 24 core / 2 ABI / 72 Flutter 测试。结束前恢复普通 main Windows release 构建和自动生成的注册文件，产物不留在 integration 入口。

## 复现与后续

准备一个新的绝对测试目录，放入五件带 `p3-official-` 独有前缀的合成文件及 `fixtures.json`（数组，每件 name/size/sha256）。`official-peer.json` 为 `{address:"IP:port",fingerprint:"64位证书SHA256"}`；应从已知测试手机单独读取证书，不能把未知对端提示当作已认证身份。设置 P2.3 最终 DLL、图像 DLL 的构建覆盖路径并执行：

```powershell
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub --target integration_test/local_transfer_official_test.dart --dart-define=P3_WORKDIR=ABSOLUTE_TEST_DIRECTORY --dart-define=P3_HOST=WINDOWS_LAN_IP
```

运行新构建，保持官方 Android LocalSend 前台，按上述顺序接收和回传。`status.json` 记录阶段，`done` 才表示完整双向完成；`received.json` 保存独立回读后的接收校验信息。单阶段最多等八分钟，整个入口最多 22 分钟。文件字节走 LAN，ADB 只负责 UI 和独立验证。

下一切片为 P3.1：受控端口冲突／发现失败兜底、断网与网卡变化后的恢复行为，再推进真实 VPN／多网卡、AP 隔离、权限撤销、锁屏强杀和窗口退出。旧版／Windows 官方客户端共存、Android 大批次、Apple、图库仍分别待验，不因本轮通过标记整个 P3 完成。
