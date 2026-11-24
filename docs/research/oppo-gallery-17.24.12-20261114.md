# ColorOS 相册 17.24.12：对 17.10.5 笔记的增量核对（2026-11-14）

> 问题：一份外部整理的 17.24.12 逆向文档（未入库）里，哪些结论能在 APK 里查到；相对 [oppo-gallery-17.10.5.md](oppo-gallery-17.10.5.md) 有哪些新增和更正。
> 样本：`相册(com.coloros.gallery3d)-17.24.12(17024012)-base.apk`，226,948,951 字节，SHA-256 `1c606795d5203934bf3a285639d45edc6d401cb931392bbca5058ed852ec5082`，18 个 dex，77 个 `arm64-v8a` 库。本机 OPPO 原片 216 个（206 HEIC、10 JPG），另有 Find X10 原片 29 个（9 HEIC、20 JPG），都在仓库外，未入库。ISO 21496-1:2025 英文原文。
> 结论状态：资源、导出符号、字符串表和反汇编到的方法体为**已实测**；调用顺序和运行时行为为**推断**；各节逐条标注。
> 方法：静态阅读，没有运行相册。方法体读的是 `dexdump -d` 的字节码，不是反编译出的源码。

本篇只写增量。HDR 两套编码、`hdr.transform.data` 的布局、人像尾条目见 17.10.5 那篇，这里不重复。

## 一页结论

1. `filter.info` 是定长小端结构，字段顺序已从解析类读出（§1）。前 140 字节在 47 张本机原片上全部吻合；5.1 的部分在 3 张 Find X10 原片上核对过，到 `captureMode` 为止吻合，三个亮度值在文件里位于 216，解析类按 208 读，差 8 字节。**已实测**。
2. `watermark.master.params` 末尾的四个数是画面矩形的四角（左、上、右、下），不是 x、y、宽、高。17.10.5 笔记和 `portrait.rs` 的 `hassel_end_content_rect` 按后者读，会把右边框和底栏算进画面（§2）。几何**已实测**（39 张）；对转换结果的影响 2026-11-16 在三张样张上**已实测**，只出现在底图是 OPPO 主图时（§2.3）。
3. 画框边距由样式 JSON 的 dp 值按 `dp2Pixel` 换算，39 张里 38 张逐像素吻合（§2.2）。**已实测**。
4. 相册给叠加水印处理 gain map 时，把水印形状内的值写成 0，也就是 `ratioMin`（§2.4）。**已实测**（反汇编）。
5. 相册的 gain map 合成与 ISO 21496-1 式 (2) 等价；权重没有符号项；gamma 原样传入 `pow`，与式 (1) 的 `1/γ` 不同，γ = 1 时没有差别（§3）。**已实测**（着色器、反汇编）。
6. `libapsultrahdr.so` 带 ISO 21496-1 附录 C 的 JPEG APP2 元数据编解码（§3）。**已实测**（符号、字符串）。
7. OLive 的 XMP 属性比我方解析的多，`Item:Semantic` 的取值里有 `Original`（§4）。字符串**已实测**，语义是**推断**。

## 核对方法与环境

macOS（Darwin 27.2），Android SDK build-tools 37.0.0 的 `dexdump`，NDK 30.0.16248370 的 `llvm-nm`。本机没有 jadx、apktool。

```bash
shasum -a 256 "$APK"
unzip -q "$APK" 'assets/*' 'lib/*' 'classes*.dex' -d "$OUT"
"$BUILD_TOOLS/dexdump" -d "$OUT/classes9.dex"      # 按 Class descriptor 截出目标类
"$NDK_BIN/llvm-nm" -D --defined-only -C "$OUT/lib/arm64-v8a/libUhdrUtils-jni.so"
python3 docs/research/oppo_gallery_tail_probe.py <原片目录>
```

混淆类都被 R8 收进 `com/oplus/aiunit/vision/`。下文的三四个字母的类名只对这一个构建有效。尾部条目的二进制结构继承同一个结构基类 `ema0`：成员 `ema0$c` 是 32 位 float，`ema0$g` 是 32 位 int，`ema0$j(n)` 是 n 字节的 UTF-8 字符数组；结构类 `<init>` 里的成员声明顺序就是文件里的字段顺序。

## 1. `filter.info` 的字节布局

