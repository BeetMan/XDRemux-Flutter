# XDRemux

[English Version](README.en.md) | 中文版

XDRemux 可以将 OPPO、OnePlus、realme 设备拍摄的 ProXDR HEIC 照片转换为标准 HDR HEIC。

它会读取原始照片中的私有 HDR Gain Map 及元数据，并重新封装为符合 ISO 21496-1 标准的 HDR HEIC 文件。转换后的照片可以在 macOS、iOS、Android 等支持 HDR 照片显示的系统中查看。

## 什么时候需要这个工具？

如果你从 OPPO、OnePlus 或 realme 手机上拍摄了 ProXDR HEIC 照片，并希望它们在其他系统或软件里仍然以 HDR 方式显示，可以使用 XDRemux 转换。

## 快速上手

> [!IMPORTANT]
> 省略 `--output` 或 `--output-dir` 时，工具会在原路径覆写文件。转换前请备份原始照片。

### Swift CLI

```bash
# 单张转换
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic

# 批量转换
swift xdremux/swift-cli/XDRemux.swift batch --input-dir photo_dump/

# 指定输出路径
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --output out.heic
```

默认模式适合大多数情况。它会尽量保留原始 Base Image，只重新处理 HDR Gain Map 及其元数据。

### Python CLI

> [!NOTE]
> 需要先安装依赖：`pip install pillow-heif Pillow numpy`

```bash
# 单张转换
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic

# 批量转换
python3 xdremux/python/XDRemux.py batch --input-dir photo_dump/
```

### macOS App

源码位于：

```text
apps/macos/XDRemuxApp/
```

本地构建和运行：

```bash
scripts/build_and_run.sh run
```

## OPPO 相册兼容模式

OPPO 系统相册对 HEVC RExt 4:4:4 Gain Map 的兼容性有限。启用 OPPO 相册兼容模式后，XDRemux 会将 Gain Map 改用 HEVC Main Still Picture Profile（4:2:0）编码，从而触发 OPPO 系统相册中的 HDR 显示。LHDR 在 OPPO 兼容模式下固定写出已验证的 RGB-copy 8-bit Gain Map；非 OPPO LHDR 输出仍保留原始灰度 Gain Map。

Swift CLI：

```bash
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --oppo-compat
```

Python CLI：

```bash
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic --oppo-compat
```

macOS App：

在导出前打开 **OPPO 相册兼容模式**。

## Swift CLI 输入处理模式

Swift CLI 支持 `--input-processing` 参数。普通用户通常不需要手动设置。

```bash
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic --input-processing hybrid
```

| 模式            | 说明                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| `hybrid`      | 默认模式。保留原始 Base Image，只重新处理 HDR Gain Map。非 OPPO 输出保留原通道结构；开启 OPPO 兼容时，LHDR 使用已验证的 RGB-copy Gain Map。 |
| `system`      | 让系统 ImageIO 负责写出最终 HEIC。这个模式会重新编码 Base Image 和 Gain Map，适合用于对照系统行为。                                          |
| `passthrough` | 实验性模式。直接改写 HEIC 内部结构，用于验证和开发。普通用户不建议使用。                                                                      |

## 支持设备

XDRemux 适用于可以拍摄 ProXDR 照片的 OPPO、OnePlus、realme 设备。

在中国大陆销售且支持拍摄 ProXDR 照片的设备如下：

| 品牌/系列         | 机型名称                                                                                                                              |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 一加            | 一加 Ace2 Pro、一加 12、一加 Ace3、一加 Ace 3V、一加 Ace 3 Pro、一加 13、一加 Ace 5 系列、一加 13T、一加 Ace 6、一加 Ace 6T、一加 Turbo 6、一加 15、一加 15T、一加 Ace 5 至尊版 |
| OPPO K 系列     | K12、K12x、K13 Turbo 系列、K15 Pro 系列                                                                                                  |
| OPPO Find 系列  | Find X6、Find X6 Pro、Find N3、Find N3 Flip、Find X7、Find X7 Ultra、Find X8 系列、Find N5、Find X8s、Find X9 系列、Find N6                     |
| OPPO Reno 系列  | Reno10 Pro、Reno10 Pro+、Reno11 Pro、Reno12 系列、Reno13 系列、Reno14 系列、Reno15 系列、Reno 16 系列                                              |
| realme GT 系列  | 真我 GT5 系列、真我 GT5 Pro、真我 GT6、真我 GT7 Pro、真我 GT7 Pro 竞速版、真我 GT7、真我 Neo7 Turbo、真我 GT8、真我 GT8 Pro                                      |
| realme Neo 系列 | 真我 GT Neo6 SE、真我 GT Neo6、真我 Neo7、真我 Neo7 SE、真我 Neo7x、真我 Neo8                                                                      |
| realme 数字系列   | 真我 12 Pro、真我 12 Pro+、真我 13 Pro+、真我 13 Pro 至尊版、真我 13 Pro、真我 14 Pro+、真我 14 Pro、真我 14、真我 15、真我 15 Pro                                |

其中，OPPO Find X8 Ultra、Find X9 系列及真我 GT8 Pro（理光模式）在 Gain Map 实现中支持 **YCbCr 4:4:4 采样的 HDR Gain Map**。

## 仓库结构

| 路径                       | 用途                             |
| ------------------------ | ------------------------------ |
| `xdremux/swift-cli/`     | Swift CLI 主入口。                 |
| `xdremux/python/`        | Python CLI 与 HEIF I/O 辅助实现。    |
| `apps/macos/XDRemuxApp/` | macOS SwiftUI App。             |
| `tests/`                 | 转换器测试。                         |
| `fixtures/`              | 小型测试样本与样本说明。                   |
| `scripts/`               | 本地构建、运行和验证脚本。                  |
| `docs/`                  | 设计说明、研究记录和维护文档。                |
| `experiments/`           | 实验性代码。                         |
| `skills/`                | 与 ISO HDR 合规审计相关的 agent skill。 |

## 已知限制

- 转换后的照片在 OPPO 相册中再次编辑并保存后，HDR Gain Map 及其 HDR 元数据可能会丢失。

本工具仅供技术研究使用。转换前请备份原始文件。作者不承担任何关于数据丢失的法律责任。
