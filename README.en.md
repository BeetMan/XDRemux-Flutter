# XDRemux

English Version | [中文版](README.md)

Convert OPPO/OnePlus/realme ProXDR HEIC to ISO 21496-1 HDR HEIC.

Extracts proprietary HDR Gain Map and metadata from ProXDR HEIC files and repackages them into industry-standard ISO 21496-1 HDR HEIC files, ensuring accurate tone mapping on macOS, iOS, and Android.

## 📱 Supported Devices

| Format | Devices |
|--------|---------|
| UHDR | OPPO Find X8 Ultra, Find X9, Find X9 Ultra |
| LHDR | OPPO Find X6 Pro, Find X7 Ultra, Find X8 |

## 🚀 Quick Start

### Swift (requires macOS 26 or later)

```bash
# Single file
swift swift/XDRemux.swift convert --input IMG_001.heic

# Batch
swift swift/XDRemux.swift batch --input-dir photo_dump/

# Specify output
swift swift/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

### Python (cross-platform)

> [!NOTE]
> Requires dependencies: `pip install pillow-heif Pillow numpy`

```bash
# Standard mode (re-encodes base image at quality=90)
python3 python/XDRemux.py convert --input IMG_001.heic

# Passthrough mode (preserves original HEVC data, lossless)
python3 python/XDRemux.py convert --input IMG_001.heic --passthrough

# Batch conversion
python3 python/XDRemux.py batch --input-dir photo_dump/
```

> [!IMPORTANT]
> Omitting `--output` or `--output-dir` overwrites the original files in place. Back up before use.

## ⚠️ Known Limitations

- **Chroma subsampling**: UHDR device 8-bit YCbCr 4:4:4 Gain Maps are downsampled to 4:2:0 (Apple ImageIO / libheif limitation).
- **LHDR Gallery recognition**: ProXDR HEICs captured on LHDR branch devices (Find X6/X7/X8) are not recognized by OPPO Gallery after conversion, so HDR highlight rendering is not triggered.
- **Gallery editing strips HDR**: Editing and saving a converted photo in OPPO Gallery strips the HDR Gain Map and its metadata.

## 🧪 Experimental Features

### `--passthrough` — Lossless Passthrough Mode

> [!CAUTION]
> **Experimental option** — behavior may change between versions.

Skips base image decode→re-encode; copies HEVC compressed data directly from the source file. Only the Gain Map is re-encoded. The base image in the output will be identical to the source — zero quality loss. Known issue: images produced by this option currently do not display correctly in OPPO Gallery. Investigation is ongoing.

```bash
# Python
python3 python/XDRemux.py convert --input IMG_001.heic --passthrough
```

---

This tool is for technical research only. Back up your files before use. The author bears no legal responsibility.
