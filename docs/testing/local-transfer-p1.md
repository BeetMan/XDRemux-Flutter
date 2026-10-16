# P1：独立传输服务验证

日期：2026-10-17。分支：`codex/local-transfer`。实现位于 `crates/xdremux-transfer/`，与图像引擎、Flutter 应用及根 Cargo workspace 隔离。

## 实现与契约

独立服务提供地址绑定、HTTPS 双向证书、明确接收确认、PIN、发送快照、流式写入、进度、取消、超时、分页回执及稳定错误码。应用入口和 FFI 在 P2 接入。常规构建直接使用固定的 LocalSend 源码副本，不再需要克隆上游；版本、原文件校验值和补丁生成器见 crate 的 `UPSTREAM.md`。

接收文件在私有事务目录中完成长度、可用 SHA-256 和 HTTP 完整性检查，文件与回执一起通过禁止覆盖的原子重命名发布；最终提交完成后才应答成功。无对端哈希的文件明确记录 `peer_hash_present=false`。原始文件名仅保存为元数据，磁盘路径使用本机 UUID。相同批次内大小写重名被拒绝，跨批次同名生成新回执。

Android 实机发现 SELinux 禁止硬链接，已将身份和文件发布统一改为原子重命名，未添加权限绕过或降低系统策略。Windows 使用不带覆盖标记的 `MoveFileExW`，Android/Linux 使用 `renameat2(RENAME_NOREPLACE)`。Apple 分支有对应实现但尚未编译、运行。完整线程、事件、磁盘与重试契约见 crate 的 `README.md`。

## 自动测试：15 项通过

命令：`cargo +1.97.1 test --manifest-path crates/xdremux-transfer/Cargo.toml --locked -j 2`。最终记录：15 passed / 0 failed。使用真实本机 HTTPS/mTLS，不以模拟网络代替传输路径。

| 覆盖 | 结果 |
|---|---|
| 显式确认、中文/emoji 名称、空文件、ACK 后可立即读最终文件、长度/哈希比对 | 通过 |
| 快照准备后修改源文件，仍发送准备时固定的字节 | 通过 |
| 用户拒绝、决策超时、待确认取消、下一会话释放 | 通过 |
| 错误 PIN、错误证书身份、同 IP/有效 token 下异证书上传及取消 | 通过 |
| 错误哈希 422、少收字节、显式新会话重试、无对端哈希标记 | 通过 |
| HTTP body 中断，但已收字节恰好等于文件元数据声明 | 通过；不提交 |
| 停滞上传、主动取消、停服时退出 worker 并清理暂存 | 通过 |
| 已接受但未上传的空闲超时、连续 20 次接受/取消竞态 | 通过；会话槽可继续使用 |
| 目录穿越、绝对路径、Windows ADS/设备名称、控制字符、重名、u64 尺寸边界 | 通过 |
| 1 MiB 元数据上限、空间预检不足 | 通过；空间不足使用 reserve 溢出注入，未填满实际磁盘 |
| 最终存储失败不得返回成功；事件溢出显式 Lagged | 通过 |
| 原子提交遇到已有目标，原文件保持不变 | 通过 |
| 重启清理自有残缺暂存、保留成功回执、身份持久化、重复实例租约、端口复用 | 通过 |
| 分页回执、同名跨会话保存、发送并发上限和发送取消 | 通过 |

另运行 `scripts/check-junction.ps1`：Windows 受管目录被换为指向外部测试目录的 junction 后，服务返回 `UnsafeStorage`，外部 sentinel 保持不变。未递归删除 junction 目标。

工具检查：本包 `cargo fmt --check` 和 `cargo clippy --all-targets --no-deps --locked -- -D warnings` 通过。Windows x64 与 Android ARM64 release 原生 harness 构建通过。Android 使用 NDK 28.2.13676358 / API 24 linker，运行在已连接的 Android 17 / ARM64 设备。

## 实机 LAN 验证

Windows → Android P1 原生服务：5 个文件，共 **18,579,897 bytes**，发送 ACK、接收回执及独立 Android 磁盘 `sha256sum`/`stat` 均一致。素材沿用 P0 的带合成私有尾部 HEIC 副本、生成的 JPEG/MOV、16 MiB 二进制和空文件；不代表 Live Photo 成组或图库能力。

ADB 仅用于部署、启动、读取回执和独立磁盘校验；文件上传通过直接 LAN HTTPS。受控 harness 显式开启 `--accept-test-files`，只接受 `xdremux-poc-*` 名称，服务本身始终要求外部接收决策。

Android → Windows P1：待重新验收。当前 Windows 防火墙有两条 `transfer.exe` 入站 Block 规则，当前进程无管理员权限；反向连接超时，Windows 没有接收到文件。没有改动、关闭或绕过这些规则。已请求用户允许该程序的专用网络访问后重试。该项不能用 P0 的双向结果替代。

P0 官方 Android LocalSend 双向互操作证据继续保留在 `local-transfer-p0-evidence.json`；本轮未重做官方客户端操作。P1 自动测试使用标准 v2 协议路径，但不据此宣称所有旧版客户端兼容。

## 已知边界

- 本轮是 Rust/native service，未接 Flutter、C ABI、系统文件选择器、图库、应用权限或后台任务。
- 磁盘预检不能预留空间；实际 I/O 仍可能失败。Windows 文件已 flush，但不承诺断电时目录元数据的持久性。
- 接收目录必须应用私有；不将防御性链接检查当作抵御有本地写权限攻击者的文件系统沙箱。
- 控制事件历史有界；持久成功状态使用分页回执恢复。失败重试是显式新任务，响应丢失时先核对回执，不能承诺 exactly-once。
- ≥2 GiB、1000 小文件、长时间性能及多播/网络切换仍属后续验收。Apple 环境不足，鸿蒙验证按用户要求延后。
- 根 manifests/lockfile、图像引擎和应用代码无变更，未触发默认发布依赖。未重新运行不受影响的图像构建；P0 已通过默认核心构建。
