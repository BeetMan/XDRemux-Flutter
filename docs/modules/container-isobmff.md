# ISOBMFF 容器层模块

> 对应代码：`isobmff.rs`（解析）、`isobmff_write.rs`（构造）、`watermark_codec.rs` 的 `rewrite_primary_grid`（容器手术）。约 20K 行核心中占最大比重的一层。

## 1. 解析（isobmff.rs）

- `parse_boxes(data, start, end)`：box 遍历（大小/类型/数据区间）
- `parse_source_meta(data)`：完整解析 meta 层 -> `items`（infe）、`iloc_entries`、`ipma_entries`（关联属性）、`refs`（iref）、`props`（ipco 原始属性）
- tail/QTI 定位逻辑在 `container.rs`（见 `formats/oppo-proxdr.md`）

设计：解析结果是**可回写的**--保留原始 box 字节（`raw_infe`、属性 `raw`），重建时能逐字节复制未改动的部分。

## 2. 构造（isobmff_write.rs）

box 工厂函数：`make_box`、`make_infe_box`、`make_iinf_box`、`make_iloc_box`、`make_iref_full_box`、`make_pitm_box`、`make_ipco/ipma` 等，以及静态 box 常量（`COLR_SRGB_BOX`、`COLR_BT2020_PQ_BOX`、`COLR_UNSPECIFIED_BT601_BOX`、`IROT_BOX`、`PIXI_*`）。

iloc 重建的关键：追加新 mdat 内容后，**所有 box 偏移重算**（meta 长度变化 -> mdat data_start 变化 -> 每个 entry 的 extent 绝对偏移平移）。

## 3. rewrite_primary_grid（容器手术模板）

"用新栅格（512×512 tile grid）替换主图"的通用手术，步骤与不变量：

1. 解析回传文件 meta；找到 primary（必须是 image grid）及其 dimg 引用的旧 tile 集合
2. 新 tile item（`hvc1`，construction_method=0，extent 指向 mdat 追加区）；新 grid item（走 idat，construction_method=1）
3. `pitm` 改指新 grid；旧 tile 的 hvcC 关联替换为新 hvcC（其余属性继承首 tile 模板）
4. iref：所有引用旧 primary 的条目改指新 grid；追加新 grid -> 新 tiles 的 dimg
5. 重建 iloc/iprp/iinf/idat/meta；尾部按序重排，mdat 偏移重算
6. 旧 grid/tile item 保留在文件里（孤儿化，不删除）--解码器按 pitm 走新图

约束：调用方保证新栅格尺寸与原 primary 一致（尺寸不一致在更上层就已失败关闭）。

## 4. 注意事项

- iref 的 version 沿用源文件（0/1 影响 item id 宽度）
- `grpl/altr` 组 ID 与 item ID 空间冲突：新增 item ID 必须越过最大组 ID（见 styles-pipeline §2.1）
- Box 偏移重算只处理 meta 与 mdat 之间的顶层 box；meta 内部相对偏移（iloc extent）单独重算
- 诊断探针：`styles_diag` 打印全量结构，是验证手术结果的首选工具
