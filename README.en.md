# XDRemux

English Version | [中文版](README.md)

Convert OPPO/OnePlus/realme ProXDR HEIC to ISO 21496-1 HDR HEIC.

Extracts proprietary HDR Gain Map and metadata from ProXDR HEIC files and repackages them into industry-standard ISO 21496-1 HDR HEIC files, ensuring accurate tone mapping on macOS, iOS, and Android.

The Swift CLI is currently the recommended conversion entry point on macOS. The macOS app is a separate graphical shell and does not live in the same source directory as the CLI.

## 📱 Supported Devices

| Format | Devices |
| --- | --- |
| UHDR | OPPO Find X8 Ultra, Find X9, Find X9 Ultra |
| LHDR | OPPO Find X6 Pro, Find X7 Ultra, Find X8 |

## 🚀 Quick Start

### Swift CLI (requires macOS 26 or later)

```bash
# Single file
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic

# Batch
swift xdremux/swift-cli/XDRemux.swift batch --input-dir photo_dump/

# Specify output
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --output out.heic

# Select the input processing branch; the default is hybrid
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid

# Prefer OPPO Gallery recognition while preserving the 4:4:4 gain map
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

The Swift CLI accepts three `--input-processing` branches:

| Branch | Description |
| --- | --- |
| `hybrid` | Default production path. Preserves the source primary HEVC and keeps the final HEVC gain map at 4:4:4. The default output is clean Apple/ImageIO-compatible structure; `--oppo-compat` adds OPPO recognition signals, a 142B ImageIO-native `tmap`, and PQ `tmap` color while still keeping the final gain map 4:4:4. |
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

## 🗂️ Repository Layout

| Path | Purpose |
| --- | --- |
| `xdremux/swift-cli/` | Recommended Swift CLI entry point. Contains only the command-line converter. |
| `xdremux/python/` | Cross-platform Python CLI and HEIF I/O support code. |
| `apps/macos/XDRemuxApp/` | macOS SwiftUI app shell, Xcode project, resources, and app tests. |
| `scripts/` | Local development, build, and verification scripts. |
| `docs/` | Maintainer-facing notes, release records, and future design documents. |
| `experiments/` | Auditable experimental branches that are not the production path. |
| `skills/` | Agent skill and reference rules for ISO HDR compliance review. |

Repository convention: converter entry points live under `xdremux/`, graphical apps live under `apps/`, automation scripts live under `scripts/`, and durable documentation lives under `docs/`. The Swift CLI and macOS app do not share a source directory, so the command-line production path stays separate from the graphical app shell.

### macOS App helper script

```bash
scripts/build_and_run.sh run
scripts/build_and_run.sh --verify
scripts/build_and_run.sh --logs
```

## ⚠️ Known Limitations

- **Smart defaults**: The Swift and Python CLIs automatically detect LHDR/UHDR and device family. Swift uses the `hybrid` input processing branch by default; users do not need to choose family or an input processing branch. Python preserves the original base HEVC data by default to avoid recompression.
- **OPPO Gallery compatibility**: Swift `hybrid` defaults to clean Apple/ImageIO-compatible output and does not automatically write OPPO private signals. With `--oppo-compat`, XDRemux uses the preserve path: it keeps the source primary HEVC and final HEVC gain map at 4:4:4, then writes OPPO tagflags, the OPPO private tail, a 142B ImageIO-native `tmap`, and PQ `tmap` color association. Strict ISO validation and ImageIO-native/OPPO compatibility are separate concerns; the 142B `tmap` is the verified ImageIO-native compatibility form, not the strict-mode 145B padded structure.
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
