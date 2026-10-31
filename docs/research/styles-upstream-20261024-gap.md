# 上游 Styles 分支 vs 我方实现：差距分析（2026-10-25）

> 上游分析对象：`upstream/codex/styles-guidance-structure-fix`，HEAD `7c3403fa`（2026-10-24），相对 `upstream/main` 有 16 个提交、51 文件 `+7197/-28`（`git diff --stat upstream/main...<branch>`）。
> 我方对象：本 worktree（`codex/docs-style-guide-and-styles-gap`，基于 `origin/main`）。
> 旧版对比 `docs/research/styles-upstream-logic-comparison.md`（2026-09-02）覆盖 key1 lattice 布局、solver 流程、AAE 侧车、PS3 契约；本文只写那之后的变化与差距，不重复。

## 0. 前提（影响所有跟进方式）

1. **两仓是独立 git 历史**（`origin`=BeetMan/XDRemux-Flutter，`upstream`=21Z121Z1/XDRemux）。不能 cherry-pick、不能 `git merge`；上游代码只能 `git show <ref>:<path>` 读，然后按我们的单 crate 架构重写。本文所有"跟进成本"都按**重写**估，不按合并估。
2. **上游是 Rust 多 crate + macOS Swift 适配层**（`crates/xdremux-{hdr,runtime,heif,engine,metadata,codec,cli}` + `Sources/XDRemuxAppleAdapter`、`Sources/XDStylesNative`）；我们是 Flutter + 单 crate `xdremux/rust/src/*.rs`，无 Apple 原生层。
3. **分支的 HDR 能力全部建立在 macOS 私有框架之上**：`Sources/XDStylesNative/Styles.m`（263 行）通过 `dlopen` + 选择器 ABI 校验调用 `NeutrinoCore`（`_NUSemanticStyleProperties`、`NUStyleTransferReverseNode`、`_NUStyleTransferReverseThumbnailProcessor`、`_NUStyleTransferApplyProcessor`、`_NUStyleEngineConfiguration`、`CMIStyleEngineProcessor`）。这条链路**无法移植**，只能整段放弃或找等价物。
4. 我方的产品目标是"Apple 照片可继续编辑"，不是逐像素等价原生渲染（`docs/modules/styles-pipeline.md:60`）。判断"跟不跟"以此为准，而不是以"上游有没有"为准。

## 1. 一页结论

1. **已合并进 `upstream/main` 的 Styles 部分是真正的差距，且多数可移植**：每图 key1 拟合（`bb66981b`）、GTC 单调拟合（`bb66981b`）、c/d 光照图改为 guide mean（`bb66981b`）、全分辨率线性 HDR 先重建再降采样（`2e4e4672`/`36175cb7`）、Apple Log 编码 + 16-bit 码（`e04c1a98`/`0d8d3de5`）、coded orientation 不变式（`026d06a4`）。这些是纯数学 + 纯容器操作，不依赖私有框架 —— **跟**。
2. **只在分支上的部分（场景亮度重建、display family、display methods、`reconstruct-styles` 命令）不跟**。它们的输入是 NeutrinoCore 反向渲染出的 `unstyled.f32` / `thumbnail_codes.f32`（`7c3403fa:Sources/XDStylesNative/Styles.m` 的 `Decode`），我们拿不到；分支文档自身也声明"需要 macOS、Metal 和配套 `xdremux-apple-adapter`"（`7c3403fa:docs/styles-reconstruction.md`）。
3. **我方 identity `styleData` 是当前最大单点差距**：生产两条路径都硬编码 identity（`styles_native.rs:241`、`styles_attach.rs:540`），key0=15、GTC=常量 `FIELD_3`、tag4=4.0（`styles_native.rs:673-693`）。上游同位置已是每图拟合值。后果是风格滑块接近 no-op、与原生画质无关联。
4. **线性缩略图我们落后两代**：我们是"8-bit 4:2:0 + 固定 1024×768 + 先中心裁切到 4:3"（`linear_thumbnail.rs:12-14`、`:46-47`、`:126-154`），上游是"全分辨率 ISO gain map 重建 → 面积重采样 → Apple Log → 16-bit → Main10"（`36175cb7:crates/xdremux-runtime/src/apple_styles.rs:940`）。
5. **P0 建议：先做"线性缩略图几何 + 传递函数"这一条**（不是 identity → 拟合）。因为 identity→拟合需要可信的(thumbnail, primary)线性像素对，而这正好被缩略图管线的缺陷堵住；先修缩略图，key1/GTC 拟合才有信号。P0 不含任何 macOS 原生依赖。

