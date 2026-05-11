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

# Disable OPPO Gallery compatibility tail
swift swift/XDRemux.swift convert --input IMG_001.heic --no-oppo-compat
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

# Disable OPPO Gallery compatibility tail
python3 python/XDRemux.py convert --input IMG_001.heic --no-oppo-compat
```

> [!IMPORTANT]
> Omitting `--output` or `--output-dir` overwrites the original files in place. Back up before use.

## ⚠️ Known Limitations

- **Chroma subsampling**: UHDR device 8-bit YCbCr 4:4:4 Gain Maps are downsampled to 4:2:0 (Apple ImageIO / libheif limitation).
- **OPPO Gallery compatibility**: OPPO Gallery compatibility metadata is written by default. LHDR sources preserve their original `local.hdr.*` private tail, while UHDR sources write a `local.uhdr.*` tail. Pass `--no-oppo-compat` to disable this.
- **Gallery editing strips HDR**: Editing and saving a converted photo in OPPO Gallery strips the HDR Gain Map and its metadata.

## 🧪 Experimental Features

### `--passthrough`

> [!CAUTION]
> **Experimental option** — behavior may change between versions.

Skips base image decode→re-encode; copies HEVC compressed data directly from the source file. Only the Gain Map is re-encoded. The base image in the output will be identical to the source — zero quality loss. This mode now writes the OPPO Gallery Path B topology, `tmap -> [primary_grid, gainmap_grid]`, but remains experimental.

```bash
# Python
python3 python/XDRemux.py convert --input IMG_001.heic --passthrough
```

---

This tool is for technical research only. Back up your files before use. The author bears no legal responsibility.
