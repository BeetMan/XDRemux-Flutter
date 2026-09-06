# 华为 XMAGE 照片格式研究

> 分支：`research/huawei-xmage`。启动时间：2026-09-06。
> 对应鸿蒙研究（`research/harmonyos-support.md` §0 的解读 B/C）：既然鸿蒙平台
> 移植（解读 A）已完成，本研究回答——华为相机 HDR 照片是什么表示法，
> 能否纳入现有转换管线（B），以及鸿蒙图库需要什么样的输出（C）。

## 0. 研究问题

1. **HDR 表示法**：华为 XMAGE 旗舰的 HDR 照片是——
   - a) 私有尾部（类似 OPPO ProXDR）？
   - b) Ultra HDR JPEG（Android 标准 gain map）？
   - c) HDR Vivid 静态图扩展（中国广电标准，华为是主要推动方）？
   - d) 标准 ISO 21496-1 HEIC？
   - e) 以上某种组合？
2. **容器组织**：HEIF 结构是否与 OPPO 同族（tile grid + 私有尾部 manifest）？
   华为与 OPPO 都基于高通/自研 ISP，容器习惯可能不同（华为麒麟平台无 QTI box）。
3. **鸿蒙图库行为**：鸿蒙图库识别/显示 HDR 的判定条件是什么
   （UserComment 路由标志？auxC？HDR Vivid 标记？）
4. **水印**：华为机型的可见水印数据在哪里（如果用户提供带水印样本）

## 1. 方法论（沿用 ProXDR 逆向的成熟路径）

1. **样本采集** → 2. **结构解剖**（box/tail  dump）→ 3. **双解码器验证**
   （heif-oxide vs 系统解码器，见 `formats/hevc-hevc-conventions.md` §5）→
   4. **格式文档化**（回填 `docs/formats/`）→ 5. **管线接入评估**

探针全部现成：`tail_dump` / `styles_diag` / `wm_oneplus_probe`（结构）；
`check_gps` / `heic_exif.py` / `heic_boxes.py`（EXIF/容器，/tmp 下的 Python 脚本可移植入库）。

## 2. 样本采集清单（第一批）

用 PLR-AL50（HarmonyOS 7.0.0.102）拍摄，导出务必原图（hdc 直接拉文件，
**不走图库分享**——鸿蒙图库分享 HEIC 必转 JPEG）：

| 组 | 内容 | 用途 |
|---|---|---|
| H1 | 普通拍照（默认模式，室外白天）×2 | 基线：容器结构、EXIF、有无 HDR |
| H2 | 同场景开 HDR/高动态范围模式 ×2 | HDR 表示法判定（核心组） |
| H3 | 夜景模式 ×1 | 多帧合成产物结构 |
| H4 | 人像模式 ×1 | 深度图组织（对照 OPPO rear.depth） |
| H5 | 带水印照片 ×1 | 水印数据位置 |
| H6 | 动态照片（若支持）×1 | 对照 OPPO LPEX/Android V1 |

拉取路径候选：`/storage/media/100/local/files/Docs/DCIM/` 或
`/sdcard/DCIM/Camera/`（hdc 权限允许的话）；否则相机拍完用
「文件管理器」复制到 Docs 再 `hdc file recv`。

## 3. 分析检查单（样本到货后逐张跑）

- [ ] 顶层 box 清单（ftyp 品牌、meta/mdat、有无私有顶层 box——OPPO 有 QTI，华为？）
- [ ] iinf 条目清单（有几个 item、有没有 auxl/tmap/Exif/mime）
- [ ] 尾部 manifest（有没有 OPPO 式 JSON manifest？entry 名清单）
- [ ] EXIF：Make/Model/Orientation/UserComment/私有 tag（华为 MakerNote）
- [ ] XMP 块（hdrgm？HDR Vivid？华为私有命名空间？）
- [ ] 色彩标记：colr nclx / ICC；主图位深（pixi）
- [ ] heif-oxide 可否解码；鸿蒙图库显示是否触发 HDR（真机目测）

## 4. 判定树（预期）

```
有私有尾部 manifest?
├─ 是 → 与 OPPO 同族，逐项 diff entry 名 → 大概率可直接复用 container.rs
└─ 否 → 查 XMP/辅助图
    ├─ hdrgm（Ultra HDR）→ uhdr_jpeg.rs 已有路径（JPEG 输入已通）
    ├─ 华为私有增益映射 → 新逆向对象
    └─ HDR Vivid → 查动态元数据标准（T/UWA 005）静态图用法
```