来源：`classes9.dex` 里的 `vfj`（日志标签 `FilterFileOperator`）方法 `c([B)`，按顺序读结构 `zhj` 的 19 个成员，写入 `xhj`（`toString` 以 `FilterPhotoInfo(version=` 开头）。`zhj.byteOrder()` 返回 `LITTLE_ENDIAN`。**已实测**。

| 偏移 | 类型 | 字段 | 读取条件 |
|---|---|---|---|
| 0 | f32 | `version` | 总是 |
| 4 | i32 | `filterIntensity` | 总是 |
| 8 | i32 | `srcOrientation` | 总是 |
| 12 | i32 | `srcMirror` | 总是 |
| 16 | i32 | `softLightEnable` | 总是 |
| 20 | i32 | `softLightType` | 总是 |
| 24 | i32 | `filterEnable` | 总是 |
| 28 | char[100] | `filterType`，LUT 文件名 | 总是 |
| 128 | f32 | `colorTemperature` | `version` ≥ 2.0 |
| 132 | f32 | `luxIndex` | `version` ≥ 4.0 |
| 136 | f32 | `filterSaturation` | `version` ≥ 4.0 |
| 140 | i32 | `isPalette` | `version` ≥ 5.0 |
| 144 | i32 | `paletteAlgoUsed` | `version` ≥ 5.0 |
| 148 | i32 | `portraitMaskUsed` | `version` ≥ 5.0 |
| 152 | i32 | `filterTone` | `version` ≥ 5.0 |
| 156 | char[50] | `captureMode` | `version` ≥ 5.0 |
| 206 | 10 字节 | 样张里全是 0，含义不明 | 不读 |
| 216 | f32 | `avgLuma` | `version` ≥ 5.1 |
| 220 | f32 | `brightLuma` | `version` ≥ 5.1 |
| 224 | f32 | `darkLuma` | `version` ≥ 5.1 |

上表到 `captureMode` 为止，解析类的偏移和文件一致。最后三行写的是文件里的位置；解析类算出来的位置是 208、212、216，见下面「亮度值的偏移」。

`FilterPhotoInfo` 另有 `portraitMaskJpeg` 和 `faceList` 两个字段，不在这个结构里。

字段名与偏移的对应方式：成员类型序列（1 个 float、6 个 int、字符串、3 个 float、4 个 int、字符串、3 个 float）和 `toString` 的标签顺序逐一对齐。外部文档把 `filterIntensity` 排在第 11 位，实际在 `version` 之后。下面两组字段的先后只有标签顺序作依据，样张里值相同，分不出来，是**推断**：`softLightEnable` 与 `softLightType`；`isPalette` 与 `paletteAlgoUsed`。

### 本机原片上的值

47 张带 `filter.info` 的原片全部是 `version` 4.0、140 字节。**已实测**（`oppo_gallery_tail_probe.py`）。

| 字段 | 取值分布 |
|---|---|
| `filterIntensity` | 90（36 张）、49（6 张）、100（5 张） |
| `srcOrientation` | 0（30 张）、90（16 张）、270（1 张） |
| `srcMirror` | 0（46 张）、1（1 张） |
| `softLightEnable` / `softLightType` | 都是 0（42 张）、1（5 张） |
| `filterEnable` | 1（47 张） |
| `filterType` | `fuji_cc.bin`（41 张）、`gourmet.cube.rgb.bin`（6 张） |
| `colorTemperature` | 2887 到 7687 |
| `luxIndex` | 112.21 到 446.56 |
| `filterSaturation` | 1.0（47 张） |

17.10.5 笔记记的「版本之后是整数 100，再是 90 或 0」就是 `filterIntensity` 和 `srcOrientation`。

