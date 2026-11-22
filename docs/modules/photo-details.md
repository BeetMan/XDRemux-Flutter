# 照片详情（photo_details / oppo_details）

> 对应代码：`xdremux/rust/src/photo_details.rs`（EXIF、HDR 摘要）、`xdremux/rust/src/oppo_details.rs`（OPPO 私有尾部）、FFI `xdremux_inspect_photo_details`。
> Flutter 侧：`apps/flutter/lib/models/oppo_tail_details.dart`、`lib/main.dart` 的 `PhotoDetailsContent`。
> 探针：`oppo_details_probe`（逐个文件打印 `oppo` 对象，加 `--entries` 连条目清单一起打印）。

## 1. 报告结构

`xdremux_inspect_photo_details` 返回一个 JSON 对象。拍摄参数和 HDR 摘要是顶层的键（`model`、`fNumber`、`hdrKind`、`edrScale` 等）。文件带 OPPO 尾部时多一个 `oppo` 对象，没有尾部时没有这个键。

`oppo` 只报告布局核对过的字段。读不到或校验不过的字段直接省略，不填默认值；其余条目只列名字和大小。

| 键 | 内容 | 来源条目 |
|---|---|---|
| `entries` | 尾部清单，每项 `name`、`length`，按清单顺序 | 尾部 JSON 清单 |
| `device` | 相机印在水印里的机型名 | `watermark.device` |
| `watermark.kind` | `png`、`frame`、`unknown`、`none` | `watermark`、`watermark.master.params` |
| `watermark.width` / `height` | PNG 叠加层的尺寸（`png`） | `watermark` 的 IHDR |
| `watermark.style` | 样式名（`frame`） | `watermark.master.params` 的 4 到 67 字节 |
| `watermark.picture` / `margins` | 边框内画面的矩形和四边边框宽度（`frame`，且矩形通过校验时） | `watermark.master.params` 末尾块 |
| `filter` | 滤镜配方，见 §2.3 | `filter.info` |
| `portrait` | 人像景深数据，见 §2.4 | `rear.depth.config` 或 `front.depth.config` |
| `sourceImage` | 未处理原图的宽高 | `src.image` |

## 2. 各字段的依据

### 2.1 机型名

`watermark.device` 是一个版本 float、一个字节、然后是以 NUL 结尾的名字。**已实测**（2026-11-17，85 个本机文件）：长度 43、47、80 三种，版本 1.0、1.1、1.2，名字都从第 5 字节开始；机型有 Find X8 Ultra、Find X10、Find X6 Pro、Find X7 Ultra，另有一个文件写的是型号代码 `PJE110`。

### 2.2 水印

- `png`：`watermark` 条目以 PNG 签名开头。
- `frame`：有 `watermark.master.params`。画面矩形经 `container::watermark_frame_picture_rect` 读取，只认三种核对过的样式，布局和校验见 `formats/oppo-watermark.md` §4.3。其他样式只报样式名。
- `unknown`：有水印条目，但两种都不是。本机有 2 个这样的文件，只带 `watermark.device` 和 `watermark.params`。
- `none`：没有水印条目，或者只有 `watermark.device`（Find X10 关闭水印拍的原片）。

**已实测**（2026-11-17，100 个带尾部的本机文件）：`frame` 39 个，全部读到矩形（含 5 个 JPG）；`png` 13 个；`unknown` 2 个；`none` 46 个。

### 2.3 `filter`

字段顺序和各字段出现的版本来自相册 17.24.12 的解析类，见 `research/oppo-gallery-17.24.12-20261114.md` §1。

| 键 | 偏移 | 出现条件 |
|---|---|---|
| `version` | 0（float） | 总是 |
| `intensity` | 4 | 总是 |
| `sourceOrientation` | 8 | 总是 |
| `mirrored` | 12，等于 1 时为真 | 总是 |
| `softLight` | 16，非 0 时为真 | 总是 |
| `enabled` | 24，非 0 时为真 | 总是 |
| `lut` | 28，100 字节的字符串 | 非空时 |
| `colorTemperature` | 128（float） | 版本 ≥ 2.0 |
| `luxIndex`、`saturation` | 132、136（float） | 版本 ≥ 4.0 |
| `palette`、`tone`、`captureMode` | 140、152、156 | 版本 ≥ 5.0 |

- 版本不在 1 到 100 之间，或者条目不足 128 字节时，整个 `filter` 不报告。
- 没有报告的字段：`softLightType`、`paletteAlgoUsed`、`portraitMaskUsed`，以及版本 5.1 的三个亮度值（文件里的位置和解析类算出来的位置不一致，见研究笔记）。
- **推断**：偏移 16 和 20 哪个是开关、哪个是类型，只有标签顺序作依据；本机原片里两者的值总是相同。
- **未验证**：`colorTemperature` 和 `luxIndex` 的单位。界面只显示数值，不加单位。
- **已实测**（2026-11-17）：53 个带 `filter.info` 的本机文件，版本 4.0 的 50 个，5.1 的 3 个（Find X10，`captureMode` 是 `common`）。

### 2.4 `portrait`

- 后摄（有 `rear.depth`）：`camera` 为 `rear`，`fNumber` 取 `rear.depth.config` 偏移 292 的 `currentFNumber`。
- 前置（有 `front.depth`）：`camera` 为 `front`，`depthWidth`、`depthHeight`、`faceCount`、`mirrored`、`fNumber` 取自 `front.depth.config`，字段表见 `modules/portrait-pipeline.md` §3.2。
- **已实测**（2026-11-17）：本机 8 张后摄人像的光圈是 9.0、4.5、3.5；2 张前置人像都是 820×616、1 张人脸、镜像、光圈 4.5。

## 3. 界面

Flutter 详情页在「HDR & 动态范围」之后多一个「OPPO 私有数据」分组，文件没有尾部时不出现。「复制全部信息」也带上这一组。

| 行 | 内容 |
|---|---|
| 水印机型 | `device` |
| 水印 | 烘焙边框、PNG 叠加层加尺寸、类型未识别、无 |
| 水印样式 | `watermark.style` |
| 边框内画面 | 画面宽高和四边边框宽度 |
| 滤镜 | LUT 名、强度、柔光、调色盘；`enabled` 为假时显示「未启用」 |
| 拍摄时的光线 | 色温和照度指数 |
| 相机记录的模式 | `captureMode` |
| 原图方向 | `sourceOrientation`，镜像时注明 |
| 滤镜数据版本 | `version` |
| 人像景深 | 前置或后摄、景深平面尺寸、虚化光圈、人脸数、镜像 |
| 未处理原图 | `src.image` 的宽高 |
| 尾部条目 | 条目数和总大小 |
| 条目清单 | 每个条目的名字和大小，可选中复制 |

界面没有显示 `saturation` 和 `tone`。

Apple 原生应用（`apps/apple`）还没有接入：`PhotoDetails` 没有 `oppo` 字段，解码时忽略这个键。

## 4. 验证

- **已实测**（2026-11-17）：`oppo_details_probe` 跑了本机 203 个 HEIC / JPG，100 个带尾部，没有报错。
- **已实测**：Rust 单元测试 `oppo_details::tests`（6 条）；Flutter 测试 `test/oppo_tail_details_test.dart`（9 条，含 320 和 390 宽度下的详情页）。Flutter 主机测试加载的是真实的核心库。
- **未验证**：没有在真机或模拟器上打开过详情页，界面只通过组件测试渲染过。
- 详情页在 320 宽、2 倍字号下有一处横向溢出 11 像素（`main.dart:7025` 的底部按钮行），加这个分组之前就有，这次没有改。
