# 华为 Mate 70 照片支持计划：识别、色彩风格、人像与 Live Photo

> 分支：`research/huawei-xmage`。制定时间：2026-09-07，Step 0 已完成。
> 规范样本：Mate 70 Pro 优享版（PLR-AL50）原始 HEIC，优先使用 hdc 直接拉取的文件。
> 其他手机照片只作探索性线索，不作为实现依据。

## 1. 已确认的产品判断

Mate 70 原生 HEIC 已验证可以在 iPhone Apple Photos 中触发 HDR 显示：

- 标准模式：可触发 HDR；包含 `xtstyle`；
- 高像素模式：可触发 HDR；明确不支持 XMAGE 风格；
- 两者都使用 ISO 21496-1 `tmap` + gain map，并带 HDR Vivid 元数据。

因此，普通的“华为 HDR → Apple HDR”重编码**没有产品意义**。对于普通华为 HDR 照片，
产品行为应是：

```text
识别为 Apple 已可读的 Huawei HDR
  → 提示「无需转换」
  → 保留原文件，不重编码
```

后续研究只围绕 Apple Photos 不会自动解决的差异：

1. XMAGE 色彩风格（`xtstyle`）；
2. 华为人像模式到 Apple 人像结构；
3. 华为动态照片到 Apple Live Photo。

## 2. 产品边界

### 做

- Mate 70 Huawei HDR HEIC 只读识别、诊断和“无需转换”判断；
- 标准模式 XMAGE `xtstyle` 的结构研究，以及未来是否能映射 Apple 摄影风格的评估；
- 华为人像深度/辅助图提取与 Apple 人像图研究；
- 华为动态照片拆分、静帧处理、Apple Live Photo 配对合成；
- 普通 EXIF、GPS、Orientation 和拍摄时间安全保留。

### 暂不做

- 不把普通 Huawei HDR 重新编码为 Apple HDR；
- 不实现 `xtstyle` → Apple Photographic Styles 的语义转换，除非完成字段/效果验证；
- 不为高像素模式恢复不存在的 XMAGE 风格；
- 暂不实现 Huawei JPEG 输入（此前样本元数据来源不可靠）；
- 暂不生成 Huawei 专属 `it35` / `_cuva` 输出；
- 暂不恢复华为原机水印（需要 Mate 70 原始带水印样本）；
- 不新增“华为兼容”输出模式；现有输出模式仍只有 **OPPO 兼容 / Apple 标准**。

## 3. 阶段计划

### Step 0：基线与兼容性闸门——已完成

- 冻结 9 张 Mate 70 HEIC：初始样本 3 张 + hdc 受控样本 6 张；
- 9/9 含 `tmap`、base/gain-map grid、`nclx/clli/mdcv`、HDR Vivid `it35` / `_cuva`；
- 5/9 含 `xtstyle`，只出现在标准路径；高像素路径不支持 XMAGE 风格；
- 当前 Rust 9/9 无法识别为 OPPO，也无法通过现有 LHDR inspect；
- iPhone Apple Photos 已确认标准/高像素原图都能触发 HDR 显示；
- Photos 内编辑、导出和回读仍待验证。

详细记录见本文件 §6。

### Step 1：Huawei 原生 HDR 只读识别与“无需转换”（基础闸门已完成）

**目标：不解码、不重编码即可安全判断。**

工作：

- 新增独立 Huawei HEIC 结构识别器（`huawei_heic.rs`，复用 `isobmff.rs` 通用解析）：
  - `ftyp` 是否含 `tmap`；
  - `tmap` item、`dimg`、base/gain-map grid 及尺寸；
  - `nclx`、`clli`、`mdcv`、`it35`、`_cuva`；
  - `xtstyle` 是否存在及 iloc payload 长度；
  - item 类型清单和 Huawei marker。