> 2026-11-17 补充：`srcMirror` 为 1 的那张是前置自拍 `IMG20260807145722.heic`。把 `src.image` 和主图里的画面缩小后比相关度，这张左右翻转后是 0.98，不翻转是 0.69；两张 `srcMirror` 为 0 的后摄样张不翻转是 0.99。所以 1 表示成片相对原始帧左右镜像。**已实测**（三张）。分支 `fix/portrait-frame-content-rect`（未提交）的人像摆放据此翻转辅助平面，同一分支还把前置景深的远近方向改成按人物遮罩判定，见该分支的 `docs/modules/portrait-pipeline.md` §3.2。
>
> 2026-11-17 再补充：第二张前置原片 `IMG20261011120934.heic` 没有 `filter.info`，成片同样是镜像的（翻转后相关度 0.98，其余方向最高 0.28）。镜像标志另存在 `front.depth.config` 里：`classes9.dex` 的 `FrontDepthData.toBytes` 依次写出各字段，末尾是 `mirrorEnable`、`cameraRoll` 和光圈值（版本 1.1 起）；两张前置原片的这三个值都是 1、270、4.5。**已实测**（反汇编加两张原片）。完整字段表在同一分支的 `docs/modules/portrait-pipeline.md` §3.2。分支已提交（`6a09717`、`a5f1c29`），没有 `filter.info` 时改读 `mirrorEnable`。

### Find X10 原片上的值

29 张 Find X10 原片（`watermark.device` 为 `OPPO Find X10`）里 6 张带 `filter.info`，长度都是 228 字节：3 张 `version` 4.0，140 之后全是 0；3 张 `version` 5.1。**已实测**（`oppo_gallery_tail_probe.py`）。

| 文件（SHA-256 前 16 位） | `filterType` | `filterSaturation` | `filterTone` | `avgLuma` | `brightLuma` | `darkLuma` |
|---|---|---|---|---|---|---|
| `IMG20260910130102.jpg`（`a84a684ee35d7e3e`） | `qing_tou.bin` | 1.83 | 89 | 50.79 | 234.64 | 11.04 |
| `IMG20260910130226.heic`（`35f19a1ea49afc85`） | `hu_po.bin` | 1.47 | 38 | 61.07 | 298.13 | 10.95 |
| `IMG20260910130237.heic`（`903bd6622b61d620`） | `portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin` | 1.00 | 0 | 70.42 | 372.16 | 10.26 |

这三张的 `isPalette` 和 `paletteAlgoUsed` 都是 1，`portraitMaskUsed` 是 0，`captureMode` 是 `common`，`filterIntensity` 是 100。`filterSaturation` 在调色盘照片上不再恒为 1.0。

### 亮度值的偏移：文件与解析类差 8 字节

- 文件：三张 5.1 样张里，`captureMode` 之后到 215 全是 0，三个非零 float 在 216、220、224。数值符合「平均、亮部、暗部」的大小关系。**已实测**。
- 解析类：`zhj` 在 `captureMode`（`ema0$j(50)`，156 到 205）之后直接声明三个 `ema0$c`。`ema0` 的成员构造方法 `ema0$e.<init>` 按字长对齐后取当前下标作偏移，`ema0.isPacked()` 返回 false，所以这三个成员落在 208、212、216。**已实测**（反汇编）。
- 后果：按解析类的偏移，这三张样张读出的是 0、0 和文件里的平均亮度。没有运行相册确认，是**推断**。也可能是相册里另有一处按别的布局读这三个值，没有找到。
- 两种解释都符合长度：相机侧的 `captureMode` 是 60 字节；或者是 50 字节加 2 字节对齐，再加两个 4 字节字段。样张里这一段全是 0，分不出来。**未验证**。

### 版本门

`zfj`（日志标签 `FilterInfoRecoverGate`）的 `a(xhj)` 在三种情况下拒绝恢复。**已实测**（反汇编）：

- `version` < 0。
- `floor(version)` > `floor(5.1)`。
- `isPalette` 或 `paletteAlgoUsed` 等于 1，且 `veb.b()` 返回 false。`veb.b()` 的含义没有读，按上下文是机型是否支持调色盘，**推断**。

### 条目长度与样张范围

- 条目长度不由 `version` 决定，见过三种：140（Find X8 Ultra 等，184 张）、216（一张 Find N5 的 JPG）、228（Find X10，6 张）。216 和 228 的文件里都有 `version` 4.0 的，这时 140 之后全是 0。**已实测**。
- 216 正好是 228 去掉三个亮度值。Find N5 那张的 `filterType` 是逗号分开的两个文件名 `portra400_sdr_gen_a_1.bin,portra400_sdr_gen_d_1.bin`。
- 206 到 215 这 10 字节的含义见「亮度值的偏移」。**未验证**。
- 相邻的 `yhj` 也是 `ema0` 结构，成员正好是上表到 `filterSaturation` 为止的 11 项。用途没有读。**未验证**。

