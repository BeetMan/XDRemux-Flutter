# OPPO 水印格式与恢复

> 对应代码：`xdremux/rust/src/watermark_codec.rs`、`xdremux/rust/src/container.rs`（`watermark_canvas_rect` / `watermark_overlay_rect`）、macOS/iOS `AppleWatermarkTailBridge.swift`（研究路径，默认未启用）。
>
> 验证样本：OPPO Find X8 Ultra（PKJ110）标准水印样张、Hasselblad 大师模式边框水印样张（2026-08 验证）。

## 1. 概述

OPPO 相机的可见水印是**烘焙在主图像素里**的（不是渲染层叠加）。"恢复原机水印"意味着把 OPPO 原始照片（donor）中的水印区域像素移植到 iPhone 编辑后的回传照片上，然后按 OPPO 的编码约定重新编码。任何路径都不能直接修改 HEVC 字节，必须走 解码 → 合成 → 重新编码。

水印分两类，恢复路径不同：

| 类型 | 尾部条目 | 恢复路径 |
|---|---|---|
| **PNG 载荷型**（标准水印） | `watermark`（PNG）+ `watermark.config`（几何） | 画布矩形恢复 |
| **烘焙边框型**（Hasselblad 底栏、大师模式画框等） | 仅 `watermark.params` / `watermark.color` / `watermark.device` / `watermark.master.params`，**无 PNG** | 按存储的画面矩形恢复（§4.4），读不到时回退边框带检测（§4.1） |

判定顺序：先试 PNG 载荷路径；失败（缺条目或几何不匹配）则读 `watermark.master.params` 里的画面矩形；再失败则回退到边框带检测。三条路径都失败时**整体失败关闭**，绝不猜测。

只带 `watermark.device` 的文件没有可见水印，写回时不做恢复（`container::has_rendered_watermark`）。**已实测**（2026-11-17）：Find X10 关闭水印拍的原片只有这一个水印条目，主图是传感器的标准尺寸；此前这类文件也被当成有水印，两种输出模式的写回都以 `donor corners disagree` 失败。

## 2. OPPO 私有尾部（tail）

水印数据存放在 HEIF 容器末尾的私有尾部结构里，从 EOF 向前扫描解析。与水印相关的条目：

- `watermark`：PNG 图像载荷（仅标准水印存在）
- `watermark.config`：几何配置（见下节）
- `watermark.params`：水印参数
- `watermark.color` / `watermark.device`：颜色 / 机型文案数据
- `watermark.master.params`：大师模式布局描述（内部含 `hassel_style_master_mode_1` 等标记，体积可达 45KB，内嵌 JPEG `src.image` 条目与之配套）

一个典型的 Find X8 Ultra 大师模式样张会恢复全部 12 个尾部条目：`basictone.info`、`filter.info`、`hdr.transform.data`、`local.uhdr.gainmap.data`、`local.uhdr.gainmap.info`、`master.mode.preset.info`、`private.emptyspace`、`src.image`、`watermark.color`、`watermark.device`、`watermark.master.params`、`watermark.params`。

尾部重建时 payload 逐字节复制，只重算 manifest 偏移和总长（见 `AppleWatermarkTailBridge.repackedCompleteTail` 与 Rust 侧对应逻辑）。写回前必须剥离回传文件自带的旧 footer，避免新旧冲突。

## 3. PNG 载荷型：画布几何

`watermark.config` 至少 20 字节，小端读取：

| 偏移 | 字段 |
|---|---|
| +4 (u32le) | 配置宽（与 PNG IHDR 宽一致） |
| +8 (u32le) | 配置高（与 PNG IHDR 高一致） |
| +12 (u32le) | 左右 inset |
| +16 (u32le) | 上下 inset |

约束（任一不满足即失败关闭）：

```
配置宽 + 左右 inset × 2 == 图像宽
配置高 + 上下 inset × 2 ≤ 图像高
PNG 尺寸 == 配置尺寸
```

Find X7 Ultra 实测：PNG 3688×218，左右 inset 204、上下 inset 111 → 画布 4096×440。

两个矩形函数：

- `watermark_canvas_rect`：整个底栏画布（含 inset），`y = 图像高 − 画布高`。**注意白色背景属于主图像素**，只恢复 PNG 会把 Styles 处理过的背景留在文字后面，所以要恢复整个画布。
- `watermark_overlay_rect`：排除透明 inset 的 PNG 实际覆盖区，适合做像素蒙版，避免覆盖文字周围被编辑过的背景。

## 4. 烘焙边框型：边框带检测（`detect_frame_bands`）

烘焙边框型先按 §4.4 读存储的画面矩形，读不到时才用本节的检测。检测只能找到顶部和底部的整行条带：只有底栏的 `hassel_style_1` 四角颜色不一致，检测直接判失败；四边画框的左右边框不在任何条带里。

### 4.1 算法

对 donor（OPPO 原始照片）解码后的 RGBA 光栅操作：

