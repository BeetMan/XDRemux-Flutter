# ISO 21496-1 增益映射

> 对应代码：`gainmap.rs`（像素重建，Swift XDRemux 移植）、`iso21496.rs`（元数据构造）。
> 标准文本翻译见 `docs/standards/ISO_21496-1_2025_zh.md`。本页只写实现相关的事实。

## 1. 转换任务

OPPO ProXDR 的 HDR 表示（UHDR JPEG 增益映射 / LHDR 灰度 mask）-> 标准 ISO 21496-1：

```
UHDR 路径:  local.uhdr.gainmap.data (JPEG) --解码--> 增益映射像素
            local.uhdr.gainmap.info (20 f32) --> ISO 元数据
LHDR 路径:  灰度 mask + EDR 参数 --曲线重建--> 增益映射像素
            meta_floats[36] --> ISO 元数据
```

产出：tmap item（元数据）+ 增益映射图 item（低分辨率灰度/单色 HEVC，独立 tile grid）。

## 2. LHDR mask 重建（`gainmap.rs`）

- `gain_map_params(edr_scale, edr_version) -> GainMapParams`：按 EDR 版本选择重建参数
- `get_knee_point(edr) -> f32`：膝点曲线
- `reconstruct(mask, w, h, stride, edr_scale, edr_version)`：灰度 mask 逐像素映射为增益映射 u8；`reconstruct_tight` 是无 stride 的便捷封装

移植自 Swift 上游（XDRemux），数值行为需与上游一致（conformance 对拍）。

## 3. UHDR info（`iso21496.rs`）

`OppoUhdrInfo`：解析/反向构造 20-float 的 UHDR info 块。`IsoMeta` 是 ISO 21496-1 元数据结构，序列化为 tmap item 的 62 字节载荷。

## 4. 增益映射图的编码约束（重要）

- **单色**：走 i400 / `main444-8` profile。4:4:4"伪彩色"码流会被 Android 增益映射路径拒绝
- OPPO 兼容输出要求 4:2:0（图库识别）：显式传 `use_420=true`，**禁止内部读环境变量决定平面布局**（见 hevc-conventions.md §4.1 事故）
- tile 0 携带参数集、其余纯 IDR slice；hvcC 提取时 chroma format 必须与码流一致（ImageIO 从 hvcC 读配置，每个 tile 带参数集会被拒绝）
- 批量编码复用单一 encoder 实例（keyint=1 每 tile 独立关键帧，~5x 加速）

## 5. 写回侧的增益映射处理

回传文件（Apple 导出）自带 tmap + 增益映射图：写回时**保留其图结构**（v0.3.1 `retain returned HDR gain-map graph`），只替换主图像素。OPPO 兼容输出还会恢复 OPPO 私有 UHDR 尾部条目（原始增益映射数据），两组数据并存时的去冲突策略见 `oppo-proxdr.md` §5 的显示调整剥离规则。
