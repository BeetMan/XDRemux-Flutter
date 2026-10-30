# 摄影风格管线（styles pipeline）

> 对应代码：`styles_scaffold.rs` -> `styles_native.rs`（主路径）、`styles_graft.rs`（金样移植）、`styles_bplist.rs`（bplist 写入器）、`styles_consts.rs`（常量表）。
>
> 目标：把 OPPO 原始照片转换为**可在 Apple 照片中继续编辑**的 HEIC——保留摄影风格编辑图（Photographic Styles graph），使 iPhone 上的风格调整可以叠加在转换结果之上。

## 1. 管线结构

```
OPPO 原始 HEIC
  │ ① 标准化：重建为标准 ISO 基线 HEIC（增益映射转为 ISO 21496-1）
  ▼
标准基线
  │ ② styles_scaffold::scaffold(standard)
  │    构造风格容器骨架（item 布局、关联属性、必需引用）
  ▼
脚手架
  │ ③ styles_native::assemble_styles(scaffolded)
  │    装配原生风格 item：
  │    - delta grid（DELTA_ROWS × DELTA_COLS tile）风格增量层
  │    - linear（线性调色）item
  │    - style_meta（风格元数据，bplist 编码）
  │    - sky 蒙版 item + mime item（天空分层编辑）
  │    - tmap 元数据接线（auxl / cdsc / dimg 引用图）
  ▼
apple-edit.heic（Apple 照片可直接编辑）
```

入口 `styles_native(standard)` = scaffold + assemble 两步。备选路径 `styles_graft::graft_styles(standard, golden)`：从金样（已知良好的 Apple 风格文件）移植风格图结构到新文件，返回 `GraftSummary`（移植了哪些 item/引用）。生产用 native 路径，graft 用于对拍验证和疑难样张兜底。

## 2. 关键机制

### 2.1 item ID 分配

新 item ID 从现有最大 ID + 1 起分配，且必须越过 `grpl/altr` 组 ID（`max_group_id_pub`），避免与组 ID 冲突。顺序：delta tiles -> delta grid -> linear -> style_meta -> sky -> sky_mime。

### 2.2 引用图（Apple 的编辑图语义）

Apple 风格文件的核心是 `cdsc` / `auxl` / `dimg` 引用网络：

- `tmap` item 持有增益映射元数据，`dimg` 指向主图 grid 和增益映射图 grid
- 风格编辑 item 通过 `cdsc` 关联回 [主图, tmap]
- 天空蒙版等辅助层通过 `auxl` 挂到主图

引用图的形状直接决定 Apple 照片能否识别编辑结构。移植/重建时**引用目标集合必须精确**（见已知问题）。

### 2.3 bplist 写入器（`styles_bplist.rs`）

手工实现的 Apple 二进制 plist 写入器（`BplistWriter`：add_bool/int/real/data/str/dict + finish）。风格元数据（tone/warmth 值、风格标识、蒙版参数）以 bplist 编码进 `styleMetadata` mime item。**不依赖第三方 plist 库**，保证字节级可控。

### 2.4 与增益映射的交互

标准化阶段 OPPO 私有 UHDR 已转为 ISO 21496-1 tmap；风格装配只接线引用，不重编码增益映射数据。工作流直通设计（v0.3.0 起）：直接从 OPPO 原始照片做一次 styles 转换，**原始照片同时是写回 donor**——中间 baseline 会带增益映射图，二次转换会产生双增益映射图和重复引用结构（历史 bug，已删除该路径）。

## 3. 已知差异（与 Apple 原生文件对比）——已定论（2026-08-27 复查）

- ~~天空蒙版 auxl 引用重复出现两次（待修）~~ 复查结论：双天空蒙版 auxl 是 **Apple 原生结构**，无需清理
- ~~部分 auxl 引用目标为 `[主图, tmap]` 而非仅主图（待修）~~ 同上，auxl→[primary,tmap] 也是 Apple 原生结构
- Apple 照片内编辑兼容性已于 2026-08-16 iPhone 真机验证通过
- 不承诺逐像素等价：目标是"Apple 照片中可继续编辑"，非字节级克隆

验证现状：直出文件 ColorOS 相册、Windows WIC、heif-oxide 均可打开；Apple 照片内编辑兼容性 iPhone 真机已验证。

## 4. 线性缩略图（Apple Log）

对应代码：`linear_thumbnail.rs`（几何 + 重采样 + 编码）、`apple_log.rs`（传递函数）、`styles_native.rs`（装配 ispe/item）。

