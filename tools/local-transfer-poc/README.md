# LocalSend 协议独立验证程序

仅供 P0 验证，不是 XDRemux 已集成的文件传输功能。独立 Cargo workspace、独立 lockfile，不依赖图像引擎或 Flutter，也不修改默认应用构建。

固定源代码见 `source-lock.json`。`bootstrap.ps1` 检出并检查上游提交；不要将来源不明或修改过的 `.upstream` 目录用于验证。普通 Git 依赖会初始化上游的 Flutter 子模块，因此这里使用可验证的本地源码路径。生产集成应再决定如何分发固定的最小源码子集。

## 构建与测试

在本目录执行，需 Windows MSVC 构建工具和 Rust/rustup：

```powershell
./bootstrap.ps1
cargo test -p xdremux-transfer-poc --locked
cargo fmt -p xdremux-transfer-poc -- --check
cargo clippy -p xdremux-transfer-poc --all-targets --no-deps --locked -- -D warnings
cargo build --locked --release --target-dir target/windows -j 2
cargo build --locked --release --no-default-features --target-dir target/disabled
cargo tree --locked --no-default-features
```

本目录固定 Rust 1.97.1，这是上游使用的工具链，不代表已测得最低 Rust 版本。`--no-deps` 让 Clippy 只检查本验证程序；未修改的上游代码有既有警告。Cargo 格式化必须指定本包，避免格式化本地路径依赖。

Android ARM64 构建示例（先安装对应 Rust target，替换实际 NDK 路径）：

```powershell
rustup target add aarch64-linux-android
$ndkBin = "$env:LOCALAPPDATA/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin"
$env:CC_aarch64_linux_android = "$ndkBin/aarch64-linux-android24-clang.cmd"
$env:AR_aarch64_linux_android = "$ndkBin/llvm-ar.exe"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $env:CC_aarch64_linux_android
cargo build --locked --release --target aarch64-linux-android --target-dir target/android -j 2
```

## 使用

接收目录必须不存在；程序仅在显式传入 `--accept-test-files` 时接收以 `xdremux-poc-` 开头的普通文件名，默认 HTTPS。接收端每文件上限 64 MiB、每会话 256 MiB、最多 1024 个文件，拒绝批次内大小写折叠后的重名。临时文件通过检查后才进入 `received/<session>/`。服务按 `--seconds` 限时退出；无文件或接收失败返回非零退出码。

```powershell
./target/windows/release/xdremux-transfer-poc.exe receive --dir results/new-receive --port 53318 --seconds 60 --pin TEST-PIN --accept-test-files --report results/received.json
./target/windows/release/xdremux-transfer-poc.exe send --host 127.0.0.1 --port 53318 --pin TEST-PIN --report results/sent.json results/fixtures/xdremux-poc-example.bin
```

首条命令在另一终端或受控子进程运行。接收端可加 `--notify-host <IP> --notify-port <port>`，向指定 LocalSend 客户端注册以便手动选择设备；这不是多播发现测试。发送端可加 `--fingerprint <SHA256>` 核对已知身份。默认会在首次 HTTPS 注册后固定该连接所见证书指纹，但首次发现本身没有独立身份认证。

`run-loopback.ps1 -FixtureDirectory <directory>` 验证 Windows 双进程收发；`run-android.ps1 -AndroidHost <phone-ip> -WindowsHost <pc-ip> -AdbPath <adb.exe> -FixtureDirectory <directory>` 部署到一台已授权 ADB 的 Android 手机并做直接 LAN HTTPS 双向校验。ADB 只负责程序部署、控制和报告取回；文件流不走 ADB 转发。Android 脚本只允许 ASCII 测试文件名，需保持两端局域网可达。脚本从随机端口启动有时限的服务；失败时关闭自己启动的本地子进程。

测试素材自备并统一使用 `xdremux-poc-*` 名称。P0 使用 HEIC 测试副本并附加合成尾部标记、FFmpeg 生成的 JPEG/MOV、16 MiB 随机字节文件和空文件；不提交照片或测试二进制。验证程序不会解码图像，因此保真结果是文件字节保证，不是图库能力保证。

## 输出与边界

- `results/`：逐文件长度/哈希回执、限时服务日志和单次基线，已忽略。脚本保留自己的 Android 临时测试目录，以便检查；不会删除用户的其他文件。
- 发送报告中的 `success` 是协议上传成功；对方是否保存到最终目录，以接收端报告与独立文件哈希为准。本 PoC 使用上游 Path target，应用提交文件在协议响应之后，P1 需要补齐最终提交与应答的事务语义。
- Android native harness 运行于 ADB shell，不代表应用权限、后台任务和 JNI 集成已经验收。官方 Android LocalSend 互传另外记录。
- 不包含生产级受信配对、会话过期管理、落盘 fsync、崩溃恢复、接收箱和图库 API。取消的协议路径被发送错误清理使用，但用户取消/中断恢复未系统验收。
- `.upstream/`、`target/`、`results/` 不应提交。该工具仅在独立分支维护，主应用无网络监听入口。

本地源码和实验结果详见 `docs/research/local-transfer-poc.md`（仓库根目录）。

## 第三方许可

本目录自有验证代码采用项目的 GPL-3.0-only 许可（见仓库根目录 `LICENSING.md`）。复用的上游 LocalSend 源码按其仓库 Apache-2.0 许可，副本见 `third-party/localsend-LICENSE`。core 的 Cargo manifest 未填写 license 字段，不能仅依赖 metadata 自动识别该项。依赖许可清单见仓库的 P0 证据；正式打包前需补齐实际分发依赖的许可文本与适用声明。
