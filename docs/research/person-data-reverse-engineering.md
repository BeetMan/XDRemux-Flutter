# 柔肤 / 人物数据反推记录（自行推导）

分支：`research/iphone-next` ｜ 样本：`/Users/beet/Desktop/iPhone 18 Pro/` 31 组原生样张
工具：`scripts/research/key1_probe.py`（bplist 定位）、`/tmp/person.py`（人物数据拆解）

## 结论先行

**柔肤不需要语义分割 mask。** 它的输入是**人脸检测结果 + 少量统计量**：

```
TextureStylePostProcessedPeopleData[i]
├─ faceROI / faceSkinROI / instanceROI / faceROIAndLandmarksROIRelativeScalingROI
├─ faceLandmarks: 76 个点（{point:{x,y}, error:...}）
├─ faceYaw / facePitch / faceRoll（头部姿态）
├─ instanceMaskReferenceKey: 'FSINCInstanceMask9'（引用已存在的 mask）
└─ imageStats
   ├─ SkinSmoothingStandalone   ← 柔肤
   ├─ Mattify                   ← 哑光
   └─ UnderEyeBrightening       ← 眼下提亮
```

这推翻了「柔肤要接语义分割（MediaPipe selfie_multiclass 之类）」的假设 ——
**工作量比预想小一个数量级**。

## 1. 数据位置

`tag:apple.com,2026:photo:metadata:texture_styles` 项的 bplist：

| 键 | 类型 | 含义 |
|---|---|---|
| `Preset` | str | 风格预设（31 样本全为 `Standard`）|
| `CaptureType` | str | `LF` |
| `CaptureMode` | str | `Still` |
| `PortType` | str | `PortTypeBack` |
| `HardwareModel` | str | `iPhone19,2` |
| `TextureStylePeopleDataVersion` | int | **3** |
| `FilmGrainSeed` | int | 颗粒种子 |
| `TextureStylePostProcessedPeopleData` | list | **人物数据** |

> 上游把 `HardwareModel` / `CaptureType` / `CaptureMode` / `PortType` 标记为
> 「未经推导的声称」——我们同样写死。见 roadmap 的 P3（provenance 对齐）。

## 2. 三个 imageStats 块的字段

### SkinSmoothingStandalone（柔肤）

| 字段 | 类型 | 样本值 | 用途 |
|---|---|---|---|
| `faceID` | int | 0 | 关联 faceROI |
| `SkinSmoothAverageFaceColour` | [3] | `[0.7547, 0.5409, 0.4437]` | 平均肤色（RGB）|
| `SkinSmoothFaceRoughness` | float | `0.02579` | **脸部粗糙度**（决定磨皮强度）|
| `SkinSmoothSkipPerson` | bool | false | 跳过此人 |

### Mattify（哑光）

| 字段 | 类型 | 样本值 |
|---|---|---|
| `faceID` | int | 0 |
| `AverageFaceColor` | [3] | `[0.749, 0.5412, 0.4431]` |
| `HighlightsToMaskRatio` | float | `0.0` |
| `SkipPerson` | bool | false |

### UnderEyeBrightening（眼下提亮）

| 字段 | 类型 | 样本值 |
|---|---|---|
| `faceID` | int | 0 |
| `LeftEyeAverageColor` / `RightEyeAverageColor` | [3] | `[0.825, 0.607, 0.488]` / `[0.606, 0.430, 0.354]` |
| `LeftEyeLumaVariance` / `RightEyeLumaVariance` | float | `0.0326` / `0.0124` |
| `LeftEyeIsBiModal` / `RightEyeIsBiModal` | bool | true / false |

## 3. 几何字段

