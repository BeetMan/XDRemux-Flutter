# iPhone 18 Pro（iOS 27）新模式研究

> 分支 `research/iphone-next`（仅本地，不推云端）。样张：`~/Desktop/iPhone 18 Pro/`
> （Apple 官方评测样张，Etretat/France，摄影师 Myrthe Geisbers，© 2026）。
> 方法：不逆 IPSW，直接读样张 EXIF/MakerNote/容器结构 + 本机 Photos/PhotoImaging 逆向佐证。

## TL;DR

**iPhone 18 Pro 的新模式 = Photographic Styles 3（质感 texture + 颗粒 grain）**，
叠加在原有色调（cast/tone/color）之上。三件事已全部在二进制层面理清：

1. **新捕获分类**：`CaptureType=LF` + `ImageCaptureType=13`（超 exiftool 已知表）=
   48MP Fusion **可变光圈主摄**的静止拍摄（样张光圈 f/1.5~f/4 各异，可变光圈在用）。
2. **拍摄时存的数据**：`texture_styles` item（Preset/CaptureType/FilmGrainSeed 的小 bplist 头）
   + 人像照的「Texture Style Post Processed People Data」（磨皮/去油光/眼下提亮统计
   + 人脸特征点）+ `FilmGrainSeed` + **新语义部件蒙版**（2026 命名空间，鼻/唇/牙/眉/耳/
   皮肤/眼镜/纹身/手，768×576 8-bit HEVC 灰度 mask）。
3. **编辑时怎么渲染**：颗粒 → `PIPhotoGrainHDR`（1536×1536 种子噪声 → ISO 分档 →
   亮度加权混入）；质感 → NeutrinoCore `NUStyleEngine`/`NUStyleTransfer`（从 People Data
   学风格）+ `definition/clarityNew` 细节增强 kernel（语义蒙版作用域内）。

现有 Rust 核心对 31/31 新样本解析/gain-map 校验无障碍。

## 样张集合

- 31 组（IMG_0004…IMG_8803），每组一个文件夹。
- 形态：纯 HEIC / Live Photo 对（HEIC+MOV）/ 编辑件（HEIC + AAE + IMG_E 重渲染）。
- 机型 `iPhone 18 Pro`，Software `27.0`；镜头组：
  - 主摄 wide `6.93mm f/1.48`（35mm 等效 35mm），24.5MP / 48.8MP
  - 长焦 `16.891mm f/2.8`（24.5MP）
  - 超广 `2.22mm f/2.2`（48.8MP，ProRAW）

## 关键发现

### 1. 新捕获分类（MakerNote）
- `CaptureType = LF`（主摄样本几乎全是），`ImageCaptureType = 13`。
- Apple 已知 ImageCaptureType 表只到 12（Scene）：1=ProRAW / 2=Portrait / 10=Photo /
  11=ManualFocus / 12=Scene。**13 超出已知表，是 iPhone 18 Pro 的新捕获类型**。
- 对照：长焦样本是 `CaptureType=DF` + `ImageCaptureType=12(Scene)`；超广 ProRAW 是
  `WYSIWYG` + `1(ProRAW)`；手动对焦是 `DigitalFlash` + `11(Manual Focus)`。
- `MakerNoteVersion = 17`（比旧机型新）。

**语义确认（结构性）**：ImageCaptureType=13 的样本**全部来自主摄**（6.93mm f/1.48），
且光圈值各不相同——**f/1.5 / f/1.8 / f/2.8 / f/4.0 都有**。对照：
- ICT=12(Scene) 全是长焦（16.891mm f/2.8，光圈固定 f/2.8）
- ICT=1(ProRAW) 是超广（2.22mm f/2.2）
- ICT=11(Manual Focus) 是主摄手动对焦（f/1.5）

旧 iPhone 主摄是**固定光圈**；iPhone 18 Pro 主摄光圈在样张里从 f/1.5 变到 f/4.0，
证明**可变光圈被实际使用**。这与官方「48MP Fusion 主摄 + 可变光圈（f/1.48–f/4，
六叶片四档）+ 手动对焦/快门/ISO/白平衡/对焦峰值」一致。

→ 结论：**ImageCaptureType 13 = iPhone 18 Pro 48MP Fusion 可变光圈主摄的静止拍摄**；
`CaptureType=LF` 是该主摄捕获的 Apple 内部管线代号（公开文档无此名，但结构上
就是新主摄的普通静止捕获）。

