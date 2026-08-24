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

## 3. 已知问题（待修）

- 天空蒙版 auxl 引用重复出现两次
- 部分 auxl 引用目标为 `[主图, tmap]` 而非仅主图

验证现状：直出文件 ColorOS 相册、Windows WIC、heif-oxide 均可打开；Apple 照片内编辑兼容性待 iPhone 真机验证。

## 4. 诊断工具

- `styles_diag <file>`：打印 box/item/引用/属性/尾部条目全量结构
- `styles_convert`：端到端转换探针
- conformance：`tests/conformance/src/styles_native.rs`、`styles_graft.rs` 对拍测试
