# 合成输出 vs iPhone 原生：文件级差异清单（2026-09-02）

> 目标：把合成文件的格式对齐到 iPhone 原生水准。
> 样本：iPhone Air IMG_3716（琥珀色，1x）vs 我们 `/tmp/lp-final6/大师 3x_iso.heic`。

## A. 容器/条目层

| # | 差异 | iPhone | 我们 | 影响 | 可修性 |
|---|---|---|---|---|---|
| 1 | styleMetadata 条目名 | `metadata` | `styleMetadata` | 实验证明两者都被接受；不是完全一致 | 直接改名，低风险 |
| 2 | tmap 元数据格式 | **62B** 紧凑格式（15×u32，版本头 0x00400000） | **142B** ISO 21496-1（35×u32，0x00C00000） | 增益图元数据版本不同；显示正常但非同构 | 需逆向 Apple 紧凑格式语义 |
| 3 | XMP 条目组织 | 2 个无名 XMP（453/445B）关联 gain-map/delta grid | 3 个 XMP + 1 个显式 `hdrgm-xmp` 命名条目 | 结构不同但语义等价 | 中 |
| 4 | Exif 体积/厂商块 | 2968B，Apple MakerNote | 18358B，OPPO MakerNote | **结构性保留**（OPPO 水印恢复依赖）；style 入口不受影响 | 不改 |
| 5 | Exif 偏移头 | `[0,0,0,6]+Exif\0\0` | 一致 | — | ✓ |

## B. styleMetadata 内容层

| # | key | iPhone | 我们 | 说明 |
|---|---|---|---|---|
| 6 | `0` 协议号 | **16** | 15 | iPhone Air/iOS 26 原生=16 |
| 7 | `1` key1 格点 | 场景自适应微调（每 tile 不同） | identity（对角=1，其余 0） | 核心差异；通用模型嫁接已验证可行 |
| 8 | `6` 场景统计 | 场景实测（whitePoint 0.858、p98 0.739…） | golden 常量（**whitePoint=0.0、p98=1.0064 异常**） | 需图像解码算直方图分位数 |
| 9 | `7` PersonMasksValidHint | **0.0**（无人场景） | -1.0 | 上游用 -1 表示「无可信人」，但 Apple 原生写 0.0 |
| 10 | `h` | 1.8944（每图） | 1.8384（常量） | 应随图计算 |
| 11 | `i` 增益范围 | (-0.0089, 0.1132, 7.58) | (0, 0.0763, 7.35) 常量 | 应从实际 gain map 推导；且原生允许负 range min |

## C. 分级行动清单

**第一档：直接对齐（低风险，纯写值）**
- [ ] 条目改名 `styleMetadata` → `metadata`
- [ ] key0 = 16
- [ ] PersonMasksValidHint：无人时写 0.0（对齐 Apple 原生语义）

**第二档：需要计算（中等工作量）**
- [ ] key `i`：从实际 gain map 推导 OriginalRangeMin/Max/Gain（Rust 已有 gain map 解码）
- [ ] key `h`：随图计算
- [ ] key `6` 场景统计：解码主图算 p02~p98/whitePoint/highKey（十个 dict × 9 值）
- [ ] key `1`：接入通用模型预测（管线已验证，真机验收已过）

**第三档：逆向/保留**
- [ ] tmap 62B 紧凑格式逆向（Apple 版本头 0x00400000 的字段语义）
- [ ] Exif/OPPO MakerNote：保留不动（与「格式一致」冲突，但功能必需）
- [ ] XMP 条目组织重构（与 auxC 关联对齐）

## 与 Photos 行为的关系

已验证的事实：上述差异（1/2/3/4/6/8/9/10/11）**全部不影响**风格入口出现、
滑块响应、编辑保存重开。差异的意义在于「格式保真」本身——向 iPhone 原生
看齐能最大化未来 iOS 版本兼容性，并消除未知的隐式校验风险。

## Sky Matte 机制全景（2026-09-02 傍晚）

### 内容语义（室外组 3670~3681 实测）

- 软值蒙版 0~255，置信天空饱和 255；3674/3675 大天空 **48.8%/53.3% 覆盖**，3671/3672 小天空 ~8%，无天空照片残留噪声 max≤25
- 分辨率规则（上游 `fitWithin(max: 2016)`）：**长边 ≤2016 保持宽高比**（4284×5712→1512×2016；4032×3024→2016×1512）
  ——此前"半分辨率~3MP 上限"的猜测修正
