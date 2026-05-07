# XDRemux

[English Version](README.en.md) | 中文版

将 OPPO/OnePlus/realme 设备拍摄的 ProXDR HEIC 转换为 ISO 21496-1 HDR HEIC。

提取 ProXDR HEIC 中的专有 HDR Gain Map 及元数据，重新封装为符合业界标准的 ISO 21496-1 HDR HEIC，确保在 macOS、iOS、Android 上呈现准确的色调映射。

## 📱 支持设备

| Format | Devices |
|--------|---------|
| UHDR | OPPO Find X8 Ultra, Find X9, Find X9 Ultra |
| LHDR | OPPO Find X6 Pro, Find X7 Ultra, Find X8 |

## 🚀 快速上手

### Swift（需要 macOS 26 及更新系统）

```bash
# 单张转换
swift swift/XDRemux.swift convert --input IMG_001.heic

# 批量转换
swift swift/XDRemux.swift batch --input-dir photo_dump/

# 指定输出路径
swift swift/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

### Python（跨平台）

> [!NOTE]
> Python 版需要安装依赖：`pip install pillow-heif Pillow numpy`

```bash
python3 python/XDRemux.py convert --input IMG_001.heic
python3 python/XDRemux.py batch --input-dir photo_dump/
```

> [!IMPORTANT]
> 省略 `--output` 或 `--output-dir` 时将在原路径覆写原始文件，请提前备份。

## ⚠️ 已知局限

- **色度下采样**: UHDR 设备的 8bit YCbCr 4:4:4 Gain Map 会被降采样为 4:2:0（Apple ImageIO / libheif 限制）。
- **LHDR 相册识别**: LHDR 分支设备拍摄的 ProXDR HEIC 经转换后，在 OPPO 相册中查看时无法被识别到 Gain Map，导致无法触发HDR提亮。
- **相册编辑丢失 HDR**: 转换后的照片在 OPPO 相册中编辑并保存后，HDR Gain Map 及其元数据会丢失。

## 🧪 实验性功能

### `--oppo-compat` — OPPO 相册兼容模式

> [!CAUTION]
> **实验性选项**，行为可能会随版本更新而改变。

在转换时附加 `--oppo-compat`，输出文件会额外写入 OPPO 私有的 UHDR 扩展数据块（`local.uhdr.gainmap.info` / `local.uhdr.gainmap.data`）并修补 EXIF UserComment 中的 `oplus_` 标志位，使转换后的 HDR 照片在 OPPO 设备相册中仍能激活 HDR 提亮效果。

```bash
# Swift
swift swift/XDRemux.swift convert --input IMG_001.heic --oppo-compat

# Python
python3 python/XDRemux.py convert --input IMG_001.heic --oppo-compat
```

默认关闭。不加此选项时，输出为纯 ISO 21496-1 标准 HDR HEIC。

### `--passthrough` — 无损基图透传模式（实验性）

> [!CAUTION]
> **实验性选项**，行为可能会随版本更新而改变。

直接拷贝源文件中 base image 的 HEVC 压缩数据，不做解码-重编码 round-trip。仅重新编码 gain map。优点：零画质损失、文件体积更小（约减少 60%）。

```bash
python3 python/XDRemux.py convert --input IMG_001.heic --output out.heic --passthrough
python3 python/XDRemux.py batch --input-dir photo_dump/ --passthrough
```

当前仅支持 Python 版。详见 [`docs/passthrough_plan.md`](docs/passthrough_plan.md)。

---

本工具仅供技术研究使用，使用前请备份原始文件。作者不承担任何法律责任。
