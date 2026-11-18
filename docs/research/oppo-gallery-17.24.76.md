# ColorOS 相册 17.24.12 / 17.24.76：真机容器实测、水印重封装、OLive 与 ODM 资产研究（2026-11-18）

> **问题**：核对 ColorOS 相册 17.24.12 与 17.24.76 相比 [oppo-gallery-17.10.5.md](oppo-gallery-17.10.5.md) 的新增/变更机制，并基于 Find X8 Ultra（`PKJ110`）真机 `/odm/` 资产与 5 组实拍/编辑样张建立可复现的二进制偏移、容器重封装与端侧算法依赖边界对照。
>
> **样本**：
> - `OppoGallery2.apk`（`com.coloros.gallery3d`，`versionName=17.24.76`，`versionCode=17024076`，`386,659,540` 字节，SHA-256 `d556a3144a6562b980af2a35b645d785533f799d17ea2548816e9a05cbd30dfe`）与基线 `17.24.12`（`17024012`）APK。
> - 真机（OPPO Find X8 Ultra / `PKJ110_17.0.1.201(CN01)` / ColorOS `V17.0.0`）拉取资产：`/odm/etc/camera/basictone/`（92 文件，`52,140,365` 字节）、`/odm/etc/camera/fb_model/AITM_*_65536_fp32.bin` 与 8 个 ODM/Product `.so`（二进制文件不入库）。
> - 真机实拍与编辑样张（不入库）：
>   - `IMG20261114172818.jpg`（`10,323,795` 字节，SHA-256 `fd72333ee9c9e9bb84feaee6ac989d3809dbeaed131a7d6f8fc69cb4b9c85e04`）
>   - `IMG20261114172831.jpg`（`9,655,339` 字节，SHA-256 `45de62706b256ac1bcfab78fc177a0e90a9a9c7c54bc3d8597b6c689115a3ad7`）
>   - `IMG20261116112820.heic`（`6,952,527` 字节，SHA-256 `12f53e72b1bbdf9f444dd36ee9f758cd861ce31c7d70bf669c55881edfe5ff00`）
>   - `wmtest-orig.heic`（`2,150,484` 字节，SHA-256 `0fe60c07befbd3ec9264fbba73c437985cde03e1f5266834b57e09cdc3544112`）
>   - `wmtest-final.heic`（`3,538,248` 字节，SHA-256 `7943a79e1e62f3d6677a6e69e9dd286e148358e2058aa56f2fb2dab9902b94ea`）
>
> **结论状态**：APK 静态拆包比对、真机 ODM 二进制表结构、OLive 偏移校验与 HEIC 水印重封装容器 Diff 均**已实测**；与 XDRemux 现有模块关联见 [../formats/oppo-proxdr.md](../formats/oppo-proxdr.md) 与 [../formats/oppo-watermark.md](../formats/oppo-watermark.md)。

---

## 1. `FileExtendedContainer`（`jxrs` 尾块）实测解析

**已实测**：对上述 5 份真机样张解码结尾 8 字节（`"jxrs"` + `uint32_le tail_len`），确认容器尾块逆向布局：

```text
[ 原生媒体容器 (JPEG / MP4 / HEIC + QTI box) ]
[ 扩展 Payload 块 (从 jstart 向前逆向连续存放) ]
[ UTF-8 JSON 目录数组 "[{...}]" + 0x00 填充 ]  <-- jstart = file_len - tail_len
[ "jxrs" (4 B) | uint32_le tail_len (4 B) ]    <-- EOF 前最后 8 字节
```

JSON 每一项 `{ "name", "offset", "length", "version": 1 }` 的起始文件偏移为 **`start = jstart - item.offset`**，长度为 `item.length`。

### 1.1 `private.emptyspace` 盒伪装机制

**已实测**：在 3 份 HEIC 样张中，`QTI ` box（`Debug Metadata\0`）之后、`jxrs` 载荷起始处的首项 `"private.emptyspace"`（固定 4 字节）均按大端 `uint32` 写入**整个 `jxrs` 尾部总字节数**；紧随其后的下一项首 4 字节版本号 `float32_le` 恰好落在 ISOBMFF box type 字段位置：

