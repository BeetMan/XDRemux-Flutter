# 水印恢复模块（watermark_codec）

> 对应代码：`xdremux/rust/src/watermark_codec.rs`（核心）、`container.rs`（几何函数）、`hevc.rs`（编码）。
> 格式知识与校准数据见 `docs/formats/oppo-watermark.md`，本页只讲模块结构与不变量。

## 1. API 面

| 函数 | 职责 |
|---|---|
| `restore_on_donor_graph(donor, returned) -> Result<Vec<u8>, String>` | **生产入口**（`lib.rs` 写回路径调用）：解码、尺寸校验、合成、原地重编码主图；保留回传文件的主图 ID 与 tmap/增益图引用图 |
| `restore_visible_watermark(donor, returned) -> Result<Vec<u8>, String>` | 另一入口：同样合成后原地重写；写回主路径不调用 |
| `restore_watermark_canvas(...)` | 合成：PNG 载荷画布 → 存储的画面矩形 → 边框带，依次尝试 |
| `stored_frame_picture_rect(donor, rgba, w, h) -> Option<(x, y, w, h)>` | 画框样式存储的画面矩形，并用原片像素确认矩形外是纯色边框（pub，探针可用） |
| `detect_frame_bands(rgba, w, h) -> Result<Vec<(u32,u32)>>` | 边框带检测（pub，探针可用） |
| `container::watermark_frame_picture_rect` | 从 `watermark.master.params` 读画面矩形，只认三种核对过的样式 |
| `container::has_rendered_watermark` | 原片是否有烘焙进像素的水印；只带 `watermark.device` 的不算，写回时跳过恢复 |
| `container::watermark_canvas_rect` | PNG 载荷型画布矩形（含 inset） |
| `container::watermark_overlay_rect` | PNG 实际覆盖矩形（蒙版用） |
| `rewrite_primary_grid_in_place(source, rgb, w, h, oppo_native_tmap)` | 原地替换主图 tile 码流，**不改主图 ID、不改 iref/iinf 图** |
| `rewrite_primary_grid(...)` | 旧的「新 tile/grid + pitm 切换」手术；自 `1689aab`（2026-08-21）起无调用方，仅保留定义 |

## 2. restore_on_donor_graph 流程与不变量

```
0. 调用方先剥离回传文件的 OPPO 尾部（container::strip_oppo_tail）；
   donor 没有烘焙水印（container::has_rendered_watermark 为假）时不进入本流程
1. 解码 donor + returned；尺寸不一致 -> Err（失败关闭）
2. 水印区域判定：
   PNG 载荷路径（watermark + watermark.config 存在且几何自洽）
     -> 画布矩形复制
   否则读存储的画面矩形（stored_frame_picture_rect）
     -> 矩形以外的整圈边框复制
   否则回退 detect_frame_bands
     -> 行区间整带复制
   三者都失败 -> Err
3. 合成光栅 -> 512×512 tile -> x265_encode_tiles_oppo_sdr（4:2:0）
4. rewrite_primary_grid_in_place：新 tile 数必须等于原 grid 的 tile 数；
   沿用原 tile item ID，iloc 改指新码流，首 tile 模板的 hvcC 属性换成新 hvcC；
   iinf / iref 原样保留（Photos 缩略图渲染器靠这些关系找 OPPO 水印叠层，
   回传文件的 tmap/增益图挂在主图 ID 上）；oppo_native_tmap=true 时把 idat 中
   62 字节的 Apple tmap 换成 OPPO 原生 tmap 载荷
5. 调用方（lib.rs）剥离旧增益图（strip_existing_gain_map_graph）并追加 donor 完整 OPPO 尾部
```

不变量（改动时自检）：

1. **编码约定唯一**：本模块的重编码必须走 `x265_encode_tiles_oppo_sdr`（BT.601 limited 数据 + full 标记），否则水印渲染观感与原图不一致
2. **属性继承**：只替换首 tile 模板关联的 hvcC 属性，其余属性与 grid 原样保留。继承的 nclx 与编码约定一致，勿改
3. **图不动**：主图 ID、iref、iinf 不变；不要改回切 pitm 的旧手术，否则 tmap 引用与水印叠层会断
4. **tile 0 带参数集**：hvcC 从 tile 0 流提取（VPS/SPS/PPS 只出现一次，`repeat-headers=0`），`extract_hvcc_config_with_chroma` 的 chroma 参数必须与实际码流一致
5. **失败关闭**：任何几何不自洽（PNG 尺寸≠配置尺寸、宽度约束不满足、四角框色不一致）直接 Err，不输出"尽力而为"的结果。存储的画面矩形与像素对不上时不采用，交给边框带检测，后者失败同样 Err

## 3. 原地重写的通用性

`rewrite_primary_grid_in_place` 不感知水印语义，只做"用同尺寸新栅格替换主图 tile 码流"。凡需要替换主图像素且必须保留引用图的路径都可复用。前提：primary 是 image grid、新栅格与原 grid 同尺寸同 tile 数。旧的 `rewrite_primary_grid`（新 grid + pitm 切换、旧 item 孤儿化）会让挂在旧主图 ID 上的 tmap 引用失效，已不再使用。

## 4. 测试与探针

- 单元测试：`watermark_codec_tests.rs`（四边画框、只有底栏、黑色边框、条目与像素不符、未核对的样式）
- 探针：`wb_probe`（端到端写回 + JSON 报告）、`wm_frame_probe`（画面矩形、边框带、实测边缘三者对照；`--verify` 比较写回输出与原片、回传件）、`wb_bands_probe`（边框带检测 + 合成预演）、`tile_stream_probe`（编码范围标记验证）、`tail_dump`（尾部条目转储）
- 验证方法：双解码器对照（WIC + heif-oxide）见 `docs/formats/hevc-hevc-conventions.md` §5
- 真机回归：ColorOS 相册 + Windows 照片双端查看（边框灰度与文字柔和度必须与原图一致）
