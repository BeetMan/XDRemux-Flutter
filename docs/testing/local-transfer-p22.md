# P2.2：Windows / Android 应用手动直连

日期：2026-10-19。分支 `codex/local-transfer`；从 P2.1 `2cec7c78` 接续。主线工作区未修改，鸿蒙运行继续按用户要求延后。

## 实现范围

- 工具栏互传入口，原文件/转换结果发送入口；手动 IP、可编辑端口、完整指纹核对、可忘记的指纹记录、显式接收整批确认。
- 文件名、数量、大小、逐文件进度、取消、失败错误、收件箱刷新/分页、受管删除、加入现有转换队列和通用文件导出。
- 控制器按需启动，关闭接收时发送/收件箱操作仅绑定 loopback；移动端 pause/detach、离开页面、桌面关闭/托盘退出等待停服。返回前台不自动开放 LAN。
- 独立 ABI **1.2**：增加 `export_receipt`；Windows 64 KiB 流式哈希校验、目标空间预检、原子拒绝覆盖。Android 使用一次性 SAF URI，原生流式写入后从文档提供方回读校验。失败保留接收原件。
- 可选 DLL/.so 独立构建与 Flutter 平台打包，随包带 LocalSend Apache 许可。图像 crate 不依赖传输 runtime。

## 验证方法与边界

环境为 Windows x64、Flutter 3.44.5 / Dart 3.12.2、Rust 1.97.1、Android ARM64 PKJ110（Android 17/API 37）、NDK 28.2。APK 合并产物 `targetSdk=36`、`minSdk=24`、声明 INTERNET。按 [Android 官方说明](https://developer.android.com/privacy-and-security/local-network-permission)（2026-10-19 核对），target 37 的 LAN 运行时权限流程留待 SDK 升级时实现；本轮没有更改设备权限兼容开关。

`integration_test/local_transfer_test.dart` 是独立 release 测试入口，生产入口仍为 `lib/main.dart`。Windows 与 Android 都使用实际 Dart worker 和打包动态库，走直接 LAN HTTPS；没有代理、ADB 端口转发或防火墙绕过。APK 使用 `.transferdev`，保留设备上原有 XDRemux。

Release 模式模拟键盘注册依赖断言，桌面遮挡下的模拟点击也未可靠触发回调。脚本显式设置真实输入框，并调用生产按钮的确认回调；身份指纹来自双方独立 ready 文件，核对后才发送。Widget 测试另外覆盖按钮点击与确认策略。这不能替代桌面可见 UI 的人工体验验收。测试可在接收件已按清单校验后跨构建恢复后续步骤，不能把不同构建间的续测称作单次无中断运行。

沿用 P0 的五个合成 fixture，每方向 **18,579,897 bytes**：JPEG、带合成私有尾部的 HEIC、MOV、16 MiB 二进制、空文件。各自长度和 SHA-256 见 [P1 记录](local-transfer-p1.md)。接收回执之外，测试持有租约再次从落盘文件独立流式求哈希；Windows 导出再从目标文件独立核对。MOV 不是已配对 Live Photo，不能从这次文件验收推断图库效果。

Android 系统文档选择器首次把 `application/octet-stream` 的 MOV 建议成 `.bin`。已改用文件后缀对应 MIME（MOV/HEIC/HEIF 明确映射），仍通过 ACTION_CREATE_DOCUMENT 保存普通文档；没有调用图库保存。修正后的首次导出名称/字节正确，但测试入口没有收到预期 pause 停服，因此选择文件和导出现在都在启动外部选择器前显式 await stop，不再依赖选择器生命周期通知。普通 `lib/main.dart` 入口另作 Home/返回前台验收。

## 检查结果

最终机器可读报告见 `local-transfer-p22-report.json`。本记录完成前以实际报告为准。

- Rust core 18 项测试通过，含流式导出、同名不覆盖及禁止向私有存储导出；ABI 2 项测试和严格 clippy 通过。
- Flutter 全部 68 项测试通过，包含真实 classifier/home queue 的持久 ACK、读取租约与停止协调、指纹确认及接收确认、分页刷新后保留已加载项与新提交项。
- Windows/Android release 构建通过；应用双向字节校验与 Windows 五件导出完成。Android SAF 的 `.mov` 后缀、2194 bytes 和独立 SHA-256 全部通过，选择器前显式停服；机器报告保留两端完成状态。
- Android 普通 `lib/main.dart` release 入口（独立测试包）通过实际设备输入打开工具栏互传并开启接收；Windows TCP 探测证实前台可达、按 Home 后关闭、返回前台仍关闭，界面重新显示“开启接收”。未覆盖锁屏/强杀/所有 OEM。
- 最终普通 APK 的 applicationId 为 `io.github.beetman.xdremux`、名称 `XDRemux`，包含独立 ARM64 传输库及 LocalSend 许可，DEX 不含 integration-test 插件；未覆盖安装用户已有应用。手机保留的是独立 `XDRemux Transfer Test`（普通 main 入口），接收已关闭。

## 保留项

P2.3 继续自动发现、可达地址筛选（当前会显示 VPN/虚拟网卡地址）、端口占用专用提示、逐失败文件重试、超过 64 个文件的完整预览和规模/性能验收。当前整批接收界面明确提示只预览前 64 项；选择发送前展示数量及体积。通用收件箱并不自动解码或入图库。

本轮覆盖 release 应用 ↔ 另一应用；官方 LocalSend 原生互通沿用 P0/P1 证据，最终应用与官方客户端、旧版本、多播、权限撤销、锁屏/断网矩阵、2 GiB/1000 文件、完整用户操作及窗口退出仍需后续验收。Android 选文件/另存为在启动外部选择器前停止 LAN，返回后需要手动开启接收。文档提供方失败可能留下外部残件，未知后缀的命名仍受提供方影响；接收箱原件保留。Windows 进程中止可能在用户所选目录留下 `.xdremux-export-*` 临时目录。这里只验收独立分支，不代表主线合并或发布完成。

构建 Flutter release 与运行其他 Flutter CLI 需串行。还需注意 Flutter 3.44.5 的 `--no-pub` 会直接跳过 `regeneratePlatformSpecificToolingIfApplicable`（本机 SDK `runner/flutter_command.dart`），不会把测试后含 dev 插件的注册文件刷新为 release 版本，而 Gradle release 会排除 dev 插件依赖，导致 `integration_test` 类缺失。本轮复现并定位了该问题；普通 release 使用正常 `flutter build ... --release`，保留原 pub 镜像和锁文件，重新生成排除 dev 插件的注册文件。不要把测试插件加入生产依赖来掩盖冲突。独立 integration target 才使用测试包专用依赖开关。