- 新增 `xdremux_huawei_inspect` FFI 与 Dart 诊断入口，报告 `huawei-hdr`、`skip-native-hdr` 和结构字段；
- 普通 Huawei HDR 进入队列后显示：**“无需转换：此照片已是 Apple 可读 HDR”**，保留原文件，不重编码；
- 不调用 OPPO `extract_lhdr`，不进入 x265、gain-map 重编码流程；
- 修正通用 `infe` 解析：`item_type` 按 ISO BMFF 固定四字节读取，避免 Huawei item name 污染类型；
- 增加本地样本回归：设置 `XDREMUX_HUAWEI_SAMPLE_DIR` 时验证全部样本，目录缺失或为空时优雅跳过。

已补齐 EXIF/GPS/Orientation/焦段字段的只读摘要；这些字段不影响当前“无需转换”判断。`xtstyle` 结构摘要也会随同一份 JSON 报告返回。

验收（当前结果）：

- [x] 9 张 S0 样本均识别为 Huawei HDR（手工探针回归；本地测试支持增量目录）；
- [x] 标准/高像素、1x/0.6x/4x 的 `xtstyle` 存在性可报告；
- [x] OPPO 主路径未接入 Huawei 重编码逻辑；
- [x] 无样本 fixture 时测试优雅跳过；
- [x] UI 不显示内部 X6/X7 或私有实现标签；
- [x] EXIF/GPS/Orientation/焦段摘要（不返回 GPS 坐标，只报告 GPS 字段存在性）；
- [ ] 更广泛的 OPPO/普通 HEIC 误分类矩阵。

### Step 2：XMAGE 色彩风格研究

**目标：先回答“Apple Photos 是否已经保留/理解色彩效果”，不急于转换。**

当前进度：**结构摘要、两种设定样本差分及 Apple Photos 编辑→导出→回读验证已完成；编辑副本重新导入后仍显示 HDR。**

工作：

1. 对标准模式的 `xtstyle` 做只读结构解析：版本、头部、长度、系数布局；
   当前已确认 payload version 5/6、三个 little-endian float32 0.5、以及观察到的
   `u16le[6][192][192]` 固定字节形态；暂不赋予 plane/尾部字段语义；
2. 采集至少两种不同 XMAGE 色彩设定的标准模式原图，比较 `xtstyle` 与像素效果；
   已完成「鲜艳」/「明快」各 2 张的原始 HEIC 差分；
3. 验证高像素模式无 `xtstyle` 是固定产品限制；
4. 在 Apple Photos 中比较：原图显示、编辑面板、导出后是否保留视觉效果；
   已完成轻微调整、AAE/编辑 HEIC 导出和结构回读；编辑副本不保留 Huawei `xtstyle`；
5. 对 Apple Photographic Styles 做概念字段对照，但不假设两者可互转。

第一版产品行为：

- 识别并报告“含 XMAGE 色彩风格”；
- 不把 Huawei `xtstyle` 伪装成 Apple 摄影风格；
- 不因风格 item 存在而重编码普通 HDR；
- 任何未来转换都必须保留原文件，避免丢失 Huawei 风格信息。

验收：

- [x] `xtstyle` 无损检测；
- [x] 标准/高像素行为有明确文档；
- [x] 至少两种风格设定有差分样本（payload version 5/6）；
- [x] Apple Photos 编辑、导出及 HEIC/AAE 结构回读完成；
- [x] 编辑副本重新导入 Apple Photos 后的 HDR 视觉复核；
- [x] 没有 Apple Photos 语义映射结论前，不进入生产转换。

### Step 3：华为人像 → Apple 人像

**目标：研究华为深度/辅助图是否能接入现有 Apple 人像图管线。**

进度：已从 Mate 70 原始 HEIC 采集 4 张人像样本（`021058`、`021101`、`021110`、`021118`）。四张均保留原始 Huawei HDR graph，并出现 `edof` 辅助 grid、`RfDataB` 私有数据和 `auxl` 关系；Rust `xdremux_huawei_inspect` 已加入只读 `huaweiPortrait` 结构报告，Flutter 队列可查看诊断；尚未把这些数据写入 Apple 人像输出。