- 编码：8-bit 单色（RExt profile 4，chroma=0）单 tile；XMP `SemanticSegmentationMatteVersion=65536`
- 生成源：`VNGenerateSkySegmentationRequest`（Vision 私有 API，L008 pixel buffer）
- 随 styleMetadata 出现（无风格照片无 sky matte）；auxl→[主图, tmap] + cdsc XMP

### 消费机制（上游 apple_style_scene_payload_probe.m 追踪）

`CMISmartStylePixelBufferRendererV1`（CMImaging 私有框架 SmartStyle 渲染器）：
`setInputSkyMaskPixelBuffer:` + cropRect（与 person/skin 蒙版并列），
连同 linear thumbnail RGBA、GTC、tone/linear 图 → `process` 产出：
- 32×32 tone/linear light maps（**key c/d 是蒙版感知推导的**）
- codedLinear RGBA（→ linear thumbnail item）
- 场景统计（key6 字典族）+ extendedStatistics

即：上游的 key c/d、key6 语义统计、linear thumbnail 全部由 Apple 私有渲染器
吃蒙版算出；我们的等价物 = UniversalPhotographicStyleStateNet 模型预测（已上线）。
蒙版对 **Photos 编辑器渲染质量** 有意义的假设待 A/B 验证。

### 我们的状态与遗留

- 全零蒙版 = "无天空" 语义（对无天空照片正确；本地全部 OPPO 样本实测无天空）
- 真实蒙版链路 R4 已建成：`sky-matte` 子命令（SegFormer-B0 ADE20K class 2，
  ort 动态链接，vs Apple Vision IoU 0.80~0.95）+ `XSCAFFOLD_MATTE_RAW`/`XSTYLES_SKY_RAW`
  接线，validate-apple + ImageIO 回读全绿
- **待办 1**：sky matte 重复 bug——scaffold 与 styles 两阶段各写一份（V3 item76/112），
  修复后才能做干净 A/B
- **待办 2**：OPPO 户外（带天空）样本 A/B——同 state 嫁接，唯一变量 = 蒙版全零 vs
  SegFormer 实值，观察 Photos 风格编辑的天空分区渲染差异（R4-realSkyMatte 验收悬置至今）

## Sky Matte A/B 定论补充：AAE 非破坏性编辑路径（2026-09-02 深夜，原片三件套）

### 原片路径传输样本（IMG_3730/3731 目录三件套）
用户从 iPhone 以保留原片方式导出的完整三件套：
- `IMG_373X.HEIC` = 原始文件，MD5 与发送时**逐字节一致**（Photos 从不回写原文件）
- `IMG_E373X.heic` = 编辑渲染（烘焙产物）
- `IMG_373X.AAE` = 编辑指令侧车（base64+zlib+JSON）

### AAE 编辑指令格式（首次完整捕获）
```json
{"adjustments":[{"identifier":"SemanticStyle",
  "settings":{"tone":-0.3,"cast":"Colorful","intensity":1,"color":0.33}}]}
```
- 容器：com.apple.photo v1.12，editorBundleID com.apple.mobileslideshow
- SemanticStyle 调整 = tone（色调滑杆）+ cast（风格基底：Colorful 等）+ color（强度）
- 两份 AAE 完全一致 → 同一风格同一参数施加于 A/B

### 完整闭环证据
1. 输入 A（全零蒙版）vs B（实值 54%）MD5 不同（仅蒙版 payload）
2. 编辑指令 AAE 完全一致
3. 输出渲染 IMG_E3730 vs IMG_E3731 逐字节相同（仅 Exif UUID）

→ **Photos 风格编辑渲染不消费文件 sky matte**，全零/实值蒙版产出逐字节相同渲染。

### 机制修正（重要）
- Photos 风格编辑**不写回原文件**：原 HEIC MD5 不变，编辑状态 100% 存 AAE 侧车，
  导出时按需烘焙（IMG_E*）或原样传输（原文件 + AAE）
- 2120 的 styleMetadata **不是编辑回写产物**——编辑路径不改 styleMetadata。
  2120 的 styleMetadata 是拍摄时写入（其 photos 早于编辑存在）或来自更早链路，待另查
- 我们此前「编辑回写会把状态写回文件」的推断**证伪**——期待对象不存在

## Sky Matte A/B 真机实验定论（2026-09-02 晚，IMG20260822161608）

### 实验设计
OPPO 50MP 天空照（SegFormer 55.7% 天空）→ 完整转换 + 预测状态嫁接 ×2：
- A：全零 sky matte（旧行为）
- B：SegFormer 实值蒙版（54.3% 天空覆盖）
唯一变量 = 蒙版内容，其余（预测 key1/统计/key7/结构）逐字节一致。