原生 `aux:linearthumbnail` 在 Styles 文件里存的是 **Apple Log 码值**，不是 sRGB、也不是线性 RGB。2026-10-25 起本移植按同一契约生成：

1. heif-oxide 解码主图得到 display-ready sRGB（8/16-bit）；
2. 按主图 `irot` 把显示方向转回 **coded 存储方向**（aux item 继承主图 irot）；
3. sRGB EOTF 转线性光（`apple_log::srgb_to_linear`），**在线性域**做面积覆盖重采样（`area_resize_linear_rgb`）；
4. 几何用 `fitted_even_dimensions`：长边上限 1024、两边强制偶数、**保持 coded 宽高比（不再裁成 4:3）**、不放大；
5. 除以 Styles baseline exposure（`styleData` plist key 4，默认 `styles_native::IDENTITY_BASELINE_EXPOSURE = 4.0`），套 Apple Log 曲线（常量 `A/B/C` 与 macOS 26A434 解码器逐位一致），量化后编码。

| 项 | 现状 | 与原生差距 |
|---|---|---|
| 传递函数 | Apple Log（`code = A*log2(linear/BE + B_off) + C`，边界码 0/1 钳位） | 无（常量对齐上游） |
| 几何 | 长边 1024、双偶数、coded 宽高比、同 irot | 无（对齐上游 `fitted_even_dimensions`） |
| 量化 | 构建期链接了 10-bit x265 时：**16-bit codes → Main10**；否则 8-bit 4:2:0 过渡路径 | 10-bit 通路已接入（`x265_10bit_bridge.cpp` + `build.rs` 可选链接）；未链接时 8-bit 回退仍只承载 SDR 码值 `[0, 0.6946]`，属预览级精度 |
| HDR 范围 | **转换路径已在内存应用 ISO 21496 增益图**（路径 3）：scene-linear 阶段乘 gain 后再重采样；增益图方向按写路径规则处理（EXIF 非 Normal 且主图 `irot==0` 时对平面做同一 EXIF 变换） | 原生在 base 分辨率应用 ISO 增益重建 scene-linear HDR。**已实测**：真实样张缩略图 16-bit luma max 35610→46159、mean 21401→26070（payload 140537→154916B）。剩余：① 原生 Apple tmap 文件的重编码场景仍需解 HEVC 增益图（`rust_h265` 仅支持 4:2:0，见 `docs/research/gainmap-decode-feasibility-20261025.md`）；② 真机 A/B 确认绝对亮度；③ 旋转样本的真机/E2E 验证（现有样本都是 Normal） |

验证（本机，`cargo test -p xdremux-core --lib` 覆盖）：

- `apple_log`：常量、编解码往返（码值 1.0 以上会钳位，约 linear 12 封顶）、边界钳位、sRGB EOTF 端点、baseline exposure 除法、8-bit 量化、异常输入拒绝；
- `linear_thumbnail`：几何契约（4:3/16:9/竖拍/小图不放大/奇数边取偶/极端宽高比）、线性域面积重采样均值与恒等、参数校验；
- 10-bit 通路（仅当构建期链接了 10-bit 库，`cfg(xdremux_main10)`）：`code16_to_10bit` 端点/单调、16-bit codes → BT.601 limited-range 10-bit YUV、编码后 hvcC 断言 `profile_idc=2` 且 bitDepth=10。本机实测：链接 10-bit 库 **263 passed**，未链接 **262 passed**。
- 真实样本端到端（2026-10-25，Windows + 10-bit 归档）：用 `examples/styles_convert` 转换两张真实样张，再用 `examples/lt_inspect <out.heic> [out.hevc]` 导出线性缩略图，`ffprobe` 判定 **`profile=Main 10` / `pix_fmt=yuv420p10le`**，尺寸与 hvcC ispe 一致（768×1024、772×1024，coded 方向长边 1024）；`ffmpeg -frames:v 1` 解码为 16-bit RGB PNG 成功，无崩溃/花屏。hvcC 断言 `profile_idc=2`、`bitDepthLuma/Chroma=10`、`chromaFormat=1`、`lengthSize=4`。
- 增益图应用（2026-10-25）：单测 `linear_thumbnail::tests::gain_map_plane_maps_codes_and_samples_nearest`；真实样张 E2E 前后对比见上表 HDR 行（16-bit luma max +29.6%、mean +21.8%，payload +10.2%）。
- 增益图方向对齐（2026-10-25）：单测 `gain_map_orientation_decision_matches_writer_rule`（Normal / 非 Normal+irot0 / 非 Normal+irot1 / 非 Normal+无 irot）与 `gain_plane_orientation_follows_exif_transform`（3×2→2×3 旋转、None 透传）；Normal 样本 E2E 回归数值与修复前完全一致（max 46159 / mean 26070.3 / p99.9 43989），确认无回归。旋转样本的真实 E2E 待补（现有样本 orientation 都是 Normal）。