工作：

- 用 Mate 70 拍原始人像 HEIC（标准模式、高像素模式各至少一张）；
- 解析 `iinf` / `iref` / `iprp`，寻找 depth/disparity/auxiliary item；
- 记录华为深度图的尺寸、位深、通道、方向和深度语义；
- 与现有 OPPO `rear.depth` → Apple portrait graph 路径对照；
- 已实现 `edof` / `auxC` / `auxl` / `RfDataB` 的只读结构诊断；
- 只在深度语义确认后，适配 `portrait.rs` / `portrait_depth.rs`；
- Apple Photos 真机验证景深滑杆、主体识别、编辑往返。

验收：

- 人像源文件不损坏，普通 HDR 仍保持原图直通；
- `edof` / `auxC` / `auxl` / `RfDataB` 的 item、关系、尺寸和观察到的字节形态可解释；
- Flutter 明确提示“华为人像结构暂不支持转换”，不输出错误景深图；设置 `XDREMUX_HUAWEI_PORTRAIT_SAMPLE_DIR` 可运行本地结构回归，缺少样本时优雅跳过。

### Step 4：华为动态照片 → Apple Live Photo

**目标：复用现有 Motion Photo / Live Photo 能力完成配对。**

进度：已从 Mate 70 原始 HEIC 采集 3 张动态照片样本（`021031`、`021033`、`021038`）。三张均是“HEIF 静帧 + 文件尾追加独立 MP4”，已在 `motion_photo.rs` 增加保守识别和范围解析；同时确认了视频、音频、`mebx` timed metadata 轨道及 Huawei 的 cover time。

工作：

- 已用 Mate 70 拍摄原始动态照片，并通过文件管理器复制到 Docs；
- 已确认它不是 Android Motion Photo、OPPO LPEX 或 HEIF `mpvd`，而是新的 Huawei/OpenHarmony 追加视频结构；
- 已接入 `motion_photo.rs` 拆分/识别路径：识别 `huaweiOpenHarmonyMotionPhoto`，保留静帧和完整追加视频范围，并读取 cover timestamp；
- 静帧如果已是 Apple 可读 HDR，则不重复转换；
- 复用 `live_photo.rs` 合成 MOV 配对、content identifier 和 still-image-time；
- iPhone Apple Photos 验证长按播放、编辑、导出和重新导入。

验收：

- 原始动态照片识别稳定；
- 静帧 HDR 不丢失；
- Live Photo 配对可被 Apple Photos 接受；
- 不把 Huawei 原视频错误当作普通 JPEG/HEIC。

### Step 5：Flutter 产品接入与文档

- 普通 Huawei HDR 队列卡显示“无需转换（Apple 已支持 HDR）”；
- 允许用户查看/复制原图；Huawei 动态照片则进入独立的动态照片策略菜单；
- XMAGE 风格只做诊断信息，不进入普通转换按钮；
- 人像和 Live Photo 采用独立策略，不改变普通 OPPO/Apple 工作流；
- 更新 `docs/formats/`、设备兼容矩阵、FFI 契约和真机验证记录；
- 照片和 ONNX 模型不入 git，fixture 缺失时优雅跳过。

## 4. 技术风险与决策点

| 风险 | 处理 |
|---|---|
| 普通 Huawei HDR 已被 Apple Photos 接受 | 默认不重编码，只做识别和原图直通 |
| `xtstyle` 是 Huawei 私有量化数据 | 第一版只检测/保留原文件，不做语义转换 |
| 高像素模式不支持 XMAGE 风格 | 不尝试恢复或伪造风格 |
| 华为人像深度语义未知 | 先采样和解码，无法确认就不写 Apple 人像图 |
| Huawei 动态照片与 Apple Live Photo 语义仍未验证 | 已完成只读识别/拆分；先保留 AAC、`mebx` 和原始 HEIC，待真机验证后再决定 Live Photo 重写策略 |
| Apple Photos 编辑后可能改变 Huawei 私有 item | 原文件永远保留，输出作为新副本 |