### 2. 新语义部件蒙版（核心内容）——`tag:apple.com,2026:` 命名空间
人像照（含人）携带一整套**细粒度部件语义蒙版**（FSINC instance mattes），
远超旧机型的 sky/skin 两件套：

- semanticnosematte（鼻）、semanticlipsmatte（唇）、semanticteethmattev2（牙 v2）
- semanticeyebrowsmatte（眉）、semanticearsmatte（耳）、semanticfaceskinmatte（脸部皮肤）
- semanticskinmattev2（皮肤 v2）、semanticnonfaceskinmatte（非脸部皮肤）
- semanticglassesmattev2（眼镜 v2）、semantictattoomatte（纹身）、semantichandsmatte（手）
- semanticpersonmatte（人整体）

沿用旧命名空间（urn:com:apple:photo:2018/2019/2020）：portraiteffectsmatte（PEM）、
semanticskymatte（天空）、semanticskinmatte（皮肤 v1）、hdrgainmap。

→ 用途：人像美颜/分区编辑（磨皮、美白牙齿、唇色、眼镜/纹身分区等）的数据基础。
这是「新模式」的主要内容载荷。

**编码格式（已解析，IMG_0391 人像）**：
- 每个部件蒙版 = **768×576、8-bit、HEVC(hvc1) 灰度蒙版**，auxl 引用主图 grid(46)+tmap(144)。
- 体积都极小（大部分区域为空）：person 5927B 最大，其余 161B~893B（teeth/eyebrows 仅 ~162B）。
- 对照：旧的 sky/skin/PEM 蒙版是 2016×1512 8-bit；styledeltamap 4096×3072 10-bit；
  linearthumbnail 1024×768 10-bit；hdrgainmap 2856×2142 8-bit。
- 即：新部件蒙版是**低分辨率（768×576）的 8-bit 灰度 mask**，按脸部部件各自一张。

### 3. 新 Photographic Style cast
编辑件 AAE（SemanticStyle，base64+zlib+JSON，buildNumber 26A396 / macOS）：
- **BrightPop**（IMG_0841，tone 0.18）
- **TanWarm**（IMG_1260，tone 0.299 / color 0.294）
- Standard（IMG_3265）
→ BrightPop / TanWarm 在我们既有 `cast-to-key1-study.md` 里已记录，属同一条线。

### 4. ⭐ Photographic Styles 3 —— 质感（texture）+ 颗粒（grain）

**官方佐证**（网络确认）：iPhone 18 Pro / iOS 27 推出 **Photographic Styles 3**，
在原有色调（cast/tone/color）基础上新增**质感（texture）**和**颗粒（grain）**控制；
官方口径「可同时调节色彩与肤质质感」，基于新 48MP 相机管线；Pro 档位可手动细调。
iOS 27 于 9/14 发布。

**UI 结构**（实测截图确认）：质感（texture）区有 **4 个质感选项**：
**标准 / 柔肤 / 光晕 / 胶片**，各配一个**强度**滑杆（0–100）；另有独立的**颗粒**开关。
- **柔肤** → People Data 的 Skin Smoothing Standalone（脸部平均色 + 皮肤粗糙度）
- **光晕** → 发光/柔焦效果（halation 一类）
- **胶片** → 胶片质感，**实测还含 halation**（胶片乳剂散射的高光红光晕）
- **强度** → 质感强度 → `definition/clarityNew` kernel 的 `intensity`
- **颗粒开关** → `FilmGrainSeed` + `PIPhotoGrainHDR` 的 `inputAmount`（on/off）

**数据载荷**（在样张里找到）：

a) **`texture_styles` 元数据项**（容器 item，content_type
   `tag:apple.com,2026:photo:metadata:texture_styles`）——质感风格参数载体。

   **基础结构**（已解析）：一个小 bplist，即质感/颗粒特性的「头」：
   ```json
   {
     "Preset": "Standard",           // 捕获时应用的摄影风格（本批评测机全是 Standard）
     "CaptureType": "LF",            // 捕获分类（见发现 1）
     "CaptureMode": "Still",
     "PortType": "PortTypeBack",
     "HardwareModel": "iPhone 18 Pro",
     "TextureStylePeopleDataVersion": 3,
     "FilmGrainSeed": 104             // 颗粒可复现种子（每拍各异；DF 的 IMG_0010 为 0）
   }
   ```
   **每一张 iPhone 18 Pro 照片都带这个项**（31/31 样本全有）。旧 iPhone 样本
   （iPhone Air / 既有 iOS）**没有**——属 iOS 27（2026 命名空间）新增。

