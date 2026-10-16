# 内置局域网传输 P0 结果与选型

日期：2026-10-17。分支：`codex/local-transfer`。Windows/Android 的最低技术验证通过，建议进入 P1 独立传输服务；Apple 仍待验证，鸿蒙运行验证按用户安排延后。

## 选型结论

采用“固定 LocalSend Rust 核心 + XDRemux 独立封装”的路线。此次实际运行证明核心可在 Windows 与 Android 上进行 v2 HTTPS 文件互传，并与官方 Android 客户端双向互操作。目前没有必要独立重写传输协议，也不需要引入整套 LocalSend Flutter 应用或迁移现有 FFI。

上游锁定 v1.18.2 / `af0416be50770a97760f7070684bc667b759a15c`，核心 crate 版本 0.1.0，协议 2.2。仅启用 `http,multicast` 能编译，实际依赖树不启用 WebRTC 或 tokio-tungstenite；普通 tungstenite 和部分信令类型仍在依赖/源码中，不能称为完全裁掉了所有非局域网代码。验证没有启动公网信令或 WebRTC。

直接 Cargo Git 依赖会拉取该仓库的 Flutter 子模块，已终止该方式。PoC 改为 `bootstrap.ps1` 固定并验证源码提交，再通过本地路径依赖构建，Cargo.lock 固定其余依赖。P1 推荐把所需核心源码、资源和许可作为可追溯的最小源码子集维护；应用正常构建不应克隆整套 Flutter 上游。提取方式和上游更新检查在 P1 落实。

## 实现与 API 证据

`tools/local-transfer-poc/` 是独立 workspace。使用上游证书生成、v2 client、事件驱动 server 和 Path target，未改变上游文件。核心依赖图、root Cargo.toml/Cargo.lock 与应用源代码保持分离。

服务接口允许上层决定接收/拒绝及保存目标，适合封装为现有 C ABI 的句柄和事件流。暂不承诺 SDK API 稳定性；只暴露 XDRemux 自己的错误和事件模型，避免 Flutter 直接依赖上游 Rust 类型。P1 仍需定义 runtime 所有权、句柄释放、事件背压与服务重启。

原型有显式测试接收开关、命名空间及大小限制、临时文件、长度及哈希检查、重复名拒绝和最终文件提交，目的仅是安全运行实验，不等同于 P1 服务完成。协议成功应答与应用最终提交之间的事务边界仍需完善，不能照搬原型作为正式接收箱。

## 已完成的验证

| 项目 | 结果与证据 |
|---|---|
| Windows HTTPS 单元/集成测试 | 3 项通过，覆盖字节保真、422 哈希失败、401 错误 PIN、证书身份不匹配、403 拒收、路径及重复名约束 |
| Windows 双进程 | 5 文件共 18,579,897 bytes，逐文件长度/SHA-256 一致 |
| Windows ↔ Android native harness | 直接局域网 HTTPS，每方向 5 文件共 18,579,897 bytes；双端长度/SHA-256 全部一致，源文件未变 |
| Windows harness ↔ 官方 Android LocalSend 1.18.2+64 | HEIC、JPEG、MOV 双方向完成；手机保存文件及 Windows 回传文件独立 SHA-256 与源文件一致 |
| 禁用传输 | `--no-default-features` 可构建；依赖树仅包含 harness 本身，运行输出 transport disabled |
| 默认图像核心 | 在独立工作树使用现有 x265 头文件和静态库，`cargo build --locked -p xdremux-core -j 2` 通过；未改图像核心、根 manifest 或 lockfile |
| 静态检查 | 本包 rustfmt 与 Clippy（--no-deps）检查；上游既有告警保留，不修改供应方源码 |
| 鸿蒙 ARM64 | 已完成 native harness 编译和链接；未运行。后续验证按用户要求延后 |

HEIC 为已有转换测试副本，并附加可识别的合成不透明尾部标记；JPEG/MOV 是 FFmpeg 控制素材。尾部标记在往返中保留，但不据此声称覆盖了所有 OPPO 原生尾部结构。MOV 与 HEIC 不是 Live Photo 配对，本次不验证图库或实况播放。

