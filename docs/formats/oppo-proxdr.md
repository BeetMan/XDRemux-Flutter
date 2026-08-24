# OPPO ProXDR HEIC 格式

> 对应代码：`xdremux/rust/src/container.rs`（tail/QTI/LHDR 提取）、`edr.rs`、`exif.rs`。
> 无公开规范，全部结论来自 OPPO / OnePlus / realme 真机样张逆向（覆盖 Ace 3、Find X6 Pro、Find X7 Ultra、Find X8 Ultra 等）。

## 1. 文件整体结构

```
ftyp
meta（ISO 标准 HEIF：grid + hvc1 tiles + Exif + colr(ICC P3)）
free
mdat（主图 tile 码流）
QTI / QTI Debug box（高通调试标记，值 144.0 的 f32 LE 用于定位）
…（LHDR 扩展区：meta 144 字节 + "PADDING" + manifest JSON）
私有尾部：[entry payloads] + NUL + vendor tag + manifest 长度(u32)
```

OPPO 相机 HEIC 的主图是标准 ISO HEIF（tile grid），其 HDR 能力不在容器标准结构里，而在文件尾部的私有扩展区。

## 2. 私有尾部（tail）结构

从 EOF 向前解析：footer = NUL + vendor tag + manifest 长度。manifest 是 JSON 数组：

```json
[{"name":"basictone.info","offset":N,"length":N}, ...]
```

`offset` 是相对 manifest JSON 起点向回推的距离。每个 entry 按 name 寻址，payload 任意二进制。

**LHDR 扩展区布局**：`[meta_bytes: 144]["PADDING": 7 字节][manifest_json]`。meta 144 字节是 36 个 f32（EDR 参数等，`meta_floats`）。家族分类由 meta 内容决定：x6（早期 LHDR）/ x7（现代 UHDR / LHDR v3+）。

## 3. 两代 HDR 表示

| 代际 | 判定 | 增益映射来源 |
|---|---|---|
| **UHDR**（x7） | 尾部有 `local.uhdr.gainmap.info` + `local.uhdr.gainmap.data` | data entry 直接是增益映射（JPEG 载荷），info 是 20 个 f32 的参数块 |
| **LHDR**（x6/早期） | 无 UHDR 条目，走 QTI/LHDR meta 路径 | 灰度 mask（`mask_data`）按 EDR 曲线重建（见 `formats/iso-21496-1-gainmap.md`） |

`extract_lhdr_from_bytes` 的判定顺序：先查 UHDR 条目，缺则回退 LHDR meta 块定位。

## 4. 尾部条目分组

| 组 | 条目 |
|---|---|
| 私有 UHDR | `local.uhdr.gainmap.data`、`local.uhdr.gainmap.info` |
| HDR 显示 | `hdr.transform.data`、`src.local.hdr.linear.mask`（另含 basictone/filter） |
| 水印辅助 | `color.space`、`gr.effect.info`、`master.mode.preset.info`、`private.emptyspace` |
| 人像编辑 | `crop.region`、`front/rear.depth(+.config)`、`front.hair.mask`、`front.matter.info`、`front.negevimg`、`front.segment`、`mesh.coord(+.config)`、`rear.spotlight`、`src.image(.block)` |
| 水印本体 | `watermark(.config/.params/.color/.device/.master.params)`（见 oppo-watermark.md） |

## 5. OppoCameraTail 策略（FFI 值 0-9）

输出时保留哪些尾部条目的策略枚举：

| 值 | 策略 | 效果 |
|---|---|---|
| 0 | Off | 不写尾部 |
| 1 | Watermark | 仅水印相关 |
| 2 | Compact | 精简集 |
| 3 | Preserve | 完整保留 |
| 4 | PreserveWithoutPortrait | 去人像编辑条目 |
| 5 | PreserveWithoutPortraitOrPrivateHdr | 去人像 + 私有 HDR |
| 6 | PreserveWithoutPrivateUhdr | 去 `local.uhdr.*` |
| 7 | PreserveWithoutPrivateHdr | 去私有 HDR 条目 |
| 8 | PreserveNoUhdr | - |
| 9 | PreserveNoHdr | - |
| 255 | AUTOMATIC | 按输出模式选默认 |

默认策略（`default_for_compat`）：OPPO 兼容输出 -> `Preserve`；Apple 标准输出 -> `PreserveWithoutPrivateHdr`（干净 ISO）。

写回场景的变体（v0.3.1 系列）：`get_oppo_tail_without_display_adjustments`（水印恢复后去掉显示调整类条目，避免旧滤镜作用在新像素上）、`disable_apple_filter_recipe`。

## 6. 重建规则

尾部重建（写回/转换输出）时 payload 逐字节复制，只重算 manifest 偏移与 footer 长度。写回前必须 `strip_oppo_tail` 剥离回传文件自带的旧尾部，避免冲突（Apple 回传文件可能带不兼容的尾部结构）。