- `wmtest-orig.heic`：`private.emptyspace` = `0x0019a017`（`1,679,383` B = `2,150,484 - 471,101`），紧接 `watermark.device` 首字 `9a99993f`（`1.2f`）。
- `IMG20261116112820.heic`：`private.emptyspace` 总长 `5,723,850` B（`6,952,527 - 1,228,677`），紧接 `hdr.transform.data` 首字 `3333b33f`（`1.4f`）。

**推断**：此举使不识别 `jxrs` 的标准 ISOBMFF / HEIF 解析器将整个扩展尾块视为一个顶层扩展 box 整块跳过，避免报容器截断或未知尾字节错误。重写/裁剪 `jxrs` 时若保留 `"private.emptyspace"`，需同步刷新该大端 `uint32` 长度（或对照参考 [../formats/oppo-proxdr.md](../formats/oppo-proxdr.md) §6 重建规则）。

### 1.2 实测高频条目结构

**已实测**：

| 条目名 | 实测字节数 | 结构 / 内容摘要 |
| :--- | :--- | :--- |
| `src.image` | `1,365,391 B`（`wmtest`）<br>`2,351,575 B`（`172818.jpg`）<br>`5,203,986 B`（`112820.heic`） | 完整原始底图 JPEG，且其内部本身可携带 Ultra HDR JPEG `GainMap`（如 `wmtest` 中 `src.image` 内嵌 `143,978 B` 增益映射 JPEG） |
| `local.uhdr.gainmap.data` | `254,644 B` / `505,977 B` | 完整 JFIF JPEG 格式的增益映射图像 |
| `local.uhdr.gainmap.info` | 固定 `80 B` | `20 × float32_le`，实测值 `[1, 1, 1, 1, 4.926108, 4.926108, 4.926108, 1, 1, 1, 0×6, 1, 4.926108, 4.926108, 0]` |
| `hdr.transform.data` | `4,220 B`（v1.3）/ `4,300 B`（v1.4） | 首字为版本 `float32_le(1.3)` / `float32_le(1.4)` + 查找曲线与参数 |
| `filter.info` | `140 B` / `216 B` | `0..4` 为版本 `float32_le(4.0)`，`4..12` 为方向/镜像整型（`90, 90` / `90, 0`），`0x18` 为启用标志 `1`，`0x1c` 起含滤镜文件名（如 `"fuji_cc.bin"`） |
| `basictone.info` | 固定 `8,216 B` | 5 份样张均仅首 `float32_le` 为 `1.0`，其余 `2,053` 个 `uint32` 字全 `0` |
| `master.mode.preset.info` | `496 B` | `ver_f32=1.0`，含 `"dlq"` 预设标识 |
| `watermark.device` / `params` / `color` / `master.params` | `80 B` / `63 B` / `72 B` / `45,117 B` | 分别记录 `ver=1.2f` 机型 `"OPPO Find X8 Ultra"`、`ver=2.0f`、`ver=1.0f` 与哈苏大师模式槽位（含 `#1E1E1E`、`hassel_style_master_mode_1`、`master_model_filter_intensity=90`、`master_model_tone=-15`、`master_model_cyan_magenta=12` 等） |
| `live.subVideo` / `live.subVideoSize` | `318,819 B` / `340,102 B` | `IMG20261114172831.jpg` 与 `IMG20261114172818.jpg` 内附带的辅流 `ftypmp42` 视频与体积 |

---

## 2. HEIC 水印编辑重封装实测：`wmtest-orig.heic` vs `wmtest-final.heic`

**已实测**：对比相册添加水印前后的 HEIC 文件对（`wmtest-orig.heic` vs `wmtest-final.heic`）：