1. **框色采样**：取四角内缩 8px 的像素，四角两两差超过 ±6 即判"非边框水印"失败。内缩是因为 HEVC 解码在图像极边缘可能有重建伪影（实测 OPPO 帧角落出现偏绿像素）。
2. **行判定**：每行按 16 像素步长采样，统计三通道都在框色 ±6 内的占比。**阈值 60%**：
   - 照片内容行实测 uniform 占比 ≤ 0.35
   - 边框文字行（稀疏字形铺在纯色框上）实测 ≥ 0.82
   - 60% 能同时穿过"大字标题行"（如 OPPO Find X8 Ultra，占比 ~0.83）和参数行
3. **边界扫描**：
   - 顶部：从 y=0 向下容忍最多 8 行非框行（解码伪影），之后连续框行直到 `height/4`
   - 底部：从 `height-1` 向上同样容忍 8 行伪影，之后连续框行直到 `height×3/4`
   - 每条带至少 16 行才算数
4. **返回** `(y0, y1)` 行区间列表，合成时把这些行整行从 donor 复制到回传光栅。

实测样张：顶带 (0, 673)、底带 (3746, 4420)。

### 4.2 校准数据（为什么是 60%/±6/8 行）

| 参数 | 值 | 依据 |
|---|---|---|
| uniform 阈值 | 60% | 照片行 ≤0.35 与文字行 ≥0.82 之间的分隔带 |
| 框色容差 | ±6 | 传感器噪声 + 重编码损失下框色稳定 |
| 边缘伪影容忍 | 8 行 | Find X8 Ultra 样张末行整行为绿色垃圾（HEVC 环路滤波边界效应） |
| 带高下限 | 16 行 | 过滤巧合的纯色行 |
| 扫描范围 | 上 1/4、下 1/4 | 边框水印几何上不会超过画面四分之一 |

### 4.3 `watermark.master.params` 末尾的几何块

条目最后 56 字节是 14 个小端 float，下面记作词 0 到词 13。**已实测**（2026-11-17 复核，35 个 HEIC 相机原片：`hassel_style_1` 14 个，`hassel_style_master_mode_1` 20 个，`hassel_style_4` 1 个。2026-11-16 记的 23 个大师模式原片里有 3 个是同一文件的副本）。

| 词 | 内容 |
|---|---|
| 0 | 画面下边。画框样式里与词 9 相同；`hassel_style_1` 有一张比词 9 大 2 |
| 1 | 竖幅画面里是画面右边，与词 8 相差不超过 1。横幅的大师模式画框里比词 8 大：主图 4268×4420 大 28，8532×8840 大 58，这个差值的含义**未验证**。所有原片里它都不小于「词 8 减 1」，也不超过主图宽 |
| 2 | 主图高 |
| 3、4 | 0 |
| 5 | `0xffffffff` |
| 6 到 9 | 画面矩形在主图里的四角：左、上、右、下 |
| 10 到 13 | 同一个矩形按传感器方向的四角。左、上与词 6、7 相同；宽高与词 6 到 9 的宽高相同或互换 |

- 词 6 到 9 是四角，不是 x、y、宽、高。边距对称时「左 + 右」也等于主图宽，单看这个和分不出两种读法。按四角读，画面都是传感器的标准尺寸。例：主图 3244×5444，四个数 86、674、3158、4770，画面是 3072×4096，左右各 86，上下各 674。
- 边距由样式模板的 dp 值换算：`px = int(dp × 画面短边 / 360)`，结果是奇数时加 1。`hassel_style_4` 和 `hassel_style_master_mode_1` 的边距是左右 10 dp、上下 79 dp；`hassel_style_1` 只有底边 60 dp。40 张原片（35 张 HEIC、5 张 JPG）里 39 张吻合，没吻合的一张是 `hassel_style_1`（`IMG20260822161054.heic`），底栏按公式是 614、实际 616。
- `hassel_style_4` 只有一张原片（`IMG20261011120934.heic`，前置人像，条目长 23487，主图 5200×8724）。14 个词是 7642、5064、8724、0、0、哨兵、136、1082、5064、7642、136、1082、6696、6010，布局与 `hassel_style_master_mode_1` 相同。

使用方：

- 读取和校验在 `container.rs::frame_picture_rect_in_params`：读词 6 到 9，换算成 (x, y, 宽, 高)。校验条件是词 0 在「下边」到「下边 + 2」之间，词 1 在「右边 − 1」到主图宽之间，词 2 等于主图高，词 3、4 为 0，词 5 是哨兵，画面不小于主图的一半且不等于整幅。
- 人像管线的 `portrait.rs::hassel_end_content_rect` 调用它，只认 `hassel_style_4` 和 `hassel_style_master_mode_1`；`hassel_style_1` 走自己的 14185 字节布局；其余样式按整幅处理。
- 水印恢复的 `watermark_codec.rs::stored_frame_picture_rect` 经 `container::watermark_frame_picture_rect` 调用它，认 `hassel_style_1`、`hassel_style_4`、`hassel_style_master_mode_1` 三种，见 §4.4。

