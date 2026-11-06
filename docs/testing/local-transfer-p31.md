# P3.1：受控故障与恢复

日期：2026-10-21。隔离分支 `codex/local-transfer`，接续 `4d67f8fe`。本轮只使用自有监听、临时目录、合成文件和受控 TLS 连接；没有修改 OS 网卡、Wi-Fi、防火墙、权限或主线开发。机器结果见 [local-transfer-p31-report.json](local-transfer-p31-report.json)。真实网络／平台矩阵仍待 P3.2，鸿蒙按用户要求延后。

## 修复

1. 服务停止后，controller 原本先查询 discovery_status，再处理已排队的停止事件。查询收到 closed 会跳过事件处理，使界面仍显示正在接收。现在先处理 core stopped、bridge stopped/fatal，再查询；closed／worker_stopped 也会清理 runtime，即使停止事件已丢失。等待读取／复制、释放租约和停服的原有顺序保留，恢复需要用户显式开启。
2. 发现子系统异步关闭时，controller 清空设备列表，并释放 Android 多播锁；HTTPS 接收保持可用。显式“重新发现”会重新获取锁和启动发现。发现启动抛错时也清除旧列表。
3. Windows 独占通配监听冲突会返回 WSAEACCES **10013**，原先被显示为普通网络失败。显式选择的非零监听端口遇到该错误，现在归为 port_in_use；提示改为“端口已被占用或被系统限制”，支持换端口。系统保留／限制的端口也可能产生此错误，不宣称一定有另一个进程占用。其他网络错误、零端口自动分配失败仍维持原有分类。没有改变防火墙或尝试绕过权限。

ABI 仍为 1.3，没有新增生产命令或默认依赖。Core 的现有 windows-sys 只增加测试用 WinSock feature，用来创建真实独占监听；根／图像 manifests 和 lockfile 不变。

## 分层验证

| 场景 | 方法与断言 |
|---|---|
| 独占端口冲突 | Windows 独占通配 socket，与特定 IPv4 监听冲突；验证 port_in_use、失败后目录租约释放、同根／同端口或更换端口恢复 |
| 多播启动不可用 | 指定 OS 上不存在的私网 IPv4；真实 native／DLL 返回 discovery_unavailable，HTTPS 直连、显式接收和独立落盘哈希仍通过 |
| 发现恢复 | 选择本机存在的 IPv4 后显式重启真实发现，验证 enabled/error；随后停止 UDP 子系统，不关闭 HTTPS |
| 传输中断 | 自有 loopback TCP relay 原样转发 TLS，不解密；一件 2 MiB 文件得到 ACK，第二件已部分到达后断开连接。验证失败终态、仅一件成功、无未完成文件暴露、停服后暂存清理 |
| 对端改变地址 | 同一私有根重新启动到另一端口，旧端口由测试监听占住；重新探测身份后显式 retry_send，只发剩余件，最终两件哈希正确、源文件不变、没有重发已 ACK 文件 |
| 身份变化 | 另建真实不同证书的服务，旧失败任务重试被 IdentityMismatch 拒绝，替代服务没有收到文件 offer |
| runtime 消失 | 停止事件优先、事件缺失但查询 closed、fatal、嵌套 core stopped 均清除旧接收状态；不会自动重开 LAN |
| 用户操作 | Widget 点击验证端口错误后输入仍可编辑、换端口重试；runtime 关闭后页面回到“开启接收” |

TCP relay 为了稳定在第二件中途切断而限速，不是设备吞吐测试；连接切断不是实际关 Wi-Fi。接口配置失败和地址改变分别模拟可达性故障，不代表真实 VPN、网卡移除、AP 隔离或系统权限撤销已验证。

## release 应用

`integration_test/local_transfer_fault_test.dart` 是独立测试入口，使用生产页面／controller／worker 和打包动态库，在全新的测试私有根运行。它先占用端口导致真实启动失败，然后恢复同一根和端口；直接停止真实 UDP 子系统，让轮询观察到发现关闭；显式重新发现；最后从 controller 外部实际 dispose native runtime/worker，验证页面关闭接收、端口释放，再由用户路径显式重启，证书保持而实例 ID 更新。

这里的 runtime 终止是受控 dispose，UDP 失效是显式停止真实子系统，没有声称强杀或注入内核 SocketsFailed。Widget 测试另外覆盖有错误码的异步发现失败和事件丢失。Windows release 测试最初复现了 network 而非 port_in_use，保留失败记录后修复并复验。Android 使用 `.transferdev` 测试包，不覆盖原 XDRemux；多播锁的获取、发现停止后释放、重新发现后获取、runtime 停止后释放由原生 isHeld 逐次断言。Windows 与 Android 最终 release 测试均通过，结果 stage 为 done。Android 真机为 PKJ110、Android 17／API 37；解锁后完成全部断言，包括同根／同端口重启、身份保持和最终端口释放。测试后已恢复普通 main 测试 APK，并停止测试包进程，未覆盖原应用。两端最终结果以机器记录为准；Windows 的 Android 多播锁字段为 false 表示不适用。

## 检查与复现

- Core 26 项、ABI 2 项、Flutter 80 项通过；包含真实 classifier/home queue 的既有回归。两个 Rust crate 严格 clippy 和格式检查通过，Flutter analyze 无问题。
- `tool/transfer_fault_smoke.dart` 使用真实 DLL 和持久 Dart worker，验证端口／目录复用、多播失败下直连、可用接口发现恢复、同身份新端口重试和独立哈希。
- Windows／Android native release 和最终普通 main release 打包结果、库哈希与许可检查见机器记录。2 GiB／1000 文件性能沿用 P2.3，本轮没有重复或扩大性能承诺。

```powershell
cargo +1.97.1 test --locked --manifest-path crates/xdremux-transfer/Cargo.toml
# 在 apps/flutter 下，选择一张只读 HEIC fixture 运行完整 Flutter 测试：
flutter test --no-pub
dart run tool/transfer_fault_smoke.dart ABSOLUTE_DLL ABSOLUTE_REPORT LOCAL_PRIVATE_IPV4
```

release 入口要求 16 位十六进制 `P31_RUN`、本地 IPv4 `P31_INTERFACE`，Windows 还需全新绝对 `P31_WORKDIR`。测试入口采用 P2.3 已记录的 integration 构建方式；普通构建回到 `lib/main.dart`，不沿用 integration 的注册文件。Android 测试 root 位于独立测试包的 `p31-<run>` 子目录，仅存合成测试状态／身份，不接触原应用资料。

P3.2 继续真实网络变化、VPN／多网卡、AP 隔离、权限拒绝／撤销、锁屏／强杀和窗口退出；官方旧版本／同机客户端共存、Android 大批次和 Apple 仍各自待验。传输完成不代表图库、Live Photo 或解码能力通过。合并主线与发布另行安排，开发分支按用户要求推送。