b) **MakerNote PLIST 的「Texture Style Post Processed People Data」**（人像照有，
   `Texture Style People Data Version = 3`）。按 face 分，含：
   - Face ROI / Face Skin ROI / Face ID / Face Yaw·Pitch·Roll（姿态）
   - **Face Landmarks**（几十个特征点 X/Y/Error）
   - 三个质感操作的 Image Stats：
     - **Mattify**（HighlightsToMaskRatio、AverageFaceColor、SkipPerson）
     - **Skin Smoothing Standalone**（SkinSmoothAverageFaceColour、FaceRoughness、SkipPerson）
     - **Under Eye Brightening**（左右眼 AverageColor、LumaVariance、IsBiModal、FaceID）
   - Instance Mask Reference Key（如 `FSINCInstanceMask9`）——指向语义部件蒙版

c) **`Film Grain Seed`**（MakerNote，如 113 / 104）——颗粒效果的可复现种子。

→ 「质感」= 按人脸/部件的磨皮、去油光、眼下提亮的分区参数 + 引用语义蒙版；
「颗粒」= 可复现的胶片颗粒种子。语义部件蒙版（发现 2）是这些质感操作的作用域。
三者合起来就是 Photographic Styles 3 的完整数据。

## 容器结构（与现有一致）
瓦片化 HEIC：主图 grid + 深度 grid + 语义 grid + tmap；Exif + 若干 mime/uri 元数据项。
我们的 `extract_lhdr`（UHDR manifest 分支）对 plain HEIC 正常；动态照片走 `uhdr_jpeg`。

## 上游 corroboration（21Z121Z1/XDRemux 的 ps3-* / photographic-styles-3-* 分支）
上游对同主题做了更深入的运行时逆向（method swizzle 注入探针 + 数值 contract 校验），
与本笔记互相印证并补全了关键数值契约：

**texture_styles item（textureInfo）结构**（上游 `texture_style_native_standard_contract.json`，
与本笔记样张解析**完全一致**）：
```json
{ "Preset":"Standard", "CaptureType":"LF", "CaptureMode":"Still",
  "PortType":"PortTypeBack", "HardwareModel":"iPhone 18 Pro",
  "TextureStylePeopleDataVersion":3, "FilmGrainSeed":… }
```
- 必填键：`Version / HardwareModel / PortType / CaptureMode / CaptureType`
  （NeutrinoCore 缺这些会拒绝）。
- 可选键：`FilmGrainSeed / TextureStylePeopleDataVersion /
  TextureStylePostProcessedPeopleData / TextureStyleFaceAttitudeMetadata`。
- HardwareModel 可为营销名 `iPhone 18 Pro` 或型号 `iPhone19,2` / `iPhone19,3`。
- `texture_styles` 是独立的 2026 元数据项，不在 2023 SemanticStyle payload 里。

**MakerNote tag 84（质感风格记录，嵌在 EXIF MakerNote 里）**——上游
`texture_style_tag84_v5_numeric_contract.json`：
- key `8` = preset，key `9` = intensity（f32），key `10` = grain（f32），
  key `11` = originalInsteadOfReversibility（bool），key `12` = renderingVersion。
- key `0..7` 是 info 字段（Version/HardwareModel/PortType/CaptureMode/CaptureType 等的数值编码）。

**preset 映射表**（tag84 key 8 → 质感风格）：
`1=Standard（标准） 2=Soft（柔肤） 3=Studio 4=Filmic（胶片） 5=Glowy（光晕）`。
→ UI 4 选项（标准/柔肤/光晕/胶片）对应 1/2/5/4；Studio(3) 是另一档。

**Photos 编辑侧（AAE）键**：`preset / intensity / grainIntensity`。

**运行时逆向**（上游 `learnnode_coefficient_probe.m`）：用 method swizzle 钩
`NUStyleTransferNode` 私有 ABI，运行时捕获 LearnNode 的 key1 系数输出——解决本笔记
「key1 拿不到」的路子（在跑 iOS 27 的设备上对风格做一次编辑即可抓到）。

**FSINC（语义部件蒙版生成网络）**：上游 `ps3-semantic-12role-runner` /
`ps3-fsinc-beta6-probe` 分支在逆 FSINC Core ML 模型（MIL/sparse ops、模型 lowering），
`Models/ReverseKey1Ensemble.mlpackage` 是相关工作。语义部件蒙版由 FSINC 网络在采集时生成。

