# 当前开发状态（2026-11-28）

主线基准为 `866512f`。Flutter 与原生 Apple 的发布标签之后，主线仅更新了 README。上一次分支盘点见 [11 月 24 日快照](../archive/current-status-20261124.md)。

## 已发布版本

| 版本线 | 发布 | 安装包与构建记录 |
|---|---|---|
| Flutter 跨平台版 | [v0.4.8（0.4.8+42），Latest](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/v0.4.8) · `01f0951` | Windows x64、macOS Apple Silicon、Android、iOS、Linux x64 和 HarmonyOS。macOS 的 `XDRemux Flutter.app` 使用 ad-hoc 签名。Windows ARM64 实验构建未产出安装包。[发布 CI](https://github.com/BeetMan/XDRemux-Flutter/actions/runs/46130014569) |
| 原生 Apple（SwiftUI） | [apple-v0.1.2，预发布](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/apple-v0.1.2) · `01f0951` | macOS DMG 已做 Developer ID 签名与公证，iOS 附未签名 IPA。TestFlight 0.1.2 构建 9 已上传，仓库尚无处理完成或安装验收记录。[Apple 构建记录](../plans/apple-native.md) |
| 鸿蒙原生（ArkUI） | [harmony-v0.5.5](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.5) · `acf1307` | 未签名 HAP，需开发签名侧载，与 Flutter HAP 分别发布。[安装与侧载](installing.md) |

## 主线能力与在审改动

- **HDR 增益图。** #135 修复鸿蒙三通道增益图的 4:2:0 编码路径。#137 移除「严格 ISO tmap」开关。产品写出的单通道、三通道 HEIF `tmap` 分别为 62、142 字节，均含 1 字节 HEIF 版本字段。
- **摄影风格。** 已转换的 ISO HDR HEIC 可追加风格 2 或 3，已有风格 2 的照片可升级到风格 3，均保留原有 HDR 增益图。重复写入风格 2 会被拒绝。Apple 的风格实况按视频帧生成缩略图与色调曲线，已有 macOS「照片」编辑、保存和重开的样本记录。[逐帧风格 #130](https://github.com/BeetMan/XDRemux-Flutter/pull/130)
- **OPPO 人像与动态照片。** ColorOS 17.24 的人像几何、拆分 MP4 的厂商尾部裁剪及大师水印画框还原已随 #127、#128 发布。唯一开放的 PR 是详情页展示 OPPO 私有尾部数据，此功能待审。[PR #129](https://github.com/BeetMan/XDRemux-Flutter/pull/129)

## 已知问题与维护重点

1. **OPPO 增益图 gamma。** 源元数据的 20 个浮点数全为零时，转换路径会把零 gamma 写入 HDR 元数据。下个补丁应将这种未设值还原为 1，并覆盖该输入。
2. **一致性检查工具。** `make_iso21496_metadata_payload` 在 flags 后多写 3 个填充字节，相关测试也按 64 / 144 字节断言。应将工具和断言对齐到 61 / 141 字节的裸元数据，再与产品封装后的 62 / 142 字节分别比对。[序列化实现](../../xdremux/rust/src/iso21496.rs) · [检查工具](../../tests/conformance/src/inspect.rs)
3. **Apple 分发与真机验收。** SwiftUI 发布包和 TestFlight 构建包含 VideoToolbox 与 x265。公开测试前仍需明确 x265 分发许可，并补传输框架的 dSYM。iPhone 上的逐帧风格实况编辑和 HDR 缩略图 A/B 验收待补。[分发计划](../plans/apple-drop-x265.md) · [真机验收项目](../testing/styles-hdr-device-checklist.md)
4. **覆盖已有静帧。** Live Photo 配对与 PVT 已支持写入失败回滚。普通静帧仍有先删旧输出再转换的路径，失败时可能丢失之前生成的静帧。[输出契约](../architecture/ffi-contract.md)

## 维护入口

[构建](building.md) · [CI 覆盖](ci.md) · [发版流程](releasing.md) · [平台行为矩阵](../validation/platform-behavior-matrix.md) · [上游研究与待接入项](../research/upstream-20261115.md)
