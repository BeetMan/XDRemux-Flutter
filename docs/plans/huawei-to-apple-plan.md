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

### Step 1：Huawei 原生 HDR 只读识别与“无需转换”

**目标：不解码、不重编码即可安全判断。**

工作：

- 新增独立 Huawei HEIC 结构识别器（建议 `huawei_heic.rs`，复用 `isobmff.rs` 通用解析）：
  - `ftyp` 是否含 `tmap`；
  - `tmap` item、`dimg`、base/gain-map grid；
  - `nclx`、`clli`、`mdcv`、`it35`、`_cuva`；
  - `xtstyle` 是否存在、版本和长度；
  - EXIF/GPS/Orientation/尺寸/焦段。
- 扩展输入分类和 inspect 报告，增加 Huawei 原生 HDR 状态；
- 普通 Huawei HDR 进入队列后显示：**“无需转换：此照片已是 Apple 可读 HDR”**；
- 不调用 OPPO `extract_lhdr`，不进入 x265、gain-map 重编码流程；
- 原文件保持原样，允许用户打开输出目录或继续分享。

验收：

- 9 张 S0 样本全部识别为 Huawei HDR；
- 标准/高像素、1x/0.6x/4x 差异准确报告；
- OPPO、普通 HEIC、UHDR JPEG 不误分类；
- 无样本 fixture 时测试优雅跳过；
- UI 不显示内部 X6/X7 或私有实现标签。

### Step 2：XMAGE 色彩风格研究

**目标：先回答“Apple Photos 是否已经保留/理解色彩效果”，不急于转换。**

工作：

1. 对标准模式的 `xtstyle` 做只读结构解析：版本、头部、长度、系数布局；
2. 采集至少两种不同 XMAGE 色彩设定的标准模式原图，比较 `xtstyle` 与像素效果；
3. 验证高像素模式无 `xtstyle` 是固定产品限制；
4. 在 Apple Photos 中比较：原图显示、编辑面板、导出后是否保留视觉效果；
5. 对 Apple Photographic Styles 做概念字段对照，但不假设两者可互转。

第一版产品行为：

- 识别并报告“含 XMAGE 色彩风格”；
- 不把 Huawei `xtstyle` 伪装成 Apple 摄影风格；
- 不因风格 item 存在而重编码普通 HDR；
- 任何未来转换都必须保留原文件，避免丢失 Huawei 风格信息。

验收：

- `xtstyle` 无损检测；
- 标准/高像素行为有明确文档；
- 至少两种风格设定有差分样本；
- 没有 Apple Photos 语义映射结论前，不进入生产转换。

### Step 3：华为人像 → Apple 人像

**目标：研究华为深度/辅助图是否能接入现有 Apple 人像图管线。**

工作：

- 用 Mate 70 拍原始人像 HEIC（标准模式、高像素模式各至少一张）；
- 解析 `iinf` / `iref` / `iprp`，寻找 depth/disparity/auxiliary item；
- 记录华为深度图的尺寸、位深、通道、方向和深度语义；
- 与现有 OPPO `rear.depth` → Apple portrait graph 路径对照；
- 只在深度语义确认后，适配 `portrait.rs` / `portrait_depth.rs`；
- Apple Photos 真机验证景深滑杆、主体识别、编辑往返。

验收：

- 人像源文件不损坏，普通 HDR 仍保持原图直通；
- 深度图结构可解释；
- 失败时明确提示“华为人像结构暂不支持”，不输出错误景深图。

### Step 4：华为动态照片 → Apple Live Photo

**目标：复用现有 Motion Photo / Live Photo 能力完成配对。**

工作：

- 用 Mate 70 拍一张原始动态照片，并通过文件管理器复制到 Docs；
- 检查 Huawei 动态照片是 Android Motion Photo、LPEX 还是新的 Huawei 结构；
- 接入现有 `motion_photo.rs` 拆分/识别路径；
- 静帧如果已是 Apple 可读 HDR，则不重复转换；
- 复用 `live_photo.rs` 合成 MOV 配对、content identifier 和 still-image-time；
- iPhone Apple Photos 验证长按播放、编辑、导出和重新导入。

验收：

- 原始动态照片识别稳定；
- 静帧 HDR 不丢失；
- Live Photo 配对可被 Apple Photos 接受；
- 不把 Huawei 原视频错误当作普通 JPEG/HEIC。

### Step 5：Flutter 产品接入与文档

- 队列卡显示“无需转换（Apple 已支持 HDR）”；
- 允许用户查看原图、复制原图或继续进入人像/动态照片专用流程；
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
| 华为动态照片结构未知 | 先接入现有 Motion Photo probe，再决定适配器 |
| Apple Photos 编辑后可能改变 Huawei 私有 item | 原文件永远保留，输出作为新副本 |

## 5. 当前下一步

**Step 1：只读识别与“无需转换”诊断。**

先实现/验证 Huawei HEIC 的结构报告和输入分类，不触碰普通 HDR 转换主路径；
确认后再分别推进 XMAGE 风格、人像和 Live Photo 三条研究线。

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
- [ ] Photos 内编辑、导出并回读验证。

**Step 0 结论**：普通 Huawei HDR 不需要 XDRemux 重编码即可在 Apple Photos 显示 HDR；
产品价值应集中在识别提示、XMAGE 风格、人像和 Live Photo，而不是普通 HDR 转换。
