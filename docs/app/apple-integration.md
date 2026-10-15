# macOS / iOS 集成

> 代码：`apps/flutter/macos/`、`apps/flutter/ios/`。媒体处理已统一走 Rust FFI（v0.3.1）；本页只讲平台集成与打包。

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
- Xcode-beta 的 iPhoneOS SDK 路径写在脚本里（随 Xcode 版本更新）
- **文件入口**：PHPicker / Files（相册直写不可用）；Share Extension（`ios/Share Extension/ShareViewController.swift`）接收系统分享
- **分发**：未签名 IPA 侧载（`XDRemux-iOS-*-unsigned.ipa`）；TestFlight/公证未配置（需要 Apple 开发者账号决策）
- Swift 后端 `ios/SwiftBackend/`：AppleFeatures / AppleCore / Providers / Probes，研究用

## 3. 平台能力矩阵

| 能力 | macOS | iOS |
|---|---|---|
| 转换/写回 | Rust FFI（dylib） | Rust FFI（静态库） |
| 预览解码 | ImageIO | ImageIO |
| 文件导入 | NSOpenPanel / 拖放 | PHPicker / Files / Share Extension |
| 相册写回 | 可（用户授权目录） | 不可直写，走分享/导出 |
| GPS 保留 | 工作流选择器保留 GPS（v0.3.1） | 同 |

## 4. 未完成验证项（backlog）

- ~~iOS 真机端到端：PHPicker、Files、GPS、HDR、`rear.depth`、Apple 照片编辑往返~~ ✅ 2026-08-16 真机验证完成（`docs/validation/ios-device-20260816.md`）
- ~~Rust FFI 写回路径在 iOS 的首次真机验证（v0.3.1 切换后）~~ ✅ 同上轮覆盖
- Apple 开发者签名分发（TestFlight / 公证）——未配置，卡点非代码