## 6. 第一批样本解剖结果（2026-09-06，Mate 70 Pro HEIC ×3 + Pura 90 Pro Max JPEG ×28）

### 6.1 核心结论：华为 HDR = ISO 21496-1 + HDR Vivid，双容器一致

**与 OPPO 完全不同**：无私有顶层 box、无文件尾部 manifest——华为直接把 HDR 做进了
**我们输出的同一个标准**（ISO 21496-1 gain map），并叠加中国 HDR Vivid（CUVA）元数据。

### 6.2 HEIC 结构（Mate 70 Pro，HarmonyOS NEXT）

```
ftyp(heic, mif1, tmap) ── tmap 品牌即 ISO 21496-1 信号
meta
├─ 主图：grid 'base'（30 块 hvc1 tile）
├─ 增益映射：grid 'gain map image'（4 块 hvc1 tile，1/4 分辨率）
├─ tmap 'Tone-mapped representation' → dimg [base grid, gainmap grid]
│   （与我们为 OPPO 转换生成的结构逐字节同型）
├─ mime 'urn:com:huawei:photo:5:1:0:meta:xtstyle'（442KB，XMAGE 色卡，见 6.4）
├─ mime 'DfxData'（473KB，内嵌 TIFF 'HUAWEI' + 相机诊断数据）
├─ it35（237B，13 条记录，HDR Vivid/CUVA 元数据）
└─ Exif（ImageDescription = '_cuva'，HUAWEI MakerNote，GPS 正常）
iprp: rICC(672B) + nclx(BT.2020 primaries=9 / HLG transfer=18 / BT.2020 matrix=9)
      + clli(maxCLL=900) + mdcv（静态 HDR 元数据齐备）
```

HDR 表示法 = **HLG 传递函数 + ISO 21496-1 增益映射 + HDR Vivid 元数据**三重冗余。
三张图都含 nclx/clli/mdcv 与 tmap/增益映射；差异在于：233642/233646 是 **4320×5760 高像素路径**，带 xtstyle、DfxData 约 473KB、it35 237B；233644 是 **3072×4096 标准/合并像素路径**，不带 xtstyle、DfxData 约 436KB、it35 160B，文件也约小一半。

### 6.3 JPEG 结构（Pura 90 Pro Max，28 张全一致）

- **ISO 21496-1 JPEG**：APP2 `urn:iso:std:iso:ts:21496:-1` + MPF 双图
- 第二图 = **半分辨率 8-bit 3 分量 JPEG 增益映射**（如 4320×6240 主图 → 2160×3120 增益图），
  自身还携带 APP8 ITUT35 / MPF / ICC
- APP8 `ITUT35` = HDR Vivid T.35 元数据；EXIF `_cuva` 标记
- **无 Google hdrgm XMP**（不是 Android Ultra HDR 体系）；**JPEG 中无 xtstyle**

### 6.4 XMAGE 色卡（xtstyle）初剖

- 固定 442368 字节；头部：`05 00 00 00`（版本 5，与 URN 中 `photo:5:1:0` 对应）
  + 三个 float32 0.5；主体为**量化系数块**（字节分布集中在 0–3 与 192/128/64/255，
  即 int8 小值与 -64/-128，典型的量化权重签名）
- 两张不同照片载荷同尺寸同头部、12% 字节不同——色卡随场景/选择变化
- 与 Apple 摄影风格 key1（34560 维 float16 格点 ≈ 69KB）概念对应，但体积约 6.4 倍，
  且以 HEIF mime item 内嵌（Apple 走 AAE sidecar + 容器内私有结构）

### 6.5 设备确认与解释

- 通过 hdc 连接到实际设备：`HUAWEI Mate 70 Pro 优享版`（型号 `PLR-AL50`）。
- 2026-09-06 相机当前界面右上角明确显示 XMAGE 色卡 **「鲜艳」**；用户确认三张样本都是同一设定。
- 因此不能把 233644 缺少 `xtstyle` 解释为“没有选择鲜艳”。用户确认：**高像素模式本身不支持 XMAGE 风格**；高像素文件没有 `xtstyle` 是预期行为，而不是漏写或损坏。
- 标准路径支持 XMAGE 风格；高像素路径仍可输出 ISO 21496-1 + HDR Vivid，但不提供 XMAGE 风格这一项。
- 受控实验已完成：同一「鲜艳」设定下，1x / 0.6x / 4x 各拍高像素与标准两组；结果见 §6.8。