样张范围：2026-11-14 扫了外置盘和用户目录下的 1050 个 HEIC / JPG（只读文件尾，没有扫照片图库），285 个带 OPPO 尾部，`watermark.device` 里的机型有 Find X8 Ultra、Find X6 Pro、Find X7 Ultra、Find N3、Find X9、Find N5；185 个带 `filter.info`，`version` 全是 4.0。Find X10 那 29 张是之后单独拷入的。**已实测**。

## 2. 大师水印画框

### 2.1 末尾四个数是四角

`watermark.master.params` 在 `长度 - 56 + 24` 处有四个 float。按四角读，画面尺寸都是传感器的标准尺寸，四边的边距对称；按 x、y、宽、高读，画面尺寸不对应任何出图尺寸。39 张本机原片。**已实测**。

| 样式 | 主图 | 四个数 | 按四角读的画面 | 左、上、右、下边距 | 张数 |
|---|---|---|---|---|---|
| `hassel_style_master_mode_1` | 8532×8840 | 170, 1348, 8362, 7492 | 8192×6144 | 170, 1348, 170, 1348 | 9 |
| `hassel_style_master_mode_1` | 6484×10888 | 170, 1348, 6314, 9540 | 6144×8192 | 170, 1348, 170, 1348 | 3 |
| `hassel_style_master_mode_1` | 3244×5444 | 86, 674, 3158, 4770 | 3072×4096 | 86, 674, 86, 674 | 5 |
| `hassel_style_master_mode_1` | 4268×4420 | 86, 674, 4182, 3746 | 4096×3072 | 86, 674, 86, 674 | 2 |
| `hassel_style_master_mode_1` | 5200×8724 | 136, 1082, 5064, 7642 | 4928×6560 | 136, 1082, 136, 1082 | 1 |
| `hassel_style_1` | 8192×7168 | 0, 0, 8192, 6144 | 8192×6144 | 0, 0, 0, 1024 | 10 |
| `hassel_style_1` | 6144×9216 | 0, 0, 6144, 8192 | 6144×8192 | 0, 0, 0, 1024 | 2 |
| `hassel_style_1` | 3072×4608 | 0, 0, 3072, 4096 | 3072×4096 | 0, 0, 0, 512 | 4 |
| `hassel_style_1` | 4416×6624 | 0, 0, 4416, 5888 | 4416×5888 | 0, 0, 0, 736 | 2 |
| `hassel_style_1` | 4916×4304 | 0, 0, 4916, 3688 | 4916×3688 | 0, 0, 0, 616 | 1 |

`hassel_style_1` 的原点是 0，四角和宽高是同一组数，两种读法分不出来。有边框的样式才分得出来。

17.10.5 笔记里 `IMG20261011120934.heic` 那组数（136、1082、5064、7642，主图 5200×8724）和上表第 5 行相同。那篇写的「画面贴齐右边和底边，左边空 136，上边空 1082」应改为：画面 4928×6560 居中，左右各 136，上下各 1082。4928×6560 正好是同一张里 `src.image`（3280×2464）转置后的 2 倍。那张样张不在本机，这一条是用同样的数值**推断**的。

### 2.2 边距怎么算出来

`classes11.dex` 的 `MasterWatermarkElementProcessor.dp2Pixel(Size, double, int)`。**已实测**（反汇编）：

```text
px = int(dp × min(宽, 高) / baseImageSize)
px 是奇数时加 1
```

`classes16.dex` 的 `IPUAiMasterWatermarkEditor.getWatermarkFrameSize` 从样式 JSON 读 `size` 的四个边距和 `baseImageSize`。相关样式的值（`assets/watermark_master_styles/`）：

| 样式 | `baseImageSize` | 左、上、右、下边距（dp） | `bitmaps` 的 `direction` |
|---|---|---|---|
| `hassel_style_1` | 360 | 0, 0, 0, 60 | 3 |
| `hassel_style_4` | 360 | 10, 79, 10, 79 | 1、3 |
| `hassel_style_master_mode_1` | 360 | 10, 79, 10, 79 | 1、3 |

