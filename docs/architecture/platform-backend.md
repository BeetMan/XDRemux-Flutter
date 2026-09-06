# 平台后端矩阵

> 哪个平台、哪个功能、走哪条实现路径。这是排障时判断"该看哪份代码"的第一入口。

## 1. 媒体处理（转换 / 写回 / 分类）

**v0.3.1 起全平台统一走 Rust FFI**，一套实现，行为一致。

| 平台 | 库形态 | 加载方式 | 构建入口 |
|---|---|---|---|
| Windows | DLL | 路径搜索（安装目录/开发目录） | cargo build（x265 MSVC 静态链接） |
| macOS | dylib | rpath / Frameworks / 可执行文件旁多级回退 | cargo build（`vendor/x265/build_desktop`） |
| Android | .so（arm64-v8a） | `DynamicLibrary.open('libxdremux_core.so')` | `cargo ndk -t arm64-v8a` -> jniLibs |
| iOS | 静态库 | `DynamicLibrary.process()` | `build_ios.sh`（x265 + Rust 静态库进 Frameworks） |
| 鸿蒙 | .so（arm64-v8a，`aarch64-unknown-linux-ohos`） | `DynamicLibrary.open('libxdremux_core.so')` | `build_ohos.sh`（DevEco NDK 交叉，产物拷到 `ohos/entry/libs/arm64-v8a/`） |

历史注记：macOS/iOS 曾走 Swift ImageIO 写回路径（`AppleReturnedPhotoWritebackBridge.swift`），但它缺少烘焙型边框水印回退和 OPPO 范围约定编码，v0.3.1 起弃用，代码保留为研究路径。

## 2. 解码预览 / 缩略图

| 平台 | 解码器 |
|---|---|
| Windows | WIC（`BitmapDecoder.Create`） |
| Android | ImageDecoder |
| macOS / iOS | ImageIO（CGImageSource） |
| 鸿蒙 | Image Kit（vendored 插件通道） |

## 3. 文件访问

| 平台 | 机制 | 原则 |
|---|---|---|
| Windows | 文件系统 + 拖放（drop_file_service） | - |
| macOS | NSOpenPanel / 拖放 | - |
| Android | SAF（Storage Access Framework）+ receive_sharing_intent | **不默认索取存储权限**；工作流产物在应用私有目录 |
| iOS | PHPicker / Files | 无相册直写；导出走分享 |
| 鸿蒙 | file_picker（vendored fork + v12 兼容门面）/ PhotoViewPicker 选图库原图 / 系统分享（sendData） | 图库分享必转 JPEG（发送方策略）；文件管理器分享是原图；保存图库走 PhotoAccessHelper |

## 4. Swift 后端（研究路径）

保留在仓库但默认不被调用：

- `apps/flutter/macos/XDremuxMacBackend/`：写回桥、水印尾部桥、风格水印蒙版桥、人像深度诊断、人像标定研究
- `apps/flutter/ios/SwiftBackend/`：AppleFeatures（摄影风格管线、人像转换）、AppleCore（HEIF/RAW/HEVC 编码）、Providers、Probes

用途：对照参考实现（ImageIO 的行为基准）、Apple 私有框架侧载研究（仅研究，不进产品承诺）。

## 5. 打包注意（历史踩坑）

- **macOS**：必须打包最新构建的 Rust dylib（曾出现打包过期 dylib 的 bug，见提交 `e95d88c`/`71bd443`）
- **Android**：release 构建锁定 SDK 36 / build-tools 36.0.0（CI runner 无 API 37），`receive_sharing_intent` 固定 1.8.1，JVM target 按插件分别对齐
- **iOS**：未签名 IPA 侧载分发；TestFlight/公证未配置
- **鸿蒙**：**发布默认 profile 模式**（AOT + `debug:true`，~34MB）——Development Profile 只能签 debug:true 的包，release 模式包（debug:false）侧载工具全拒；debug JIT 包 118MB 不可取。签名用 DevEco 自动签名材料（本机注入，不入库）；hap 签名是 zip 块而非文件。构建必须用 PowerShell（Git Bash 会触发嵌套 bat 递归炸弹）。插件走 vendored path 依赖 + `pubspec.ohos.yaml` 变体（`tools/ohos/build_hap.ps1` 自动同步版本行）
- **Windows ARM64**：`windows-11-arm` 原生 runner，x265 `-A ARM64 -DENABLE_ASSEMBLY=OFF`，Inno Setup `BuildArch` 参数化