### 6.6 对 XDRemux 的含义（初步）

1. **华为输入支持门槛低**：增益映射是标准 tmap/auxl 而非私有尾部——
   读路径只需识别 tmap 品牌 + HLG，不需要 container.rs 的 OPPO 尾部族逻辑
2. **输出兼容性假设（待真机验证）**：我们为 OPPO 转换生成的 ISO 21496-1 HEIC
   理论上鸿蒙图库可直接识别 HDR——需要在 Mate 70 Pro 上实测（解读 C 的关键实验）
3. **XMAGE 色卡 vs Apple 摄影风格**：两者都是「可编辑风格元数据 + 场景自适应系数」，
   存在做双向概念映射的可能（长期研究项，类比 styles 管线）

### 6.7 待办

- [x] 同一「鲜艳」设定下的标准/高像素三焦段配对已完成（6 张；见 §6.8）：高像素模式不支持 XMAGE 风格，`xtstyle` 只在标准路径出现
- [ ] 验证 233644 增益映射是否恒等（解码增益图看数值范围）
- [ ] it35 记录与 T/UWA 005 (HDR Vivid) 语法元素逐字段对应
- [ ] xtstyle 系数块的几何形状推断（110592 个 int8 = 3×192×192？还是格点表）
- [ ] DfxData 内嵌 TIFF 完整解析（可能含编辑参数）
- [ ] **Mate 70 Pro 真机实验**：我们转换的 OPPO 输出在鸿蒙图库是否显示 HDR
- [ ] H2/H4/H5/H6 组样本（Mate 70 Pro 自产：HDR 开关对比、人像、水印、动态照片）

## 6.8 六张受控样本：焦段配对实验（2026-09-07）

用户在同一台 Mate 70 Pro、同一「XMAGE 鲜艳」设定下拍摄 1x / 0.6x / 4x 三个焦段，
随后又拍同样三焦段。6 张原始 HEIC 通过 hdc 拉取，结果形成非常干净的 A/B 对照：

| 文件 | 焦段（EXIF） | 主图尺寸 | `xtstyle` | 结构路径 |
|---|---:|---:|---:|---|
| `235958` | 6.98 mm / 24 mm（1x） | 6144×8192 | 无 | 高像素 |
| `000016` | 1.95 mm / 13 mm（0.6x） | 5472×7296 | 无 | 高像素 |
| `000022` | 15.00 mm / 92 mm（4x） | 6000×8000 | 无 | 高像素 |
| `000028` | 6.98 mm / 24 mm（1x） | 4320×5760 | **有** | 标准 |
| `000031` | 1.95 mm / 13 mm（0.6x） | 4320×5760 | **有** | 标准 |
| `000034` | 15.00 mm / 96 mm（4x） | 4320×5760 | **有** | 标准 |

六张均含：`tmap` + base/gain-map grid、HDR Vivid `it35`（237B）、EXIF `_cuva`、
BT.2020/HLG `nclx`、`clli`、`mdcv`。因此本实验把变量锁定为**高像素/标准输出路径**，并结合用户确认得出：

> **XMAGE「鲜艳」不是 HDR 的必要条件；高像素模式明确不支持 XMAGE 风格。
> `xtstyle` 是标准分辨率路径的可编辑风格载荷；高像素路径仍输出 ISO 21496-1 + HDR Vivid，
> 但不提供 XMAGE 风格元数据，缺少 `xtstyle` 是预期的功能边界。**

此外，三张标准路径的 `xtstyle` 都是 442368B，但 SHA-256 前 16 位分别为
`50570b79e63b1aa6` / `bfa11d872aeb57dc` / `c9682150f18a3e1e`，说明载荷会随焦段/场景变化，
不是简单固定的「鲜艳」常量。

## 7. 产出目标

- `docs/formats/huawei-xmage.md`：格式文档（结论无论是否可接入都写）
- 设备兼容矩阵加华为条目
- 若可接入：管线接入方案（华为无尾部——大概率是新增 tmap 输入识别路径 + categorize.rs 规则，而非 container.rs 尾部族）