### 结果（决定性）
用户在 iPhone Photos 对 A/B 各套同款风格 → AirDrop 回传两文件：
- 全部 275 item 除 Exif 内随机 UUID 外**逐字节相同**
- 主图 216 tiles、增益图 54 tiles、tmap 全部一致
- 用户主观：无视觉差异

### 结论：Photos 风格编辑不消费 sky matte
- `CMISmartStylePixelBufferRendererV1.setInputSkyMaskPixelBuffer:` 只在上游**生成 styleMetadata 状态**
  时生效（光图 c/d + 场景统计的推导入口）；Photos 编辑器应用风格走另一渲染路径，不读文件蒙版
- 全零蒙版与真蒙版产出逐字节相同的编辑渲染
- **我们无需为户外照集成 SegFormer**——转换文件全零蒙版即可，省掉 ONNX runtime 分发/模型打包/
  分割推理整条依赖链。天空层研究关闭。

### 附带确认
- AirDrop 编辑导出（照片模式）剥 styleMetadata + delta/linear/matte，只留主图/增益图/tmap + Exif，
  Exif 带新随机 UUID（导出器重写）
- 编辑回写（若走原片路径）才会把编辑管线状态写回文件（2120 观察）

## 风格辅助层图谱与内容解码（2026-09-02 下午，2120/3716/3437 三方对照）

### 完整辅助层清单（auxC URI + 规格 + 挂载方式）

| 辅助层 | auxC | 规格 | iref |
|---|---|---|---|
| 风格 delta map | `tag:apple.com,2023:photo:aux:styledeltamap` | ½ 像素量 HEVC grid（10-bit 4:2:0） | auxl→[主图, tmap] |
| 线性缩略图 | `tag:apple.com,2023:photo:aux:linearthumbnail` | **固定 1024×768**（10-bit 4:2:0 彩色） | auxl→[主图, tmap] |
| 天空蒙版 | `urn:com:apple:photo:2020:aux:semanticskymatte` | ~3MP 8-bit 单色（RExt profile 4） | auxl→[主图, tmap] + cdsc XMP |
| 人像蒙版族 | portraiteffectsmatte / skin / hair / teeth / glasses | ~3MP 单色 | auxl + cdsc |

**所有风格辅助层都同时 auxl 到主图和 tmap 两个 item**。tmap 自身 dimg→[主图, gainmap]。
语义蒙版分辨率 = min(半分辨率, ~3MP 上限)；天空蒙版**随 styleMetadata 出现**（3437 无风格即无天空蒙版）。

### styledeltamap 内容语义（ffmpeg 裸解码定案）

2120（金色风格编辑，j=1.3）的 delta tile 10-bit 裸值：**Y/U/V 全部以 512 为中性**（均值 511.8/512.0/512.0），
偏差仅 ±3~6%（Y 504–530、U 509–543、V 502–513）。即 delta map 是**逐像素 RGB 增益图，
512=1.0**，风格的空间变换（含 B 通道偏移最多）编码于此。我们 graft 的 golden 中性 tile 常数 506（-1.2%），
来自真实参考片，Photos 接受。

### linearthumbnail 内容语义

原生为 **10-bit 4:2:0 彩色**（非单色）、固定 1024×768（横置 + irot），是线性域彩色预览。
我们当前占位：8-bit 黑块 768×1152（profile 4 / chroma 3）。真生成路径 = 解码主图 → 线性化 → 缩到 1024×768 → 10-bit HEVC。

### 传输/导出路径差异

- AirDrop「照片」模式导出：像素烘焙（3437 编辑版均值差 R+4.4/B-8.1）、深度与蒙版全剥、
  **无 styleMetadata**——导出器不写风格状态。
- 2120 = 原始像素 + 完整辅助层 + styleMetadata（编辑管线回写原件，传输走了原片路径）。
- 人像模式拍摄 5/5 从不写 styleMetadata；编辑入口打开时现场重算（Base 渲染 + Vision 蒙版）。

### 我们嫁接件的遗留项（按影响排序）

1. ~~**linearthumbnail 黑块**~~：已解决（2026-09-03，`linear_thumbnail.rs` 真生成：
   heif-oxide 解码主图 → 反 irot 转横置 → 中心裁切 4:3 → box 缩放 1024×768 → 4:2:0
   HEVC。与原生差异仅 8-bit vs 10-bit——MAIN10 取决于 x265 构建）。
