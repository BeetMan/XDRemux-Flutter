# Motion Photo 解析器对拍：xdremux-core vs LibLivePhoto（2026-11-15）

> 问题：我方 `xdremux/rust/src/motion_photo.rs` 与上游作者的 LibLivePhoto 对同一批文件的判定是否一致。2026-08-27 的三方差分（`motion-photo-parser-differential.md`）只用了 12 个合成 fixture，OPPO 真机一直未验证。
> 对象：我方 `origin/main @ e5bb1d2` 的 `parse_motion_photo` + `primary_video_range` + `standalone_bmff_length`，即 `xdremux_make_live_photo` 实际交给 remux 的视频（`xdremux/rust/src/lib.rs:319-324`）；LibLivePhoto `main @ 9328a05`（v0.1.0 之后），`MotionPhoto::parse(Input::SingleFile, ParseOptions::compatible())`。
> 结论状态：**已实测**（2026-11-15，macOS，`tests/motion-diff` release 构建）。设备与相册行为**未验证**。

## 一页结论

1. **真机动态照片 21 个全部一致**：上游 fixtures 14 个（OPPO ColorOS 15 ×3、ColorOS 16 双码流 ×2、三星 HEIC ×4、三星 JPEG ×2、vivo ×2、小米 ×1）加本机 OPPO 实况 7 个，识别、静帧范围、视频范围、呈现时间四项都相同。三方差分遗留的"OPPO 真机未验证"由此关闭。
2. **普通照片 174 个，我方判定正确**：本机 174 个非动态照片我方全部判为普通照片；LibLivePhoto 有 132 个一致，另外 42 个报错（39 个 Apple 原生 HEIC 与本项目转换出的 HEIC 报 "Motion Photo XMP is malformed"，3 个不带视频的 OPPO Ultra HDR JPEG 报 "resource ranges are invalid or overlap"）。已核对这 3 个 OPPO 文件没有 MotionPhoto 标记、没有 `ftyp`，确实不是动态照片。
3. **一个真实的覆盖差距**：只写在三星 SEF 里、没有 Google XMP 的动态照片，我方不识别（LibLivePhoto 合成样本 `samsung-normal.jpg`、`distinct-normal.jpg`）。我方真机三星样本都带 XMP，不受影响；这种文件在真实设备上是否仍在产生**未验证**。
4. **导出路径口径不同（不是解析错误）**：`xdremux_motion_photo_split`（Flutter `MotionPhotoService.exportVideos` 与原生 Apple 端 `XDRemuxEngine.splitMotionPhoto` 都调用它）按粗范围原样写出 MP4，会带上视频后的厂商字节。LibLivePhoto 把这段标为 `OpaqueSuffix`。ffprobe 对带尾字节和裁剪后的文件给出相同的时长与流数、没有告警；照片 App / AVFoundation 的反应**未验证**。转换路径已经裁剪，不受影响。
5. 本次没有发现需要修的解析 bug。

## 方法

工具 `tests/motion-diff` 是独立 crate，有自己的 `[workspace]`，不进根 workspace，常规构建和 CI 不会去拉 LibLivePhoto。

```bash
cargo run --release --manifest-path tests/motion-diff/Cargo.toml -- [--json] <文件或目录>...
```

对每个 `.jpg/.jpeg/.heic/.heif/.avif` 文件比较四项：状态（动态照片 / 普通照片 / 报错）、静帧字节范围、视频字节范围、呈现时间（µs）。两边的格式命名体系不同，`kind` 只打印、不比较。我方的视频范围按转换路径取：`primary_video_range` 后再用 `standalone_bmff_length` 截到最后一个完整 BMFF box；LibLivePhoto 取 `motion_video()` 的单一 extent。退出码：全部一致为 0，有差异为 1。

语料（文件都不入库）：

| 组 | 来源 | 数量 | 许可与隐私 |
|---|---|---|---|
| A | 上游 `21Z121Z1/XDRemux` 的 `fixtures/motion-photo/**`（`main @ b8148ca`），用 `git show` 导出到临时目录，按上游 `fixtures/SHA256SUMS` 校验 14/14 通过 | 14 | 上游 fixture 许可允许本地互操作测试和只含元数据的发布，不得再分发 |
| B | LibLivePhoto `fixtures/` 与 `web/public/demo/` 中的 JPEG/HEIC（合成） | 21 | Apache-2.0 / CC0 |
| C | 维护者本机样张：OPPO 实况、iPhone 原生 HEIC、OPPO HEIC、本项目转换产物 | 181 | 私有，只发布汇总 |