## 2. 上游现状

### 2.1 已合并进 `upstream/main`（可跟的部分）

| 提交 | 日期 | 内容 | 关键落点 |
|---|---|---|---|
| `e04c1a98` | 2026-10-14 | HDR 参考缩略图改用 Apple Log 编码 | `crates/xdremux-runtime/src/apple_styles.rs`、`crates/xdremux-engine/src/apple_photographic_styles.rs` |
| `2e4e4672` | 2026-10-15 | 先重建 Gain Map HDR，再降采样做缩略图 | `apple_styles.rs`（+197/-66） |
| `36175cb7` | 2026-10-18 | 原分辨率 code 空间应用 gain map → 面积重采样 → Apple Log → 16-bit 送 Main10，取代 RGB8 量化 | 新增 `crates/xdremux-hdr/src/scene_linear.rs`（688 行）、`VideoToolboxMain10.swift` |
| `0d8d3de5` | 2026-10-18 | Apple Log 反函数保持有限（非正 lift/NaN → code 0）；16-bit 码探针 | `scene_linear.rs`、`apple_styles.rs` |
| `bb66981b` | 2026-10-18 | 按 12×9×8 网格拟合 key1（remove-style 局部二次）、拟合 GTC、c/d 改 32×32 guide mean | `apple_styles.rs`（+796/-?）、`apple_photographic_styles.rs` |
| `026d06a4` | 2026-10-18 | gain map / Style Delta Map / Linear Thumbnail 统一使用主图 coded 宽高比与 irot；tmap 用显示尺寸 + irot 0 | 新增 `crates/xdremux-heif/src/orientation.rs`（176 行） |
| `9647b290` | 2026-10-20 | 保留完整 coded transform；Styles 绑定到提交的 HDR 场景 | `crates/xdremux-heif/src/{direct,styles,orientation}.rs` |
| `89d806c8` | 2026-10-20 | Texture Styles 与 Photographic Styles 连带生成（#70） | `Sources/XDTextureNative/infer.m` |
| `083b9d35`/`6f637aea`/`f0292a99` | 2026-10-20 | 分别是 PR #68（全分辨率线性 HDR）、PR #65（HDR-before-reduction）、PR #69（coded orientation）的集成合并 | — |

已合并部分的**代码事实**（`upstream/main`）：

- `crates/xdremux-runtime/src/apple_styles.rs` 1769 行。`derive_style_scene:637` 在 base 分辨率应用 ISO 21496 增益得到场景线性 HDR；`linear_thumbnail_raster:940` 注释明确"Apple Log codes at 16-bit, not RGB8"；`source_derived_style_data:971` 用 remove-style 局部拟合产出每图 key1；c/d 两张图是"主图 guide mean / 缩略图 guide mean"，并注明"不是乘到亮度上"（`apple_styles.rs:336-352`）。
- `crates/xdremux-engine/src/apple_photographic_styles.rs` 2917 行。`apple_log_encode:239`、`apple_log_decode:255`（`2^((code-C)/A)` 常量与"非正 lift → 0"边界见 217-254 的注释）、`apple_style_linear_thumbnail_codes:272`（除 plist key 4 后编码）、`apple_style_identity_data:301`、`apple_style_identity_global_tone_curve:327`、`apple_style_monotonic_global_tone_curve`（PAV 单调投影，516 字节 = 257 count + 256 sRGB 编码节点）。
- `crates/xdremux-hdr/src/scene_linear.rs`：`reconstruct_scene_linear_hdr:176`（按 ISO 21496 权重在 base 分辨率应用增益，逐通道 min/max/gamma/offset）、`fitted_even_dimensions:231`（长边上限、双偶数、跟随源宽高比、小图不放大）、`area_resize_linear_rgb:257`。