1. **HEIF 主体从单 `grid` 升级为标准 ISO 21496-1 `tmap` 容器**：
   - `wmtest-orig.heic`（`2,150,484 B`）：`meta` 内仅含 `grid` `10081`（9×9 = 81 `hvc1` tiles）与 `Exif` `10082`，`mdat` 为 `400,125 B`，**无** `tmap` 或增益映射 `grid`；其增益映射仅存在 `jxrs` 的 `local.uhdr.gainmap.*` 与 `src.image` 中。
   - `wmtest-final.heic`（`3,538,248 B`）：`mdat` 重编码扩增至 `1,782,590 B`，`iinf` 共 193 项，`pitm = 193`：
     - item `193`：`grid`，`4268×4420`（9×9 = 81 tiles），Display P3 ICC + `clli` + 3×8-bit `pixi`；
     - item `110`：`grid`，`2134×2210`（5×5 = 25 tiles，精确半分辨率），`nclx 2/2/6` + 3×8-bit `pixi`（增益映射 HEVC 流）；
     - item `111`：`tmap`（`idat` 内 `62 B`，`iref dimg: 111 -> [193, 110]`），`ipco` 关联 `nclx 9/16/9`（**BT.2020 + PQ ST.2084** 备选 HDR 色彩空间）与 `3×10-bit` `pixi`；`tmap` 内部有理数实测为 `gain_map_min=0.0`、`gain_map_max=9648787/4194304=2.30045`、`base_hdr_headroom=0.0`、`alt_hdr_headroom=2.30045`、`gamma=1.0`、`base_offset=alt_offset=10737/1073741824≈1e-5`；
     - 另有同分辨率 `grid` `82`（`4268×4420`，81 tiles，共用 `ipco` 1/2/4/6/5）、XMP `mime` `84`（`538 B` `application/rdf+xml`，`cdsc -> [193, 111]`）与 `Exif` `83`（`1,162 B`，`cdsc -> [193, 111]`）。
2. **`QTI ` box 与 `jxrs` 尾部逐字节无损迁移**：
   - `wmtest-orig.heic` 的 `QTI ` box（`65,996 B`，SHA-256 前 16 位 `bf00e7b108cb1650`）与 `jxrs` 全区（`1,679,383 B`，SHA-256 前 16 位 `06c7f7856e8c31df`），在 `wmtest-final.heic`（偏移 `1,792,869` 起）中与原片**完全逐字节一致**。

---

## 3. OLive 实况图混排容器中 `OpCamera:VideoLength` 与 `Item:Length` 的口径差异

**已实测**：在两张带 OLive + Ultra HDR + `jxrs` 的实拍 JPEG 中验证字节边界：

- `IMG20261114172831.jpg`（`9,655,339 B`）：
  1. 主图 JPEG：`0 .. 3,304,812`（`Container:Item` `Item:Length="0"`）
  2. GainMap JPEG：`3,304,812 .. 3,664,008`（`Item:Length="359196"`，`SOF0` `1536×2048` 3 分量，`hdrgm:GainMapMax="2.30045"`）
  3. MP4 (`ftypmp42`)：`3,664,008 .. 7,016,584`，严格等于主图 XMP **`OpCamera:VideoLength="3352576"`**
  4. 尾部 `jxrs`：`7,016,584 .. 9,655,339`（`2,638,755 B`）
- 主图 XMP 中 `Item:Semantic="MotionPhoto"` 的 **`Item:Length="5991331"`** = `3,352,576 + 2,638,755 = EOF - 3,664,008`。
- `IMG20261114172818.jpg`（`10,323,795 B`）遵循完全一致的规则：`GainMap=390,810`，`OpCamera:VideoLength=3,811,297`，`MotionPhoto Item:Length=6,516,995`。

**已实测（APK 静态验证）**：对照 `17.24.76` APK 中 `OliveFileExtenderContainerHelper`、`OLiveDecodeImpl (v1.2.7)`、`JpegOLiveWriter` 与新增的 `TravelOliveLengthRefreshScanner` / `OliveSaveSpec`，确认相册在写入/擦除尾部扩展数据后会调用 `refreshOliveVideoLength()` 刷新 `MotionPhoto Item:Length` 使其包含尾部扩展区长度，而保持 `OpCamera:VideoLength` 指向纯 MP4 长度。**未验证**：第三方在裁剪/清除 `jxrs` 后若仅更新其中一处长度，ColorOS 17 相册侧的兼容性表现尚未实机对比测试。

---

## 4. `17.24.12 -> 17.24.76` 关键增量与真机 `/odm/` 算法资产验证

### 4.1 `17.24.76` 关键增量

**已实测**（静态 DEX + 资源 Diff）：

