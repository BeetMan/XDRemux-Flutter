# 构建指南（五平台）

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
| macOS/Linux | `vendor/x265/build_desktop` | - |
| 鸿蒙 | `vendor/x265/build_ohos` | DevEco NDK 交叉，关汇编；平台分支用 `CARGO_CFG_TARGET_ENV == "ohos"` 判定 |

`x265_helper.c` 以 C++ 编译（x265.h 用了 `bool`）。

## 2. Flutter 应用

```bash
cd apps/flutter
flutter build windows        # x64 安装包前体
flutter build macos          # + copy_dylib.sh 自动进 Podfile post_install
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