用画面短边代入，39 张里 38 张的四个边距逐像素吻合。**已实测**。例：短边 4928，`int(10 × 4928 / 360)` = 136，`int(79 × 4928 / 360)` = 1081，奇数加 1 得 1082。

没吻合的一张是 `hassel_style_1`、主图 4916×4304：算出来底边 614，文件里是 616。616 对应短边 3696，画面是 3688。原因**未验证**。

### 2.3 我方现在的读法

- `xdremux/rust/src/portrait.rs:561` 的 `hassel_end_content_rect` 把这四个数当 x、y、宽、高，用 `x + w == primary_w`、`y + h == primary_h` 校验后原样返回。边距对称时 `左 + 右角` 恰好等于主图宽，所以校验通过，返回的宽高比真实画面多出右边框和底栏。
- `xdremux/rust/src/portrait_tests.rs:133` 的 `hassel_style_4_end_rect_is_the_content_frame` 断言 5200×8724 的主图得到 `(136, 1082, 5064, 7642)`。按 §2.1 应是 `(136, 1082, 4928, 6560)`。
- 同一个函数后半段的对齐旧格式（`portrait.rs:652` 起，测试 `aligned_legacy_watermark_symmetric_corners_remain_supported`）已经把四角换算成宽高。两条路径对同一种数据的读法不一致。
- `portrait.rs:637` 的注释写明了非零原点时需要区分尺寸和四角，`hassel_style_1` 路径因此只接受原点为 0。
- 这个矩形在 `portrait.rs:1124` 交给 `PortraitPlacement::new`，只在底图是 OPPO 主图时使用。带边框大师水印的人像，深度和遮罩会按偏大的矩形摆放。以 3244×5444 为例，宽多 86（2.8%），高多 674（16.5%）。这是读代码得到的**推断**，没有跑转换对比。

> 2026-11-16 更新：分支 `fix/portrait-frame-content-rect`（未提交、未合并）已改成四角读法，只认 `hassel_style_4` 和 `hassel_style_master_mode_1`。三张本机原片（两张后摄、一张前置）在 `XDREMUX_PORTRAIT_OPPO_BASE=1` 下跑过转换：主图 3244×5444 的内容框修改前是 `(86, 674, 3158, 4770)`，修改后是 `(86, 674, 3072, 4096)`，辅助平面落在画面矩形内，不再铺到右边框和底栏。**已实测**。默认底图是 `src.image`，不查这个矩形，默认转换不受影响。末尾 56 字节的完整布局写在该分支的 `docs/formats/oppo-watermark.md` §4.3。
>
> 2026-11-17 更新：
>
> - 末尾块的第 2 个 float 不是右边的副本。竖幅画框里它与右边相差不超过 1，横幅画框里比右边大 28（主图 4268×4420）或 58（8532×8840）。11-16 的校验按「相差不超过 1」写，把 20 张大师模式原片里的 11 张横幅拒掉了；提交 `a5f1c29` 放宽为「右边 − 1」到主图宽之间。**已实测**（35 张 HEIC 原片）。
> - `hassel_style_4` 有了本机样张 `IMG20261011120934.heic`（条目长 23487），14 个数的布局与 `hassel_style_master_mode_1` 相同。**已实测**（1 张）。
> - 水印恢复也改为读这个矩形（分支 `feat/watermark-restore-frame-rect`，未提交）：`hassel_style_1` 原先写回直接失败，四边画框原先不恢复左右边框。用两张真实的 iPhone 编辑件跑过写回，结果记在该分支的 `docs/formats/oppo-watermark.md` §4.4。

### 2.4 gain map 上的水印

`classes16.dex` 的 `IPUAiMasterWatermarkEditor.getOverlayForGainMap(Bitmap)`。**已实测**（反汇编）：

1. 建一张同尺寸位图，`drawColor(Color.rgb(c, c, c))`，`c` 是静态常量 `ADD_GAIN_MAP_FIXED_RGB_COLOR`，值为 0。
2. 画笔的 `ColorMatrix` 是 20 个 float，只有 alpha 行的 alpha 系数是 1，其余全 0（`classes16.dex` 文件偏移 `0x23e90c` 起）。
3. 用 `PorterDuff.Mode.DST_ATOP` 把水印图层画上去。

结果是一张水印形状的黑色图层，alpha 取自水印。叠到 gain map 上之后，水印覆盖处的值是 0，对应 `ratioMin`。相机样张的 `ratioMin` 是 1，所以水印处不提亮。

