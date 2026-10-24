# 发版流程

> 触发：推送 `v*` tag 到 GitHub -> `release.yml` 构建五个平台产物并挂到 Release；Flutter 鸿蒙另行本地构建和补附件。
> **tag 与 Release 文案由维护者掌控**：CI 只负责产物，不覆盖手写文案。

## 1. 发版清单

1. `apps/flutter/pubspec.yaml` 版本号更新（CI 从 pubspec 解析 TAG_VERSION）
2. Rust `Cargo.toml` 版本同步（应用报告的核心版本从 Cargo 读取）
3. `tools/installer/RELEASE_NOTES_v<版本>.md` 手写发布说明
4. 检查发版检查单：**本轮改动涉及的 docs/ 页面是否更新**
5. 提交 -> 打 tag -> 推送 tag：

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

## 2. 产物命名（CI 强制约定）

```
XDRemux-Windows-<tag>-Setup.exe          (x64)
XDRemux-Windows-arm64-<tag>-Setup.exe
XDRemux-Android-<tag>.apk
XDRemux-iOS-<tag>-unsigned.ipa           （如启用）
XDRemux-macOS-<tag>.dmg
XDRemux-Linux-<tag>-x64.AppImage
XDRemux-Linux-<tag>-x64.tar.gz
XDRemux-Linux-<tag>-x64.sha256
XDRemux-HarmonyOS-<tag>-unsigned.hap     （本地构建，见 §3.5）
```

`<tag>` 含 pre-release 后缀（如 `0.3.0-pre.1`）。资产名即 `TAG_VERSION` 变量拼接，改名需同时改 release.yml 的 path 声明。

## 3. CI job 概览

| Job | Runner | 产物 |
|---|---|---|
| Windows installer | windows-2022 | x64 Setup.exe（x265 缓存 + NASM） |
| Windows ARM64 | windows-11-arm | arm64 Setup.exe（x265 无汇编） |
| Android | ubuntu-latest | APK（SDK 36 / build-tools 36.0.0） |
| macOS | macos-latest | DMG |
| iOS | xcode-27，显式选 Xcode 27.1 | unsigned IPA（编译前验证 Duo API，打包前校验所有 Dart FFI 符号） |
| Linux | ubuntu-22.04（复用 linux.yml） | x64 AppImage / tar.gz / sha256（预览） |
| publish | ubuntu-latest | 汇总挂载（`needs` 含全部构建 job） |

macOS / iOS 已纳入 CI；Windows ARM64 为实验性且非发布阻塞，x265 按 runner 实际 VS 版本选择 CMake 生成器。

`publish` 要求 **windows / android / macos / ios / linux 全部成功**，并额外校验各类产物文件都已落地，缺任何一个都不创建 Release（Windows ARM64 因 `continue-on-error` 不参与 gate）。如果 macOS/iOS 因托管 runner 容量被取消，tag 会存在但没有 Release：先重跑失败 job，再 `Re-run all jobs`（被 `needs` 跳过的 publish 不会被“重跑失败 job”带走）。

### 3.1 只构建的发版预检

在实际准备分支上运行 `release.yml` 的 `workflow_dispatch`，`platforms=all` 构建五平台，`platforms=ios` 只构建 iOS；`publish` 仍受 tag ref 门禁保护。不要为了预检创建 `v*` 标签。

iOS 使用 `xcode-27` 预览 runner，并显式设置 `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer`；该镜像默认仍可能是 27.0，不能只换 runner 名字。`tools/apple/check_ios_sdk.sh` 校验 iPhoneOS SDK >= 27.1，并实际 typecheck `verticalBarEdge` / leading / trailing。应用最低部署目标仍为 iOS 15.0。若 runner 排队或缺少该 Xcode，停止该平台预检，使用装有新 SDK 的 Mac 完成归档，不删除 Duo 代码、不用旧 SDK 伪造成功。

Linux 使用 `workflow_call` 复用构建；tag 后缀用于资产命名，并核对源码版本。独立 Linux 手动上传 job 不会在 Release 调用时执行；统一附件由 `publish` 汇总上传。Flutter OHOS 仍需 §3.5 的本地出包，CI 的 OHOS Rust smoke 不等于 HAP 验收。

## 3.5 鸿蒙 hap（本地发布流程）

鸿蒙不进 CI（见 `operations/ci.md` §2.5）。本地发布：

1. `bash xdremux/rust/build_ohos.sh` 构建 Rust 核心，产物拷到 `apps/flutter/ohos/entry/libs/arm64-v8a/`
2. `tools/ohos/build_hap.ps1 -Profile`（**PowerShell**，必须显式使用 profile；无参数是 debug/JIT）
3. 取签名构建的 `entry-default-unsigned.hap` 中间产物作为公开包（hap 签名是 zip 块，unsigned 中间产物可直接被侧载工具签名）
4. 手动挂到 Release 资产

侧载规则：Development Profile 只能签 `app.debug: true` 的包——所以发布用 profile 模式（AOT + debug:true）；release 模式包（debug:false）侧载工具全拒。安装方式：DevEco 自动签名构建，或 hap-sign-tool 自备 AGC 证书。

## 4. 历史踩坑（排障索引）

- JVM target 不一致（`compileReleaseJavaWithJavac (11) vs Kotlin (17)`）-> 分插件对齐（`f258f3e`）
- Android API 37 缺失 -> 锁 SDK 36（`27e8094`）
- Windows ARM runner 的 x265 汇编不支持 -> `-DENABLE_ASSEMBLY=OFF`（`d24aecc`）
- publish job 漏 needs windows-arm64 -> pre.2 缺 ARM64 包（`0eb097b` 修）
- Release 失败但 tag 已推：**先征得维护者同意再移动 tag**（v0.3.0 曾强移到修复提交）
- v0.4.4：托管 macOS arm64 runner 容量不足，iOS job 排队 15 分钟后被判 `The job was not acquired by Runner of type hosted`，而 publish 当时只 gate windows+android，于是 Release 缺 iOS IPA。补救方式：本机用同一 Flutter/Xcode 线 `flutter build ipa --release --no-codesign`，校验 Dart FFI 符号后打包上传到已有 Release；同时给 publish 加上 macOS/iOS 成功门禁与产物校验（见 §3）。
- v0.4.4：Windows ARM64 job 用 `architecture: arm64` 请求 Flutter SDK 会在 setup 阶段 4 秒失败（`Unable to determine Flutter version ... architecture: arm64`），说明上游没有该版本的 Windows ARM64 SDK；`continue-on-error` 保证不阻塞发布。

## 5. 发版后验证

1. 下载每个资产：能安装/打开
2. Android 装真机跑一次完整工作流（含水印恢复）
3. 更新检查机制（`/releases/latest`）确认新版本被发现（pre-release 应被跳过）
4. 在 GitHub Release 页面把预写的说明文案校对一遍