## 待办 / 下一步
- [x] 确认 `CaptureType=LF` / `ImageCaptureType=13` 的语义（= 48MP Fusion 可变光圈
  主摄的静止拍摄；光圈 f/1.5~f/4 在样张中被实际使用）。
- [x] 解析新语义部件蒙版的编码（768×576、8-bit、HEVC 灰度 mask，auxl 引用主图+tmap）。
- [x] 评估现有 Rust 核心对这些新样本的兼容（31/31 解析 + gain-map 校验通过）。
- [x] 解析 `texture_styles` 元数据项的结构（小 bplist 头）。
- [x] 定位颗粒渲染（`PIPhotoGrainHDR` 全套 kernel：generateNoise → _blendGrainsHDR
  → _grainBlendAndMixHDR → _grainGenCombineHDR）。
- [x] 定位质感渲染（NeutrinoCore `NUStyleEngine`/`NUStyleTransfer` + PhotoImaging
  `definition/clarityNew` 细节 kernel）。
- [ ] 「Texture Style Post Processed People Data」各 Image Stats 到质感滑杆的精确
  数值映射（需反汇编抠 Learn 节点拟合逻辑，工作量大，暂搁）。
- [ ] BrightPop/TanWarm 的 key1 晶格（受阻：见「key1 晶格差异」节）。

## 逆向：Photos app / PhotoImaging 框架（本机 macOS 27 + iOS 27 DeviceSupport 符号）

不逆 IPSW，直接读本机 `/System/Applications/Photos.app` + iOS 27 的 PhotoImaging 符号。
框架二进制在 dyld 共享缓存里（不在盘上独立 dylib）。

### 颗粒（grain）渲染
- **`PIPhotoGrainHDR`**：HDR 颗粒渲染器，用一张 **1536×1536 噪声图**（`generateNoiseImage`，
  width==512*3 / height==512*3），由 `PIGrainSeedExpression` 把 `FilmGrainSeed` 求值为种子。
- **完整内核**（从符号抠出）：

  `_blendGrainsHDR(isoImages, log10iso)` —— 按 ISO 分档混合颗粒强度（10/50/400/3200）：
  ```
  mix10_50    = mix(c.r, c.g, log10iso*1.43067655809 - 1.43067655809)
  mix50_400   = mix(c.g, c.b, log10iso*1.10730936496 - 1.88128539659)
  mix400_3200 = mix(c.b, c.a, log10iso*1.10730936496 - 2.88128539659)
  v = compare(log10iso-1.699, mix10_50, compare(log10iso-2.602, mix50_400, mix400_3200))
  ```
  → 高 ISO 颗粒更重（log10(50)≈1.699、log10(400)≈2.602 是切换点）。

  `_grainBlendAndMixHDR(img, grainImage, contrast, mixAmount)` —— 按亮度加权混入颗粒：
  ```
  luminance = clamp(dot(rgb, 0.333), 0, 1)
  gamma = 4.01 - 2.0*luminance
  rgb = sign(rgb)*pow(abs(rgb), 1.0/gamma)      // 转线性
  grain = grainImage.r - 0.5
  rgb += max(luminance, 0.5) * (contrast*grain) * (1.0-luminance)  // 阴影/中间调颗粒多
  rgb = sign(rgb)*pow(abs(rgb), gamma)          // 转回
  rgb = min(rgb, 12.0)                          // HDR 上限
  return mix(img, rgb, mixAmount)               // mixAmount = 颗粒滑杆量
  ```
  → 颗粒加权 = `max(luminance,0.5) * (1-luminance)`（暗部/中间调多、高光少）。

  `_grainGenCombineHDR(r,g,b,a)` = `vec4(r.x,g.x,b.x,a.x)`（4 个噪声通道合成一张）。
- 颗粒输入参数：`grain:<inputAmount / inputISO / inputSeed / inputImage>`。

### 质感（texture）渲染
- **`PITextureStyleAdjustmentController`**：Photos 编辑侧的质感调整控制器
  （`canRenderTextureStylesOnComposition:` 决定该照片能否用质感——即是否有 People Data）。
- 配套：`macStyleCollectionsIncludingTextureStyle:smartStyleRenderingVersion:`
  （把质感风格并进风格集合）、`_canRenderTextureStyle`。
