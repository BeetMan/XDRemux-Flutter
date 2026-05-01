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

### Swift（仅 macOS）

```bash
# 单张转换
swift swift/XDRemux.swift convert --input IMG_001.heic

# 批量转换
swift swift/XDRemux.swift batch --input-dir photo_dump/

# 指定输出路径
swift swift/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

### Python（跨平台）

> [!WARNING]
> Python 版仍在开发中。元数据提取与 gain map 重建已可用，但 HEIC 编码输出的增益图缺少 ISO auxC 标记（受限于 pillow-heif API），macOS 可能无法识别为 HDR。完整转换请使用 Swift 版。

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

## 🗺 未来目标

- Python 跨平台版完善 HEIC 编解码支持。

---

本工具仅供技术研究使用，使用前请备份原始文件。作者不承担任何法律责任。
