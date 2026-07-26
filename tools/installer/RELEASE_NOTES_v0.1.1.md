# XDRemux v0.1.1

体验与发布流程更新：

- 拖入 `.heic` / `.heif` 与其他文件混合时，明确提示已添加和已忽略的数量。
- Flutter 依赖和 CI 固定使用项目的 `pub.flutter-io.cn` 镜像。
- GitHub Actions 自动检查 Rust / Flutter，并在 `v*` tag 下构建 Windows 安装包和 Android APK。
- Windows 安装包与 Android APK 的版本号从 Git tag 注入。