`WATERMARK_DIRECTION_OVERLAY` 的值是 4。`isOnlyOverlayWatermark`、`isOnlyFrameWatermark`、`isFrameAndOverlayWatermark` 用它和 `bitmaps[].direction` 比较。**已实测**。

### 2.5 模板概况

`assets/watermark_master_styles/` 共 43 个 JSON，其中 `restrict_local_songkran_holiday_2025_style_1.json` 带 UTF-8 BOM。**已实测**：

- `baseImageSize`：360（42 个）、291（1 个）。
- `bitmaps[].direction`：3（25 处）、4（12 处）、1（7 处）、2（6 处）。只有值为 4 的 12 处带 `composite` 字段。
- 元素的 `content.type`：`text` 168、`elements` 70、`image` 60、`shape` 50、`space` 28。
- 字体：`/system/fonts/SysSans-En-Regular.ttf` 85 处，`/system/fonts/OPSans-En-Regular.ttf` 2 处；另有 81 处是 `videoclipfs.coloros.com` 上的 zip 地址，这些样式的字体不在 APK 里。

外部文档省略了 `elements`。APK 里的模板是完整的，文字来源（`textSource`）、边距、图片资源名都在。

## 3. gain map 合成与 ISO 21496-1 对照

标准条款见 `docs/standards/ISO_21496-1_2025_zh.md` §6.2.1、§6.3、附录 C。相册侧的着色器是 `assets/pipeline/uhdr/fs_uhdr.glsl`；给同名 uniform 赋值的渲染器读了三个：`classes16.dex` 的 `die0`（日志标签 `UhdrRenderer`）、`classes9.dex` 的 `zyj` 和 `ImageContentPass$image$2`。

| 项 | ISO 21496-1:2025 | 相册 17.24.12 | 状态 |
|---|---|---|---|
| 反归一化 | 式 (1)：归一化值先取 `1/γ` 次幂，再映射到 log2 域的最小值和最大值之间 | `mix(uLogRatioMin, uLogRatioMax, pow(g, uGainmapGamma))`；三个渲染器都把 gamma 的三个值原样传入，中间没有运算 | 已实测；γ ≠ 1 时与标准不同 |
| 对数底 | log2，合成用 2 的幂 | `Math.log` 取自然对数，合成用 `exp` | 已实测，等价 |
| 合成 | 式 (2)：`(Baseline + K_baseline) × 2^(W × G) − K_alternate` | `(sdr + uEpsilonSdr) × exp(L × W) − uEpsilonHdr` | 已实测，等价 |
| 权重 | 式 (3)：带 `sign(H_alternate − H_baseline)` | `clamp((lnDevice − lnSdr) / (lnHdr − lnSdr), 0, 1)`，没有符号项；`die0` 在 `ln(deviceHdrSdrRatio) ≤ 0` 时直接返回 | 已实测；只覆盖 SDR 底图 |
| 应用色域 | 由 `use_base_colour_space` 决定在哪一方的原色下合成 | 在底图的线性空间合成，再乘 `uGamutTransform` | 已实测（着色器） |
| 元数据存储 | 附录 C.2 的大端分数结构；C.4.6 的 JPEG APP2，标签 `urn:iso:std:iso:ts:21496:-1` | `libapsultrahdr.so` 有这条 URN，以及 `gain_map_metadata::encodeGainmapMetadata`、`decodeGainmapMetadata`、`gainmapMetadataFloatToFraction` | 已实测（符号、字符串）；相册是否写入这一段未验证 |

字段对应：OPPO 的 `ratioMin` / `ratioMax`、`displayRatioSdr` / `displayRatioHdr` 存线性比值，标准存 log2 值；`epsilonSdr` / `epsilonHdr` 对应基线和备用图像的偏移常数。

gamma 那一行的依据：`die0` 和 `zyj` 里 `UltraHdrInfo.getGamma()` 的三个元素取出后直接进 uniform；`ImageContentPass` 里 gamma 和两个 epsilon 走同一个逐元素拷贝的辅助方法 `A`，`ratioMin` / `ratioMax` 走另一个逐元素取 `Math.log` 的辅助方法 `H`。读到的是这三处调用点。`UltraHdrInfo` 里的 gamma 在更上游是否已经取过倒数，没有追。**未验证**。17.10.5 笔记记录的相机样张 gamma 都是 1，这种情况下两种写法结果相同。

