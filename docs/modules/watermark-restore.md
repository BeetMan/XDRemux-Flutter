# 水印恢复模块（watermark_codec）

> 对应代码：`xdremux/rust/src/watermark_codec.rs`（核心）、`container.rs`（几何函数）、`hevc.rs`（编码）。
> 格式知识与校准数据见 `docs/formats/oppo-watermark.md`，本页只讲模块结构与不变量。

## 1. API 面

| 函数 | 职责 |
|---|---|
| `restore_visible_watermark(donor, returned, ...) -> Result<(Vec<u8>, Report)>` | 入口：解码、合成、重编码、容器重建 |
| `detect_frame_bands(rgba, w, h) -> Result<Vec<(u32,u32)>>` | 边框带检测（pub，探针可用） |
| `container::watermark_canvas_rect` | PNG 载荷型画布矩形（含 inset） |
| `container::watermark_overlay_rect` | PNG 实际覆盖矩形（蒙版用） |
| `rewrite_primary_grid(source, rgb, w, h) -> Result<Vec<u8>>` | 新 tile/grid 替换主图（通用容器手术） |

## 2. restore_visible_watermark 流程与不变量

```
1. 解码 donor + returned；尺寸不一致 -> Err（失败关闭）
2. 水印区域判定：
   PNG 载荷路径（watermark + watermark.config 存在且几何自洽）
     -> 画布矩形复制
   否则回退 detect_frame_bands
     -> 行区间整带复制
   两者都失败 -> Err
3. 合成光栅 -> 512×512 tile -> x265_encode_tiles_oppo_sdr（4:2:0）
4. rewrite_primary_grid：追加 tile payload 到 mdat、新 tile/grid infe、
   pitm 指向新 grid、iloc（新 tile construction_method=0，grid 走 idat）、
   iref 更新（旧主图引用改指新 grid + 新 dimg）、ipma 继承模板属性
5. 剥离旧 footer -> 追加 donor 完整 OPPO 尾部
```

不变量（改动时自检）：

1. **编码约定唯一**：本模块的重编码必须走 `x265_encode_tiles_oppo_sdr`（BT.601 limited 数据 + full 标记），否则水印渲染观感与原图不一致
2. **属性继承**：新 tile 关联属性 = 回传文件首 tile 模板（剔除旧 hvcC，push 新 hvcC）；新 grid = 回传 grid 模板。继承的 nclx 与编码约定一致，勿改
3. **tile 0 带参数集**：hvcC 从 tile 0 流提取（VPS/SPS/PPS 只出现一次，`repeat-headers=0`），`extract_hvcc_config_with_chroma` 的 chroma 参数必须与实际码流一致
4. **失败关闭**：任何几何不自洽（PNG 尺寸≠配置尺寸、宽度约束不满足、四角框色不一致）直接 Err，不输出"尽力而为"的结果

## 3. rewrite_primary_grid 的通用性

它不感知水印语义，只做"把一个新栅格以 tile grid 形式替换主图"的容器手术。除水印恢复外，凡需要替换主图像素的路径（未来的蒙版恢复等）都可复用。注意它假设 primary 是 image grid 且 tile 关联属性可从首 tile 模板复制。

## 4. 测试与探针

- 探针：`wb_probe`（端到端写回 + JSON 报告）、`wb_bands_probe`（边框带检测 + 合成预演）、`tile_stream_probe`（编码范围标记验证）、`tail_dump`（尾部条目转储）
- 验证方法：双解码器对照（WIC + heif-oxide）见 `docs/formats/hevc-hevc-conventions.md` §5
- 真机回归：ColorOS 相册 + Windows 照片双端查看（边框灰度与文字柔和度必须与原图一致）
