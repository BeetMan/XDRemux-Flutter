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

## 6. 写入端校验（tmap 前置检查）

tmap 是定点有理数载荷，**写不出「范围反了」这种东西的修复版本**：一旦 `gain_map_max < gain_map_min` 被写进去，读者只能得到错误的 HDR 头room。因此校验必须在写入之前、且在比値域（ratio 域）完成，而不是靠读回检查。

`iso21496.rs` 的两个入口：

- `validate_uhdr_gain_parameters()`：把 20-float UHDR info 转成 ISO 元数据之前校验逐通道参数。规则（对齐上游 21Z121Z1/XDRemux 的 `canonical_channel_values`）：`ratio_min`、`ratio_max` 有限且 `> 0`；**`ratio_max < ratio_min` 即拒绝**（reversed per-channel gain range，2026-10-15 上游修复项）；`gamma` 有限且 `> 0`；offset 必须有限。
- `validate_iso_meta()`：对已组装的 `IsoMeta`（log 域）再校验不变量：通道字段长度 ≥ `channel_count`；逐通道 `gain_map_max ≥ gain_map_min`；`gamma > 0`；headroom 与 scale 有限。供构造路径和外部调用方（如测试、写回路径）复用。

边界语义（**比上游更宽松**，因为本移植要兼容"未设置"的零值块）：

| 输入 | 结果 | 原因 |
|---|---|---|
| 两个正数且 `max < min`（任一通道） | 拒绝 | 写出的 tmap 上限低于下限，读取端判为无效（上游 8844899c 的核心修复） |
| `min == max` | 接受 | 「不额外提亮」是合法配置 |
| `min < max`，含 `min < 1`（如 0.5 → 1.0） | 接受 | 增益可小于 1，表示压暗 |
| `ratio` 为 `0` 或负数（非有限除外） | 接受，按"未设置"透传（`safe_log2 → 0`） | OPPO 源与合成 HDR 路径会带全零 20-float 块；历史上就按 no-boost 处理 |
| `ratio` / `gamma` / `offset` 为 NaN / Inf | 拒绝 | 无法编码为有理数，静默归零会掩盖错误 |
| `gamma = 0` | 接受，原样透传 | 同上，历史"未设置"语义；负 gamma 拒绝 |
| `display_ratio_hdr < 1` | 接受，`hdr_capacity_max` 钳到 0 | 对齐上游 `max(ratio, 1.0)` 后再取 log2 的做法 |

> 2026-10-25 的教训：最初按上游严格度要求 `ratio > 0`，CI 的 `synthesize_bakes_exif_orientation_into_primary_and_gain_map` 立刻失败——该测试用 `vec![0.0; 20]` 合成 UHDR 容器。移植上游校验时必须先确认本仓支持的"零值=未设置"路径，否则会把合法输入拦死。

JPEG 导入侧（`jpeg_gainmap_metadata.rs::validate`）早已有同样的反序检查（`f[4 + c] < f[c]`），本次补齐的是 **OPPO UHDR / LHDR 构造侧**；两条路径现在共用同一套"反序拒绝"语义。

校验失败时的行为：UHDR 构造在 `isobmff_write.rs` 的 `map_err("UHDR metadata: …")` 处返回可见错误，队列显示该任务失败并可重试，不会产出半成品 tmap。