1. **`OutputResolution` 保存规格管线**（`com.oplus.gallery.photoeditor.editingvvm.outputresolution`，32 个类，在 `17.24.12` 与 `17.24.76` 均完整存在）：
   - `SizeGrade` 分档：`ORIGINAL(100)`、`LARGE(75)`、`MEDIUM(50)`、`SMALL(25)`、`CUSTOM(-1)`（受 `maxCustomSide` 限制）；
   - `QualityGrade` 五档质量常量：`BEST(97)`（默认）、`HIGH(92)`、`MEDIUM(85)`、`LOW(75)`、`LOWEST(60)`；
   - 通过 `InputFileContainerRetriever` + `CompressMeasurer` 在 `quality=97` 实测编码体积并叠加 `ExportExtraSizeEstimator`（含 `live.subVideoSize`、`watermarkCaptureSize` 等）预估大小，选项序列化进 `"edit.project.save_option"`。
2. **分块增益映射边缘对齐修复**：`GalleryTileRegionDecoder` 新增 `padGainmapToDestSize`，当 tile 解码出的增益映射尺寸与目标尺寸不匹配时在左上角 `1:1` 绘制并对右/下边缘像素做复制填充（edge-replicate），防止边缘 Gain 跳变。
3. **水印模板微调**：`assets/watermark_master_styles/hassel_style_1.json` 中右对齐参数列（`id: 3`）的 `content.width` 由 `148` 调至 `152`。
4. **流式 OLive 写入与导出看门狗**：`OLiveDecodeImpl v1.2.7` 引入流式 SOS 写入、`OliveSaveSpec$MeicamBitrateLevel`（`HIGH/MIDDLE/LOW`）与 `ExportImpl.idleWatchdog`。

### 4.2 `/odm/` 查找表格式与闭源依赖边界

**已实测**：真机拉取的查找表均为小端 `float32` 裸表（无文件头）：

| 真机资产 | 文件大小 | 逻辑结构 | 实测范围 / 配置对应 |
| :--- | :--- | :--- | :--- |
| `AITM_hdr2sdr_65536_fp32.bin` | `262,144 B` | `65536 × float32_le` (1D LUT) | `[0.000158, 1.000000]`，单调递增逆色调映射曲线 |
| `AITM_sdr2hdr_65536_fp32.bin` | `262,144 B` | `65536 × float32_le` (1D LUT) | `[0.000000, 1.000000]`，单调递增 HDR 扩展曲线 |
| `basictone/lmt/SC16Lut0`, `SC16Lut4`, `CWCM16Lut0` | `49,152 B` | `16³ × 3` RGB `float32_le` 3D LUT | 对应 `.ini` 中 `SCLutNum=9`、`CMCWLutNum=9`（`-100/0/100` 3×3 网格） |
| `basictone/lmt/LMTLut0`, `odt/ODT_Photo` | `3,145,728 B` | `64³ × 3` RGB `float32_le` 3D LUT | 对应 `SimTool_Photo_Master.ini` 中 `mergeSize=64`（`Sensor0..3/LMTLut0` 为 `32³ × 3`） |
| `basictone/vig/VigTab_Main` | `884 B` | `17 × 13` `float32_le` 暗角网格 | `[0.78125, 1.00000]`，对应 `VigTableWidth=17, VigTableHeight=13` |

同时确认核心 native 符号边界：**可移植模块**包括 `assets/pipeline/{uhdr/fs_uhdr.glsl, gray/fs_gain_single.glsl, gamut/fs_gamut.glsl}`（log 域系数、单通道 `pow(max, 1/2.2)`、HLG/PQ/sRGB 矩阵）与 `assets/glsl/basic_tone_*`；**强依赖真机 `/odm/` 与 `/product/` 闭源 `.so`** 的能力包括 `libCombineLut.so`（`CombineLut_V2.0.3.3`）、`libPalette-Jni.so`（`PaletteP010Gl.cpp` P010/RGBA1010102 AHardwareBuffer 渲染）、`libOPAlgoCamHDRTransformCamera.so`、`libOPAlgoCamCoverEnhancer.so`（OpenCL + `RRDBNet_sm8750.bin` 等模型）及 `libOPAlgoCamITMC.so`。
