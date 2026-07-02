# XDRemux

English Version | [中文版](README.md)

XDRemux converts ProXDR HEIC photos captured on OPPO, OnePlus, and realme devices into standard HDR HEIC files.

It reads the private HDR Gain Map and metadata from the original photo, then repackages them into an HDR HEIC file compliant with ISO 21496-1. The converted photo can be viewed on macOS, iOS, Android, and other systems that support HDR photo display.

## When do I need this tool?

Use XDRemux if you captured ProXDR HEIC photos on an OPPO, OnePlus, or realme phone and want them to keep displaying as HDR photos in other systems or software.

## Quick Start

> [!IMPORTANT]
> Omitting `--output` or `--output-dir` makes the tool overwrite files in place. Back up your original photos before conversion.

### Swift CLI

```bash
# Single file
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic

# Batch conversion
swift xdremux/swift-cli/XDRemux.swift batch --input-dir photo_dump/

# Specify output path
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

The default mode is suitable for most cases. It tries to preserve the original Base Image and only reprocesses the HDR Gain Map and its metadata.

### Python CLI

> [!NOTE]
> Install dependencies first: `pip install pillow-heif Pillow numpy`

```bash
# Single file
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic

# Batch conversion
python3 xdremux/python/XDRemux.py batch --input-dir photo_dump/
```

### macOS App

Source path:

```text
apps/macos/XDRemuxApp/
```

Build and run locally:

```bash
scripts/build_and_run.sh run
```

## OPPO Gallery compatibility mode

OPPO Gallery has limited compatibility with HEVC RExt 4:4:4 Gain Maps. When OPPO Gallery compatibility mode is enabled, XDRemux encodes the Gain Map with HEVC Main Still Picture Profile (4:2:0), allowing OPPO Gallery to trigger HDR display.

Swift CLI:

```bash
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

Python CLI:

```bash
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --oppo-compat
```

macOS App:

Enable **OPPO Gallery compatibility mode** before export.

## Swift CLI input processing modes

The Swift CLI supports the `--input-processing` option. Most users do not need to set it manually.

```bash
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid
```

| Mode | Description |
| --- | --- |
| `hybrid` | Default mode. Preserves the original Base Image and only reprocesses the HDR Gain Map. It can encode the Gain Map as HEVC RExt 4:4:4, preserving Gain Map sampling precision while also reducing file size for some photos. |
| `system` | Lets the system ImageIO writer produce the final HEIC. This mode re-encodes both the Base Image and the Gain Map, and is useful as a reference for system behavior. |
| `passthrough` | Experimental mode. Rewrites the internal HEIC structure directly for validation and development. Not recommended for normal use. |

## Supported devices

XDRemux is intended for OPPO, OnePlus, and realme devices that can capture ProXDR photos.

The following mainland China models are known to support ProXDR photo capture:

| Brand/series | Models |
| --- | --- |
| OnePlus | OnePlus Ace2 Pro, OnePlus 12, OnePlus Ace3, OnePlus Ace 3V, OnePlus Ace 3 Pro, OnePlus 13, OnePlus Ace 5 series, OnePlus 13T, OnePlus Ace 6, OnePlus Ace 6T, OnePlus Turbo 6, OnePlus 15, OnePlus 15T, OnePlus Ace 5 Supreme Edition |
| OPPO K series | K12, K12x, K13 Turbo series, K15 Pro series |
| OPPO Find series | Find X6, Find X6 Pro, Find N3, Find N3 Flip, Find X7, Find X7 Ultra, Find X8 series, Find N5, Find X8s, Find X9 series, Find N6 |
| OPPO Reno series | Reno10 Pro, Reno10 Pro+, Reno11 Pro, Reno12 series, Reno13 series, Reno14 series, Reno15 series, Reno 16 series |
| realme GT series | realme GT5 series, realme GT5 Pro, realme GT6, realme GT7 Pro, realme GT7 Pro Racing Edition, realme GT7, realme Neo7 Turbo, realme GT8, realme GT8 Pro |
| realme Neo series | realme GT Neo6 SE, realme GT Neo6, realme Neo7, realme Neo7 SE, realme Neo7x, realme Neo8 |
| realme number series | realme 12 Pro, realme 12 Pro+, realme 13 Pro+, realme 13 Pro Supreme Edition, realme 13 Pro, realme 14 Pro+, realme 14 Pro, realme 14, realme 15, realme 15 Pro |

Among them, OPPO Find X8 Ultra, the Find X9 series, and realme GT8 Pro in Ricoh mode support **YCbCr 4:4:4 HDR Gain Map sampling** in their Gain Map implementation.

## Repository structure

| Path | Purpose |
| --- | --- |
| `xdremux/swift-cli/` | Swift CLI entry point. |
| `xdremux/python/` | Python CLI and HEIF I/O helper implementation. |
| `apps/macos/XDRemuxApp/` | macOS SwiftUI app. |
| `tests/` | Converter tests. |
| `fixtures/` | Small test samples and sample notes. |
| `scripts/` | Local build, run, and validation scripts. |
| `docs/` | Design notes, research records, and maintainer documentation. |
| `experiments/` | Experimental code. |
| `skills/` | Agent skill for ISO HDR compliance review. |

## Known limitations

- HDR Gain Map and HDR metadata may be lost after editing and saving a converted photo again in OPPO Gallery.

This tool is for technical research only. Back up your original files before conversion. The author assumes no legal responsibility for data loss.
