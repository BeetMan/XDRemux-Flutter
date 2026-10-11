# ColorOS 相册 17.10.5：HDR、编辑与人像

静态阅读 `com.coloros.gallery3d` 17.10.5（版本号 17010005）的 base APK，用来核对 XDRemux 已经在搬的 OPPO 相机尾数据。没有运行相册，也没有方法级反编译。

样张家族见 [oppo-proxdr-families.md](oppo-proxdr-families.md)。那篇是 Find N3 / Find X8 Ultra 原片的容器差异；这篇是 17.10.5 相册怎么显示和编辑这些数据。

样本：

- 路径：`C:\Users\Beet\Downloads\Telegram Desktop\相册(com.coloros.gallery3d)-17.10.5(17010005)-base.apk`
- SHA-256：`3f7689a23ec0b7ae450c8cdb9f26c4ccc9d59fefceeb5b8a5b260452b8b91004`
- 约 215 MB，18 个 dex，只带 `arm64-v8a`
- 这是 base 包。分包里的资源不在本次范围内

证据来自资源、着色器、DEX 字段表和 native 符号。调用顺序是从类名和日志字符串推出来的，不是执行轨迹。

## 和 XDRemux 的关系

相册把尾数据分成显示、重虚化和画框三类。现有保留策略和这个分法一致：

- HDR 参数在 `xdremux/rust/src/iso21496.rs`、`xdremux/rust/src/container.rs`
- 后摄景深在 `xdremux/rust/src/portrait_depth.rs`
- 人像与 HDR 尾条目名单在 `container.rs` 的 `PORTRAIT_EDITING_ENTRY_NAMES`

这次没有改这些实现。下面只记录相册侧观察到的机制，以及还缺的样张。

## HDR

相册声明四种编码：`local_hdr`、`ultra_hdr`、`hdr_hlg`、`hdr_pq`。

大图提亮走 `PhotoBrightenSectionCompatLHDR` → `HdrImageRendererCompatLHDR`，屏幕侧是 `BrightenSessionManager` 和 `EdrFlags`。机型是否开启 Local HDR 由 `LocalHdrDecision` 和 `libLocalHdrRus-jni.so` 决定。

文件侧：

- Local HDR 元数据键 `LOCAL_HDR_INFO_KEY_BYTE_ARRAY`，结构 `LocalHdrInfoStruct` 是 4 个 float，对应现有的 `version`、`length`、`metaSize`、`offset`
- Ultra HDR 是 `UltraHdrInfo` / `OplusUhdrInfoStruct`。`libUhdrUtils-jni.so` 的 `oplus_uhdr_mask2map` 把线性 mask 转成 gainmap
- gainmap 字段与 `parse_oppo_uhdr_info` 的 20 float 一致：`ratioMin/Max`、`gamma`、`epsilonSdr/Hdr`、`displayRatioSdr/Hdr`、`scale`，文件块末尾还有 `baseImageType`
- `local.hdr.linear.mask` 是 JPEG。现有 Swift 路径已按 `FF D8` 提取，Local HDR 按灰度解，Ultra HDR 按 RGB 解

显示有两套着色器：

- `assets/colorspace/shaders/` 来自 AndroidX Media3。Ultra HDR 按 Android Gainmap 公式合成，峰值按 1000 nit、SDR 白点按 500 nit 固定
- `assets/pipeline/uhdr/fs_uhdr.glsl` 是相册自己的合成。权重用设备当前 HDR/SDR 比，再乘色域矩阵，输出编回 sRGB
- `assets/pipeline/gray/fs_gain_single.glsl` 把彩色 gainmap 收成单通道最大值，再编成 gamma 2.2

所以同一张 gainmap，在 ColorOS 相册和按 ISO 21496 解码的软件里，亮度权重可以不同。

### hdr.transform.data

`com.oplus.gallery.foundation.codec.extend.HdrTransformData` 会 `toBytes()` 写入这条尾数据。字段包括：

- `version`
- 拍摄条件：`cameraMode`、`luxIndex`、`zoomFactor`、`faceNum`、`faceLumaRatio`
- `gammaEnable`，以及 `hlgDstGammaTable`、`srgbDstGammaTable`
- 仅完整结构有的预览表：`previewHlgDstGammaTable`、`previewSrgbDstGammaTable`
- `lutEnable`、`lightUpEnable`
- 锐化：`sharpenEnable`、`sharpenRadius`、`sharpenSigma`
- `tmcMode`、`tmcFeatureArr`、`ccmData`、`imageCoeff`

人像插件里的同名副本少了预览 gamma 表和 `tmcFeatureArr`。`HdrTransformType` 有 CPU 和 GPU。JNI 入口是 `com.oplus.ocs.camera.hdrtransform.HdrTransform.transact`，算法在 `libOPAlgoCamHDRTransformGallery_mtk.so` / `_qcom.so`。

默认 gamma 表在 `assets/hdrtransform/`，各 1028 字节，即 257 个无符号整数。native 读取下标 1、50、100、255、256。范围是 10-bit：`srgb.gamma`、`dolbyHlg.gamma`、`dolbySrgb.gamma` 收到 1023，`hlg.gamma` 收到 897。四条曲线起点不同。

紧凑尾策略留下 `hdr.transform.data` 和 `src.local.hdr.linear.mask` 是符合相册编辑方式的：滤镜、水印、人像虚化声明为 `independent` 时，不把这些效果烤进 gainmap。丢掉变换数据之后，标准 gainmap 仍可能发亮，但按拍摄场景做的 CCM、锐化和提亮不在了。

