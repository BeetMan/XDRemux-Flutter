# 发版流程

> 触发：推送 `v*` tag 到 GitHub -> `release.yml` 全自动构建四平台产物并挂到 Release。
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
XDRemux-macOS-<tag>.dmg                  （本地构建，未进 CI）
```

`<tag>` 含 pre-release 后缀（如 `0.3.0-pre.1`）。资产名即 `TAG_VERSION` 变量拼接，改名需同时改 release.yml 的 path 声明。

## 3. CI job 概览

| Job | Runner | 产物 |
|---|---|---|
| Windows installer | windows-2022 | x64 Setup.exe（x265 缓存 + NASM） |
| Windows ARM64 | windows-11-arm | arm64 Setup.exe（x265 无汇编） |
| Android | ubuntu-latest | APK（SDK 36 / build-tools 36.0.0） |
| publish | ubuntu-latest | 汇总挂载 |

macOS DMG 待纳入 CI（backlog）。

## 4. 历史踩坑（排障索引）

- JVM target 不一致（`compileReleaseJavaWithJavac (11) vs Kotlin (17)`）-> 分插件对齐（`f258f3e`）
- Android API 37 缺失 -> 锁 SDK 36（`27e8094`）
- Windows ARM runner 的 x265 汇编不支持 -> `-DENABLE_ASSEMBLY=OFF`（`d24aecc`）
- Release 失败但 tag 已推：**先征得维护者同意再移动 tag**（v0.3.0 曾强移到修复提交）

## 5. 发版后验证

1. 下载每个资产：能安装/打开
2. Android 装真机跑一次完整工作流（含水印恢复）
3. 更新检查机制（`/releases/latest`）确认新版本被发现（pre-release 应被跳过）
4. 在 GitHub Release 页面把预写的说明文案校对一遍
