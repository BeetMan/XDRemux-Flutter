# 华为 Mate 70 照片支持计划：识别、色彩风格、人像与 Live Photo

> 集成分支：`integrate/huawei-portrait-live`，目标版本 `0.4.3+37`。研究起点：2026-09-07；发布核查：2026-09-30。
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

### Step 3：华为人像 → Apple 人像（已完成并解决光效蒙版）

**目标：将华为视差与对焦结构无损转换为 Apple 标准人像图。**

进度：
- 已完成华为人像转换器 `run_huawei_portrait`，实现 1024×768 视差图方向对齐（竖屏 CW 90° / 横屏自适应）、2× 上采样与归一化对焦区域映射；
- 真机验证结果：iOS Apple Photos 可正常调整模拟光圈（f/1.4 - f/16）与重新指定对焦点；
- **人像光效蒙版（Portrait Effects Matte）修复（2026-09-27）**：
  - 针对 iOS 端人像光效（摄影室/轮廓光/舞台光）无法抠出主体的问题，解析 `RfDataB` 内部的 `0x00007b07` 人脸/主体检测框并自适应推导主体深度 `subj_depth`；
  - 结合平滑 Hermite S 曲线（Smoothstep）构建抗锯齿主体 Alpha Matte，2× 上采样后通过 HEVC 编码输出到 `portraiteffectsmatte` 辅助图流；
  - 本地样本与断言测试已更新并验证通过。

### Step 4：华为动态照片 → Apple Live Photo

**目标：复用现有 Motion Photo / Live Photo 能力完成配对。**

进度：已从 Mate 70 原始 HEIC 采集 3 张动态照片样本（`021031`、`021033`、`021038`）。三张均是“HEIF 静帧 + 文件尾追加独立 MP4”，已在 `motion_photo.rs` 增加保守识别和范围解析；同时确认了视频、音频、`mebx` timed metadata 轨道及 Huawei 的 cover time。
已接通 Apple Live Photo 合成管线（2026-09-27）：
- Rust `xdremux_make_live_photo` 自动对 Motion Photo 输入静帧切片 `still_range`，消除追加 MP4 污染；
- Flutter `_inspectMotionPhoto` 保留 `item.huaweiHdr = true` 标识，并对动态照片解除策略跳过置为 `pending`；
- Flutter `_convertOne` 实现华为普通 HDR 动态照片静帧无损直通抽取（不重复重编码），顺利进入 `makeLivePhoto` 配对；
- 华为人像+动态照片与普通华为 HDR+动态照片均验证通过，可输出有效 Apple Live Photo 配对文件；
- 自动化测试与回归用例全部通过。

真机配对修复（2026-09-29，对照 iPhone Air / iOS 27 原片 `IMG_4091`、`IMG_4093`）：
- 华为静帧的 Exif 里 `0x927C` 出现四次（`AF_C`、嵌套 HUAWEI TIFF、`##**N5022` 等）。只替换第一条时，Apple Photos 读到的是华为私有数据，静帧和 MOV 被导入成两个项目。现在只保留一条 Apple MakerNote（风格/人像模板 + tag `0x0011` content identifier）；
- MOV 与 iPhone 原片对齐：`still-image-time` 样本值为 int8 `-1`，`ftyp` 只含 `qt  `，`moov/meta` 带 `com.apple.quicktime.live-photo.auto = 1`；
- 五对样本（`021031`、`021033`、`021038`、`234224`、`001253`）已在 iPhone Photos 中识别为单张实况照片。

工作：

- 已用 Mate 70 拍摄原始动态照片，并通过文件管理器复制到 Docs；
- 已确认它不是 Android Motion Photo、OPPO LPEX 或 HEIF `mpvd`，而是新的 Huawei/OpenHarmony 追加视频结构；
- 已接入 `motion_photo.rs` 拆分/识别路径：识别 `huaweiOpenHarmonyMotionPhoto`，保留静帧和完整追加视频范围，并读取 cover timestamp；
- 静帧如果已是 Apple 可读 HDR，则不重复转换；
- 复用 `live_photo.rs` 合成 MOV 配对、content identifier 和 still-image-time；
- iPhone Apple Photos 验证长按播放、编辑、导出和重新导入。

验收：

- [x] 原始动态照片识别稳定；
- [x] 静帧 HDR 不丢失（普通 HDR 静帧无损直通抽取，人像 HDR 经 remux 保留 gain map）；
- [x] Live Photo 配对可被 Apple Photos 接受（生成对应 MakerNote Content Identifier 与 paired MOV）；
- [x] 不把 Huawei 原视频错误当作普通 JPEG/HEIC。

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
| Huawei 动态照片与 Apple Live Photo 语义仍未验证 | 已完成只读识别/拆分与 Live Photo 合成，静帧与 MOV 结构配对通过 |
| Apple Photos 编辑后可能改变 Huawei 私有 item | 原文件永远保留，输出作为新副本 |

