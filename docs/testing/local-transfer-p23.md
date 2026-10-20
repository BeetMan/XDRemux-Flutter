# P2.3：自动发现、显式重试与规模验收

日期：2026-10-20–21。隔离分支 `codex/local-transfer`，接续 P2.2 `a0ecadd3`；未修改主线工作区，鸿蒙运行按用户要求延后。机器记录见 [local-transfer-p23-report.json](local-transfer-p23-report.json)。

## 行为与边界

开启接收后启动 LocalSend IPv4 多播发现（224.0.0.167:53317），HTTPS 接收端口独立，仍可编辑。可选物理或虚拟网卡；选择具体 IPv4 时，HTTPS 也只绑定该地址；“所有网卡”包含 VPN/虚拟网卡，不宣称能自动识别正确网络。发现范围限 RFC1918 私网和 IPv4 link-local，不扫描子网，不自动信任或接收。手动 IP/端口继续可用。

多播只提供候选提示。每个候选经过 HTTPS register 和证书指纹匹配后才显示；点击后再次探测并与发现指纹比较，随后由用户核对完整指纹。发现最多 128 台、90 秒过期、64 项输入队列、单探测 1.2 秒、每端点 10 秒冷却。发现失败与端口占用分别显示可操作提示。Android 按需持有 MulticastLock，停止、Activity.onStop/onDestroy 都释放；返回前台不自动开放网络。

独立 ABI 升至 **1.3**，新增 discovery_start/status/stop、retry_send、send_batch。后者用同目录和安全文件名列表容纳 1000 文件，仍受 64 KiB JSON、1024 文件及路径约束；不同目录的过大请求在 Dart 提交前提示拆批。逐文件状态读取全部分页，总进度覆盖整批；预览每次展开 64 项。

失败重试只发送未获成功 ACK 的文件；同一失败任务只能领取一次，创建新的任务 ID。必须重新确认同一证书身份，允许其 IP 改变。已准备的源文件按原长度和 SHA-256 校验，变化即 source_changed，校验完成前不发送文件清单。PIN 不保留。回执丢失时远端可能已保存，显式确认提示可能产生副本；没有自动重放、断点续传或 exactly-once 保证。重试元数据与最近 32 个终态任务共同限额，停服/重启后消失；UI 同步清除本次任务记录，收件箱持久保留。

## 实际应用与生命周期

Windows x64 ↔ Android ARM64 PKJ110（Android 17/API 37），Flutter 3.44.5 / Dart 3.12.2、Rust 1.97.1、NDK 28.2。独立 release 测试入口为 `integration_test/local_transfer_discovery_test.dart`，Android 包为 `.transferdev`，未覆盖用户原应用。

双方启用实际多播，在设备列表点击发现对象；独立 ready 文件仅提供预期指纹，没有用其 IP 代替发现流程。通过再次 HTTPS 探测和生产指纹确认回调后，Android 先发送，Windows 明确拒绝；Android 使用生产重试按钮和确认弹窗再次发送成功。随后 Windows 向发现的 Android 回传。两个方向均为 P0 的五件合成 fixture、18,579,897 bytes，逐件校验落盘长度及独立 SHA-256；Windows 五件导出也再次校验。Android 原生锁在测试开始持有、显式停止后释放。

测试使用真实 worker 和打包库、LAN HTTPS，没有代理、ADB 转发或防火墙修改。release 测试调用生产控件回调，Widget 测试另外验证真实点击；不能替代完整人工体验验收。该应用互传发生在最后的 Windows 发布重试修复前；最终 DLL 的修复由下面的原生及 ABI 规模复验覆盖，最终普通应用另作 release 打包。原始/最终库哈希分开保存在机器记录中。

普通 `lib/main.dart` release 测试包另用 android-cli 检查界面、ADB 输入：工具栏进入、开启接收后 TCP 可达且 dumpsys 显示本应用多播锁；Home 后 TCP 不可达、锁释放；返回后显示“开启接收／自动发现已关闭”，TCP 仍不通。测试结束接收关闭。原 APK 仍为独立测试包，用户原应用未改动。

## 规模、故障修复与检查

Windows 本机双服务 loopback HTTPS 合成压力测试，源文件与接收件均独立流式哈希，发送源再次校验未改动。16 MiB 基线、2 GiB 单文件、1000 × 1 KiB 连续两轮通过。第一轮：2 GiB 发送 7.658 s，1000 文件 13.703 s；第二轮分别 7.187 s、12.672 s。计时包含发送快照/协商/上传，不含生成、预先求哈希和接收独立回读。数据大部分为零，不能作为真实照片、Wi-Fi 或 Android 吞吐承诺。

100 ms 采样的整个测试进程工作集峰值分别为 18,456,576 / 18,542,592 bytes（约 17.6 / 17.7 MiB），第一轮基线／2 GiB 阶段约 10.3 / 12.5 MiB。CPU 累计约 32.34 / 30.47 s，包括 fixture 哈希和验证。指标覆盖两个原生服务及测试代码，不是 Flutter 应用内存，也不是精确瞬时峰值。

最初 1000 文件用例暴露 Windows 接收目录 MoveFileExW 返回错误 5。等待 Tokio 写操作结束、把标准文件的 sync/close 放到同一 blocking worker 后，一轮成功但复跑仍失败。最终对 Windows 5/32/33 的短暂访问／共享／锁冲突增加最多八次、合计 450 ms 退避；每次仍是系统原子 no-replace，持续失败仍返回 Io，不能假设一定由哪个外部程序持锁。没有改成覆盖或忽略错误。Windows 回归测试分别覆盖持续占用失败、短占用恢复及已有目标不覆盖。

- Rust core **24** 项、ABI **2** 项通过；两 crate 严格 clippy 和格式检查通过。
- Flutter **72** 项通过，含真实 classifier/home queue 持久 ACK；analyze 无问题。
- 最终真实 DLL 的 ctypes 冒烟额外通过 **1000 文件 send_batch、完整状态分页、1000 件独立落盘哈希**；包含已有取消、停止、租约、内存边界与端口/根复用检查。
- Windows/Android 普通 main release 打包，核对独立库与许可；生产 APK 不使用测试包名或 integration-test 插件。构建与产物检查结果见机器记录。

复现：运行 `cargo +1.97.1 run --release --locked --manifest-path crates/xdremux-transfer/Cargo.toml --example p23_validation -- --synthetic-test-only ABSOLUTE_REPORT_PATH`；报告父目录须已存在。测试仅生成/接受带 p23 前缀的自有临时 fixture，结束清理其 tempdir。ABI 复现见 adapter README。

## 下一轮

P2.3 的发现、手动兜底、显式重试和首轮规模验收完成。完整平台/网络退出矩阵继续 P3：最终应用与官方/旧版 LocalSend、多网卡/VPN 与同机官方客户端共存、AP 隔离、权限撤销、断网/切网、锁屏/强杀、完整窗口退出。发现证书验证、TTL、多播失败保留直连、端口冲突等已有自动测试，但不代表上述真实网络环境已验收。

2 GiB/1000 文件本轮覆盖 Windows 原生/ABI，没有宣称 Android 大批次、系统选择器 1000 项或 Flutter 端同规模的性能验收。Apple 待验，鸿蒙延后。HEIC 含合成私有尾部；MOV 不是已配对 Live Photo，不代表图库或动态照片恢复。合并主线和发布另行安排。
