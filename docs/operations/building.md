# 构建指南（跨平台）

> CI 全自动流程见 `.github/workflows/release.yml` 与 `operations/ci.md`；本页是本地/手动构建。

## 1. Rust 核心（所有平台的地基）

```bash
cargo build --release -p xdremux-core          # Windows/macOS/Linux 宿主
cargo ndk -t arm64-v8a -o apps/flutter/android/app/src/main/jniLibs build --release -p xdremux-core   # Android
xdremux/rust/build_ios.sh                        # iOS 真机（见脚本头注释，产物进 ios/Runner/Frameworks）
xdremux/rust/build_ios_sim.sh                    # iOS 模拟器（同上，供模拟器/UI 验收用）
bash xdremux/rust/build_ohos.sh                  # 鸿蒙（产物在仓库根 target/aarch64-unknown-linux-ohos/，
                                                 # 拷到 apps/flutter/ohos/entry/libs/arm64-v8a/）
```

真机与模拟器的归档不能混用：Podfile 通过 `$HOME/xdremux_ios_libs` 强制链接，两个脚本都会覆盖同一份暂存目录，切回真机时重跑 `build_ios.sh` 即可（否则链接报 `building for 'iOS', but linking in object file ... built for 'iOS-simulator'`，反之亦然）。

x265 静态库由 `build.rs` 按平台自动链接，位置约定：

| 平台 | x265 路径 | 特殊参数 |
|---|---|---|
| Windows MSVC | `vendor/x265/build_windows/Release/x265-static.lib` | ARM64: `-A ARM64 -DENABLE_ASSEMBLY=OFF` |
| Android | `vendor/x265/build_android` | 必须静态（SELinux 禁子进程） |
| iOS | `vendor/x265/build_ios` | `-DCMAKE_SYSTEM_NAME=iOS`，无汇编 |
| macOS/Linux | `vendor/x265/build_desktop` | Linux 未装 nasm 时加 `-DENABLE_ASSEMBLY=OFF` |
| 鸿蒙 | `vendor/x265/build_ohos` | DevEco NDK 交叉，关汇编；平台分支用 `CARGO_CFG_TARGET_ENV == "ohos"` 判定 |

`x265_helper.c` 以 C++ 编译（x265.h 用了 `bool`）。

### 可选：Main10（10-bit）静态库

Styles 线性缩略图的 10-bit 通路是**构建期可选**的：只要 `vendor/x265/build_<平台>_10bit` 存在，`build.rs` 就会把 10-bit 归档复制成唯一库名 `x265-main10`、编译 `src/x265_10bit_bridge.cpp` 并定义 `cfg(xdremux_main10)`；不存在则静默回退 8-bit Apple Log 路径，所以各平台可以分批启用。

| 平台 | 期望目录 | 归档名 |
|---|---|---|
| Windows MSVC | `vendor/x265/build_windows_10bit`（或 `.../Release`） | `x265-static.lib` |
| macOS/Linux | `vendor/x265/build_desktop_10bit` | `libx265.a` |
| Android | `vendor/x265/build_android_10bit` | `libx265.a` |
| iOS / 模拟器 | `vendor/x265/build_ios_10bit` / `build_ios_sim_10bit` | `libx265.a` |
| 鸿蒙 | `vendor/x265/build_ohos_10bit` | `libx265.a` |

构建要点（必须 `HIGH_BIT_DEPTH=ON` + `EXPORT_C_API=OFF` + `XDREMUX_SKIP_RC=ON`）、单帧 Rext 坑、链接语义与风险见 `docs/research/x265-main10-feasibility-20261025.md`。验证：`cargo test -p xdremux-core --lib` 的 `hevc::tests::main10_thumbnail_encode_is_profile_2_and_10bit_hvcc`（仅 `cfg(xdremux_main10)` 时运行）。

已验证的 10-bit 归档（2026-10-25；Apple 平台 2026-10-28）：

