# XDRemux

[English Version](README.en.md) | 中文版

XDRemux 可以将 OPPO、OnePlus、realme 设备拍摄的 ProXDR HEIC 照片转换为标准 HDR HEIC。

它会读取原始照片中的私有 HDR Gain Map 及元数据，并重新封装为符合 ISO 21496-1 标准的 HDR HEIC 文件。转换后的照片可以在 macOS、iOS、Android 等支持 HDR 照片显示的系统中查看。

## 什么时候需要这个工具？

如果你从 OPPO、OnePlus 或 realme 手机上拍摄了 ProXDR HEIC 照片，并希望它们在其他系统或软件里仍然以 HDR 方式显示，可以使用 XDRemux 转换。

## 三种输出模式

当前 Swift CLI 只有两个产品开关。两个都不指定时使用标准 ISO 默认模式。

| 模式 | 开关 | 结果 |
|---|---|---|
| 标准 ISO（默认） | 无 | 输出 ISO 21496-1 HDR；保留源 Base Image、原始通道结构和完整 OPPO/QTI 元数据尾；源数据允许时 Gain Map 最高可达 HEVC RExt 4:4:4 |
| OPPO 相册兼容 | `--oppo-compatible` | 将 Gain Map 写成 OPPO 相册可消费的 HEVC Main Still Picture 4:2:0，并保留 OPPO 私有元数据尾 |
| Apple 人像 | `--apple-portrait` | 把 OPPO 人像景深、主体、宠物、头发和光圈信息转换成 Apple disparity、Portrait Effects Matte、Semantic Hair Matte、Focus 与人像元数据 |

> [!IMPORTANT]
> 省略 `--output` 或 `--output-dir` 时会覆写输入文件。转换前请备份原片。

### 默认：标准 ISO HDR

```bash
# 单张
swift xdremux/swift-cli/XDRemux.swift convert \
  --input IMG_001.heic \
  --output IMG_001_iso.heic

# 批量
swift xdremux/swift-cli/XDRemux.swift batch \
  --input-dir photo_dump/ \
  --output-dir iso_output/
```

默认不启用 OPPO 专用兼容层。XDRemux 尽量保留原始 Base Image，只重建标准
ISO Gain Map 图；单通道源保持单通道，未被降采样的三通道源可保留最高
4:4:4/HEVC Range Extensions。已经是 4:2:0 的 Gain Map 不会被伪装成
4:4:4，因为丢失的色度信息无法恢复。

默认同时保留完整的 OPPO/QTI/FileExtendedContainer 元数据尾，包括水印、
大师模式、拍摄参数、人像后期数据以及工具尚未识别的厂商字段。

### `--oppo-compatible`：OPPO 相册兼容

```bash
swift xdremux/swift-cli/XDRemux.swift convert \
  --oppo-compatible \
  --input IMG_001.heic \
  --output IMG_001_oppo.heic
```

此模式把高规格 Gain Map 转成 Main Still Picture 4:2:0，以触发 OPPO 相册的
HDR 显示。它仍保留 OPPO 私有元数据尾，因此适合需要回到 OPPO 生态的照片。

### `--apple-portrait`：转换 OPPO 人像景深

```bash
swift xdremux/swift-cli/XDRemux.swift convert \
  --apple-portrait \
  --input IMG_001.heic \
  --output IMG_001_apple_portrait.heic

# 批量时自动跳过没有完整人像资源的普通 HEIC
swift xdremux/swift-cli/XDRemux.swift batch \
  --apple-portrait \
  --input-dir photo_dump/ \
  --output-dir apple_portraits/
```

XDRemux 自动读取 `src.image`、`rear.depth`、`rear.depth.config` 和 Gain Map
参数：Base Image/Gain Map 只编码一次；rank plane 转成 Apple Float16
disparity；OPPO portrait/pet/hair plane 转成 PEM 与 Semantic Hair Matte；
Vision 只在主体 plane 为空时兜底，并用于选择人脸兴趣 Focus。OPPO 模拟光圈
会写入 Apple 人像编辑元数据，图像方向由原片自动确定。

Apple 人像模式会省略已经完成语义迁移的大型 OPPO 人像私有尾，避免同时保存
两套景深资源。它与 `--oppo-compatible` 互斥；同时指定会在写文件前报错。
Apple 虚化强度映射仍在设备验证阶段。

### Python CLI

> [!NOTE]
> 需要先安装依赖：`pip install pillow-heif Pillow numpy`

```bash
# 单张转换
python3 xdremux/python/XDRemux.py convert --input IMG_001.heic

# 批量转换
python3 xdremux/python/XDRemux.py batch --input-dir photo_dump/

# OPPO 相册兼容输出（旧名 --oppo-compat 仍可用）
python3 xdremux/python/XDRemux.py convert --oppo-compatible --input IMG_001.heic
```

Apple 人像转换目前由 Swift CLI 提供。

### macOS App

源码位于：

```text
apps/macos/XDRemuxApp/
```

本地构建和运行：

```bash
scripts/build_and_run.sh run
```

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
| `experiments/`           | 实验性代码。                         |

## 已知限制

- 转换后的照片在 OPPO 相册中再次编辑并保存后，HDR Gain Map 及其 HDR 元数据可能会丢失。

本工具仅供技术研究使用。转换前请备份原始文件。作者不承担任何关于数据丢失的法律责任。