### 2.2 只在分支上（未合并，2026-10-24 最后提交）

按主题分组，均为 `upstream/main` 所无：

- **A. 场景亮度重建（R）**：`crates/xdremux-hdr/src/scene_reconstruction.rs`（1116 行）—— `styles_thumbnail_to_linear:91` 是实测原生反函数 `2^((code-0.69336945)/0.08550479) - 0.00964052`，`decode_styles_thumbnail:98` 除 `linearGain` 后按 `linearRangeMin/Max` 裁剪，`make_scene_gain_map:38` 以 `1/64` 偏移生成有符号 RGB 增益图；`crates/xdremux-metadata/src/scene_gain_map.rs`（78 行）承载派生 tmap。基础提交 `f246a003`（2026-10-17）。
- **B. 场景引导（平坦面正则化）**：`crates/xdremux-hdr/src/scene_guidance.rs`（693 行），`SceneGuidancePolicy:6` 16 个参数（`flat_ev`/`edge_ev`/`primary_span_ev`/`detail_*`/`merge_radius`）。策略见 `docs/styles-reconstruction.md`「以原图引导平坦区域的增益」：0.075 EV 方差门限、0.1 EV 连通、64 像素最小区域、细结构双路径（亮度模型 / 仅背景）与 90% 内点、相关系数 ≥0.5/≥0.9 门限。细化提交：`9deb2a43`、`89fbd87a`、`fc012a66`、`167969ca`、`bea161c3`、`aa1d9506`、`68c1dcf6`（均 2026-10-23）。
- **C. 显示族与显示方法（独立 HDR 外观）**：`display_family.rs`（644 行，`DISPLAY_FAMILY_HEADROOM=8`、`w(h)=log2(h)/3`、`lambda=1-log2(h)/max(3,g)`，单图 ISO 21496 折中）、`display_methods.rs`（378 行，`render_styles_display:237`，中间调/皮肤/对立色度）、`display_methods_vectors.rs`（151 行合成向量）；提交 `dc22eff7`、`ea9286b4`（2026-10-23）。
- **D. 独立分析命令 + 发布命令**：`crates/xdremux-cli/src/reconstruct_styles.rs`（143 行）、`crates/xdremux-cli/src/hdr_look.rs`（163 行）、`crates/xdremux-runtime/src/style_reconstruction.rs`（820 行，`reconstruct_styles_hdr:429`）、`crates/xdremux-runtime/src/hdr_look.rs`（349 行，`plan_hdr_look:90`）、`crates/xdremux-engine/src/style_reconstruction.rs`（109 行，`STYLE_RECONSTRUCTION_METADATA_VERSIONS=[8,9,15,16]`）；提交 `d5de3cb9`（2026-10-23，含 macOS `HDRLookView.swift`）。
- **E. 容器读取（唯一可移植的分支资产）**：`crates/xdremux-heif/src/style_reconstruction.rs`（570 行，`extract_style_reconstruction_resources:288`）—— 按 URI 精确定位 `2023:photo:metadata:styles`、`aux:linearthumbnail`、`aux:styledeltamap` 三个子图，禁止经替代图像组回退，并给出主图签名字节。这段只有容器解析，不含 Apple 依赖。
- **F. 契约对齐与测试**：`73804f5c`（2026-10-24）把缩略图与 GTC 解码对齐到原生契约，新增 `crates/xdremux-runtime/tests/native_thumbnail_decode.rs`（54 行）、`native_gtc_consumer.rs`（267 行）与 `tests/native_styles_display.py`（208 行）；文档 `docs/styles-reconstruction.md`、`docs/research/styles-tonal-color-methods.md`。

