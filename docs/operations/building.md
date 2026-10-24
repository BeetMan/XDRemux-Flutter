# 构建指南（跨平台）

> CI 全自动流程见 `.github/workflows/release.yml` 与 `operations/ci.md`；本页是本地/手动构建。

## 1. Rust 核心（所有平台的地基）

```bash
cargo build --release -p xdremux-core          # Windows/macOS/Linux 宿主
cargo ndk -t arm64-v8a -o apps/flutter/android/app/src/main/jniLibs build --release -p xdremux-core   # Android
xdremux/rust/build_ios.sh                        # iOS（见脚本头注释，产物进 ios/Runner/Frameworks）
bash xdremux/rust/build_ohos.sh                  # 鸿蒙（产物在仓库根 target/aarch64-unknown-linux-ohos/，
                                                 # 拷到 apps/flutter/ohos/entry/libs/arm64-v8a/）
```

x265 静态库由 `build.rs` 按平台自动链接，位置约定：

| 平台 | x265 路径 | 特殊参数 |
|---|---|---|
| Windows MSVC | `vendor/x265/build_windows/Release/x265-static.lib` | ARM64: `-A ARM64 -DENABLE_ASSEMBLY=OFF` |
| Android | `vendor/x265/build_android` | 必须静态（SELinux 禁子进程） |
| iOS | `vendor/x265/build_ios` | `-DCMAKE_SYSTEM_NAME=iOS`，无汇编 |
| macOS/Linux | `vendor/x265/build_desktop` | Linux 未装 nasm 时加 `-DENABLE_ASSEMBLY=OFF` |
| 鸿蒙 | `vendor/x265/build_ohos` | DevEco NDK 交叉，关汇编；平台分支用 `CARGO_CFG_TARGET_ENV == "ohos"` 判定 |

`x265_helper.c` 以 C++ 编译（x265.h 用了 `bool`）。

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

脚本自动从主线 pubspec 同步版本行到 `pubspec.ohos.yaml` 变体；插件为 vendored path 依赖（`tools/ohos/fetch_plugins.sh` 重建，file_picker 除外——vendored v12 门面已入库）。签名材料本机注入（DevEco 自动签名，不入库）。

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

CI：`.github/workflows/linux.yml` 在相关 PR 与手动 `workflow_dispatch` 时，于 `ubuntu-22.04` 上构建并打包，校验 glibc 基线、无 appindicator / libdartjni 依赖，上传 workflow artifact。构建使用只读权限和独立的 jammy x265 缓存；只有手动填写 `attach_release_tag`，独立的写权限 job 才会把产物附加到匹配版本的既有 Release，PR 不会执行发布。该 workflow 目前独立于 tag 触发的 `release.yml`。

已验证：GTK 拖放导入、`xdremux photo.heic` 命令行导入、Rust FFI 转换与 x265 编码、XDG Portal 文件选择。暂未接入：系统托盘（`TrayService` 仅 Windows）、完成通知（仅 Windows/Android）、移动端相册与分享；Apple/OPPO 回传页在 Linux 上仍按既有产品门禁隐藏。

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