| 平台 | 结果 | 交叉编译验证 |
|---|---|---|
| Windows MSVC | 构建通过 + 真实样本 E2E（ffprobe Main10） | `cargo test` 263 passed |
| Linux（CI） | `ci.yml` 同时构建 8-bit/10-bit | `cargo test --workspace` 在 CI 覆盖 Main10 |
| Android arm64-v8a | NDK 27 构建通过 | `cargo ndk -t arm64-v8a --platform 24 build --release` → `libxdremux_core.so` |
| 鸿蒙 arm64-v8a | DevEco SDK 构建通过 | `build_ohos.sh`（默认构建，`XDREMUX_MAIN10=0` 可跳过）→ `libxdremux_core.so` |
| macOS arm64（本机） | Xcode 27.1 构建通过 | `cargo test -p xdremux-core --lib` 266 passed（含 `main10_thumbnail_encode_is_profile_2_and_10bit_hvcc`）；macOS 发布包尚未构建 10-bit |
| iOS arm64 / 模拟器 arm64 | iPhoneOS / iPhoneSimulator 27.1 SDK 构建通过（`LC_BUILD_VERSION` platform 2 / 7） | `build_ios.sh` → `libxdremux_core.a` 内含 `x265_10bit::` 符号；按 Podfile 的 `-force_load` 参数模拟链接通过。**未在真机/模拟器运行** |

iOS 链接语义：Xcode 链接的是 Rust **staticlib**，`cargo:rustc-link-arg` 对 staticlib 无效，所以 `build.rs` 在 iOS 上同样用 `rustc-link-lib=static=x265-main10`，让 rustc 把 10-bit 归档打包进 `libxdremux_core.a`。Podfile 对 `libx265.a`（8-bit）与 `libxdremux_core.a` 都是 `-force_load`；两者重叠的只有 weak 模板/内联符号（10-bit 自有 C 符号带 `_x265_10bit_` 前缀），不会重复定义。

坑：`build_ios.sh` 只在 `build_ios/libx265.a` 缺失时才 configure，旧 SDK 留下的归档会被一直复用。若 release 链接报 `building for 'iOS', but linking in object file ... built for 'macCatalyst'`，用 `otool -l vendor/x265/build_ios/libx265.a | grep -A4 LC_BUILD_VERSION` 看 platform（iOS=2、模拟器=7、macCatalyst=6），把该目录挪走后设置 `IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"` 重跑。

发布侧同步：`release.yml` 的 Android job 已同时构建 `build_android_10bit`（缓存键 `-asm-ndk-v4-`）；`ci.yml` 的 Linux job 已同时构建 `build_desktop_10bit`；iOS job 经 `build_ios.sh` 构建 `build_ios_10bit`（缓存键 `x265-ios-sdk27.1-main10-`）。

### Windows 本地开发（MSVC + x265，已实测 2026-10-25）

在 `git worktree` 里直接 `cargo test` 常会失败，原因通常不是工具链坏，而是两个环境问题：

1. **worktree 缺 `vendor/x265`**：`vendor/` 不在版本库内（`build.rs` 按 `CARGO_MANIFEST_DIR/vendor/x265` 查找头文件与静态库），fresh worktree 里没有，`x265_helper.c` 编译会因找不到 `x265.h` 失败（cc-rs 只报 "status code exit code: 2"，不打印 cl 的具体错误）。处理：把主工作区已构建好的 vendor 以**目录联接**挂进来（不需要管理员权限）：

   ```powershell
   New-Item -ItemType Junction -Path "<worktree>\xdremux\rust\vendor" `
            -Target "<主仓>\xdremux\rust\vendor"
   ```

2. **共享 `target/` 里的旧 C 产物**：多个 worktree 共用一个 `CARGO_TARGET_DIR` 时，`zstd-sys` 等 `cc` 构建产物可能来自不同环境（缺 `INCLUDE`/`LIB` 的旧运行），表现为 GCC 风格参数传给 MSVC 的 `cl/lib`、或 `lib.exe` 打开输出失败（1104）。处理：用**独立 target 目录**。

已验证可复现的完整流程（Git Bash 之外的 `cmd` 里执行，先加载 MSVC 环境）：

```bat
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
set CARGO_TARGET_DIR=%TEMP%\xdremux-clean-target
cd /d <repo>
cargo test -p xdremux-core --lib
```

本机实测结果：`248 passed; 0 failed; 3 ignored`（2026-10-25，Windows 11、MSVC 14.51、Rust 1.99.1）。最小复现 `cc = 1.4.0` 单独编译 C 文件是正常的，所以**不要**先怀疑 VS/cc-rs 版本；先查上面两项。

## 2. Flutter 应用

```bash
cd apps/flutter
flutter build windows        # x64 安装包前体
flutter build macos          # 需先跑上面的 cargo build：dylib 由 Runner 的
                             # Bundle Framework 阶段随构建打包并签名