### 2.3 分支的自述边界（引用其文档，用于判断可信度）

- `docs/styles-reconstruction.md`：「此命令需要 macOS、Metal 和配套的 `xdremux-apple-adapter`。它使用 Apple 私有框架方法……未来的系统版本可能使这项能力不可用。」
- 同文档「限制」：结果是相对场景亮度近似，不是 RAW 恢复；"平坦表面正则化是一种有界的外观先验，不能证明缩略图中的内容就是错误"；不标定绝对辐亮度。
- `docs/research/styles-tonal-color-methods.md`：Tone 生成 17 背景/16 前景/7 语义系数，正负 Tone 不互逆；"纹理 12 是天空"（推翻了此前把它当人物标签的理解）；抓取参照 iPhone17,3 / 24A446，实际环境 M1 Pro / macOS 26A434。

## 3. 我方现状（含证据行号）

### 3.1 styleMetadata：全 identity

- 生产入口 `styles_native():42` → `assemble_styles():47`，`style_state = StyleStateOverride::identity()`（`xdremux/rust/src/styles_native.rs:241`）；`styles_attach.rs:540` 同样用 identity。
- identity 的具体值：`key0=15`、`key1=identity_style_data()`、`gtc=FIELD_3`（512B 常量）、`tag4=4.0`、`tag5=2`、`light_c/light_d=FIELD_C/FIELD_D`（常量）、`tag_h=1.8384`、`gain=7.3535`、`key7` 三个 0（`styles_native.rs:673-693`）。
- key1 生成：864 块 × 30 f16，仅 index{3,7,11} = 1.0（`styles_native.rs:608-622`），与 `STYLE_DATA_BLOCKS=864`（`:32`）一致；即**没有任何每图拟合**。
- 头部注释自陈："delta map 用内嵌 golden IDR、linear thumbnail 是占位、sky matte 为零、styleMetadata 是 identity、`i`/`h`/`6`/`c`/`d` 是 golden 参考值"（`styles_native.rs:7-23`）；`build_stats_dict` 仍是 TODO（`:780`）。
- 唯一非 identity 的通道：当缩略图生成成功时会用真实 `light_c/light_d` 覆盖（`styles_native.rs:242-245`），来源 `linear_thumbnail.rs:107-108` 的 `compute_storage_light_maps`。
- 上游通用风格状态模型（CoreML）的产物只能经 `StyleStateOverride` 注入，且只出现在 `examples/`（`styles_graft_only.rs:17`、`bplist_debug.rs:5`、`attach_bisect.rs:78`）。`docs/research/native-fidelity-gap.md:75` 称模型预测"已上线"，与生产代码矛盾 —— **未验证**。

### 3.2 线性缩略图：8-bit 4:2:0、固定画幅、sRGB 而非 Apple Log

- 头注释直接写明取舍："encode 8-bit 4:2:0 HEVC（the existing x265 path）。Native files carry 10-bit; MAIN10 support depends on the linked x265 build, so 8-bit is…"（`linear_thumbnail.rs:12-14`）。
- 输出固定 `OUT_W=1024`/`OUT_H=768`（`linear_thumbnail.rs:46-47`；`styles_native.rs:182-183` 的 `LT_W/LT_H`），先**中心裁切到 4:3**再重采样（`linear_thumbnail.rs:126-154`）——非 4:3 源会被裁掉内容，且存储宽高比恒为 4:3，不随主图 coded 宽高比变化。
- 采样是 8-bit 截断：16-bit 源取高字节 `s >> 8`（`linear_thumbnail.rs:93`、`:98`），面积平均后写 8-bit（`:215-217`）。
- 编码走 `x265_encode_tiles(..., 3, true)` + `extract_hvcc_config_with_chroma(&stream, 1)`（`linear_thumbnail.rs:156-168`）；hvcC 的 `bit_depth_luma/chroma` 硬编码 8（`hevc.rs:1179-1180`、`:1237-1238`），**没有 Main10 能力**。
- 只有 `1/rot` 的旋转补偿（`linear_thumbnail.rs:113-124`，按主图 irot 反向旋转）——与上游"缩略图与主图同 coded 宽高比 + 同 irot"（`026d06a4`）**不是同一契约**。
- 失败即回退纯黑帧（`styles_native.rs:224-235`），保留结构但预览全黑。