- **质感操作 kernel（PhotoImaging，已抠出）**：`definition(image, blur, intensity)`
  → `clarityNew(s, b, intensity)`，非锐化蒙版式细节增强：
  ```
  dl = sl + (sl - bl) * intensity        // 细节 = 原图亮度 + (原图-模糊)亮度 × 强度
  mult = 1.571*(dl/sl - 1); mult = mult/(1+|mult|); mult += 1   // 软削波
  s.rgb *= clamp(mult, 1-0.5|intensity|, 1+|intensity|)
  ```
  作用于语义部件蒙版限定的皮肤/人脸区域。People Data 里的 Mattify / SkinSmoothing /
  UnderEyeBrightening 统计量提供分区参数（平均色、粗糙度、眼部颜色/方差）。

- **风格渲染引擎（NeutrinoCore）**：`NUStyleEngine` + `NUStyleTransfer` 管线：
  - `NUSemanticStyleProperties`（cast/tone/texture/grain 属性集）
  - `NUStyleTransferLearnNode`（`_evaluateImage:` 从 People Data + 图像学风格）
  - `NUStyleTransferApplyNode`（应用风格，`initWithInput:thumbnail:target:settings:`）
  → 质感操作由风格引擎的 Style Transfer（学习→应用）驱动，`textureStyleProperties`
  是质感参数载体。

### 语义风格主管线（neutrino 引擎，沿用既有研究）
- `PISemanticStyle*` 全家：AdjustmentController / ApplyNode / AutoCalculator / Filter /
  LearnNode / LinearThumbnailNode / Node / RenderNode / Renderer / SettingsExpressionFunction /
  ThumbnailApply。
- 源码路径：`Sources/Photos/workspaces/neutrino/PhotoImaging/...`。
- `PIParallaxInactiveStyleData`：视差风格数据。

### 关键映射
`FilmGrainSeed`（拍摄时存的随机种子）→ `PIGrainSeedExpression` → `PIPhotoGrainHDR`
按 ISO 混合噪声图 → 可复现的胶片颗粒。`texture_styles` item + People Data 块 →
`PITextureStyleAdjustmentController` → 语义部件蒙版作用域内的质感操作
（磨皮/去油光/眼下提亮）。

## 兼容性评估（Rust 核心 vs iPhone 18 Pro 样本）
- **解析**：31/31 样本能被 `isobmff` 解析器完整解析，无失败。
- **gain map 校验**：`iso_validate_probe` 认可新结构（grid 5×3、mono gain map、
  pixi 1ch、profile 4）。
- **新项读取**：texture_styles / 语义部件蒙版都能被解析器读出（可分析）。
- 结论：现有 Rust 核心读/校验新格式无障碍；转换/回写路径不受影响
  （这些样本是目标格式参考，非 OPPO 输入）。

## 写出 Standard PS3 输出（已验证可行）

按「② Standard 版」路线做了写出验证：往我方 OPPO→Apple 转换产物（`/tmp/photo1_iso.heic`）
注入一个 Standard `texture_styles` 项（`/tmp/inject_ts3.py`，按上游 native Standard contract
构造 bplist）：

- 注入项：`uri metadata` 项，content_type = `tag:apple.com,2026:photo:metadata:texture_styles`，
  item_name=`metadata`，cdsc 引用主图，payload 是 Standard textureInfo bplist
  （Preset=Standard / CaptureType=LF / CaptureMode=Still / HardwareModel=iPhone 18 Pro /
  PeopleDataVersion=3 / FilmGrainSeed=104）。
- 重建 iinf/iloc/iref 并同步调绝对 iloc 偏移（construction=1 的 idat 项不平移）。
- 结果：`iso_validate_probe` 通过（7×11 grid gain-map 结构完好），我方解析器正确读出
  texture_styles 项。
- → **写出合法 Standard PS3 文件的路径已打通**（`isobmff_write` 现有工具 + 该注入逻辑即可）。

剩下设备侧确认：此文件在 Photos 里是否出现质感/颗粒编辑入口（需真机/模拟器开 Photos 验证）。

## key1 晶格差异（受阻说明）
样张全是 `Preset=Standard`（拍摄时无风格）；BrightPop/TanWarm 是 Photos 里**编辑**
加的（AAE 里有 cast/tone/intensity 输入参数），编辑后的 IMG_E 被展平（无可编辑 key1）。
→ 新风格的 key1 只在 Photos 编辑会话里临时存在，样张拿不到；要拿到需在跑 iOS 27 的
设备上对 BrightPop/TanWarm 做一次编辑并捕获编辑前后的 key1。暂搁置。
