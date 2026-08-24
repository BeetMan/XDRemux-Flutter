# HEIF/HEVC 色彩约定实测手册

> 对应代码：`xdremux/rust/src/hevc.rs`。本页记录各厂商 HEIC 文件在 YUV 范围、矩阵、传输函数上的**实测**约定，以及本项目编码时必须遵守的规则。所有结论来自真实样张逆向（OPPO Find X8 Ultra / Find X7 Ultra、Apple iPhone 导出文件），无公开规范可依。

## 1. 核心事实：范围标记与实际数据可以不一致

HEVC SPS VUI 的 `video_full_range_flag` 声明数据范围，但**厂商文件并不总是自洽**。本项目遇到的真实约定：

| 来源 | 数据实际范围 | VUI/容器标记 | 后果 |
|---|---|---|---|
| OPPO 相机 HEIC | **limited**（BT.601） | **full**（`yuvj420p`），无 nclx，transfer = sRGB (`iec61966-2-1`)，primaries = `bt470bg` | 信任标记的解码器渲染出提亮暗部/压缩高光的"软"观感 |
| Apple 照片导出 | full（BT.709 系） | nclx full-range=1 + ICC（Display P3） | 各解码器渲染一致 |
| 本项目标准编码 | full（BT.709） | VUI bt709 + range=full | 数据正确但与 OPPO 原图并排时观感不同 |

推论：**"正确的数据"未必是"一致的观感"**。要复刻某厂商文件的显示效果，必须复刻它的数据表示（包括它的不一致），而不是复刻理论上正确的编码。

## 2. 双解码器验证法

写回输出必须同时在两种解码器下与原图一致才算通过：

- **WIC（Windows）**：信任 VUI/nclx 标记，代表真实图库行为
- **heif-oxide**：无 nclx 时默认按 limited 展开，代表另一类解码器行为

limited 数据 + full 标记的约定恰好让两种解码器都复现原图：

| 解码器 | 原图边框渲染 | 正确编码的输出 | OPPO 约定编码的输出 |
|---|---|---|---|
| WIC（信任标记） | 28 | 16 ✗ | 28 ✓ |
| heif-oxide（默认展开） | 16 | 0 ✗ | 16 ✓ |

用 ffprobe 可快速检查码流声明：`ffprobe -show_streams tile.h265` 看 `pix_fmt`（`yuvj420p` = full 标记）、`color_range`、`color_space`、`color_transfer`。

## 3. 本项目编码矩阵

`hevc.rs` 提供两条 RGB 编码路径：

### 3.1 标准路径（`x265_encode_tiles`，BT.709 full）

- 转换：`rgb_to_yuv444` / `rgb_to_yuv420`（BT.709 系数，全范围，无 16 偏移）
- x265：`range=full`、`colormatrix/colorprim/transfer=bt709`
- CRF 14、preset medium、`repeat-headers=0`、`keyint=1`
- 用于：增益映射、蒙版等中间产物

### 3.2 OPPO 约定路径（`x265_encode_tiles_oppo_sdr`，BT.601 limited）

- 转换：`rgb_to_yuv444_limited601` / `rgb_to_yuv420_limited601`：
  - `Y = 16 + (65.481R + 128.553G + 24.966B) / 255`
  - `U = 128 + (−37.797R − 74.203G + 112B) / 255`
  - `V = 128 + (112R − 93.786G − 18.214B) / 255`
- x265：`range=full`（**标记保持 full，数据是 limited**）、`colormatrix=smpte170m`、`colorprim=bt470bg`、`transfer=iec61966-2-1`
- 用于：水印写回路径（见 `docs/formats/oppo-watermark.md` §5）

ffmpeg fallback 构建（`XDREMUX_USE_FFMPEG=1`，仅桌面冒烟）下 oppo 路径退化为普通批量编码，无范围控制。

## 4. 已知陷阱清单

### 4.1 `setup_pic_planes` 必须显式接收 `use_420`

历史 bug：函数内部读取 gain-map 环境变量（`gain_map_420_enabled()`）决定平面布局，而编码器由调用方参数配置 i420。结果：编码器按 i420 配置却收到 4:4:4 平面 -> **逐瓦片色度错乱**（画面成块偏色、橙色块）。修复后 `use_420` 与 `oppo_sdr` 都是显式参数，平面布局与编码器配置由同一路径唯一决定。教训：**平面布局和 encoder 参数必须来自同一个调用方参数，禁止内部读取全局状态**。

### 4.2 每 tile 独立 IDR、参数集只放 tile 0

`repeat-headers=0` + `keyint=1`：tile 0 携带 VPS/SPS/PPS，其余 tile 是纯 IDR slice。ImageIO 的 ISO 增益映射解码器从 hvcC 读参数集，每个 tile 都带参数集会被拒绝。提取 hvcC 时注意 SPS 的 chroma format 要与实际码流一致（`extract_hvcc_config_with_chroma(stream, chroma)`）。

### 4.3 增益映射必须单色 / 4:4:4 规则

ISO 21496-1 增益映射 tile：gray 走 i400（main444-8 profile），OPPO 兼容输出要求 4:2:0 时显式传 `use_420=true`。4:4:4"伪彩色"码流会被 Android 增益映射路径拒绝。

### 4.4 heif-oxide 的解码怪癖（不修文件）

heif-oxide 对"ICC colr（无 nclx）的 grid + nclx 在 tile 上"这类结构按默认 limited 展开。它不是真实图库行为的代表，**验证以 WIC / 真机图库为准**，heif-oxide 仅作交叉参考。

### 4.5 WIC 解码 HEIC 的注意点

- 用 `BitmapDecoder.Create` + `BitmapCacheOption.OnLoad`，帧格式可能是 Bgr32（注意通道序）
- WIC 会应用容器声明（ICC/nclx），是验证"真实图库观感"的最方便基准

## 5. 验证方法备忘

1. **像素级**：WIC 解码原图与输出为 PNG（PowerShell 脚本见仓库历史），PIL 对比边框带/文字行/画面中部的像素值
2. **码流级**：`ffprobe -show_streams` 检查 VUI 三元组（space/transfer/primaries）与 `color_range`
3. **容器级**：`styles_diag` 探针打印 box 结构、item 表、关联属性、尾部条目
4. **探针**：`tile_stream_probe`（编码已知灰阶验证范围标记）、`wb_probe`（端到端写回）、`wb_bands_probe`（边框带检测）