### 3.3 天空蒙版与 PS3 蒙版：零值占位

- scaffold 阶段："Semantic sky matte item: mono 8-bit HEVC …… Matte content is all-zero ("no sky"); R4 will…"（`styles_scaffold.rs:13-16`），实际 `matte_w=(pw/2)&!1` 半分辨率全零（`:99-103`）。
- styles 阶段复用或新建零值 matte（`styles_native.rs:73-118`、`:163` `vec![0u8; ...]`）；真实蒙版只能靠环境变量注入（`XSTYLES_SKY_RAW` / `XSCAFFOLD_MATTE_RAW`，`styles_native.rs:125-144`、`styles_scaffold.rs:122-125`）。
- 12 个 PS3 语义 matte 同为 768×576 纯黑占位（`semantic_mattes.rs:1-14`、`:64`），仅 Huawei 人像轮廓可写入 `semanticpersonmatte`（`:11-14`）。
- 真实分割能力存在于离线子命令（`sky-matte`，SegFormer-B0，见 `docs/research/native-fidelity-gap.md:78`），但默认管线不调用；`native-fidelity-gap.md:80-84` 记录 sky matte 双写 bug 与 A/B 验收仍悬置。

### 3.4 我方完全没有的能力（grep 零命中）

对 `xdremux/rust/src/` 全量检索 `scene_guidance|scene_linear|display_headroom|reconstruct` 无任何 Styles 侧命中：**没有**场景亮度重建、平坦面正则化、display family、display methods、Apple Log 编解码、`reconstruct-styles`/`hdr-look` 命令、每图 key1/GTC 拟合。`docs/operations/current-status.md:38` 亦把 Photographic Styles 标为"实验性"，`:46-47` 明确 identity、8-bit 4:2:0 与 10-bit x265 构建成本。

Flutter 侧只有开关与互斥约束：`_stylesRequested`（`apps/flutter/lib/main.dart:719-733`）、Live Photo 清空 styles-only（`:1703-1712`）、`styleLayerStyles/Texture/Mattes` 位标志（`:1770-1773`）；无场景/显示相关 UI。

## 4. 差距矩阵

成本口径：半天 / 1-3 天 / 3-5 天（按重写估）；「依赖」列标明是否卡 macOS 原生层、10-bit x265、模型。

