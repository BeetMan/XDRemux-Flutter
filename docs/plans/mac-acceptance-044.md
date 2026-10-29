# Mac / iPhone 最新主线验收交接（2026-10-17）

## 拉取与范围

- 仓库：`https://github.com/BeetMan/XDRemux-Flutter`，使用最新 `origin/main`，不要切到电影模式实验分支或鸿蒙原生分支。
- 拉取前先检查 `git status`；有本地修改时保留它们，不执行 reset/clean。干净 main 可用 `git pull --ff-only origin main`；若历史分叉则停止并核对，不强制覆盖。
- Apple 业务代码基线已在 `9ee2431f` 及其父提交中；本次同步补充 OHOS 启动构建防护、Android/鸿蒙验收记录和本交接文档，不额外修改 Apple 产品逻辑。
- 正式应用版本仍为 `0.4.3+37`，是准备 0.4.4 的候选，尚未发布 0.4.4。不要擅自打标签、创建 Release 或上传私有照片/证书。

## 环境与依赖

- **官方 Flutter 3.47.7 / Dart 3.13.5**，由 `apps/flutter/.fvmrc` 和 CI 固定。不要使用 Windows 上的 OHOS 专用 SDK，也不要把 OHOS pubspec 变体覆盖到 Apple 构建中。
- 使用项目镜像和已提交 lockfile，不批量升级插件、不重新解析成其他版本：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter --version
cd apps/flutter
flutter pub get --enforce-lockfile
```

- 使用 Xcode、CocoaPods、Rust、CMake 和本机对应架构。当前 macOS Podfile 的最低版本为 macOS 15.0。
- 必须从本次主线源码重新构建 Rust 核心，不能复用旧 app 内的 dylib/静态库。默认 decoder 配置，不默认开启 Windows 测试包的可选 libheif。
- x265 的 CI 固定版本为 **4.2**。首次准备依赖时参照 `.github/workflows/release.yml` 的 macos/ios job：macOS 使用 `build_desktop`，Apple Silicon 关闭 x86 汇编，并准备 `vendor/x265/include/{x265.h,x265_config.h}`；不要混用 Windows/OHOS/iOS 的静态库。

## 构建和自动检查

1. 在仓库根构建 `cargo build --locked --release -p xdremux-core`，并运行对应 Rust 测试。
2. 在 `apps/flutter` 执行完整 `flutter analyze` 和 `flutter test`。此前本机 141 项通过；CI 缺公开样片时为 139 passed / 2 fixture-dependent skipped。若 Mac FFI 测试找不到新 dylib，修正测试宿主加载路径，不把测试整体跳过。
3. `flutter build macos --release`，确认 `XDRemux.app/Contents/Frameworks/libxdremux_core.dylib` 存在、架构正确且来自本次重编。不要只看 Flutter 打包成功。
4. iOS 用 `rustup target add aarch64-apple-ios`；设置 `IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"`，参照 CI 先配置 x265/生成 include，再运行 `bash xdremux/rust/build_ios.sh`。不要使用脚本里默认的另一台机器 Xcode-beta SDK 路径。
5. 编译 iOS release（可先 `flutter build ios --release --no-codesign` 验证原生代码）；安装到 iPhone 时使用 Mac 本机已有开发团队签名，不同步 Windows 或他人的私有签名。

## 人工验收重点

- macOS：启动；文件单选/多选/中文路径/拖放；预览颜色与方向；普通转换、摄影风格、人像；Codec 诊断打开/复制/导出；批量取消、失败重试。
- macOS：Live Photo 合成输出同 stem 的 HEIF 与 MOV；两份原文件一起导入 Photos，识别为一个可播放、有声音的 Live Photo；再单独验证投送到 iPhone。保存到照片库与文档/文件导出分开记录，不把普通文件分享当成 Photos 原生写入。
- iPhone：从 app 内“保存 Live Photo”，PhotoKit 应以 `.photo` + `.pairedVideo` 在同一事务写入一个资产；保存后在照片 App 长按播放、有声音、封面正确。既测单项，也测批量/自动保存（如果启用）。
- iPhone：首次允许/拒绝相册添加权限、改为允许后重试、再次保存；失败不能提示完整成功，也不能静默只存静图；app 原始 HEIF/MOV 不应被移动或删除。
- iPhone：普通静图与“拆分静帧 + 视频”不误带残留 MOV，拆分模式不承诺 Apple 配对 ID；配对原文件分享包含两个附件。
- UI：实况三种选项切换不跳动、不溢出；主页及详情页底栏留出安全区；Mac 窗口缩放也能正常操作。

之前“一组文件经 Mac 投送到 iPhone 正常”只证明那组产物与该传输方式可用，不能替代本次 iOS app 内 PhotoKit 保存验收；iPhone 文件 App 的“保存”不作为唯一配对判断依据。

## 当前其他平台状态与回写

- Android：用户已确认本轮 Flutter 3.47.7 候选整体 OK。
- Windows：自动回归和完整便携包已准备，尚无本轮用户人工验收结论。
- OHOS Flutter：旧 SDK 平台内核缓存不匹配导致启动闪退；独立干净 SDK 重编后，真机覆盖安装及启动 smoke 已通过。**统一相册保存入口和 Live Photo 双文件分享仍未完成 OHOS 接入**，不可标记完整功能验收通过。
- 鸿蒙原生：不是本次 Flutter 修复的同步目标，尚不能宣布原生 0.5.1 已验收或发布。
- 把 Mac/iPhone 的实际 SDK/Xcode/系统版本、测试提交、构建结果、用例结果和未解决问题回写到 `docs/plans/release-candidate-044.md`；导出相关细节同时更新 `docs/plans/live-photo-export-fix.md`。编译通过、安装通过和人工功能验收分开记录。