2. **skymatte 重复**：scaffold 阶段与 styles 阶段各写一个（V3 里 item76/112 全零重复）——去重待办
3. delta map 恒定 506 vs 原生逐像素实值：嫁接预测状态时中性即可，机制上无误
4. 缩略图规格：768×1152/8-bit vs 原生固定 1024×768/10-bit——Photos 容忍，对齐属锦上添花

## 语义层机制解码（2026-09-02，人像样本组）

样本：iPhone Air 人像模式 6 张（`samples/portraits-20260902/`，未入 git）+ 此前 3716~3722/3670 组。

### key7 PersonMasksValidHint 三态语义（三角验证定案）

| 样本组 | 管线 | key0 | j | hint |
|---|---|---|---|---|
| 3716~3722 风格拍摄（无人） | 拍摄 | 16 | 1.0 | 0.0 |
| 3717 风格拍摄（远小人 People=0.0041） | 拍摄 | 16 | 1.0 | 0.0 |
| 3670 Live 拍摄（有人 People=0.30/Skin=0.12） | 拍摄 | 16 | 1.0 | **-1.0** |
| 2120 人像拍摄 + Photos 风格编辑（People=0.37/Skin=0.07） | **编辑** | **15** | **1.3** | **+1.0** |

结论：hint=0.0 无人或占比过小；hint=-1.0 拍摄时分割蒙版；hint=+1.0 编辑时 Vision 重算蒙版。
上游写 1.0 对应的是编辑管线（其代码即跑在编辑路径）——**不是 bug**，此前判断有误。
key0：拍摄=16、编辑=15（3719=131088=0x20010 为珠光 flag 位叠加）；j 编辑时=渲染强度（2120 为 1.3）。

### 人像模式拍摄不写 styleMetadata（5/5 证实）

3437/3312/2929/1591/1237 均为原版人像模式拍摄（portraitEffectsMatte/depth 齐全），
**全部无 styleMetadata item**——Apple 人像管线与风格管线分离，拍摄时永不写入。
2120 之所以有，是用户在 Photos 里对人像照片套过风格编辑（编辑管线补写）。

### RGB 通道皮肤字典首次观测（2120）

ToneMappedImage{Red,Green,Blue}ChannelSkinBased 首次出现实值；Red 通道 p98=1.0632、
whitePoint=1.0985 **>1.0**——tone-mapped 域按通道统计不 clamp。
3670（拍摄管线）同样有 RGB 通道字典实值，无人样本（3717）仅有 Person 字典、无皮肤字典。

### 对嫁接路径的指导

- 我们的嫁接件走编辑读路径，key0=15 与编辑管线标记一致（此前以为是差距，实为对齐）。
- 无人场景 hint=0.0（V3 已实现）；有人场景（若未来做）应写 +1.0 且需真实统计。
- 线性统计量化：3670 LinearImage 各分位为 ~1/122 步长的倍数（7-bit 线性域量化特征）。


## Live Photo + 风格组合终局实验（2026-09-02 深夜，IMG_1591 预测状态）

### 实验设计
- 静帧：IMG_1591 人像 → scaffold+styles → graft 预测 state v2
  （key1 ΔRMS=0.0173 为 6 张人像预测中最大；key7 从文件自带蒙版实算
  People=0.417/Skin=0.087/hint=+1.0 编辑读路径语义）
- 视频侧：OPPO motion 流（内容与静帧不匹配——刻意控制变量：配对判定只看
  双侧 content identifier，与画面无关；失败发生在编辑加载层，内容不影响否证）
- `make_live_photo` 配对：cid 双侧一致、`existing_pair_is_valid=true`

### 结果（真机）
- 实况徽章出现（配对成立）
- 编辑器能打开、风格 tab 可见（style 状态被识别）
- 编辑加载报「无法加载此图像的编辑内容」——与 identity+pair 失败模式完全一致

### 定论（与 2026-09-02 早间矩阵合并）
三轮实验（identity key1 / 真实 key1 / 预测非身份 key1 + pair）全部卡在同一层：
**Photos 对「声明 style 状态的 Live Photo」的联合编辑加载是结构性拦截，与风格
内容（identity 与否、ΔRMS 大小、key7 语义）无关。**
- Live Photo 档强制关闭 styles 的互斥决策验证闭环，转为永久设计约束
- 除非未来观察到 Apple 原生「Live Photo + styleMetadata」样本（目前从未见过，
  3670 Live 拍摄件无 styleMetadata），否则不应再投入此方向的绕过研究

### 实验工具
- `xdremux/rust/examples/lp_pair.rs`：带参数 Live Photo 配对 CLI
  （still + motion.mp4 → 配对静帧 + MOV，可选从源 JPEG 取 pts/vendor 元数据）