| 能力项 | 上游 | 我方 | 差距 | 跟进成本 | 依赖 |
|---|---|---|---|---|---|
| 每图 key1 拟合（remove-style 局部二次，12×9×8） | `bb66981b`：`apple_styles.rs:971` | identity 常量（`styles_native.rs:608-622`） | 滑块近似 no-op，状态与画面无关 | 3-5 天 | 需线性缩略图/主图像素对；无原生依赖 |
| GTC 每图单调拟合（257/516B，PAV，sRGB 节点） | `bb66981b`：`apple_photographic_styles.rs` 的 `apple_style_monotonic_global_tone_curve` | 常量 `FIELD_3`（`styles_native.rs:677`） | 无从校验曲线语义；分支 `73804f5c` 又修正了 65535 scale 与 sRGB 反解 | 1-3 天 | 需可信 (thumb, primary) 对；无原生依赖 |
| c/d 光照图（主图/缩略图 guide mean） | `bb66981b`：`apple_styles.rs:336-347` | 常量 `FIELD_C/FIELD_D`，缩略图成功时覆盖（`styles_native.rs:242-245`） | 已部分跟上 | 半天 | 无 |
| 全分辨率线性 HDR 重建（base 分辨率应用 ISO gain map） | `2e4e4672`/`36175cb7`：`scene_linear.rs:176` | 无（`linear_thumbnail.rs` 直接降采样 SDR 8-bit） | 缩略图不含 HDR 信息，styles 无法承载超 SDR | 3-5 天 | 需管线内拿到增益栅格；已有 ISO 21496 与增益重建链（`isobmff_write.rs:86-89` 区域） |
| Apple Log 传递函数 + 16-bit 码 | `e04c1a98`/`0d8d3de5`：`apple_log_encode:239`、`linear_thumbnail_codes:272` | sRGB 8-bit（`linear_thumbnail.rs:12-14`） | 传递函数错，动态范围被压 | 1-3 天（8-bit 先落地） | Main10 需 10-bit x265（五平台构建，`current-status.md:47`） |
| 缩略图几何/coded orientation 契约 | `026d06a4` + `fitted_even_dimensions:231` | 固定 1024×768 + 4:3 中心裁切（`linear_thumbnail.rs:46-47`、`:126-154`） | 非 4:3 源被裁；宽高比/irot 契约不一致 | 半天-1 天 | 无 |
| scene guidance（平坦面/细结构正则化） | 分支 `scene_guidance.rs:6`（693 行） | 无 | 我们无场景重建，无对象可约束 | 3-5 天（若强行重写） | 输入需原生反向渲染，**不建议** |
| display family（1-8× headroom 系列） | 分支 `display_family.rs`（644 行） | 无 | 无独立 HDR 外观输出 | 3-5 天 | 同上，**不建议** |
| display methods（中间调/皮肤/对立色度） | 分支 `display_methods.rs:237` | 无 | 无 | 3-5 天 | 同上，**不建议** |
| `reconstruct-styles` 独立分析命令 | 分支 `xdremux-cli/src/reconstruct_styles.rs` | 无 | 无场景分析产物 | 不建议 | 依赖 macOS 私有 SPI |
| HDR look 独占发布 | 分支 `runtime/hdr_look.rs:90` | 无 | 无 | 不建议（产品上无对应需求） | 同上 |
| identity styleData | 上游已是每图值 | identity（`styles_native.rs:241`） | 见第 1 行 | — | — |
| 真实天空分割 | 上游用原生 Vision/语义蒙版；分支仍不产 2026 matte（旧版对比文档已记） | 零值占位；离线 `sky-matte` 子命令可用 | 编辑分层差异未验收 | 1-3 天（接线，非新算法） | ort/SegFormer 已有；需真机 A/B |
| 语义蒙版 → 元数据（people/skin ratio、scene type） | `apple_styles.rs:362` `vision_scene_scores` + `style_scene_statistics:1037` | key7 恒 0（`styles_native.rs:686-690`） | 人物/皮肤比例不反映画面 | 1-3 天 | 需人脸/皮肤蒙版来源（`semantic_mattes.rs` 现为零值） |
| 每图 key6 统计 | 上游实算 | golden 参考值（`styles_native.rs:780` TODO） | 统计与画面无关 | 1-3 天 | 无（纯计算，需 RGB） |
| 容器侧 Styles 资源读取（无原生依赖） | 分支 `heif/style_reconstruction.rs:288` | 自有 `isobmff.rs` 解析，无此精确 URI 资源抽取 | 缺"按 URI 定位三子图"的严格校验 | 半天 | 无 |
| 私有适配层（NeutrinoCore 反向/预览/回读） | 分支 `Sources/XDStylesNative/Styles.m` | 无 | 不可移植 | 不建议 | macOS 私有框架 |