## 结果

### A 组：上游真机 fixtures（14/14 一致）

"尾字节"是原始范围比转换路径多出的厂商字节；"双码流"列给出原始全长。

| 文件 | 我方 kind | LibLivePhoto kind | 静帧 | 视频 | PTS (µs) | 尾字节 | 双码流 |
|---|---|---|---|---|---|---|---|
| `oppo/coloros15-ultrahdr-01.jpg` | oppoLivePhoto | AndroidMotionPhoto/Oplus | 0..5212915 | 5212915..15163112 | 1469600 | 2572 B | 否 |
| `oppo/coloros15-ultrahdr-02.jpg` | oppoLivePhoto | AndroidMotionPhoto/Oplus | 0..4610334 | 4610334..13356899 | 1433190 | 2572 B | 否 |
| `oppo/coloros15-ultrahdr-03.jpg` | oppoLivePhoto | AndroidMotionPhoto/Oplus | 0..19365654 | 19365654..30678020 | 1666600 | 2638 B | 否 |
| `oppo/coloros16-dualstream-ultrahdr-01.jpg` | oppoLivePhoto | AndroidMotionPhoto/Oplus | 0..6809684 | 6809684..23192390 | 1533287 | 18732 B | 是（全长至 24929781） |
| `oppo/coloros16-dualstream-ultrahdr-02.jpg` | oppoLivePhoto | AndroidMotionPhoto/Oplus | 0..13591436 | 13591436..27230414 | 1298732 | 4412 B | 是（全长至 29199130） |
| `samsung/heif-ultrahdr-01.heic`（及其副本 `-duplicate-r002`） | androidHeifMotionPhotoV1 | AndroidMotionPhoto/SamsungSef | 0..1232154 | 1232162..5181667 | 1540401 | 0 | 否 |
| `samsung/heif-ultrahdr-02.heic`（及其副本 `-duplicate-r003`） | androidHeifMotionPhotoV1 | AndroidMotionPhoto/SamsungSef | 0..1217171 | 1217179..5586957 | 2518658 | 0 | 否 |
| `samsung/jpeg-ultrahdr-01.jpg` | androidMotionPhotoV1 | AndroidMotionPhoto/SamsungSef | 0..2689001 | 2689001..6842454 | 1573888 | 116 B | 否 |
| `samsung/jpeg-ultrahdr-02.jpg` | androidMotionPhotoV1 | AndroidMotionPhoto/SamsungSef | 0..2690459 | 2690459..3751980 | 1585246 | 116 B | 否 |
| `vivo/android-v1-sdr-01.jpg` | androidMotionPhotoV1 | AndroidMotionPhoto/AndroidStandard | 0..3307962 | 3307962..6031584 | 1333944 | 0 | 否 |
| `vivo/android-v1-sdr-02.jpg` | androidMotionPhotoV1 | AndroidMotionPhoto/AndroidStandard | 0..3036474 | 3036474..9638904 | 838055 | 0 | 否 |
| `xiaomi/android-v1-ultrahdr-01.jpg` | androidMotionPhotoV1 | AndroidMotionPhoto/AndroidStandard | 0..9541876 | 9541876..10550148 | 430574 | 0 | 否 |

- 三星 HEIC 的静帧结束与视频开始相差 8 字节，是 `mpvd` box 头，两边一致。
- 双码流两边都取文件中靠前、较大的第一码流（约 16.4 MB / 13.6 MB；第二码流约 1.7 MB / 2.0 MB），与三方差分 fixture 05 的结论一致。
- 尾字节内容：三星为 SEF 块（`SEFH` … `SEFT`）；OPPO 单码流文件末尾是含机型字符串（如 `OPPO Find X8 Ultra`）和 JSON 的厂商块，以 `jxrs` 结尾；双码流的两条码流之间也有一段以 `OPPO Find X9` 开头的厂商块。

