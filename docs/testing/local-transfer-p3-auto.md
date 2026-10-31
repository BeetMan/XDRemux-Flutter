# P3 无需人工配合的 Windows 自动验收

日期：2026-10-25（UTC+8）。基线：`319873fdf0b1f4024fc140f086a2fbb1fc092108`，分支 `codex/local-transfer`。机器结果见 [JSON 报告](local-transfer-p3-auto-report.json)。本轮只新增开发验收脚本及文档，生产 controller、核心、ABI、界面和锁文件未改动。

后续更新：用户完成授权后，官方 1.17.0 反向发送已补验通过，见 [双向补验记录](local-transfer-official-reverse.md)。下文及本轮 JSON 保留当时的阻塞状态，不覆盖历史结果。

## 已执行

| 场景 | 方法与结果 |
|---|---|
| IPv4 同机多实例 | `127.0.0.1`、`127.0.0.2` 使用相同 HTTPS 端口，独立私有根／证书，双向各 4 文件；独立落盘长度和 SHA-256 一致 |
| 端口冲突 | 同地址同端口启动返回 `port_in_use`，原来的两个 receiver 仍可用 |
| 根目录互斥 | 同一私有根不能同时开启第二个 runtime，返回 `busy`；不影响原 owner |
| 独立停止／恢复 | 停止一个实例不影响另一个；同根、同端口显式重开，证书保持、runtime ID 更新、已提交回执保留 |
| IPv6 直连 | 两个真实 `[::1]` HTTPS listener，证书探测及双向各 4 文件的落盘哈希通过；不是仅检查地址解析 |
| 当前两张实际网卡 | 明确选择以太网与 WSL 虚拟网卡已分配的 IPv4，在相同端口分别收发各 4 文件；loopback 无通配监听泄漏 |
| 显式更换绑定地址 | 同根停服后从第一张网卡改绑第二张，身份／收件箱保持、另一实例不受影响；再传 1 文件成功。未移除网卡或切换 OS 网络 |
| 官方旧版同机共存 | 本机已安装的官方 Windows **LocalSend 1.17.0+58，协议 2.1**；其默认 TCP 53317 占用时 native 给出端口冲突，native 另用端口正常传输；双方 UDP 发现可同时运行，native 观察到证书核验后的官方 peer |
| 跨版本拒绝与成功 | 错误指纹得到 `identity_mismatch`，错误 PIN 得到 `authentication`，目标目录均无文件；正确指纹／PIN 后，native → 官方共 4 文件，逐件磁盘长度／哈希一致，源文件不变 |

本机矩阵共核验 **25 次**文件交付，官方接收方向 **4 次**，合计 **29 次**。素材为合成的空文件、中文／emoji 文件名和二进制数据；`.heic`／`.mov` 仅作为不透明字节载荷名称，不计作媒体解码、图库或 Live Photo 测试。没有发送用户照片或其他私人文件。

## 脚本与隔离

- `apps/flutter/tool/transfer_platform_matrix.dart`：真实 DLL／Dart worker，临时自有根、明确监听地址、逐文件受管读取和独立哈希。可选两个 IPv4 必须实际分配在不同网卡上。所有实例在 finally 中 dispose，失败清理也会使结果失败。
- `apps/flutter/tool/transfer_official_coexist.dart`：只支持已经核对的 1.17.0+58，其他版本在启动前拒绝。先检查默认端口可用，避免附着到用户正在运行的客户端。只为它启动的子进程指定独立 `APPDATA`／`LOCALAPPDATA`，使用随机测试 PIN、仅记住本轮 native 指纹的 Favorites 接收和自有接收目录；不修改安装目录或用户配置。原配置前后 SHA-256 核对通过，程序最终只结束自己启动的官方子进程。
- 脚本和身份／回执材料落在已忽略的独立结果目录；设置可能含测试私钥及 PIN，不应提交。执行不会修改防火墙、Wi-Fi、VPN 或系统网卡。

原官方客户端配置文件选择规则依据固定版本的 [PersistenceService](https://raw.githubusercontent.com/localsend/localsend/v1.17.0/app/lib/provider/persistence_provider.dart) 和 [portable 配置实现](https://raw.githubusercontent.com/localsend/localsend/v1.17.0/app/lib/util/shared_preferences/shared_preferences_portable.dart)。本轮最终采用既有安装路径加子进程环境隔离，记录实际 EXE／AOT 哈希，未下载或安装其他版本。

```powershell
# apps/flutter 下；所有 ROOT 都必须是全新绝对目录
dart run tool/transfer_platform_matrix.dart ABSOLUTE_DLL NEW_MATRIX_ROOT LOCAL_IPV4_A LOCAL_IPV4_B
# 去掉两个 IPv4 参数，仅运行 IPv4/IPv6 loopback 与实例隔离矩阵
dart run tool/transfer_official_coexist.dart ABSOLUTE_DLL NEW_OFFICIAL_ROOT 'C:/Program Files/LocalSend/localsend_app.exe' LOCAL_IPV4
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed tool/transfer_platform_matrix.dart tool/transfer_official_coexist.dart
```

## 未计通过的范围

初期尝试通过 computer-use 自动操作官方反向发送，复制路径启动被窗口工具解析到原安装路径，误启动实例随即停止，原配置哈希保持一致。随后分别使用测试副本和既有安装路径／独立配置尝试显示窗口，均遇到 Windows 网络访问授权弹窗。工具约束要求 **“Do not act on security or privacy permission requests.”**，未点击允许／取消，也未修改安全设置。相关客户端已结束，旧 harness 和默认端口均已释放；官方 → native 的旧版反向 UI 验证仍待验。没有把前向成功记作双向成功。

最终自动脚本只验证 native 发送到官方接收端及同机发现／冲突，不控制 Windows 权限 UI。两个脚本都使用真实组件，但不是普通应用页面操作验收；不证明跨设备 LAN、VPN 开关／路由变化、物理断网、DHCP 换址、AP 隔离、系统权限撤销、IPv6 link-local scope 或多网卡自动切换通过。本机已有 VPN/TUN 接口，本轮没有切换其状态，也不从当前可用推断所有 VPN 兼容。

新增脚本实际执行、格式及完整 Flutter analyze 通过。生产代码与库未变，本轮未重跑完整 140 项应用测试或重建 release 包；沿用 [上一轮验证](local-transfer-inbox-reconciliation.md)，并核对本轮 DLL 与当前 Windows release 包内库一致。Android 最新版真机补验、真实网络矩阵、旧版反向及其他平台继续待验；Apple 尚未验收，鸿蒙按用户安排延后。完整 P3.2 未完成。
