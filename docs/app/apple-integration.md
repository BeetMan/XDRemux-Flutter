# macOS / iOS 集成

> 代码：`apps/flutter/macos/`、`apps/flutter/ios/`（Flutter 版，当前发布）。媒体处理已统一走 Rust FFI（v0.3.1）；本页只讲平台集成与打包。
> 原生 SwiftUI 前端（`apps/apple/`，未发布）见 §5。

## 1. macOS

- **Rust dylib 打包**：Runner target 的 `Bundle Framework` 拷贝阶段（`dstSubfolderSpec = 10`，即 `Contents/Frameworks`）直接引用 `target/release/libxdremux_core.dylib`，并带 `CodeSignOnCopy`。所以 `flutter build macos` 产出的就是完整且签名有效的 app，**不需要任何构建后的补救步骤**。拷贝阶段在 Xcode 的 CodeSign 之前执行，dylib 既被签名也被计入封印。
  - 该阶段引用的是 cargo 的构建产物本身（单一来源），因此不存在「打包过期 dylib」的可能（历史 bug：`e95d88c`/`71bd443`）。
  - 先跑 `cargo build --release -p xdremux-core`：dylib 缺失时**构建期报错**，而不是产出一个加载不了 Rust core 的 app。
- `deploy_macos.sh`：flutter build macos + 整包拷到仓库根 `xdremux.app`
- DMG 分发：本地构建；CI 另跑 `flutter build macos --release` 并**断言** dylib 已在包内
- FFI 加载：多级回退（rpath 裸名 -> 可执行文件旁 -> Frameworks），见 `architecture/ffi-contract.md`
- Swift 后端 `XDremuxMacBackend`：研究路径（写回桥/水印尾部桥/人像标定），默认不调用

## 2. iOS

- **Rust 静态库**：`xdremux/rust/build_ios.sh` 构建 `aarch64-apple-ios` 的 `libxdremux_core.a` + x265 静态库 + helper，拷进 `ios/Runner/Frameworks/`；FFI 走 `DynamicLibrary.process()`
- Xcode-beta 的 iPhoneOS SDK 路径写在脚本里（默认 `iPhoneOS27.0.sdk`，可用 `IPHONEOS_SDK` 覆盖，随 Xcode 版本更新）
- **Main10**：`build_ios.sh` / `build_ios_sim.sh` 默认同时构建 10-bit x265（`vendor/x265/build_ios_10bit`），`build.rs` 打包进 `libxdremux_core.a`；0.4.6 起 iOS 发布包的风格缩略图为 10-bit
- **文件入口**：PHPicker / Files；Share Extension（`ios/Share Extension/ShareViewController.swift`）接收系统分享
- **保存到照片**：普通图走 `gal`；Live Photo 走 MethodChannel `xdremux/live-photo`（`AppDelegate.swift` 的 `saveLivePhoto`，`PHAssetCreationRequest` 以 `.photo` + `.pairedVideo` 写入同一个 asset）
- **分享 `.pvt`**：iOS / macOS 直接分享 `.pvt` 包（`output_export_service.dart`），其他平台分享 `.pvt.zip`
- **分发**：未签名 IPA 侧载（`XDRemux-iOS-*-unsigned.ipa`）；TestFlight/公证未配置（需要 Apple 开发者账号决策）
- Swift 后端 `ios/SwiftBackend/`：AppleFeatures / AppleCore / Providers / Probes，研究用

## 3. 平台能力矩阵

| 能力 | macOS | iOS |
|---|---|---|
| 转换/写回 | Rust FFI（dylib） | Rust FFI（静态库） |
| 预览解码 | ImageIO | ImageIO |
| 文件导入 | NSOpenPanel / 拖放 | PHPicker / Files / Share Extension |
| 保存到照片 | 导出到用户授权目录 / 分享 `.pvt` | 可：普通图（`gal`）与 Live Photo（`PHAssetCreationRequest`）；也可分享 / 导出 |
| GPS 保留 | 工作流选择器保留 GPS（v0.3.1） | 同 |

## 4. 未完成验证项（backlog）

- ~~iOS 真机端到端：PHPicker、Files、GPS、HDR、`rear.depth`、Apple 照片编辑往返~~ ✅ 2026-08-16 真机验证完成（`docs/validation/ios-device-20260816.md`）
- ~~Rust FFI 写回路径在 iOS 的首次真机验证（v0.3.1 切换后）~~ ✅ 同上轮覆盖
- Apple 开发者签名分发（TestFlight / 公证）——未配置，卡点非代码

## 5. 原生 SwiftUI 前端（`apps/apple/`，未发布）

> 计划与各阶段执行记录：`docs/plans/apple-native.md`；目录、iOS 模拟器步骤与 CLI 用法：`apps/apple/README.md`。

- **定位**：与 Flutter 版并行的第二个 Apple 前端（独立 bundle ID `io.github.beetman.xdremux.swiftui`），共用同一 Rust 核心；首要收益是 HDR 预览（`Image.allowedDynamicRange(.high)` / iOS 上 `UIImageReader`）。达到计划 P4 对等验收前，`apps/flutter/ios`、`apps/flutter/macos` 保持可构建并继续发布。
- **核心链接**：`xdremux/rust/build_apple.sh` 产出静态 `XDRemuxCore.xcframework`（`XDREMUX_APPLE_SLICES` 选 `macos` / `ios` / `ios-sim`），放在 `apps/apple/Frameworks/`（不入库）；Swift 通过 `XDRemuxCoreC` 模块引用 `include/xdremux_core.h`。改了 FFI 导出须重新生成头文件，`tools/apple/check_header.sh` 校验。
- **工程**：`project.yml` 用 xcodegen 生成 `XDRemux.xcodeproj`（不入库）；`Packages/XDRemuxKit` 含 C ABI 封装（`XDRemuxKit`）、纯 Swift 模型（`XDRemuxModel`）和 macOS CLI `xdremux`（convert / inspect / details / verify / capabilities / edit-copy / writeback）。
- **已完成（2026-10-31）**：P0–P2 与 P3 三批——导入（文件、拖放、iOS PhotosPicker）、详情优先转换、队列 journal 与重启恢复、Motion Photo → Live Photo 并写入照片库、OPPO ↔ Apple 往返、真正取消（`xdremux_progress_cancel`）、摄影风格 3 后处理、英文本地化。
- **验证范围**：`swift test`、CLI 冒烟、macOS App 构建在 `apple-ci.yml` 中运行（只 macOS 切片）；iOS 只在 iOS 27.2 模拟器实跑。**未验证**：iOS 真机签名安装、Live Photo 声音、真机 HDR 亮度。
- **待做**：Share Extension、批量导出、P4 跨端回归；签名 / TestFlight / 公证与 Flutter 版同样未配置。

