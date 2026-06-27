# XDRemux

[English Version](README.en.md) | 中文版

将 OPPO/OnePlus/realme 设备拍摄的 ProXDR HEIC 转换为 ISO 21496-1 HDR HEIC。

提取 ProXDR HEIC 中的专有 HDR Gain Map 及元数据，重新封装为符合业界标准的 ISO 21496-1 HDR HEIC，确保在 macOS、iOS、Android 上呈现准确的色调映射。

当前推荐使用 Swift CLI 作为 macOS 上的主转换入口。macOS App 是独立的图形界面外壳，不与 CLI 放在同一源码目录。

## 📱 支持设备

| Format | Devices |
| --- | --- |
| UHDR | OPPO Find X8 Ultra, OPPO Find X9 系列 |
| LHDR | OPPO Find X6 Pro 发布后，OPPO Find X8 Ultra 发布前所有支持 ProXDR 照片拍摄的设备 |

## 🚀 快速上手

### Swift CLI（需要 macOS 26 及更新系统）

```bash
# 单张转换
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic

# 批量转换
swift xdremux/swift-cli/XDRemux.swift batch --input-dir photo_dump/

# 指定输出路径
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --output out.heic

# 选择输入处理分支；默认是 hybrid
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid

# 需要 OPPO 相册优先识别时，启用 OPPO 兼容信号并保留 4:4:4 gain map
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

Swift CLI 的 `--input-processing` 接受三个分支：

| 分支 | 说明 |
| --- | --- |
| `hybrid` | 默认生产路径。保留源文件 primary HEVC，并让最终 HEVC gain map 保持 4:4:4。默认输出为纯净 Apple/ImageIO 兼容结构；使用 `--oppo-compat` 时，增加 OPPO 识别信号、142B ImageIO-native `tmap` 与 PQ `tmap` 颜色关联，同时继续保持最终 gain map 为 4:4:4。 |
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

## 🗂️ 仓库层级

| 路径 | 用途 |
| --- | --- |
| `xdremux/swift-cli/` | 当前推荐的 Swift CLI 主入口。只放命令行转换器。 |
| `xdremux/python/` | 跨平台 Python CLI 与 HEIF I/O 辅助实现。 |
| `apps/macos/XDRemuxApp/` | macOS SwiftUI App 外壳、Xcode 工程、资源与 App 测试。 |
| `scripts/` | 可运行的本地开发、构建与验证脚本。 |
| `docs/` | 面向维护者的说明、发布记录和后续设计文档。 |
| `experiments/` | 可审计但非产品主线的实验分支。 |
| `skills/` | 与 ISO HDR 合规审计相关的 agent skill 与参考规则。 |

目录约定：转换器入口放在 `xdremux/`，图形界面应用放在 `apps/`，自动化脚本放在 `scripts/`，长期文档放在 `docs/`。Swift CLI 与 macOS App 不共用同一个源码目录，以免把命令行产品路径和图形界面外壳混在一起。

### macOS App 本地辅助脚本

```bash
scripts/build_and_run.sh run
scripts/build_and_run.sh --verify
scripts/build_and_run.sh --logs
```

## ⚠️ 已知局限

- **智能默认路径**：Swift / Python CLI 会自动识别 LHDR/UHDR 与设备家族。Swift 默认使用 `hybrid` 输入处理分支；普通用户不需要指定 family 或输入处理分支。Python 默认保留原始 base HEVC 数据，避免二次压缩。
- **OPPO 相册兼容**：Swift `hybrid` 默认保持 Apple/ImageIO 兼容输出，不自动写入 OPPO 私有信号。使用 `--oppo-compat` 时，XDRemux 走保留路径：保留源文件 primary HEVC，并让最终 HEVC gain map 保持 4:4:4，同时写入 OPPO tagflags、OPPO 私有尾部、142B ImageIO-native `tmap` 载荷和 PQ `tmap` 颜色关联。严格 ISO 检查与 ImageIO-native/OPPO 兼容性是两个独立关注点；142B `tmap` 是已验证的 ImageIO-native 兼容形式，不等同于严格模式检查的 145B padded 结构。
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