flutter build linux          # 需先跑 cargo build --release；.so 由 linux/CMakeLists.txt 打包进 bundle/lib
flutter build apk --release  # Android（需先 cargo ndk 更新 jniLibs）
```

鸿蒙 hap（必须用 **PowerShell**，Git Bash 会触发嵌套 bat 递归炸弹）：

```powershell
tools/ohos/build_hap.ps1 -Profile # profile 模式（AOT + debug:true，可侧载，~34MB）
tools/ohos/build_hap.ps1          # 默认 debug JIT（~118MB，仅调试用）
tools/ohos/build_hap.ps1 -Release # release（~27MB，侧载不可签，仅供有发布证书场景）
```

脚本自动从主线 pubspec 同步版本行到 `pubspec.ohos.yaml` 变体；插件为 vendored path 依赖（`tools/ohos/fetch_plugins.sh` 重建；file_picker 不拉上游，带 v12 门面的副本在 `28260c0` 起不再跟踪，脚本从其前一提交恢复）。签名材料本机注入（DevEco 自动签名，不入库）。

macOS（Apple Silicon，2026-10-31 验证 0.4.6 profile hap）用 bash 版脚本，依赖 DevEco Studio 自带的 OpenHarmony SDK、hvigor、ohpm、node 与 JBR：

```bash
bash xdremux/rust/build_ohos.sh          # macOS 默认用 DevEco.app 内的 native SDK 与 ninja
cp target/aarch64-unknown-linux-ohos/release/libxdremux_core.so \
   /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so \
   apps/flutter/ohos/entry/libs/arm64-v8a/
bash tools/ohos/fetch_plugins.sh
tools/ohos/build_hap.sh --profile        # SDK 默认 ~/.sdks/flutter-ohos-3.41.9-1.0.2
```

- OHOS Flutter SDK：`git clone --depth 1 --branch '3.41.9+ohos-1.0.2' https://atomgit.com/CPF-Flutter/flutter_flutter.git`（即 `62357a93`），再执行该 SDK 的 `flutter precache --ohos`；`build_hap.sh` 做与 `check_sdk.ps1` 相同的内核校验，macOS 下载的内核哈希与 Windows 基线一致。
- **需要 Rosetta**：该 fork 只为 macOS 主机提供 x86_64 的 `gen_snapshot`（profile/release AOT 用），未装时报 `bad CPU type`。
- 脚本内置三处 macOS 适配：`CI=true`（hvigor 调用的 pnpm 无 TTY 会中止）、`NODE_PATH` 指向 DevEco 自带的 `@ohos/hvigor-ohos-plugin`（SDK 内的 flutter-hvigor-plugin 按 SDK 路径解析依赖、找不到它），以及构建后还原被写入本机 SDK 路径的 `ohos/package*.json`。
- 本机未配置签名时 hvigor 在打包后提示配置 Signing Configs 并返回非零；脚本识别这种情况，以未签名中间产物 `entry-default-unsigned.hap` 为结果。

鸿蒙 SDK 与官方 Flutter SDK 分开管理。可用 `-FlutterSdk C:\SDKs\flutter-ohos-clean` 或环境变量 `XDREMUX_OHOS_FLUTTER_SDK` 指定 OHOS SDK；未指定时仍兼容旧路径 `C:\flutter-ohos`。不要只替换 PATH 后复用另一版本的 cache。准备独立 SDK 后，先用该 SDK 执行 `flutter precache --ohos`，保留 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 与 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 的项目镜像配置；不要复制旧 SDK 的 `bin/cache`。

