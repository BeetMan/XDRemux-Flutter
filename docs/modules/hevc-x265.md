# HEVC 编码模块（x265）

> 对应代码：`hevc.rs`、`x265_ffi.rs`、`x265_helper.c`。
> **色彩约定（范围/矩阵/传输函数）是本模块最关键的知识，单独成文**：见 `docs/formats/hevc-hevc-conventions.md`。本页只列 API 面与调用纪律。

## 1. 公开 API 面

| 函数 | 用途 |
|---|---|
| `x265_encode_tiles(tiles, w, h, pixel_bytes, use_420)` | 批量编码（标准路径，BT.709 full） |
| `x265_encode_tiles_oppo_sdr(...)` | 批量编码（OPPO 约定：BT.601 limited 数据 + full 标记） |
| `encode_hevc_tile_gray(pixels, w, h)` | 单 tile 灰度（增益映射） |
| `encode_hevc_tile_rgb(pixels, w, h)` | 单 tile RGB（4:4:4 保色度） |
| `rgb_to_yuv444` / `rgb_to_yuv420` | BT.709 全范围转换 |
| `rgb_to_yuv444_limited601` / `rgb_to_yuv420_limited601` | BT.601 limited 转换（OPPO 路径专用） |
| `extract_hvcc_config_with_chroma(stream, chroma)` | 从码流提取 hvcC（chroma 必须与码流一致） |

内部：`open_encoder`（参数配置）、`setup_pic_planes`（平面布局）--两者共享同一组调用方参数。

## 2. 调用纪律

1. **平面布局与 encoder 配置由同一调用方参数唯一决定**（`use_420`、`oppo_sdr`）。禁止在内部读环境变量/全局状态做布局决策（历史事故：gain-map env 导致 i420 配置收 4:4:4 平面，逐瓦片色度错乱）
2. pixel_bytes 语义：1 = 灰度（i400 / main444-8，ultrafast CRF18）；3 = RGB（medium CRF14）
3. `repeat-headers=0` + `keyint=1`：tile 0 带参数集，其余纯 IDR（ImageIO 增益映射解码器的硬要求）
4. ffmpeg fallback（`XDREMUX_USE_FFMPEG=1`，桌面冒烟构建）：oppo 路径退化为普通批量编码，无范围控制--**不得用于验证色彩行为**
5. x265 以静态库内建（四平台构建矩阵见 `architecture/platform-backend.md`）

## 3. 构建

- Windows：MSVC x265-static（ARM64 需 `-A ARM64 -DENABLE_ASSEMBLY=OFF`）
- Android：`vendor/x265/build_android`（SELinux 禁止子进程，必须静态）
- iOS：`build_ios.sh`（交叉编译，无汇编）
- macOS/Linux：`vendor/x265/build_desktop`
- `x265_helper.c` 以 C++ 编译（x265.h 用了 `bool`，MSVC C 模式没有）
