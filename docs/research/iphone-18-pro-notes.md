# iPhone 18 Pro（iOS 27）新模式初探

> 分支 `research/iphone-next`（仅本地，不推云端）。样张：`~/Desktop/iPhone 18 Pro/`
> （Apple 官方评测样张，Etretat/France，摄影师 Myrthe Geisbers，© 2026）。
> 方法：不逆 IPSW，直接读样张 EXIF/MakerNote/容器结构 + 本机 Photos 已支持佐证。

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
- `LF` 大概率为 **Light Field（光场）**——待与 Photos 实际行为核对。
- `MakerNoteVersion = 17`（比旧机型新）。

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

**数据载荷**（在样张里找到）：

a) **`texture_styles` 元数据项**（容器 item，content_type
   `tag:apple.com,2026:photo:metadata:texture_styles`）——质感风格参数载体。

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

## 待办 / 下一步
- [ ] 确认 `CaptureType=LF` / `ImageCaptureType=13` 的语义（与 Photos 实际行为核对——
  是否光场/重对焦）。
- [ ] 解析新语义部件蒙版的编码（dtype/分辨率/与 tmap 的引用关系）。
- [ ] BrightPop/TanWarm 的 key1 晶格与既有风格的差异（沿用 universal graft 思路）。
- [ ] 评估现有 Rust 核心对这些新样本的兼容（转换/回写路径）。
- [ ] 解析 `texture_styles` 元数据项的结构（质感参数的具体布局）。
- [ ] 「Texture Style Post Processed People Data」各 Image Stats 的语义与 Photos
  质感滑杆的映射（磨皮 / 去油光 / 眼下提亮）。
- [ ] Film Grain Seed 如何驱动颗粒渲染（可复现性验证）。