## 5. 当前下一步

**Step 3/4：华为人像和动态照片结构研究。**

Step 1 基础识别闸门已落地；Step 2 的 `xtstyle` 版本、头部和固定字节形态已加入只读诊断。
EXIF/GPS/Orientation/焦段摘要、「鲜艳/明快」样本差分以及 Apple Photos 编辑导出、回读和 HDR 视觉复核已完成；动态照片已加入独立只读识别/拆分器，下一步是人像资源只读探针、Flutter 专用流程和 Apple Live Photo 真机验证。

当前不改变普通 Huawei HDR 的 `skip-native-hdr` 行为，也不把 `edof`/`RfDataB` 当作已确认的 Apple 深度语义；Flutter 仅保存并展示 `huaweiPortrait` 只读报告，`safeToTransform=false`。

## 6. Step 0 执行记录（2026-09-07）

### 6.1 样本 manifest

已冻结 9 张 Mate 70 HEIC：初始样本 3 张 + 通过 hdc 拉取的受控样本 6 张。
照片与完整 manifest 只保存在本机 `C:/tmp/huawei/`，不入 git；仓库只记录结构结论和哈希前缀。

| 样本组 | 数量 | 来源 | 关键差异 |
|---|---:|---|---|
| 初始 Mate 70 | 3 | 用户提供的 Mate 70 HEIC 压缩包 | 2 张含 `xtstyle`，1 张不含 |
| 受控高像素 | 3 | Mate 70 → Docs → hdc | 1x / 0.6x / 4x；均不含 `xtstyle` |
| 受控标准 | 3 | Mate 70 → Docs → hdc | 1x / 0.6x / 4x；均含 `xtstyle` |

### 6.2 当前核心基线

| 检查 | 结果 |
|---|---|
| `xdremux_classify` | 9/9 `missing-user-comment`；没有误报 OPPO 模式 |
| `xdremux_inspect` | 9/9 失败：`Failed to locate LHDR metadata block` |
| `tail_dump` | 9/9 `entries: []`；无 OPPO 私有尾部 |
| `ftyp tmap` | 9/9 存在 |
| `tmap` + base/gain-map grid | 9/9 存在 |
| HDR 静态标记 `nclx/clli/mdcv` | 9/9 存在 |
| HDR Vivid `it35` / `_cuva` | 9/9 存在 |
| `xtstyle` | 5/9 存在；只在标准路径出现，高像素模式明确不支持 |
| ffmpeg 基础解码 | 9/9 成功 |

### 6.3 Apple Photos 闸门

- [x] Mate 标准模式原图在 iPhone Apple Photos 中触发 HDR 显示；
- [x] Mate 高像素模式原图在 iPhone Apple Photos 中触发 HDR 显示；
- [x] Photos 内编辑、导出及 HEIC/AAE 结构回读；
- [x] 编辑副本重新导入后的 HDR 视觉复核。

**Step 0 结论**：普通 Huawei HDR 不需要 XDRemux 重编码即可在 Apple Photos 显示 HDR；
产品价值应集中在识别提示、XMAGE 风格、人像和 Live Photo，而不是普通 HDR 转换。

**Step 1 当前结论**：Huawei HDR 已进入只读识别和 UI 直通闸门；普通 Huawei HDR 不会进入转换队列。
Step 2 已完成「鲜艳/明快」样本差分及 Apple Photos 编辑、导出、回读和 HDR 视觉复核；Step 3/4 已采集 4 张人像和 3 张动态照片样本，结构结论见下方。