`tools/ohos/check_sdk.ps1 -SdkPath C:\SDKs\flutter-ohos-clean -BuildMode profile` 可单独校验，构建脚本也在替换 pubspec 前自动执行。针对框架提交 `62357a93` 固定干净下载的 profile/debug 与 release 平台内核 SHA256；这是已验证稳定线的兼容性防护，不是所有 SDK 的真实性验证。其他框架提交只给出尚未验证的警告，须另行建立基线。发现 checksum mismatch 时停止构建并准备独立干净 SDK，不要跳过校验：2026-10-17 曾出现版本号一致、但 `platform_strong.dill` 缓存不匹配，编译和签名均成功而真机在 `SetNeedsReportTimings` 初始化时崩溃的情况。

桌面开发注意：macOS 用 `deploy_macos.sh` 产出"固定版本" app；Windows 开发目录需能找到 Rust DLL（FFI 搜索安装目录/开发目录）。

### Linux 桌面（本地开发）

Linux 目标位于 `apps/flutter/linux/`，与 Windows/macOS 共用同一套 Dart 代码与 Rust FFI 核心；发布形态为 AppImage / tar.gz（预览资产），打包脚本见 `tools/linux/package_linux.sh`。

系统依赖：Flutter 3.47.7（`.fvmrc`）、clang、cmake、ninja、pkg-config、GTK3、libayatana-appindicator、libnotify。`file_picker` 在 Linux 走 XDG Desktop Portal（需要 `xdg-desktop-portal` 及桌面后端），不需要 zenity。

x265 静态库（Linux 宿主）：

```bash
git clone --depth 1 --branch 4.2 https://bitbucket.org/multicoreware/x265_git.git xdremux/rust/vendor/x265
mkdir -p xdremux/rust/vendor/x265/include
cp xdremux/rust/vendor/x265/source/x265.h xdremux/rust/vendor/x265/include/x265.h
cmake -S xdremux/rust/vendor/x265/source -B xdremux/rust/vendor/x265/build_desktop \
  -G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
  -DENABLE_ASSEMBLY=OFF
cmake --build xdremux/rust/vendor/x265/build_desktop --target x265-static --parallel
cp xdremux/rust/vendor/x265/build_desktop/x265_config.h xdremux/rust/vendor/x265/include/x265_config.h
```

`-DENABLE_ASSEMBLY=OFF` 用于未安装 nasm 的机器；已装 nasm 时可去掉，以获得更好的编码性能（发布构建应安装 nasm 启用 SIMD）。

构建与运行：

```bash
cargo build -p xdremux-core --release       # 生成 target/release/libxdremux_core.so
cd apps/flutter
flutter pub get --enforce-lockfile
flutter build linux --release               # 产物：build/linux/x64/release/bundle
./build/linux/x64/release/bundle/xdremux
```

`linux/CMakeLists.txt` 会把 `target/release/libxdremux_core.so`（缺失时回退 `target/debug`）安装到 `bundle/lib/`，Dart 侧 `XdRemuxFFI._openLinux` 按 bundle 布局查找；也可用 `XDREMUX_LINUX_RUST_LIB=/path/to/libxdremux_core.so` 指定其他产物。`flutter test` 从 Cargo `target/` 目录加载核心。CMake 还会从生成的插件列表里过滤掉 Linux 不使用的 `tray_manager`（避免 `libayatana-appindicator3` 硬依赖）与 `jni`（避免 `libjvm.so`）；过滤器与 Windows 的 jni 过滤思路一致。

发布打包（AppImage / tar.gz / sha256，不发布上网）：

```bash
tools/linux/package_linux.sh 0.4.4 --output build/linux-packages
# -> XDRemux-Linux-0.4.4-x64.AppImage
# -> XDRemux-Linux-0.4.4-x64.tar.gz （含 run.sh / install.sh / README.txt）
# -> XDRemux-Linux-0.4.4-x64.sha256
```

