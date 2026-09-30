# 设备兼容矩阵（随样本到达增量登记）

> 模式：不做专门的大批量采集；每收到一个用户反馈/实测样本，跑一遍
> 转换 + 水印恢复检查，登记到此表。defensive 解析 + 失败关闭设计兜底。
> 来源依据：v0.4 roadmap「OPPO/Apple 颜色与继续编辑兼容性（多样本）」
> 已降级为增量验证（3bf2747）。

## 已验证设备

| 设备 | 固件/批次 | 样本数 | 转换 | 水印条目 | GPS | UserComment 补丁 | 备注 |
|---|---|---|---|---|---|---|---|
| OPPO Find X8 Ultra | 现款（2026-08/09） | 多张（含 5 张动态照片 + 1 张定位样本） | ✅ | ✅ | ✅ 真实坐标逐值一致（22.767672, 113.893064，2026-09-06） | ✅（源已带 UHDR 位时幂等） | Orientation=1；UserComment 带 `ASCII\0\0\0` 前缀；顶层 `QTI` box + 私有尾部 |
| OnePlus 12 | 早期固件（2023-12 批次） | 15 | ✅ 3 张抽测 | ✅ 15/15 检测 + 几何校验 | ✅ 8 条目保留 | ✅ `oplus_1441792`→`oplus_538312704` | Orientation=1；**UserComment 无 ASCII 前缀**（更老格式）；两种分辨率 4608×3952 / 4096×3512 均通过；源不带 UHDR 路由位（0x160000/0x160400） |
| OnePlus 12 | 新固件动态照片（2024-10） | 5 张 Live JPEG | ✅ 5/5 端到端（拆静帧→转换） | - | - | - | 单码流（LPEX v0）；静帧全为 Ultra HDR JPEG（hdrgm+MPF）；与 X8 Ultra 的双码流（LPEX v1+）不同 |
| OnePlus 13 | 早期固件动态照片（2024-11） | 14 张 Live JPEG | ✅ 14/14 端到端 | - | - | - | 同上，LPEX v0 额外带 `frameInterpolationInfo`；全部 androidXMP 时间戳 |

## Huawei / Apple 0.4.3 验证（2026-09-30）

| 输入/运行环境 | 验证依据 | 当前结论 |
|---|---|---|
| Mate 70 Pro 优享版 PLR-AL50：9 张 HDR | 本地 opt-in Rust corpus | 识别并保留原生 ISO gain-map；默认无需转换 |
| Mate 70：4 张人像 HEIC | 本地 Rust 核心 + C FFI 重封装、嵌套目录、风格层及人像图检查 | 通过，FFI 与核心输出逐字节一致；竖/横构图均覆盖 |
| Mate 70：3 张 OpenHarmony 动态 HEIC | 本地 Rust 检测/拆分/配对；Flutter 真实 FFI 同目录重试 | 通过，输出配对标识一致，源文件未修改 |
| iPhone Air / iOS 27 | 2026-09-29 已归档的五对 Live Photo 对照验证 | 已识别单一 Live Photo；不是本轮 Windows 主机重复验收 |
| OHOS 应用 | 用户 2026-09-30 验证最新本机构建 | 用户反馈功能正常；本轮构建另行登记 |
| Windows x64 应用 | 本轮 release 编译、57 项 Flutter 测试和 FFI 符号/版本检查 | 通过 |
| Android / macOS / iOS 发布包 | 与上述相同 Rust 逻辑；云端完整构建待记录 | 不将静态逻辑核对等同于设备端安装验收 |

范围限制：其他华为系列机型没有逐机型背书；XMAGE v5/v6 只读诊断；图库保存/单文件分享并非系统 Live Photo 资产导入。

## 已知设备特定问题（OPPO）

| 设备 | 问题 | 状态 |
|---|---|---|
| OPPO X9s Pro | 导出 HEIC 的 EXIF Orientation=0（非法值）、无 `irot`；旧版 Rust 直接报错导致转换失败 | ✅ 已修复（fdce1c0：越界值钳位为 Normal，对齐 ImageIO/Swift 行为）；待原图复核 |
