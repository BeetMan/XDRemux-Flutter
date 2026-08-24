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
| **烘焙边框型**（Hasselblad 大师模式等） | 仅 `watermark.params` / `watermark.color` / `watermark.device` / `watermark.master.params`，**无 PNG** | 边框带检测回退 |

判定顺序：先试 PNG 载荷路径，失败（缺条目或几何不匹配）则回退到边框带检测。两条路径都失败时**整体失败关闭**，绝不猜测。

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

**闭环验证**（Find X8 Ultra 大师模式样张）：边框和文字在 WIC（28/171 视角）和 heif-oxide（16/180 视角）两种解码器下都与原图逐像素一致，同时照片区域保留 iPhone 编辑。这正是 limited+full 标记约定的好处：两种解码器行为都被复现。

## 6. 与写回管线的衔接

`restore_visible_watermark`（watermark_codec.rs）整体流程：

1. 解码 donor 与回传文件（尺寸不一致 → 失败关闭）
2. 优先 PNG 载荷路径：`watermark_canvas_rect` → 复制画布区
3. 回退边框带检测：`detect_frame_bands` → 复制带区
4. 合成光栅 → 512×512 tile → `x265_encode_tiles_oppo_sdr`（4:2:0）
5. `rewrite_primary_grid`：追加新 tile、新 grid item、pitm 切换、iloc/idat/iref 重建
6. 剥离旧 footer → 追加恢复的 OPPO 完整尾部

新 tile 的关联属性（ipma）继承回传文件首 tile 模板并替换 hvcC；新 grid 继承回传文件的 grid 模板。继承的 nclx colr（BT.601、full-range=1）与上述编码约定一致，无需改写。
