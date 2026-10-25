# 传输专项 Windows CI

2026-10-25：新增 `Transfer CI`，覆盖独立于主 workspace 的两个传输 Rust 项目。实现见 `.github/workflows/transfer-ci.yml` 与 `.github/scripts/transfer-ci.ps1`。相关文件的 main／开发分支 push 和 PR，以及手动触发均可运行；并发规则取消同一 ref 的过时运行。触发语义依据 [GitHub 官方文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)。

门禁依次执行 core／FFI 的 locked test、format、clippy，构建真实 Windows DLL，执行 Python ABI 冒烟、完整 Flutter analyze、全部 `transfer_*_test.dart` 和 Dart worker 冒烟。设置实际 DLL 路径，使 Windows 原生集成用例参与运行；真实媒体 classifier 用例仍需要外部 HEIC fixture，不在此门禁声明范围。

```powershell
# 仓库根目录，PowerShell 7；默认安装与恢复锁定的 pub 依赖
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
./.github/scripts/transfer-ci.ps1
# 已准备依赖时可跳过 pub get；Python 可指定绝对路径
./.github/scripts/transfer-ci.ps1 -NoPub -Python ABSOLUTE_PYTHON
```

每次创建全新报告目录，逐阶段记录退出码、耗时和日志；任一步失败即停止，finally 仍写入 `summary.json`。CI 仅上传报告目录顶层 JSON／log，保留七天；自有身份、PIN、fixture 和应用数据不在上传范围。没有官方客户端安装、手机、网络切换或桌面权限弹窗依赖。

后续将真实子进程崩溃验收加入同一门禁，见 [崩溃恢复记录](local-transfer-crash.md)。首轮远端在 `pub get --enforce-lockfile` 正确失败：默认 hosted 源与仓库锁文件的镜像源不一致；runner 已改用锁文件原有镜像源，未更新依赖或锁文件。Rust 缓存仅包含 registry、git 依赖及编译目录，排除运行时身份和测试数据。

本地首轮完整入口通过：Rust core 29 项、FFI 2 项及实际 ABI／worker 冒烟均通过，Flutter analyze 无问题，传输 Flutter 用例通过。ABI 冒烟还核验了 1000 文件，worker 验证受管副本、ACK 丢失重试和读取中停服。此处的本地通过不代表 GitHub runner 已执行；远端状态按对应提交的 Actions 结果记录。固定 Rust 1.97.1、Flutter 3.44.5；本轮新构建 DLL SHA-256 为 `447e9276e1e2758c4c750891a9d8b8f861c1bc49ae22ca1910b63020c89bb71c`。
