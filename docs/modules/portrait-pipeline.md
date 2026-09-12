# 人像模式管线（portrait pipeline）

> 对应代码：`portrait.rs`（主流程）、`portrait_depth.rs`（rear.depth 解析与 disparity 标定）、`portrait_graft.rs` / `portrait_scaffold.rs`（图移植/脚手架，结构与 styles 同族）、`portrait_consts.rs`。
> UI 入口：独立"人像实验室"页面已隐藏（`apple_portrait_page.dart`），设置开关保留。

## 1. 任务

把 OPPO 人像模式的私有深度数据（尾部 `rear.depth` / `rear.depth.config`）转换为 Apple 人像模式可用的 disparity/深度结构，使 iPhone 上能继续调整景深/光圈。

## 2. run_portrait 主流程

```
input (OPPO 原始 HEIC/JPEG, 含 rear.depth)
  │ parse_depth: 解析 rear.depth（ranks 平面 + exponentiation + config）
  │   - decision.scale() 选定 disparity scale（无可用值 -> Err）
  ▼
build_disparity(ranks, exponentiation, scale, stretch_to_span)
  │   -> disparity_u8 平面 + float min/max
  │   - CurveDerived: 把本场景的 rank 分布拉伸到目标 span，
  │     使 apdi:FloatMinValue/FloatMaxValue 承载绝对尺度
  │   - Passthrough / CalibratedP50: 保留旧映射（范围由 rank 覆盖决定）
  ▼
REND 动态记录构造
  │   - focus: config 焦点窗口的 rank 中位数归一化
  │   - headroom: LHDR/UHDR meta_floats[17]（线性比）换算为档（stops）
  ▼
portrait_scaffold / portrait_graft（结构与 styles 管线同构）
  ▼
输出（Apple 人像深度结构）
```

## 2.1 底图来源（BaseOrigin）

人像转换的底图有两种来源，几何映射方式不同：

- **`SrcImage`**（默认）：取尾部 `src.image`（Ultra HDR JPEG，含自带 GainMap）。它是**未虚化、未裁切**的相机原始帧，且不含 Hasselblad 水印。
  - 深度/蒙版按 `src.image` 几何**直接等比缩放**，不查水印内容框。
  - GainMap 与主图同源，天然配套；主图与 tmap 尺寸一致，GainMap 为其 0.5×。
  - `src.image` 的 EXIF orientation **烘焙进主图像素**（主图存成呈现方向并声明 `irot`=0），GainMap 按同一变换旋转。最终 EXIF Orientation 归一为 1，避免 OPPO/鸿蒙图库重复旋转。此前样本的非零 `irot` 路径曾出现 Photos 黑帧，不代表所有非零旋转输入都会失败。
  - 主图/GainMap 转换完成后，从**原始 HEIC 的 Exif item / 原始 JPEG 的 APP1**恢复拍摄 EXIF，不沿用 `src.image` 的精简信息。保留相机、曝光、镜头、时间、GPS 等；尺寸改为实际输出尺寸，ColorSpace 沿用渲染底图（缺失时为 Uncalibrated）。断开原图 IFD1 缩略图，避免旧水印/裁切预览。随后写入 Apple 人像 MakerNote 与 CustomRendered；原厂 MakerNote 不作为有效 MakerNote 保留。原图无 EXIF 时仍沿用底图信息。
  - 典型输出：主图/tmap `3072×4096`，GainMap 与深度/蒙版 `1536×2048`，`irot`=0。
- **`OppoPrimary`**（回退）：源无可用 `src.image` 时使用 OPPO 主图（已带虚化与品牌水印），深度/蒙版经水印内容框映射。可用环境变量 `XDREMUX_PORTRAIT_OPPO_BASE=1` 强制。

OPPO 的 JPEG 导出带同样的尾部条目，因此与 HEIC 走同一路径。

## 3. disparity 标定（portrait_depth.rs）

标定按优先级选择，并输出 JSON 诊断（含 rationale）：

1. **`passthrough`**：量化有效（`exponentiation ∈ 1..=2` 且 `disparityMaximum > disparityMinimum`）**且** producer scale 可信（`> MIN_USABLE_SCALE`，即 1e-6）时，直接使用头部 `0x18` 的 producer 值。
   - 该字段并非总是浮点：部分机型写入小整数（观察到 4/6/9/11/12/14），按 f32 读出是 1.3e-44 这类非规格化值。若只判断「有限且 >0」会选中它，span 塌缩到 ~0，Photos 表现为「完全没有深度」。
