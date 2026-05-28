# XDRemux

[English Version](README.en.md) | 中文版

将 OPPO/OnePlus/realme 设备拍摄的 ProXDR HEIC 转换为 ISO 21496-1 HDR HEIC。

提取 ProXDR HEIC 中的专有 HDR Gain Map 及元数据，重新封装为符合业界标准的 ISO 21496-1 HDR HEIC，确保在 macOS、iOS、Android 上呈现准确的色调映射。

当前推荐使用 Swift CLI 作为 macOS 上的主转换入口。

## 📱 支持设备

| Format | Devices |
|--------|---------|
| UHDR | OPPO Find X8 Ultra, OPPO Find X9 系列 |
| LHDR | OPPO Find X6 Pro 发布后，OPPO Find X8 Ultra 发布前所有支持 ProXDR 照片拍摄的设备 |

## 🚀 快速上手

### Swift（需要 macOS 26 及更新系统）

```bash
# 单张转换
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic

# 批量转换
swift xdremux/swift/XDRemux.swift batch --input-dir photo_dump/

# 指定输出路径
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --output out.heic

# 选择输入处理分支；默认是 hybrid
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid

# 需要在 OPPO 相册中优先识别时，启用 OPPO 兼容输出
swift xdremux/swift/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

Swift CLI 的 `--input-processing` 只接受三个分支：

| 分支 | 说明 |
|------|------|
| `hybrid` | 默认生产路径。输入原始 HEIC 和解析出的 gain map，先让 ImageIO/Preserve 产出 HEVC gain map，再重写 ISOBMFF 并 graft 原始 primary subtree。目标是 primary passthrough、HEVC gain map、ImageIO 可读 ISO gain map。 |
| `system` | 系统直出路径。直接让 ImageIO 写最终 HEIC，用作系统行为对照；base image 和 gain map 均由 ImageIO 决定编码方式。 |
| `passthrough` | 实验性路径。直接重写 ISOBMFF box，使输出能被 ImageIO 识别为 HDR 照片；用于验证直接 box rewrite 的可行性。 |

### Python（跨平台）

> [!NOTE]
> 需要安装依赖：`pip install pillow-heif Pillow numpy`

```bash
# 标准模式（保留原始 base HEVC，仅重写 HDR gain map）
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic

# 批量转换
python3 xdremux/python/XDRemux.py batch --input-dir photo_dump/

# 需要在 OPPO 相册中优先识别时，额外写入 OPPO 兼容尾部
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --oppo-compat

# 排障模式：解码并重新编码 base image
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --reencode
```

> [!IMPORTANT]
> 省略 `--output` 或 `--output-dir` 时将在原路径覆写原始文件，请提前备份。

## ⚠️ 已知局限

- **智能默认路径**：Swift / Python CLI 会自动识别 LHDR/UHDR 与设备家族。Swift 默认使用 `hybrid` 输入处理分支；普通用户不需要指定 family 或输入处理分支。Python 默认保留原始 base HEVC 数据，避免二次压缩。
- **OPPO 相册兼容**：标准 Swift 输出默认不写 OPPO 私有兼容尾部。需要面向 OPPO 相册优先识别时，使用 `--oppo-compat`。LHDR 源文件会保留原始 `local.hdr.*` 私有尾部；UHDR 源文件会写入 `local.uhdr.*` 尾部，并使用 ImageIO-native 142B/PQ `tmap` 图，同时保留源文件 primary HEVC。严格 ISO 检查仍会把 142B `tmap` 作为非严格兼容形态处理。
- **相册编辑丢失 HDR**：转换后的照片在 OPPO 相册中编辑并保存后，HDR Gain Map 及其元数据会丢失。

## 🧪 实验性功能

### `--reencode`

> [!CAUTION]
> **实验性选项** — 行为可能会随版本更新而改变。

默认路径会跳过 base image 的解码→重新编码，直接从源文件复制 HEVC 压缩数据，仅重新编码 Gain Map。`--reencode` 保留为排障模式，会重新编码 base image，通常文件更大且可能带来二次压缩损耗。

```bash
# Python
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --reencode
```

---

本工具仅供技术研究使用，使用前请备份原始文件。作者不承担任何关于数据丢失的法律责任。
