# 文件互传终态与进度验证

日期：2026-10-22。基线：`b087151116a964352b839f049e2b706b34226de8`。分支：`codex/local-transfer`。机器可读结果见 [JSON 报告](local-transfer-terminal-report.json)。

本轮在独立 worktree 完成，不操作手机、不更改网络或防火墙。用户暂时无法配合的 Android 生命周期测试仍待执行；本轮本机结果不将 P3.2 标记完成。

## 修复的行为

- 原生快照结束会话时，文件的 `checksum_mismatch`、`truncated` 等原因可能被通用 `remote_failure` 或整批取消错误覆盖。现在逐文件保留自己的错误；整批明确取消／超时仍在批次摘要显示。协议仅报告会话结束时，摘要采用已知文件原因，没有具体原因才回退 `remote_failure`。多文件有不同原因时摘要只提供一条提示，逐文件结果保留各自原因。
- Flutter 在 `refresh()` 已读取新快照后，可能继续收到队列中的旧进度事件。现在批次终态、已 ACK／已提交文件优先，活动文件进度不会被旧事件倒退或超过文件长度。
- 活动会话中的失败文件仍可能被对端重传。收到该文件的进度时重新读原生快照，确认当前状态，避免仅凭旧事件恢复，也避免禁止合法的同会话重传。

本轮只调整状态及错误报告；协议、文件发布、取消清理、重试规则和 ABI 1.3 不变。

## 验证结果

| 层次 | 本轮证据 |
|---|---|
| 修复前复现 | 原生新终态用例 2 失败、1 通过；Flutter 新进度用例 7 失败 |
| 原生核心 | 完整 29 项通过；包括取消／超时保留文件原因、已提交 receipt 不变、未知原因兜底、全成功不被迟到错误污染 |
| 真实 loopback HTTPS | 错误哈希后显式取消，批次为取消、文件仍为哈希错误；截断后协议结束，保留截断原因；无残缺 receipt，另建会话重试成功且字节一致 |
| C ABI | 2 项通过，含真实资源释放 |
| Flutter | 完整 101 项通过，含 8 项新增进度回归、2 项真实 DLL 确认回归及 classifier／home queue fixture |
| 真实 DLL／Dart worker | 4 文件、71,303,181 bytes；源文件与副本哈希一致，含停止时等待复制、同根／同端口重启及 receipt 恢复 |
| 静态检查 | 两个自有 Rust crate 的 `clippy --all-targets --no-deps -- -D warnings` 和格式检查通过；Flutter analyze 无问题 |
| Windows 普通入口 | `lib/main.dart` release 构建通过，包内传输 DLL 与本轮真实测试 DLL SHA-256 一致，含 LocalSend 许可 |
| Android 普通入口 | arm64 release APK 构建通过；包名 `io.github.beetman.xdremux`、min SDK 24、target SDK 36；包内库与本轮构建库经 NDK 去符号后完全一致；无 IntegrationTestPlugin、含许可；未安装 |

依赖也纳入的 core clippy 首次检查报告 vendored LocalSend 的 76 项既有 lint；未扩展本轮范围修改上游。上述严格检查针对自有 crate，使用 `--no-deps`，并未将依赖 lint 记作通过。

本轮测试期间曾将截断后的摘要预期写成空闲超时；协议会在所有文件处理结束后直接结束该会话，实测应为截断。已核对 vendored `finalize_file` 语义并修正测试，随后完整 29 项通过。取消／超时与文件错误的优先级另由确定性的 journal 用例覆盖。

## 复现入口

```powershell
cargo +1.97.1 test --locked --manifest-path crates/xdremux-transfer/Cargo.toml
cargo +1.97.1 test --locked --manifest-path crates/xdremux-transfer-ffi/Cargo.toml
cargo +1.97.1 clippy --locked --manifest-path crates/xdremux-transfer/Cargo.toml --all-targets --no-deps -- -D warnings
cargo +1.97.1 clippy --locked --manifest-path crates/xdremux-transfer-ffi/Cargo.toml --all-targets --no-deps -- -D warnings
# apps/flutter 下；真实 DLL／队列 fixture 的环境变量见既有测试说明
flutter test --no-pub
flutter analyze --no-pub
dart run tool/transfer_worker_smoke.dart ABSOLUTE_DLL REPORT_PATH
```

## 保留边界

Android 锁屏／按 Home／强杀及部分上传清理仍待用户方便时验证；真实切网、VPN／多网卡、AP 隔离、权限撤销、旧版／同机官方客户端和 Android 规模矩阵仍未完成。Apple 未验证，鸿蒙按用户安排后续验证。本轮未重跑此前的 2 GiB／1000 文件规模测试，也不从状态修复推断新的性能或平台支持结论。