打包细节见 [tools/linux/README.md](../../tools/linux/README.md)。要点：产物保持 **glibc 2.35（Ubuntu 22.04+）** 基线；Rust 核心 NEEDs `libnuma.so.1`，Ubuntu 22.04 桌面默认不带，因此打包器会选用可兼容 glibc 2.35 的 libnuma（缓存的 Ubuntu 22.04 版本），并由 `AppRun` / `run.sh` / 安装后的启动器设置 `LD_LIBRARY_PATH`。tar.gz 为用户级安装（`~/.local`），不需要 root。

CI：`.github/workflows/linux.yml` 在相关 PR、手动 `workflow_dispatch` 和 `release.yml` 的 `workflow_call` 中，于 `ubuntu-22.04` 上构建并打包，校验 glibc 基线、无 appindicator / libdartjni 依赖，上传 workflow artifact。构建使用只读权限和独立的 jammy x265 缓存；Release 调用时由统一 publish 汇总并检查附件，PR 和构建预检不会发布。直接运行 Linux workflow 时，只有手动填写 `attach_release_tag`，独立写权限 job 才会把产物附加到匹配版本的既有 Release。

已验证：GTK 拖放导入、`xdremux photo.heic` 命令行导入、Rust FFI 转换与 x265 编码、XDG Portal 文件选择。暂未接入：系统托盘（`TrayService` 仅 Windows）、完成通知（仅 Windows/Android）、移动端相册与分享；Apple/OPPO 回传页在 Linux 上仍按既有产品门禁隐藏。

### iOS 模拟器（含 iPhone Duo）

模拟器跑真机归档会链接失败（`building for 'iOS-simulator', but linking in object file ... built for 'iOS'`），所以需要单独的模拟器归档：

```bash
xdremux/rust/build_ios_sim.sh      # x265 模拟器版（vendor/x265/build_ios_sim）+ aarch64-apple-ios-sim 静态库
cd apps/flutter
flutter run -d <simulator-udid>
```

- `build.rs` 用 `CARGO_CFG_TARGET_ENV == "sim"` 区分模拟器与真机，各自链接 `build_ios_sim` / `build_ios`。
- 两个脚本都写同一份 `$HOME/xdremux_ios_libs` 暂存目录，切换真机前重跑 `build_ios.sh`。
- 前置：`rustup target add aarch64-apple-ios-sim`、iOS 模拟器 runtime（iPhone Duo 需要 **iOS 27.1**，`xcodebuild -downloadPlatform iOS -buildVersion 27.1`）。

iPhone Duo（`iPhone19,4`，iOS 27.1 模拟器实测）几何，供布局验证参考：

| 项 | 数值 |
|---|---|
| 主屏 | 1398×2034 px @3x → **466×678 pt**，安全区右 84pt、下 34pt、上/左 0 |
| 第二块集成屏 | 2007×2853 px @3x → **669×951 pt**（系统不会自动把 app 放上去） |
| Flutter 视角 | `views=1`、`displayFeatures=[]`（iOS 不暴露折痕）、`textScale=1.0` |

主屏走 `compact(<600)` 与 `narrow(<480)` 分支，不会触发 800/1120 网格断点；风险在纵向空间（678pt 高）和右侧 84pt 不可用区。

## 3. 构建变体

- `XDREMUX_USE_FFMPEG=1`：桌面 ffmpeg fallback 冒烟构建（无 x265，**色彩行为不可信**，见 hevc-x265.md）
- `XDREMUX_GM_420=1`：单 tile 增益映射强制 4:2:0（批量路径本就由调用方参数决定）

## 4. 测试构建

```bash
cargo test --release -p xdremux-core            # 121+ 单元测试
cargo run --release -p xdremux-core --example styles_diag -- <file.heic>
```

探针清单与用法见各模块页；conformance 见 `testing/conformance-suite.md`。

## 5. 安装包

Windows：Inno Setup（`tools/installer/xdremux.iss`，`BuildArch` 参数化 x64/ARM64）。