### 6.4 Step 3：Mate 70 人像样本（2026-09-07）

四张文件均被 Huawei 只读探针报告为 `huawei-hdr`，且仍有 `tmap`、base/gain-map graph、`xtstyle`、`it35`/`_cuva`。与普通样本相比，人像文件固定增加以下结构：

- `item 35`：命名为 `edof` 的 `grid`，尺寸与静帧相同（前三张 `3072×4096`，横向样本 `4096×3072`），由 12 个 `hvc1` tile 组成；
- `item 35 -> item 15` 的 `auxl` 关系；`auxC` 为观察到的
  `urn:com:huawei:photo:5:0:0:aux:unrefocusmap`；
- `item 38`：`mime` 名为 `RfDataB`，四张长度分别为 `3491016`、`3476326`、`3552892`、`3497512` 字节；与主图有 `cdsc` 关系；
- `RfDataB` 可从偏移 64 的观察布局读出 `1024×768`、每 sample 1 字节的平面；其中一张样本出现 `obp8` 标记，其余样本的对应 header 字节不同。该平面视觉上明显是分层/深度样式的图，但目前不赋予具体深度单位或通道语义；
- `edof` tile 解码后为 10-bit 三通道声明的灰度辅助图。它与 `RfDataB` 的对应关系及 Apple Portrait 的目标编码仍未确认。

因此当前结论是“已发现可研究的人像资源”，不是“已支持 Huawei 人像转换”。在深度方向、量化和坐标方向未验证前，不写入 Apple 人像图。

### 6.5 Step 4：Mate 70 动态照片样本（2026-09-07）

三张文件均是 Huawei HDR 静帧后追加独立 ISO-BMFF 视频：

| 文件 | 静帧 base | 第二个 `ftyp` 偏移 | 视频 | 音频 | cover time |
|---|---:|---:|---|---|---:|
| `IMG_20260907_021031.heic` | `4320×5760` | `2854016` | HEVC `1920×1440`, 53 帧, 1.930 s | AAC 32 kHz, 1.856 s | 910.8 ms |
| `IMG_20260907_021033.heic` | `3072×4096` | `2330687` | HEVC `1920×1440`, 39 帧, 1.426 s | AAC 32 kHz, 1.376 s | 333.12 ms |
| `IMG_20260907_021038.heic` | `4320×5760` | `2298162` | HEVC `1920×1440`, 50 帧, 2.327 s | AAC 32 kHz, 2.304 s | 1330.119 ms |

追加 MP4 的视频 track 都带 `[0,1;-1,0]` 旋转矩阵，显示方向与静帧的竖屏比例一致；另有 `mebx` timed-metadata track（与视频同帧数，单包 32768 字节）。`moov/udta/meta` 中存在 OpenHarmony 键：`covertime`、`deferredVideoEnhanceFlag`、`encParam`、`starttime`、`videoId`。`covertime` 是 big-endian `float32` 毫秒值，可作为后续 Live Photo 的 cover timestamp 候选。

三张样本的 `moov` 后还各有 60 字节 ASCII 风格的 Huawei trailer（以 `v6_` 开头，包含 `LIVE_...`）；它不是 ISO-BMFF box。拆分时应保留原始 video range，重写 MOV 前则应像现有 `standalone_bmff_length` 一样剥离这 60 字节。

此前 `motion_photo.rs` 对三张样本返回“不是动态照片”，原因是它只处理 XMP、`mpvd` 和 OPPO LPEX；这三张并非损坏文件。当前已增加保守的 `huaweiOpenHarmonyMotionPhoto` 识别：以第二个合法 `ftyp` 到文件末尾作为 video range，读取 `covertime`（big-endian float32 毫秒）和 `videoId`，并让现有拆分/`resolve_still_time` 路径可以继续使用。音频和 `mebx` 是否保留仍需要 Apple Photos 真机回归；原始 Huawei HEIC 必须保留。