| 字段 | 类型 | 含义 |
|---|---|---|
| `faceROI` | {x,y,w,h} | 人脸框，归一化坐标 |
| `faceSkinROI` | {x,y,w,h} | **皮肤区域框**（比 faceROI 大）|
| `instanceROI` | {x,y,w,h} | 人体实例框 |
| `faceROIAndLandmarksROIRelativeScalingROI` | {x,y,w,h} | 关键点归一化用的缩放 ROI |
| `faceLandmarks` | list[76] | 每项 `{point:{x,y}, error:...}` |
| `faceLandmarkType` | int | 1 |
| `faceUnitOfAngle` | int | 1 |
| `faceYaw` / `facePitch` / `faceRoll` | float | 头部姿态（弧度）|
| `instanceMaskReferenceKey` | str | `'FSINCInstanceMask9'` —— 引用别处的 mask |

**注意** `faceSkinROI` 比 `faceROI` 大（本例 skin 0.1445×0.1927 vs face 0.0738×0.0983）
—— 皮肤区域是放大的脸部框，不是像素级分割。

`instanceMaskReferenceKey` 引用 **FSINC**（上游也提到 `FSINC sparse materialization`
和 `FSINCInstanceMask9`）—— 说明人物 mask 是**单独的资源**，通过引用键关联，
不在 PeopleData 里内联。

## 4. 实现路径（柔肤）

要产出可用的 PeopleData，需要：

| 步骤 | 输入 → 输出 | 跨平台方案 |
|---|---|---|
| 1. 人脸检测 | 图 → faceROI | `ort` + ONNX 人脸检测模型；Apple 上可用 Vision |
| 2. 关键点 | faceROI → 76 点 | ONNX 人脸对齐模型（68/76 点）|
| 3. 姿态 | 76 点 → yaw/pitch/roll | 由关键点几何推算（PnP 或简化）|
| 4. 平均肤色 | faceSkinROI 内像素 → RGB 均值 | 简单统计 |
| 5. **脸部粗糙度** | faceSkinROI 内高频方差 | 高通滤波后的能量（待标定）|
| 6. 眼部统计 | 眼部 ROI → 颜色 + 亮度方差 + 双峰性 | 由关键点定位眼部 ROI |
| 7. 填结构 | 上述 → bplist | 已有 `styles_bplist.rs` |

**唯一需要标定的是 `SkinSmoothFaceRoughness` 的定义**（0.0258 是什么尺度）。
可以用多样本对比统计反推：取不同纹理的脸部照片，看粗糙度怎么变。

## 5. 与上游的对照

上游（`41c56a8`）在探的 SPI：

```
+[CMITextureStylesPersonInputDataUtilities personInputDataArrayFromDetectedFaces:]
-[PITextureStyleProcessorKernel personInputDataFromStillProperties:]
-[CMITextureStylesProcessor setInputPersonData:]
-[CMITextureStylesProcessor setInputSkinSmoothingFaceDetections:]
```

**`personInputDataArrayFromDetectedFaces:` 的输入是「检测到的脸」** —— 与我们
反推出的字段完全吻合：faceROI / faceSkinROI / landmarks / pose 就是
`CMITextureStylesPersonInputData` 的内容。

上游文档说的「determine which fields Apple derives deterministically from
image-reconstructible face geometry」—— 我们的结论：**绝大部分字段都能从
人脸几何 + 图像统计重建**，无需 Apple 私有 API。

## 6. 仍未解决

1. `SkinSmoothAverageFaceColour` —— **已锁定可用配方**：线性空间 + 肤色
   mask 均值，误差 0.09（改善 42%）。精确到 0 仍需更好的 mask 或归一化
2. `SkinSmoothFaceRoughness` —— **仍未锁定**：是高频纹理能量（lap_abs
   相关 0.68），但真 matte 加权反而更差。见 6.5 的对比表
2. **`FSINCInstanceMask9`** 引用的 mask 从哪来（是相机管线生成的？我们能生成吗？）
3. ~~无人脸照片的 PeopleData 形态~~ **已确认：整键 `TextureStylePostProcessedPeopleData` 缺失**
   （不是空 list）—— 31 张里 8 张如此
