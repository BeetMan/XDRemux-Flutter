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
> 需要安装依赖：`pip install pillow-heif Pillow numpy`

```bash
# 标准模式（重新编码 base image，quality=90）
python3 python/XDRemux.py convert --input IMG_001.heic

# Passthrough 模式（保留原始 HEVC 数据，无损）
python3 python/XDRemux.py convert --input IMG_001.heic --passthrough

# 批量转换
python3 python/XDRemux.py batch --input-dir photo_dump/
```

> [!IMPORTANT]
> 省略 `--output` 或 `--output-dir` 时将在原路径覆写原始文件，请提前备份。

## ⚠️ 已知局限

- **色度下采样**：UHDR 设备的 8-bit YCbCr 4:4:4 Gain Map 会被降采样为 4:2:0（Apple ImageIO / libheif 限制）。
- **LHDR 相册识别**：LHDR 分支设备拍摄的 ProXDR HEIC 经转换后，在 OPPO 相册中查看时无法被识别到 Gain Map，导致无法触发 HDR 提亮。
- **相册编辑丢失 HDR**：转换后的照片在 OPPO 相册中编辑并保存后，HDR Gain Map 及其元数据会丢失。

## 🧪 实验性功能

### `--passthrough` — 无损直通模式

> [!CAUTION]
> **实验性选项** — 行为可能会随版本更新而改变。

跳过 base image 的解码→重新编码，直接从源文件复制 HEVC 压缩数据。仅重新编码 Gain Map。输出文件的 base image 将与源文件完全一致，无质量损失。目前已知问题：该选项输出的图像目前还无法在 OPPO 相册中正常显示，正在排查。

```bash
# Python
python3 python/XDRemux.py convert --input IMG_001.heic --passthrough
```

---

本工具仅供技术研究使用，使用前请备份原始文件。作者不承担任何法律责任。