## 5. 跟进建议

### P0（立即做，纯 Rust，无原生依赖）

**P0-1 线性缩略图几何与 coded 契约对齐。**
落点：`xdremux/rust/src/linear_thumbnail.rs:46-47`（固定 OUT_W/OUT_H）、`:126-154`（4:3 中心裁切）→ 改为 `fitted_even_dimensions` 语义（长边上限、双偶数、跟随主图 coded 宽高比），`styles_native.rs:182-183` 的 `LT_W/LT_H` 常量与 `ispe` 同步；irot 沿用主图。
前置：无。风险：`styles_native.rs:310` 区域把 `matte_w/matte_h`、`linear` 的 `ispe` 与主图尺寸绑定的地方要一并核对；旧测试 `fitted_size_*`（`:984-1008`）需同步。
成本：半天-1 天。验收：竖拍/非 4:3 源的缩略图不被裁切，Apple 照片风格选图预览不变形。

**P0-2 线性缩略图传递函数：先重建再降采样，再 Apple Log。**
落点：`linear_thumbnail.rs:84-108`（解码后直接 8-bit 降采样）→ 插入"base 分辨率应用 gain map → 线性域面积重采样 → Apple Log 编码"，编码器沿用 `hevc::x265_encode_tiles`（8-bit 先落地，Main10 留 P1）。
前置：管线内在转换时已重建的增益栅格（`isobmff_write.rs:86-89` 附近链路的复用点需实测确认，**未验证**）。风险：传递函数接错会让预览变黑/发灰（`0d8d3de5` 的"非正 lift → code 0"必须照抄）；需真机与 `XSTYLES_LINEAR_STREAM` 金样对拍（`styles_native.rs:184-194` 已有旁路）。
成本：3-5 天（含真机验收）。验收：与 golden 缩略图亮度分布对比 + Photos 预览不异常。

### P1（P0 之后，仍无原生依赖，但需要前置信号）

> 2026-10-30：P1-1 / P1-2 已在 `xdremux/rust/src/styles_fit.rs` 实现（单测 + 真实样张探针），真机 A/B 未做；详见 `docs/modules/styles-pipeline.md` §4.1。

- **P1-1 每图 key1 拟合**：落点 `styles_native.rs:608-622` 换为按 12×9×8 网格的 remove-style 局部拟合（算法见 `bb66981b` 的 `source_derived_style_data`）。前置：P0-2 完成，否则拟合对无信息。风险：拟合方向写反（上游注释明确"forward primary-to-styled residual would point the other way"）；写坏后 Photos 拒收或滑块异常，需 A/B 金样。成本 3-5 天。
- **P1-2 GTC 单调拟合**：落点 `styles_native.rs:677`。注意 `73804f5c` 修正：读回按固定 65535 scale + sRGB 反解，端点不归一化、末位重复一个节点。风险：516 字节布局错一字节即整段失效。成本 1-3 天。
- **P1-3 key6 统计 + key7 语义比例真实化**：落点 `styles_native.rs:780` TODO 与 `:686-690`。前置：皮肤/人物蒙版来源（`semantic_mattes.rs` 目前零值）。成本 1-3 天。
- **P1-4 真实天空蒙版接线**：把 `sky-matte` 子命令输出接到 `XSTYLES_SKY_RAW`/`XSCAFFOLD_MATTE_RAW` 的等价内部通道，先修 `native-fidelity-gap.md:80-84` 记录的双写 bug。成本 1-3 天，风险在真机 A/B 结论未定。
- **P1-5 Main10 缩略图**：`hevc.rs:1179-1180` 的 8-bit 硬编码与五平台 x265 构建。前置：10-bit x265 可用。成本 3-5 天，风险最高（构建矩阵）。

### P2（观察，等上游合并或专业化需求）

