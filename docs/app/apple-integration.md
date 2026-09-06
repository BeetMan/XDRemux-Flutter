# macOS / iOS 集成

> 代码：`apps/flutter/macos/`、`apps/flutter/ios/`。媒体处理已统一走 Rust FFI（v0.3.1）；本页只讲平台集成与打包。

## 1. macOS

- **Rust dylib 打包**：`copy_dylib.sh` 由 Podfile post_install 自动调用，把 `target/release/libxdremux_core.dylib` 复制进 app 的 Frameworks/。脚本会**优先取更新的宿主构建**，防止 Flutter 重建时静默打包过期 FFI（历史 bug：打包过期 dylib，提交 `e95d88c`/`71bd443`）
- `deploy_macos.sh`：flutter build macos + dylib 复制 + 整包拷到仓库根 `xdremux.app`
- DMG 分发：本地构建；CI 尚未纳入 macOS 产物（待办）
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