`fs_uhdr.glsl` 里还有一行被注释掉的归一化：`H *= 1.0f / exp(W * maxRatio)`。

## 4. OLive 与 Motion Photo

DEX 字符串表里的 XMP 属性名。**已实测**：

- `OpCamera:MotionPhotoPrimaryPresentationTimestampUs`、`OpCamera:MotionPhotoOwner`、`OpCamera:OLivePhotoVersion`、`OpCamera:VideoLength`
- `OpCamera:MotionPhotoVideoStart`、`OpCamera:MotionPhotoVideoEnd`
- `OpCamera:MotionPhotoEditorFlag`、`OpCamera:MotionPhotoEnable`、`OpCamera:MotionPhotoFeatureFlag`、`OpCamera:MotionPhotoSoundEnable`、`OpCamera:hdrVersion`
- `Container:Directory`、`Item:Mime`、`Item:Semantic`、`Item:Length`、`Item:Padding`

同一批 dex 里有独立字符串 `Primary`、`Original`、`GainMap`、`MotionPhoto`，以及尾部条目名 `olive.supportRestoreOriginal` 和方法名 `restoreOriginalCover`。`Original` 是换封面后旧封面的 `Item:Semantic` 取值，这一条是**推断**，没有换过封面的样张。外部文档把这几个值写成「MPF 语义角色」，MPF 条目里没有语义字符串。

换封面的三段处理，类名都出现在 `classes10.dex` 的字符串表里。**已实测**（名字存在）；先后顺序是**推断**：

| 阶段 | 类 | native |
|---|---|---|
| 画质增强 | `BitmapQualityWorker` | `libCoverEnhancerJNI.so`，运行时加载 `/odm/etc/camera/livephoto_coverenhancer/libs/libOPAlgoCamCoverEnhancer.so` 和 `/odm/lib64/libstface_fd_api.so` |
| HDR 帧转换 | `HdrVideoFrameTransformWorker` | `libHdrTransform-common-jni.so` 的 `process_output_gainmap` |
| 逆色调映射 | `ProXDRWorker` | `libInverseToneMappingJNI.so`，按名字取 13 个 `oplus_camera_itmc_*` 接口，库名 `libOPAlgoCamITMC.so`、`/libcvwarp.so`、`/libdlib.so` |

逆色调映射返回的 `HdrXmpInfo` 有 `gainMapMax`、`gainMapMin`、`hdrCapacityMax`、`hdrCapacityMin` 四个字段。换过封面的照片，gain map 来自这一步，不是拍摄时的。**推断**。

## 5. 尾部条目名

18 个 dex 的字符串表里，我方 `container.rs` 的名单和格式文档没有提到的名字。**已实测**（字符串存在）；是不是都作为尾部条目使用，**未验证**：

- `basictone.lmtlut.table`（`basic_tone_3dlut_texture_fragment_shader2.glsl` 的注释说三维查找表由它生成）
- `capture.info.backup`、`depth.rule.config`、`filter.type.origin`
- `live.subVideoSize`（本机一张 Find N5 的 JPG 尾部有这一项，8 字节，与 `live.subVideo` 并列，确认是尾部条目）
- `olive.supportRestoreOriginal`、`video.hdr.transform.data`
- `watermark.capture`、`watermark.custominfo`、`watermark.director`、`watermark.filter`、`watermark.hasWatermark`、`watermark.remove`、`watermark.spring.festival.params`
- `edit.project.entity`、`edit.project.config`、`edit.project.save_option`

反过来，我方名单里的 `private.emptyspace` 在相册的字符串表里没有出现。

## 6. 其余核对过的条目

下面各条外部文档的说法与 APK 一致。**已实测**：