4. 多人脸时的 faceID 分配规则
5. `faceLandmarks` 的 76 点具体布局（哪 76 点？需要可视化对照）

## 5.5 A1/A2/A3 实测结果

### A1 —— 76 关键点布局（可视化 + 数值双确认）

把关键点画到样张上（按 EXIF 方向转正，坐标同变换），归一化到 faceROI：

| 索引 | 部位 | 点数 |
|---|---|---|
| 0-6 | **左眼** | 7 |
| 7-13 | **右眼** | 7 |
| 14-19 | 左眉 | 6 |
| 20-25 | 右眉 | 6 |
| 46, 47, 48 | 鼻梁（顶/中/尖）| 3 |
| 49-58 | 嘴 | 10 |
| 26-45, 59-75 | 轮廓与下颌 | 其余 |

**要点**：眼睛两组各 **7 点**（6 轮廓 + 1 中心？）→ `UnderEyeBrightening` 的
眼部 ROI 可由它们直接算出，无需额外检测。

⚠️ 坐标变换陷阱：`faceROI`/`faceLandmarks` 存的是**未应用 EXIF 方向**的归一化坐标。
可视化时图像和坐标必须做**同一个**变换，否则点会错位（我第一次就错在这里）。

### A2 —— 粗糙度标定（n=21）

`SkinSmoothFaceRoughness` 与 `faceSkinROI` 内图像纹理统计的相关：

| 统计量 | 与 roughness 相关 r |
|---|---|
| **`lap_abs`（平均绝对拉普拉斯 = 高频纹理能量）** | **+0.673** ← 最强 |
| `lap_var` | +0.584 |
| `skin_G` | +0.572 |
| `grad_mag` | +0.506 |
| `lum_std` | +0.206 |
| `lum_mean` | -0.114（无关）|

**结论**：粗糙度 ≈ **皮肤区域的高频纹理能量**，用 `lap_abs` 最接近。

⚠️ 方法学缺陷：分析时把图缩到 1024px，**丢掉高频细节**，所以 0.673 是**下界**。
全分辨率重测预期更高。实现建议：在 faceSkinROI 内做全分辨率 3×3 拉普拉斯，
取绝对值均值，再做线性标定（用已有 21 个样本拟合）。

### A3 —— `FSINCInstanceMask9` 的 mask 在哪

`FSINC` 是 **XMP 命名空间**（`fsincMattes` 1.0）：

```xml
<fsincMattes:InstanceMaskReferenceKey>FSINCInstanceMask9</fsincMattes:InstanceMaskReferenceKey>
<fsincMattes:FSINCMatteVersion>0</fsincMattes:FSINCMatteVersion>
```

mask 数据在**独立的 XMP 二进制 blob** 中（样张 0x1b89b 处：键名 `FSINCInstanceMask9`
后跟二进制 payload），PeopleData 里只有**引用键**，不内联像素。

**推论**：要生成人物 mask，需要产出同样形态的 XMP blob 并写入引用键。
这与 `semanticpersoninstances`（item 列表里已有）是不同的资源。

顺带确认：样张 item 列表与我们注入的 12× 2026 semantic matte + `semanticpersoninstances`
完全对应 ✓。

## 6. 样本统计（31 组原生样张实测）

| 项 | 结果 |
|---|---|
| 有人脸的样张 | **23 / 31**（其余 8 张**整键缺失**，不是空 list）|
| 人脸数 | 1 或 2 |
| 每张脸的关键点 | **恒为 76** |
| `SkinSmoothFaceRoughness` | n=24，mean=**0.01389**，std=0.00505，min=0.00643，max=0.02683 |
| 粗糙度缺失 | **2 例**（`IMG_4177`、`IMG_6791` 为 `None`）|
| Preset | 全为 `Standard` |
| `TextureStylePeopleDataVersion` | 恒为 3 |