- 分支的容器读取资产（`heif/style_reconstruction.rs:288` 的 URI 精确抽取）可借来做**只读校验**，不需要原生层：用于对拍我们生成的 styles 图是否被正确定位。成本半天。
- display family / display methods：只在我们要做"独立 HDR 外观导出"产品时才需要，且必须自己找场景参考（我们没有原生反向渲染）。

### 暂不跟

- `reconstruct-styles`、`hdr-look`、`scene_guidance`、`display_family`、`display_methods`、`Styles.m` 适配层：全部以 NeutrinoCore 反向渲染产物为输入，或直接调用私有选择器。分支文档自身声明依赖 macOS/Metal 且未来系统可能失效；我们的跨平台目标与之冲突。
- **必须等上游合并的项**：分支里唯一值得等的判断是"`reconstruct-styles` 的契约是否被上游接受"（其 `STYLE_RECONSTRUCTION_METADATA_VERSIONS=[8,9,15,16]`、报告字段、0.05/0.15 EV 门槛目前只是分支自我定义）。在这些固化进 `upstream/main` 之前，按它设计我们的产物格式会白做。已合并的 7 个提交则**不需要等**，现在就可用作规格。

## 6. 不适用条件与风险

1. **分支结论可能失效**：第 2.2 节与矩阵中标注"分支"的 5 行全部基于未合并提交（HEAD `7c3403fa`，2026-10-24）。上游可能改写参数、拆分 crate 或放弃方向；本文引用的行号均针对该快照。
2. **原生层结论不可外推**：`Styles.m` 只在 macOS build 26A434 / M1 Pro 抓取验证（分支文档自述），且明确"未来系统版本可能不可用"。不能推断 iOS 行为，也不能推断其他 macOS 版本。
3. **读代码推断、未实测**：a) 我方"增益栅格可在转换管线内复用"（5-P0-2 前置）未实测；b) key1 拟合在 identity→拟合切换后的 Photos 接受度未验证；c) 天空蒙版 A/B 差异仍悬置（`native-fidelity-gap.md:84`）；d) `native-fidelity-gap.md:75` 关于模型"已上线"的说法与生产代码矛盾，按生产代码（identity）处理，标注**未验证**。
4. **我方行号易失效**：所有 `xdremux/rust/src/*` 行号取自本 worktree 当前快照，后续改动会使引用偏移；引用时以函数名为主、行号为辅。
5. **成本是重写估算**：文中"半天/1-3 天"仅指 Rust 侧实现 + 单测，不含真机验收与 CI 时长；涉及真机的项（P0-2、P1-1、P1-4、P1-5）实际周期通常翻倍。
6. **不在本文范围**：key1 lattice 布局、solver 流程、AAE 侧车、PS3 最小契约、ReverseKey1/通用状态模型 —— 见 `docs/research/styles-upstream-logic-comparison.md`；PS3 契约的 2026 matte 部分见 `docs/research/native-fidelity-gap.md`。

## 7. 复核方法（可重跑）

```bash
git log upstream/main..upstream/codex/styles-guidance-structure-fix --format='%h %ad %s' --date=short
git diff --stat upstream/main...upstream/codex/styles-guidance-structure-fix
git show upstream/codex/styles-guidance-structure-fix:crates/xdremux-hdr/src/scene_reconstruction.rs | sed -n '85,135p'
git show upstream/main:crates/xdremux-runtime/src/apple_styles.rs | sed -n '336,400p'
git show upstream/main:crates/xdremux-engine/src/apple_photographic_styles.rs | sed -n '217,300p'
git show upstream/codex/styles-guidance-structure-fix:Sources/XDStylesNative/Styles.m | sed -n '108,190p'
grep -n "identity\|FIELD_3\|LT_W" xdremux/rust/src/styles_native.rs
grep -rn "scene_guidance\|display_headroom\|apple_log" xdremux/rust/src/   # 预期零命中
```
