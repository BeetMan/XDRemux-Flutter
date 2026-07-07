# XDRemux 快速开始

## 30 分钟环境配置

### Windows

```powershell
# 1. 安装 Rust
winget install Rustlang.Rustup

# 2. 安装 Flutter
winget install Flutter.Flutter

# 3. 安装 Git
winget install Git.Git

# 4. 安装 VS Code
winget install Microsoft.VisualStudioCode

# 5. 安装 VS Build Tools (选择 C++ 工作负载)
winget install Microsoft.VisualStudio.2022.BuildTools

# 6. 重启终端，验证
flutter doctor -v
rustc --version
```

### macOS

```bash
# 1. 安装 Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. 安装工具
brew install flutter rust git

# 3. 安装 Xcode (App Store)
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# 4. 验证
flutter doctor -v
```

### Linux

```bash
# 1. 安装依赖
sudo apt update
sudo apt install -y curl git

# 2. 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 3. 安装 Flutter
sudo snap install flutter --classic

# 4. 验证
flutter doctor -v
```

---

## 项目克隆与构建

```bash
# 克隆项目
git clone https://github.com/your-username/xdremux-flutter.git
cd xdremux-flutter

# 安装 Flutter 依赖
flutter pub get

# 构建 Rust 核心
cd rust && cargo build --release && cd ..

# 运行应用
flutter run
```

---

## 核心命令

| 命令 | 说明 |
|------|------|
| `flutter run` | 运行调试版本 |
| `flutter build apk` | 构建 Android APK |
| `flutter build ios` | 构建 iOS |
| `flutter build windows` | 构建 Windows |
| `flutter build macos` | 构建 macOS |
| `cargo build --release` | 构建 Rust 核心 |
| `cargo test` | 运行 Rust 测试 |

---

## 常见问题

### Q: Flutter 找不到 Rust 编译器?

```bash
source ~/.cargo/env  # Linux/macOS
# 或重启终端
```

### Q: Android 构建失败?

```bash
flutter doctor -v  # 检查 Android SDK
flutter clean      # 清理构建缓存
flutter pub get    # 重新获取依赖
```

### Q: Windows 构建失败?

确保安装了 Visual Studio Build Tools 并选择了 "Desktop development with C++" 工作负载。

---

## 详细文档

完整的开发指南请查看 `PROJECT_SETUP.md`