### 4.4 按画面矩形恢复

`restore_watermark_canvas` 在 PNG 载荷路径失败后走这一步：

1. 读 §4.3 的画面矩形。样式不在三种之内、校验不过或矩形等于整幅时放弃，回退 §4.1。
2. 用原片像素确认：矩形以外按 16 列、8 行的步长采样，取出现最多的颜色当框色，至少 60% 的采样点落在框色 ±6 以内才采用。条目与像素对不上（例如图像在相机写入条目之后被改过）时放弃，回退 §4.1。
3. 把矩形以外的所有像素从原片复制到回传光栅，矩形以内不动。

**已实测**（2026-11-17）：

- 本机 35 张画框原片全部读到矩形并通过像素确认，框色占比 94.7% 到 99.1%。五张原片（三种样式、黑白两种框色）逐边核对，矩形的四条边都精确到像素。
- 同一批原片上 §4.1 的检测：14 张 `hassel_style_1` 全部失败；21 张四边画框只覆盖边框面积的 86% 到 92%，缺的是左右边框。
- 真实 iPhone 编辑件写回（`wb_probe`，heif-oxide 解码后逐像素比较，数值是各通道最大差的平均）：
  - `hassel_style_1`（原片 `IMG20260822161608.heic`，回传 `edit-ab-pairs/IMG_3731/IMG_E3731.heic`）：改动前两种输出模式都以 `donor corners disagree` 失败。改动后成功，底栏与原片差 0.03（回传件自身差 13.40），画面与回传件差 2.91。
  - `hassel_style_master_mode_1`（原片 `IMG20260819191729.heic`，回传 `iphone-styles-native/IMG_3506.HEIC`）：改动前上下条带与原片差 0.04，左右边框差 16.03，没有恢复。改动后左右边框差 0.37，画面与回传件差 1.84，前后相同。
- **未验证**：真机上的观感；`hassel_style_4` 的端到端写回（没有对应的回传件，只跑了矩形读取和像素确认）；三种以外的样式仍走 §4.1。

## 5. 编码约定（关键！）

**OPPO 相机 HEVC 存的是 limited-range BT.601 数据，但码流标记为 full-range（VUI `yuvj420p`），容器无 nclx。**

解码器按标记渲染这类文件时：

- 暗部被"提亮"：sRGB 16 → 渲染为 28
- 高光被压缩：sRGB 180 → 渲染为 171

即标准水印呈现"灰框软字"的观感。如果写回时用标准的全范围 BT.709 编码（数据本身"正确"），水印会渲染成更黑更硬的"黑框白字"，与原图并排立刻看出差异。

因此写回路径必须用 `x265_encode_tiles_oppo_sdr`（`hevc.rs`）：

- RGB → YUV 用 **BT.601 limited-range** 系数（`rgb_to_yuv444_limited601`）
- x265 参数：`range=full`、`colormatrix=smpte170m`、`colorprim=bt470bg`、`transfer=iec61966-2-1`
- tile 尺寸 512，CRF 14

**ImageIO 下的差异**（**已实测**，2026-11-17，macOS）：ImageIO 把相机原片的白色底栏解码成 254，把写回输出的同一块解码成 234，两种输出模式都是这样；heif-oxide 下两者一致。**推断**：原片没有 nclx、被 ImageIO 当作 limited 数据展开，而输出继承了回传件的 full-range nclx。**未验证**：这在 iPhone 相册里是否看得出来。

**闭环验证**（Find X8 Ultra 大师模式样张）：边框和文字在 WIC（28/171 视角）和 heif-oxide（16/180 视角）两种解码器下都与原图逐像素一致，同时照片区域保留 iPhone 编辑。这正是 limited+full 标记约定的好处：两种解码器行为都被复现。

## 6. 与写回管线的衔接

`restore_visible_watermark`（watermark_codec.rs）整体流程：

1. 解码 donor 与回传文件（尺寸不一致 → 失败关闭）
2. 优先 PNG 载荷路径：`watermark_canvas_rect` → 复制画布区
3. 其次读存储的画面矩形：`stored_frame_picture_rect` → 复制矩形以外的整圈边框（§4.4）
4. 回退边框带检测：`detect_frame_bands` → 复制带区
5. 合成光栅 → 512×512 tile → `x265_encode_tiles_oppo_sdr`（4:2:0）
6. `rewrite_primary_grid`：追加新 tile、新 grid item、pitm 切换、iloc/idat/iref 重建
7. 剥离旧 footer → 追加恢复的 OPPO 完整尾部

新 tile 的关联属性（ipma）继承回传文件首 tile 模板并替换 hvcC；新 grid 继承回传文件的 grid 模板。继承的 nclx colr（BT.601、full-range=1）与上述编码约定一致，无需改写。