### B 组：LibLivePhoto 合成样本（14 一致，7 不同）

- 一致：8 个动态照片（标准 Motion Photo、vivo 变体、CC0 demo）、6 个普通照片。
- 不同，全部是三星 SEF 样本，且我方都判普通照片：
  - `vendor/samsung-normal.jpg`、`vendor-selection/distinct-normal.jpg`：LibLivePhoto 识别为 `Unspecified/SamsungSef` 动态照片（视频只在 SEF 里，没有 Google XMP）。**这是真实的覆盖差距。**
  - `vendor/samsung-ambiguous.jpg`、`vendor/samsung-bad-pointer.jpg`、`vendor-selection/distinct-ambiguous.jpg`、`vendor-selection/distinct-bad-pointer.jpg`、`vendor-selection/pointer-alias.jpg`：LibLivePhoto 报错（候选不唯一或指针越界）。两边都不会转换，只是分类不同。

### C 组：本机样张（139 一致，42 不同）

- 一致：7 个 OPPO 实况（含 4K、大师/标准模式 1x/3x），四项全同；132 个普通照片。
- 不同：42 个，全部是"我方普通照片 / LibLivePhoto 报错"。
  - 39 个 HEIC（iPhone 原生、iPhone 摄影风格原片、本项目转换产物）：LibLivePhoto 报 "Motion Photo XMP is malformed"。这些文件都是单独的 HEIC 静帧，视频在独立的 MOV 里或根本没有。
  - 3 个 OPPO JPEG：XMP 目录只有 Primary 和 GainMap 两项，没有 MotionPhoto 标记，全文件没有 `ftyp`，是不带视频的 Ultra HDR 照片；LibLivePhoto 报 "resource ranges are invalid or overlap"。

## 导出路径的尾字节

`xdremux_motion_photo_split`（`xdremux/rust/src/lib.rs:248-264`）把 `video_range` 写成 `<stem>.video.mp4`，双码流时再把 `primary_video_range` 写成 `<stem>.primary.mp4`，都不裁剪。Flutter `MotionPhotoService.exportVideos`（`apps/flutter/lib/services/motion_photo_service.dart:151`）把它们导出为 `<stem>.motion.mp4` / `<stem>.primary.mp4`，原生 Apple 端 `XDRemuxEngine.splitMotionPhoto`（`apps/apple/Packages/XDRemuxKit/Sources/XDRemuxKit/MotionPhoto.swift`）直接返回这两个路径。对 A 组样本：

- 单码流：导出的 MP4 末尾多出三星 SEF 116 B 或 OPPO 厂商块约 2.6 KB。
- 双码流：`video.mp4` 是第一码流 + 厂商块 + 第二码流 + 尾部，`primary.mp4` 是第一码流 + 厂商块。

ffprobe（`-v warning`）对带尾字节与裁剪后的文件给出相同的时长与流数，没有告警（三星 JPEG-01、OPPO 15-01、OPPO 16-01 三组已实测）。照片 App 与其他播放器是否接受**未验证**。

## 跟进建议

- **P2 导出视频去掉厂商尾字节**：单码流 `video.mp4` 和 `primary.mp4` 用 `standalone_bmff_length` 裁剪，与转换路径一致。双码流的 `video.mp4` 应改为分别导出两条码流，这会改变 split 的输出约定，Flutter 与 SwiftUI 要一起改。建议先确认照片 App 能否导入带尾字节的 MP4，再定优先级。
- **P2 三星"只写 SEF"的动态照片**：先拿到真机原片，证明这种文件仍在流通，再参照 LibLivePhoto 的三星 SEF 解析实现；没有真机样本前不做。
- **回归**：上游 fixtures 或 LibLivePhoto 更新后，改 `tests/motion-diff/Cargo.toml` 中的 `rev` 重跑。三组语料的取得方式见上文"方法"。

## 不适用条件

- 只覆盖单文件动态照片；Apple HEIC+MOV 配对不在 `parse_motion_photo` 的范围内。
- LibLivePhoto 只跑了 compatible 模式；strict / forensic 模式的结果可能不同。
- 结论只对所列样本和版本成立；照片 App、安卓相册与其他播放器的行为都未验证。