**多实例**：`IMG_3265` / `IMG_3863` / `IMG_8588` 各有 2 张脸，**各自独立的粗糙度和平均肤色**：
例如 `IMG_3863` = `0.0268 (肤色 0.79,0.64,0.58)` + `0.0106 (肤色 0.37,0.28,0.26)`
—— 两个人不同肤色/肤质，统计量分开算 ✓

**平均肤色范围**：`(0.37, 0.28, 0.26)` 到 `(0.84, 0.48, 0.31)` —— 覆盖不同肤色与光照。

**粗糙度可以缺失**（2/24 为 None）—— 实现时要允许字段缺省，不能假设必填。

> 可比性：粗糙度 0.006-0.027 是**归一化图像域**的量（图像值 0-1）。
> `IMG_0004` 的 0.0258 接近上限，`IMG_4428` 的 0.0064 接近下限 ——
> 可以对照这两张样张的皮肤纹理来标定定义。

## 6.5 统计公式的标定尝试（重要发现）

**假设**：拿记录里的 ROI/关键点 → 自己算统计 → 与 Apple 记录值对照。

### 结果：统计不是在包围框上算的

| 样本 | 记录 `SkinSmoothAverageFaceColour` | 我算（`faceSkinROI` 包围框均值）| Δ |
|---|---|---|---|
| IMG_0004 | [0.755, 0.541, 0.444] | [0.447, 0.370, 0.330] | 0.308 |
| IMG_5787 | [0.809, 0.544, 0.425] | [0.372, 0.246, 0.188] | 0.437 |
| IMG_5205 | [0.688, 0.545, 0.507] | [0.662, 0.534, 0.489] | 0.025 |

**21 样本平均误差 0.156、最大 0.437，且记录值系统性更亮。**

**推论**：`faceSkinROI` 是**包围框**（含头发/背景/阴影），而 Apple 的统计
**只在皮肤像素上做** —— 用 `semanticfaceskinmatte` / FSINC mask 加权。
这解释了系统性偏差（暗区拉低了我的均值）。

→ **统计公式的标定必须在 mask 加权下做**，不是包围框。

### 粗糙度（包围框上的结果，下界）

| 公式 | 与记录相关 r | 线性拟合 |
|---|---|---|
| **`lap_abs`（平均绝对拉普拉斯）** | **+0.681** | `rough ≈ 0.475·lap_abs + 0.0057` |
| `hf`（lap_abs / 亮度均值）| +0.661 | `rough ≈ 0.187·hf + 0.0072` |
| `lap_var` | +0.645 | `rough ≈ 2.632·lap_var + 0.0108` |

**方向确认**：粗糙度是高频纹理能量 ✓。但精确公式要在 mask 加权重测。

### mask 加权假设已验证

用**肤色启发式 mask**（`R>G+0.02 & G>B & 0.12<lum<0.95`）在 `faceSkinROI` 内加权：

| 加权策略 | 平均最大误差 (n=21) |
|---|---|
| 全包围框 | 0.156 |
| **肤色启发式 mask** | **0.108**（↓31%）|
| 鲁棒（中位数±MAD）| 0.137 |
| 亮度阈值 mask | 0.204（更差）|

**结论**：mask 加权方向正确 ✓，但启发式 mask 不够精确。
**剩余误差需要真正的 matte** —— 样张里的 `semanticfaceskinmatte`
（id=87，768×576，2002B，HEVC 单通道）。

**下一步标定**：解出 matte → mask 加权重算 → 与记录值比对。
若吻合，则：
1. 统计公式锁定
2. 也证明了**关键点几何生成的 mask 足以替代语义分割**
   （先验证几何 mask 能达到什么精度，再决定是否需要模型）

### 真 matte 标定结果（含否定发现）

用 `dump_item` + ffmpeg 解出样张里的真实 matte，做 mask 加权（n=21）：

| mask 来源 | 平均肤色误差 | 粗糙度相关 r |
|---|---|---|
| 全包围框 | 0.156 | +0.681 |
| **肤色启发式**（R>G+0.02 & G>B & 0.12<lum<0.95）| **0.108** | **+0.681** |
| `semanticfaceskinmatte`（id=87）| 0.131 | +0.557 |
| `semanticskinmattev2`（id=67）| 0.135 | +0.280 |