2. **`curve-derived`**：OPPO 在 `rear.depth.config` 写入一条**每张照片的**光圈→虚化强度曲线（float 38..=58）。
   - 已实测：同一张照片的 f/16…f/1.4 四个导出中该曲线**逐字节相同**（同时 `rear.depth` 与 `src.image` 哈希也相同），因此它只编码深度、不随渲染设置变化。
   - 曲线最大值与镜头焦距成正比（705→50、1468→84、1941→145、2063→150），符合绝对视差尺度的物理预期。
   - 映射：`span = clamp(curve_max / 150 × 2.1, 0.3, 2.4)`，再 `scale = span / 255`。上界取自 Apple 参考人像实测（0.41…2.13）。
   - 仅信任已记录布局（float 0 的版本在 1.0..=4.0），并要求 rank 平面非空。
3. **`calibrated-p50`**（回退）：`focal*baseline/(disparity*distance)` 取焦点窗口中位 rank。
   - **已知不可靠**：与 producer 真值相差 1.8–45 倍且随拍摄距离漂移（真值基本不随距离变化），仅在前两条均不可用时使用。
   - 该分支保留 5.6× 经验系数，仅适用于 OPPO zero-quantization 样本。

`SimulatedAperture` 写入 OPPO 的 `currentFNumber`（例如 f/9.0、f/4.5），即拍摄时的原始光圈值。

## 3.1 观察到的机型差异

| 机型 | 分类 | exponentiation | disparity min/max | 标定路径 |
|---|---|---|---|---|
| Find X8 Ultra | `zero-quantization` | 0 | 0 / 0 | curve-derived |
| Find X8 Ultra（部分设置） | `validated-quantization` | 2 | 有效，但 `0x18` 仍无效 | curve-derived |
| Find X10 | `validated-quantization` | 1 | 有效 | passthrough |

非标准尺寸亦有观察：深度平面 `1020×768`（非 1024）、`src.image` `3072×4080`（非 4096）；部分样本无 hair 平面。

## 4. 边界规则

- 尾部缺 `rear.depth` / `rear.depth.config` -> 跳过人像处理，不影响主转换（不报错）
- 深度平面尺寸与主图不匹配 -> 失败关闭
- `front.depth` 等前置深度条目目前不消费（仅尾部保留策略涉及，见 `formats/oppo-proxdr.md` §4）

## 5. Portrait + Styles 元数据与几何约束

- Styles 保留已有完整 Apple MakerNote（含未知标签和 UUID）；缺字段时仅合并 Styles 所需的 43/84。Apple 偏移以 MakerNote 起点为基准，不是 TIFF 起点。当前 portrait 模板已含相同的 Styles flags，整段保持不变。若不完整的 note 扩展目录需移动未知的 out-of-line UNDEFINED 数据，则明确报错，不猜测其内部偏移；已验证的自相对 tag84 plist 除外。
- CustomRendered 使用正确的 `0xA401 / SHORT / count=1`，保留 `DigitalZoomRatio (0xA404)`。值 **9** 来自 Swift 参考源码；本次未找到可核对的本地 golden EXIF，也不代表已证明 Photos 的能力开关含义。
- 水印识别新增严格限定的 `version=1 / hassel_style_1 / 14185 bytes` packed 布局，校验源尺寸、方向、全幅 crop.region、已观察到的零起点和边界；两张 192113/192141 样本内容为 `(0,0,3072,4096)`，外框 `3072×4608`。旧 aligned 对称边框格式仍支持，未知 packed 布局不做任意浮点扫描。
- 焦点与 disparity/人物/头发平面共享旋转、居中 cover crop、padding 映射；焦点只归一化一次。上述样本半幅 aux 的底部 256 行为零，不覆盖水印。
- 本修复不改变主图像素来源以外的 HDR 策略、REND 强度。设备验收状态：真机已确认 HDR 正常、人像开关可打开、分层正确、方向正确、光圈调整有虚化；**未实现**「默认开启人像」——实测写 `PortraitScore`/`PortraitScoreIsHigh` 不会改变默认状态，那需要主图本身虚化（与「关闭时显示清晰原图」的取舍），已决定维持默认关闭。
- 回归测试：`cargo test --offline -p xdremux-core --lib`（`portrait_tests.rs`、`styles_scaffold_tests.rs`）。

## 6. 诊断

- `xdremux_diagnose_portrait` FFI 入口（Dart 侧人像页使用）
- conformance：`portrait_depth.rs` 对拍模块（`portrait.rs` 镜像已停用，见 `testing/conformance-suite.md`）
- macOS 研究路径：`PortraitDepthDiagnostics.swift`、`PortraitCalibrationResearch.swift`