Main10 启用方式：把 10-bit x265 静态库存到 `vendor/x265/build_<platform>_10bit`（Windows 也接受 `build_windows_10bit/Release`），`build.rs` 会自动把它复制成唯一库名 `x265-main10` 并定义 `cfg(xdremux_main10)`；库缺失时自动回退 8-bit。构建配方与坑位见 `docs/research/x265-main10-feasibility-20261025.md`。CI 已在 Ubuntu 上同时构建 8-bit 与 10-bit 归档（`.github/workflows/ci.yml`），所以 `cargo test --workspace` 会覆盖 Main10 路径。

后续（P1）：
1. ~~10-bit Main10 编码~~ **已完成（构建期可选）**；剩余：为 Linux / Android / iOS / OHOS 产出 10-bit 静态库并纳入 CI；
2. 增益图解码（HEVC tile 解码）打通后，把 base 分辨率的 gain map 应用到线性光再重采样，恢复 HDR 高光；
3. 真机 A/B：对照原生文件在 Photos 风格选择器里的观感，确认 baseline exposure 的绝对亮度与 10-bit 缩略图接受度。

## 4.1 每图 styleData：key 1 / key 3 拟合（2026-10-30）

对应代码：`styles_fit.rs`（拟合）、`linear_thumbnail.rs`（产出拟合输入 `fit_raster`）、`styles_native.rs`（写入 plist）。对应差距文档 `docs/research/styles-upstream-20261024-gap.md` P1-1 / P1-2，按上游 `bb66981b`（含 `73804f5c` GTC 读回修正）重写。

- 输入：缩略图几何、**显示方向**的一对线性光栅 —— 主图（sRGB 解码到线性，"styled"）与 scene-linear 缩略图（有增益图时乘了增益）。消费端的 `S = scene / key4 × keyH`，钳位 `[0,1]`；key 4 / h 取同一 plist 写入的值（目前仍是 4.0 / 1.8384）。
- **key 3（GTC）**：每通道共享一条 256 节点曲线，按 half 量化码值分箱求主图均值 → 空箱邻近插值 → PAV 单调投影；线格式 257 + 256 个 sRGB 编码节点（65534 刻度）+ 末节点重复，共 516B；端点不归一化。误差按消费端读回（65535 刻度 + 反 sRGB）统计。
- **key 1**：12×9 空间格 × 8 亮度平面，每格 10 项二次多项式 × RGB 加权最小二乘（remove-style：styled 主图 → 缩略图码），残差叠加在 identity 上并钳位 ±1/8（常数/一次）、±1/16（二次）；欠定格回退 identity。
- 失败或缩略图走黑帧回退时保持 identity 资源；`styles_attach` 的"只注入 metadata"分支没有像素，仍写 identity。

验证：`cargo test -p xdremux-core --lib styles_fit` 覆盖单调性、线格式、上游 fixture（二次 + 亚白端点、阶跃、局部左暗）、未改动图像得 identity、合成场景对上拟合优于 identity；`examples/styles_fit_probe <heic...>` 在真实样张上对比 identity（消费端模型，非 Photos 结论）。2026-10-30 本机 5 张样张（3 张 iPhone 原生、2 张 OPPO，均无增益图）：GTC RMSE 0.0004–0.0007 vs identity 0.16–0.36，全部单调；key 1 RMSE 比 identity 低 25–38%（受系数上限约束）。

**未验证（需真机 A/B）**：Photos 是否接受拟合值、风格滑块观感；key 1 空间格采用显示方向（照抄上游）在旋转样本上的表现；key 4 / h 仍为固定参考值，per-image `linear_metadata` 未跟进。

## 5. 诊断工具

- `styles_diag <file>`：打印 box/item/引用/属性/尾部条目全量结构
- `styles_convert`：端到端转换探针
- conformance：`tests/conformance/src/styles_native.rs`、`styles_graft.rs` 对拍测试
