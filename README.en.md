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
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic

# Batch
swift xdremux/swift/XDRemux.swift batch --input-dir photo_dump/

# Specify output
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --output out.heic

# Select the input processing branch; the default is hybrid
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid

# Add OPPO Gallery compatibility metadata when OPPO Gallery is the target viewer
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

The Swift CLI accepts exactly three `--input-processing` branches:

| Branch | Description |
|--------|-------------|
| `hybrid` | Default production path. It takes the original HEIC and the parsed gain map, lets ImageIO/Preserve produce the HEVC gain map first, then rewrites ISOBMFF and grafts the original primary subtree. The target is primary passthrough, HEVC gain map, and an ImageIO-readable ISO gain map. |
| `system` | System-output path. ImageIO writes the final HEIC directly; use it as a reference for system behavior. ImageIO decides how both the base image and gain map are encoded. |
| `passthrough` | Experimental path. Rewrites ISOBMFF boxes directly so the output is recognized by ImageIO as an HDR photo; this branch is for validating direct box-rewrite behavior. |

### Python (cross-platform)

> [!NOTE]
> Requires dependencies: `pip install pillow-heif Pillow numpy`

```bash
# Standard mode (preserves original base HEVC and rewrites only the HDR gain map)
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic

# Batch conversion
python3 xdremux/python/XDRemux.py batch --input-dir photo_dump/

# Add OPPO Gallery compatibility metadata when OPPO Gallery is the target viewer
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --oppo-compat

# Troubleshooting mode: decode and re-encode the base image
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --reencode
```

> [!IMPORTANT]
> Omitting `--output` or `--output-dir` overwrites the original files in place. Back up before use.

## ⚠️ Known Limitations

- **Smart defaults**: The Swift and Python CLIs automatically detect LHDR/UHDR and device family. Swift uses the `hybrid` input processing branch by default; users do not need to choose family or an input processing branch. Python preserves the original base HEVC data by default to avoid recompression.
- **OPPO Gallery compatibility**: Standard Swift output does not write the OPPO private compatibility tail by default. Use `--oppo-compat` when OPPO Gallery is the target viewer. LHDR sources preserve their original `local.hdr.*` private tail, while UHDR sources write a `local.uhdr.*` tail.
- **Gallery editing strips HDR**: Editing and saving a converted photo in OPPO Gallery strips the HDR Gain Map and its metadata.

## 🧪 Experimental Features

### `--reencode`

> [!CAUTION]
> **Experimental option** — behavior may change between versions.

The default path skips base image decode→re-encode and copies HEVC compressed data directly from the source file. Only the Gain Map is re-encoded. `--reencode` remains as a troubleshooting mode; it re-encodes the base image and can produce larger files with recompression loss.

```bash
# Python
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --reencode
```

---

This tool is for technical research only. Back up your files before use. The author bears no legal responsibility.
