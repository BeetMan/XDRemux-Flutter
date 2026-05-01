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

### Swift (macOS only)

```bash
# Single file
swift swift/XDRemux.swift convert --input IMG_001.heic

# Batch
swift swift/XDRemux.swift batch --input-dir photo_dump/

# Specify output
swift swift/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

### Python (cross-platform)

> [!WARNING]
> Python version is still in development. Metadata extraction and gain map reconstruction work, but HEIC output lacks ISO auxC box marking (pillow-heif API limitation). macOS may not detect it as HDR. Use the Swift version for full conversion.

```bash
python3 python/XDRemux.py convert --input IMG_001.heic
python3 python/XDRemux.py batch --input-dir photo_dump/
```

> [!IMPORTANT]
> Omitting `--output` or `--output-dir` overwrites the original files in place. Back up before use.

## ⚠️ Known Limitations

- **Chroma subsampling**: UHDR device 8-bit YCbCr 4:4:4 Gain Maps are downsampled to 4:2:0 (Apple ImageIO / libheif limitation).
- **LHDR Gallery recognition**: ProXDR HEICs captured on LHDR branch devices (Find X6/X7/X8) are not recognized by OPPO Gallery after conversion, so HDR highlight rendering is not triggered.
- **Gallery editing strips HDR**: Editing and saving a converted photo in OPPO Gallery strips the HDR Gain Map and its metadata.

## 🧪 Experimental Features

### `--oppo-compat` — OPPO Gallery Compatibility Mode

> [!CAUTION]
> **Experimental option** — behavior may change between versions.

Pass `--oppo-compat` during conversion to additionally write OPPO-proprietary UHDR extension blocks (`local.uhdr.gainmap.info` / `local.uhdr.gainmap.data`) and patch the EXIF UserComment `oplus_` tag flags, so the converted HDR photo can still activate HDR highlight rendering in OPPO Gallery.

```bash
# Swift
swift swift/XDRemux.swift convert --input IMG_001.heic --oppo-compat

# Python
python3 python/XDRemux.py convert --input IMG_001.heic --oppo-compat
```

Off by default. Without this flag, the output is a pure ISO 21496-1 standard HDR HEIC.

## 🗺 Roadmap

- Polish Python cross-platform HEIC encode/decode support.

---

This tool is for technical research only. Back up your files before use. The author bears no legal responsibility.