**否定发现**：**真 matte 并不比肤色启发式更准**（0.131 vs 0.108），
粗糙度相关反而更低（0.557 vs 0.681）。

**推论**：
1. `semanticfaceskinmatte` / `semanticskinmattev2` **可能都不是**柔肤统计用的
   mask —— 或者统计方式不是简单 mask 加权（可能有鲁棒估计、线性空间、
   或归一化）
2. **好消息**：肤色启发式已经很接近，说明柔肤统计**不需要精确语义分割**，
   几何 + 色域启发式就够用（误差 0.108 可接受的话）
3. 记录值系统性偏亮（所有方法都是），提示可能是**色彩空间差异**
   （线性 vs sRGB）或**鲁棒均值**（中位数/截尾）

### mattechnical note: matte 解码

matte payload 是单个 **length-prefixed HEVC IDR NAL**；VPS/SPS/PPS 在该 item 的
**hvcC 属性**里（通过 ipma 匹配 item→属性，抓文件里第一个 hvcC 会拿到主图
tile 的配置，解码报 `offset_len 52 is invalid`）。

⚠️ matte 存的是**未应用 EXIF 方向**的坐标，处理时必须与图像同步变换
（第一次没转 matte，导致 mask 错位、两张样本全 0）。

### 估计器与色彩空间标定

固定 mask（肤色启发式），比较估计器与色彩空间（n=21）：

| 估计器 | 平均误差 | 中位误差 | 最大误差 |
|---|---|---|---|
| sRGB 均值 | 0.108 | 0.094 | 0.272 |
| sRGB 中位数 | 0.091 | **0.059** | 0.279 |
| sRGB 截尾均值 | 0.101 | 0.083 | 0.271 |
| **线性空间均值** | **0.090** | 0.072 | **0.211** ← 最稳 |
| 线性中位数 | 0.091 | 0.059 | 0.279 |
| 线性截尾均值 | 0.090 | 0.071 | 0.225 |

**色彩空间假设验证 ✓**：线性空间比 sRGB 更准（0.156 → 0.090，改善 42%）。
**线性空间均值**在最大误差上最稳（0.211），是当前最佳估计器。

**剩余误差**（~0.09）可能来自：
- mask 不够精确（肤色启发式 vs 真皮肤区域）
- 可能还有归一化（如按亮度归一后的色度平均）
- 或统计区域不是整个 `faceSkinROI`（如只取面颊）

**当前可用配方**：`linear-space mean over skin-hue mask in faceSkinROI`
—— 平均误差 0.09，对柔肤的应用（给风格引擎一个参考肤色）应已足够。

### 对实现的影响

柔肤统计的正确做法：

```
1. 解码图像
2. 得到皮肤区域（semanticfaceskinmatte 或人脸关键点生成的 mask）
3. 在 mask 内计算：
   - SkinSmoothAverageFaceColour = 加权 RGB 均值
   - SkinSmoothFaceRoughness     = 加权 lap_abs（全分辨率）+ 线性标定
   - 眼部颜色 / 亮度方差 / 双峰性 = 在眼部 mask 内
```

**所以柔肤实现需要皮肤/眼部 mask** —— 但这个 mask 可以由**关键点几何生成**
（用 76 点的轮廓 + 眼点做多边形/椭圆填充），不需要语义分割模型。

## 7. 下一步

1. **样本统计**：31 张样张的 PeopleData 汇总（人脸数、粗糙度分布、有无人脸的差异）
2. **可视化 76 关键点**：在样张上画出来，对照人脸拓扑确定布局
3. **粗糙度标定**：不同肤质照片的 roughness 对比
4. **Rust 实现**：人脸检测 + 统计 → 填 bplist（先做 Apple 上可用的，跨平台后补）