## 5. 当前下一步

**Step 5：文档、设备兼容性矩阵与真机验证记录归档。**

Step 1–2 基础识别和 XMAGE 诊断已完成。
Step 3 华为人像毕业已完成（2026-09-26）。
Step 4 华为动态照片 → Apple Live Photo 合成已完成（2026-09-27）：
- Rust `xdremux_make_live_photo` 自动对 Motion Photo 来源静帧切片 `still_range`；
- Flutter `_inspectMotionPhoto` 针对华为动态照片切换为可运行状态，同时保留华为机型元数据；
- Flutter `_convertOne` 实现华为原生 HDR 静帧免重编码抽取，无缝接轨 Live Photo 合成器；
- 华为人像动态照片与普通动态照片均能正常完成配对与产出。

下一步是完成 Step 5 的文档、设备矩阵与最终真机交付验证。

### 5.1 0.4.3 合并/发版核查（2026-09-30）

- [x] 用户已验证最新 OHOS 构建的华为功能正常（用户反馈，不冒充本轮独立真机验证）。
- [x] 核对 Windows / Android / macOS / iOS / OHOS：识别、人像重封装、风格附加、Live 配对共用 Rust；华为文件明确路由 Rust，不受 Apple 的 Swift 选择影响。
- [x] 修复 Apple 平台 OPPO `rear.depth` 预检误拒华为 `edof/RfDataB` 人像。
- [x] iOS Podfile 补齐华为、动态照片和风格 FFI 的 `-u` 保留；增加 Dart/Podfile 契约测试及 IPA 二进制符号检查。
- [x] 修复设置变更使华为动态照片重新「无需转换」的问题；修复 checkpoint 丢失跳过状态/原因，恢复保留华为元数据和处理策略。
- [x] 人像 FFI 自动创建分类输出目录；人像 Motion 输入先切出静帧，不把追加 MP4 带入输出 HEIC。
- [x] Live Photo 改为临时目录合成、验证后输出；避免同目录写回覆盖源照片。失败标记为失败，重试使用固定同名 MOV，便于恢复验证。
- [x] 重建 Windows DLL 并检查核心/Flutter 版本一致；所有 Dart 使用的 FFI 符号均存在。
- [x] 本地 `cargo test --workspace --locked`：231 项通过，4 项依赖私有样片/手工流程的测试 ignored；单独启用华为 corpus 测试 7 项通过（9 张 HDR、4 张人像、3 张动态、XMAGE v5/v6）。
- [x] `flutter test --no-pub`：56 项通过，含真实华为 FFI 的同目录配对、源文件字节保留与两次重试；`flutter analyze --no-pub --no-fatal-infos` 无问题。
- [x] 本地 Windows release 编译通过。
- [ ] 云端 Windows x64/ARM64、Android、macOS、iOS 完整发布构建与 OHOS 核心 smoke。
- [x] 本地更新后的 OHOS profile HAP 编译通过（0.4.3+37，AOT / debug:true）；全部 35 个 FFI 入口均由 OHOS 核心导出。
- [ ] 合并 PR #2 到 main，发布 v0.4.3，并在 GitHub Release 使用手写更新说明。

平台差异是系统文件/图库接口，不是华为转换算法：OHOS 使用原生图库桥和 `general.file` 分享（避免系统改写 HEIC 辅助图）；Android/iOS 使用 Gal，桌面使用文件保存。上述保存/单文件分享只包含静帧；Live Photo 仍需同时导入 HEIC + MOV。本轮不声称实现系统图库 Live 资产写入，也不声称已在 Windows 主机上做 Apple 设备 UI 验收。

云端首轮出包额外发现 Windows ARM64 runner 已升级到 VS 2026，而 x265 的生成器仍锁 VS 2022；改为通过 vswhere 读取实际版本选择 CMake 生成器。该失败发生在编译前，并非华为算法差异；ARM64 路线原有实验性状态不变。

首轮 Windows x64、Android、macOS 发布构建通过；iOS archive 成功，但新增 `nm` 闸门检测到运行时 FFI 不可见，IPA 打包被阻止。在 `-u` 保留之外，按 [Flutter 官方静态 FFI 指引](https://docs.flutter.dev/platform-integration/legacy-ffi-plugin#stripping-symbols) 将 Runner 三个配置设为 `STRIP_STYLE=non-global`（不使用限制其它符号的导出白名单）。新增配置契约测试，单独重跑 iOS，不以 archive 编译成功冒充可用。

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

以上是 2026-09-07 的采样结论。深度方向、量化和坐标方向后来已在 Step 3 验证，Huawei 人像转换已支持，见 Step 3。

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
