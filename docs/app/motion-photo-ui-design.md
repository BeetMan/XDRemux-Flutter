# Motion Photo（3a）UI/交互设计

> 范围：3a = 识别动态照片 → 提取静帧 → 走现有转换管线。
> 不做 3b（Live Photo 合成）的 UI，但为其预留设置位。
> 解析能力已有：`motionPhotoInspect` / `motionPhotoSplit`（ae4e0e0）。

## 核心决策

1. **默认行为：转换静帧，视频不丢但不动**
   转换产出和静态照片完全一致（HEIC/OPPO 兼容）。视频流不打进输出
   （那是 3b 的事），但用户可以随时单独导出。理由：3a 的价值是
   「动态照片不再被拒之门外或悄悄变成普通照片」，最小惊讶原则。

2. **识别时机：入队即识别，不是转换时才识别**
   文件进队列（选图/拖入/分享进）后异步跑 `motionPhotoInspect`，
   结果缓存进 `ConversionItem`。用户加完文件立刻看到「动态」标记，
   转换前就知道会发生什么。

3. **不弹窗、不打断**
   批处理场景弹窗是灾难。策略走设置项，逐文件操作走进项菜单。

## 各界面行为

### 主转换页（main.dart）

**队列项**
- 动态照片项在文件名旁显示「动态」chip（accent 色，小尺寸）
- 副标题追加：`静帧 <尺寸> · 视频 <MB>`
- OPPO 双码流额外显示「双码流」

**转换**
- 走现有管线，输入是原文件（转换器只读静帧部分的字节范围即可——
  现有解析器对尾部附加数据本就容忍，无需先拆包）
- 输出命名规则不变

**逐文件操作（溢出菜单 ⋮）**
- 新增「导出动态视频…」：`motionPhotoSplit` 到用户选的位置
  （桌面：目录选择器；移动：写入相册目录/分享）
- OPPO 双码流文件导出两个 mp4：`*.video.mp4`（全部）+
  `*.primary.mp4`（高质量主流），菜单文案「导出动态视频（含高质量主流）」

**设置页新增「动态照片」组**
- 策略选择：`转换静帧（默认）` / `跳过动态照片`
- （3b 预留：`合成 Apple Live Photo`，灰显标注「后续版本」）

### Apple/OPPO 工作流页（apple_oppo_workflow_page.dart）

- 选源图后检测：**动态照片的 donor 必须是静帧**
  （水印 graph、EXIF、ProXDR 元数据都在静帧字节段）
- 若是动态照片：先 `motionPhotoSplit` 静帧到临时文件，以静帧作为
  source/donor 继续四步流程，源卡片显示「动态照片 · 已取静帧」
- 视频部分在工作流里不提供导出（保持单职责；要导出去主转换页）

### 整理页（organize_page.dart）

- 扫描结果新增「动态照片」属性 tag（与 HDR/人像同级，不新增目录层级），
  与上游 v1.4 分类语义一致

## 降级与边界

| 情况 | 行为 |
|---|---|
| inspect 报错（畸形文件） | 按普通照片处理，不显示标记（静默降级） |
| 分享进来的动态照片 | OPPO 相册分享通常只发 JPEG 静帧——识别结果自然为非动态，无需特殊处理 |
| split 导出失败（权限等） | SnackBar 报错，不影响队列 |
| 设置=跳过时遇到动态照片 | 转换时该项标记「已跳过」，不进输出 |

## 实现清单

| # | 文件 | 内容 |
|---|---|---|
| 1 | `lib/models/app_models.dart` | `ConversionItem` 加 `MotionPhotoSummary?`（kind/stillSize/videoSize/streamCount） |
| 2 | `lib/services/motion_photo_service.dart`（新） | FFI 封装 + 异步识别 + 结果缓存 |
| 3 | `main.dart` | ingest 钩子、chip 与副标题、⋮ 菜单项、设置组、跳过策略 |
| 4 | `apple_oppo_workflow_page.dart` | 源图检测 → 拆静帧到临时文件 → donor 指向静帧 + 提示条 |
| 5 | `organize_page.dart` | 属性 tag |
| 6 | 测试 | widget test（chip 显示、跳过策略）；service 单测用合成 fixture |

## 不做（3a 明确排除）

- 不解析视频时长/编码参数（需要 mvhd/trak 解析，3b 再说）
- 不做 Live Photo 合成、不做视频预览播放
- 不改输出文件命名规则