- `assets/tbluniformeditor/plugin/` 共 30 个配置。水印、IPU 滤镜是 `independent`，调色盘是 `combine`，调节、滤镜、变形、图像替换同时声明两种。
- `fs_uhdr.glsl`、`fs_gain_single.glsl`、`fs_gamut.glsl` 和两个 BasicTone 着色器的公式。`fs_gamut.glsl` 的 HLG 用系统伽马 1.2 和 BT.2020 亮度系数；PQ 模式只做 EOTF 和 OETF。
- `libWaterMark-Jni.so` 的 20 个 `MasterWatermarkAssembler_*` 导出；`libUhdrUtils-jni.so` 的 `oplus_uhdr_mask2map`、`mask2mapImpl`、`convertMetaToStruct`、`edrScaleCalculator`、`calFunUhdrGain`、`createLookupTableUhdrGain`、`createLookupTableGroup`、`paralGainMapProcYChannel`。
- 版本串 `_watermark_photo_20251127_version`、`color_mark_20210915_version_1.0`。
- `assets/aifilter/` 三个 `style` 文件各 100 字节，内置编号为负数。

与外部文档不一致的。**已实测**：

- `tbl_uniform_editor_filter_information.json` 有 39 项，30 项的路径以 `.bin` 结尾，9 项是没有后缀的资源编号，16 项的键以 `key_camera_` 开头。`800t.bin` 不在这个文件里，只出现在 DEX 字符串中。
- BasicTone 三维查找表的边长 16 只出现在着色器的注释里，`uLutSize` 是 uniform。CPU 侧传的值**未验证**。

## 我方现状与差距

| 项 | 相册 17.24.12 | 我方 | 差距 |
|---|---|---|---|
| 大师水印画面矩形 | 四角；边距由 `dp2Pixel` 得出 | `portrait.rs:561` 按 x、y、宽、高读 | 带边框样式的画面矩形偏大（§2.3） |
| `filter.info` | 定长结构（§1） | `container.rs:265` 起只按名字保留或停用，不解析内容 | 没有功能缺口；需要读滤镜名或强度时可直接用 §1，亮度值按文件里的 216 读 |
| gain map gamma | 原样传入 `pow` | `iso21496.rs:89` 的 `parse_oppo_uhdr_info` 读入 20 个 float，`iso21496.rs:147` 只校验 gamma 有限且不为负 | 样张 gamma 为 1，没有可观察的差别 |
| OLive XMP | 至少 11 个 `OpCamera:*` 属性 | `motion_photo.rs:1162` 只读 `OpCamera:VideoLength`，语义只认 `Primary` 和 `MotionPhoto` | `MotionPhotoVideoStart` / `End` 和 `Original` 没有处理；是否需要取决于有没有换过封面的输入 |
| 尾部条目名单 | §5 | `container.rs:54`、`:61`、`:78` | 新名字没有归类；`Preserve` 策略逐字节保留，不受影响 |

## 跟进建议

| 级别 | 事项 | 成本 | 依赖 |
|---|---|---|---|
| P0 | `hassel_end_content_rect` 改成四角读法。已在分支 `fix/portrait-frame-content-rect` 提交（`6a09717`、`a5f1c29`），四张样张上对比过，未推送 | 小 | 真机上看景深对位 |
| P2 | 弄清 `filter.info` 206 到 215 的含义，以及相册是否真的按 208 读亮度值 | 中 | 需要这一段非零的样张，或者反汇编写入侧 `getFilterInfoByteArray` |
| P2 | 找换过封面的 JPEG OLive，确认 `Original` 条目和 `OpCamera:MotionPhotoVideoStart` / `End` 的实际取值 | 中 | 需要在手机相册里操作一次 |
| 暂不跟 | gamma 方向 | 无 | 出现 gamma ≠ 1 的 OPPO 文件时再看 |

## 未验证与不适用条件

- 没有运行相册。所有「先后顺序」「必定调用」一类的说法都是从类名、日志串和调用点推出来的。
- 混淆类名只对 17.24.12 这一个构建有效。换版本要用日志标签（`FilterFileOperator`、`FilterInfoRecoverGate`、`UhdrRenderer`）重新定位。
- §2 的样张以 `hassel_style_1` 和 `hassel_style_master_mode_1` 为主。`hassel_style_4` 只有 2026-11-17 拷入的一张。
- §3 的 gamma 结论只覆盖读到的三个渲染器，不覆盖 `UltraHdrInfo` 的构造过程。
- 外部文档关于调色盘（`CombineLutProcessUnitSDK`、`/odm/etc/camera/basictone/`）和 AI 滤镜的部分只核对了字符串存在，没有读方法体。