`toBytes()` 的字段顺序还没有从字节布局上拆开。DEX 字段表按名字排序，不能当成文件顺序。

## 编辑插件

插件池在 `assets/tbluniformeditor/plugin/`。HDR 编辑方式只有两种：`independent`（画面和 gainmap 分开改）和 `combine`（合成后一起改）。

支持 HDR 的包括调节、滤镜、调色盘、水印、变形、人像虚化、纹理混合、IPU 滤镜。不支持 HDR 的包括美颜、普通模糊、马赛克、AI 消除、AI 修复、AI 水印、相框。

普通滤镜是美摄 `.MS-LUT` 三维查找表，强度 0 到 1，清单在 `tbl_uniform_editor_filter_information.json`。边长 17 或 32。相机色彩风格是另一组 `key_camera_*` LUT，走 `IpuFilterAlgoImpl` 和 `BasicToneProcessor`，LUT 在相册包里，不在照片里。照片尾里对应保留的是 `gr.effect.info` 和 `master.mode.preset.info`。

调色盘 `ColorPaletteAlgoImpl` 的 HDR 方式只有 `combine`。被相册用 combine 改过的图，20 float 不再是相机原值。

## 水印

大师水印样式在 `assets/watermark_master_styles/`，由 `WatermarkMasterStyle` 解释。`hassel_style_1` 以 360 为基准边长，底边留白 60，文字用系统字体，`textSource` 指向拍摄信息。系列包括哈苏、Lumo、个性化和 realme。

合成在 `MasterWatermarkAssembler.watermarkComposite`。水印插件支持 `local_hdr` 和 `ultra_hdr`，方式是 `independent`。照片里留下的是已画好的 PNG 和 `watermark.config`。现有几何对齐对的是这块结果，不是 JSON 模板。

## 人像

相册人像编辑是用相机已经写入的深度和遮罩重新虚化。插件 `PortraitBlurAlgoImpl` 支持全部四种 HDR 编码，方式是 `independent`。

### 前置

`FrontDepthData` 是参数。像素在相邻尾条目里：

| 尾条目 | 内容 |
| --- | --- |
| `front.depth` | 深度 |
| `front.segment` | 人体分割 |
| `front.hair.mask` | 头发 |
| `front.matter.info` | matte 灰度图，带 `startXSrc`、`startYSrc`、`widthSrc`、`heightSrc` |
| `front.negevimg` | 欠曝帧，由 `isNegEVImgEnable` 决定 |

参数还有 `version`（结构常量 `VERSION_V1_1`）、`fNumber`、`blurStrength`、`lightStrength`、人脸框、`refocusModeAps`。引擎是 `FrontPortraitBlurEngine`，native 为 `libportraitblurjni.so` 和 `libOPAlgoCamSinglePortrait.so`（路径字符串含 `oppo_selfiebokeh`）。单摄链是分割与深度、头发 matting、景深遮罩，再做虚化渲染。

只保留前置深度、不保留头发和分割时，不能按相册的方式重虚化。当前 Rust 人像实验室消费的是后摄 `rear.depth`。

### 后摄

后摄是虹软双摄重对焦：`RearPortraitBlurEngine`，库版本字符串 `ArcSoft_DualCamRefocus_2.0`，JNI `JNIArcEngine_DualCamRefocusJarJNI_3.0.18`。调节量是焦点、`f_aperture`、`blur_strength`。

`RearDepthStruct` 的版本常量从 V2 到 `VERSION_V4_0`。`portrait_depth.rs` 接受 1.0 到 4.0，并读取版本、焦点、光圈和距离，与这个版本化配置相符。float 38 到 58 的曲线对应字段 `blurApertures` / `blurValue`。

`rear.spotlight` 是单独的光斑图，配置里有宽高、`lightSpotStrength` 和锐化。`mesh.coord` 是 `FaceCoordData`，给人脸三角网格，`isSupportMeshWarp` 用它把脸从虚化里摘出来。这两项已经在 `PORTRAIT_EDITING_ENTRY_NAMES` 里。Apple 景深不用它们；OPPO 再次编辑需要它们。

配置里还有宠物、长焦大师、`oplusBokehVersion`、人脸关键点和 `sceneMode`。Apple 转换不读这些字段。

资源名有 `portrait_blur_before_os16` 和 `portrait_blur_after_os16`。包内两代实现都在。哪一个系统版本切到哪条链，没有反编译到判断代码。

普通模糊插件是圆形、椭圆和区域模糊，不支持 HDR，和人像景深不是一条链。

## 还需要样张才能做的事

1. 用一张原片把 `HdrTransformData.toBytes()` 的字段顺序对出来。
2. 用一张只有线性 mask 的 Local HDR，对照 `oplus_uhdr_mask2map` 和相册实际 gainmap。
3. 用一张 17.10 时代的 Find 或 Reno 原片列出尾键，看有没有 `PORTRAIT_EDITING_ENTRY_NAMES` 尚未覆盖的新名字。
4. 实况、人像和 HDR 叠在同一张图上时，确认 `hdr.transform.data` 与视频 HDR 谁生效。相册里有 `updateLivePhotoHdrTransformData`。
5. 认出被相册以 `combine` 改过的 gainmap，避免再合成一次。

没有这些样张时，上面五项保持未验证。不要用本说明里的结构名代替字节级测试。