Android 测试机为 ARM64、Android 17/API 37。native harness 运行于 ADB shell；官方客户端互通验证是另外一条应用路径。不能用 shell 下的网络能力代替 XDRemux 应用的局域网授权、JNI、生命周期或后台验收。

## 单次资源基线

这些数字来自一次本机环境测量，仅用于早期决策，不是速度承诺。受网络、缓存、证书生成和日志采样影响。

| 项目 | 当次结果 |
|---|---|
| Windows native release 程序 | 5,579,776 bytes |
| Windows 禁用传输程序 | 109,568 bytes |
| Android ARM64 release 程序 | 4,424,200 bytes |
| 鸿蒙 ARM64 release 程序 | 4,346,000 bytes（仅编译） |
| Windows → Android 整批发送进程墙钟时间 | 532 ms，含该进程启动/证书、注册、哈希及上传 |
| 16 MiB 文件上传请求耗时 | Windows → Android 182 ms；反向 279 ms，不含先前的哈希和注册 |
| Windows 发送进程采样峰值工作集 | 11,235,328 bytes（Android 测试） |
| Windows 接收进程工作集快照 | 10,526,720 bytes（Android 测试） |
| Windows 本机双进程整批发送 | 332 ms；发送采样峰值工作集 10,510,336 bytes |
| 本机发送累计 CPU 时间采样 | 343.75 ms；多线程累计时间，不等同于单核占用百分比，也不是系统峰值 CPU |
| 本机接收启动 | 110 ms；其他独立运行记录为 52–54 ms |

体积为原型独立可执行文件，不能当成 XDRemux 安装包增量。Android/鸿蒙尺寸对应早期测量构建，其哈希在证据中固定；之后的测试接收约束和 notify 辅助入口修改可能改变尺寸。尚未测手机侧 CPU/内存、大文件规模曲线、长期稳定性和实际应用包体增量。

## 许可与依赖

Windows 所选特性的依赖闭包 metadata 记录了 218 个 package（含构建依赖与本包），完整名单与当次结果保存在 P0 证据目录。core manifest 没有填写 license 字段，应以固定提交仓库 LICENSE 中的 Apache-2.0 为依据；副本随 harness 留存。其他依赖的声明包括 MIT/Apache、BSD、ISC、Unicode、Zlib 等，正式分发前仍需汇总许可文本和适用归属，metadata 清单不是完整合规审查。

## 尚未覆盖与平台限制

- iOS/macOS：本机为 Windows，没有 Xcode/xcrun 和 Apple 目标 SDK，未做 Apple 编译或运行验证。多播 entitlement、局域网授权、侧载签名和前台生命周期仍是待验证项。
- 鸿蒙：编译证据保留，模拟器/真机、TCP/TLS 与多播运行验证延后，不标为已支持。
- Windows 官方 1.17.0 客户端：已识别本机安装版本，但 Computer Use 工具未获该应用的界面操作权限；未以其他手段绕过。旧客户端互操作未验证，官方互通证据来自 Android 1.18.2。
- 多播：特性可以编译，但本次使用手动 IP 和已知设备注册，不把附近设备自动发现列为已验证。
- 生产边界：首次身份认证、应用权限、用户接收确认、取消竞态、断网恢复、超大文件/批次、低磁盘空间、强制退出与持久提交、完整照片资产语义，仍按 P1–P4 推进。
- 默认图像核心编译通过，不代表运行了整套照片转换、Flutter 或图库回归。本次没有接入主界面或发布配置。

## 下一步

P1 采用独立 crate 封装固定核心，先落实原文件流、受控接收决策、事务提交/应答、取消及资源释放和有界事件队列。延续当前 C ABI，不引入新的 Flutter 桥接体系。P1 结束后再接 Flutter 入口；平台开放范围由各自实际验证结果决定。

参考：[固定上游核心](https://github.com/localsend/localsend/tree/af0416be50770a97760f7070684bc667b759a15c/packages/core)、[协议](https://github.com/localsend/protocol)、[开发计划](../plans/local-transfer-plan.md)、[P0 证据](../testing/local-transfer-p0-evidence.json)。
