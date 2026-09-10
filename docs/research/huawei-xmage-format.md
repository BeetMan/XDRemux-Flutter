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

1. **样本采集** → 2. **结构解剖**（box/tail dump）→ 3. **双解码器验证**
   （heif-oxide vs 系统解码器，见 `formats/hevc-hevc-conventions.md` §5）→
   4. **格式文档化**（回填 `docs/formats/`）→ 5. **管线接入评估**

### 样本可信度分级

- **S0（唯一规范基准）**：Mate 70 Pro 优享版（PLR-AL50）相机原图，
  通过 hdc 从设备文件路径直接拉取；保留完整 HEIF 容器、EXIF、MakerNote、HDR 元数据和私有 item。
- **S1（探索性线索）**：此前从其他手机/其他来源收到的照片。由于传输链路可能重编码或清理元数据，
  只用于提出假设，**不用于格式定论、兼容矩阵或产品实现**。

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

## 6. 第一批样本解剖结果（S0：Mate 70 Pro 原始 HEIC；S1 JPEG 仅作历史线索）

> 规范结论以下面的 Mate 70 Pro 原始 HEIC 为准。此前其他手机的 JPEG/HEIC 可能已丢失或改变元数据，
> 不参与产品接入判断；相关内容单独降级为 §6.3 的探索性记录。

### 6.1 核心结论（以 Mate 70 Pro 原始 HEIC 为准）：ISO 21496-1 + HDR Vivid

**与 OPPO 完全不同**：无私有顶层 box、无文件尾部 manifest——Mate 70 Pro 直接把 HDR 做进了
**我们输出的同一个标准**（ISO 21496-1 gain map），并叠加中国 HDR Vivid（CUVA）元数据。

结论已由 3 张初始 HEIC + 6 张通过 hdc 拉取的受控 HEIC 交叉确认。

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

Rust 只读报告现在还会摘要 EXIF Make/Model、Orientation（越界值归 Normal）、
GPS 字段存在性/字段数和焦段；为避免诊断泄露位置，不返回 GPS 经纬度。

HDR 表示法 = **HLG 传递函数 + ISO 21496-1 增益映射 + HDR Vivid 元数据**三重冗余。
三张图都含 nclx/clli/mdcv 与 tmap/增益映射；差异在于：233642/233646 是 **4320×5760 高像素路径**，带 xtstyle、DfxData 约 473KB、it35 237B；233644 是 **3072×4096 标准/合并像素路径**，不带 xtstyle、DfxData 约 436KB、it35 160B，文件也约小一半。

### 6.3 历史 JPEG 线索（S1，非权威）

此前收到的 Pura 90 Pro Max JPEG 曾观察到 APP2 `urn:iso:std:iso:ts:21496:-1`、MPF、ITUT35 和
`_cuva` 等线索，但这些文件的来源/传输链路可能已经清理或改变元数据。

因此本节只保留为后续重新采集时的**待验证假设**：

- 可能存在 ISO 21496-1 JPEG + MPF 增益图路径；
- 可能叠加 HDR Vivid T.35 元数据；
- **不据此添加 JPEG 输入支持、不据此更新兼容矩阵**；需要从 Mate 70 Pro 或原始 Pura 设备通过 hdc 直接拉取原件后再确认。

### 6.4 XMAGE 色卡（xtstyle）初剖

当前新增的 4 张标准模式样本的 `xtstyle` 都是 442368 字节，Rust 诊断器已加入**只读结构摘要**：

- 前 16 字节稳定为 little-endian：`u32 version` 为 5 或 6，后接三个 `float32 = 0.5`。
  HEIF `mime` 名称仍为 `urn:com:huawei:photo:5:1:0:meta:xtstyle`，因此 URN 版本和
  payload 版本不能混为一谈。
- 总长度恰好等于 `6 × 192 × 192 × 2`。按 little-endian `u16` 对齐可观察到
  `u16le[6][192][192]` 的固定字节形态；当前样本均有 4 个 plane 含非零字节，
  其余区域包括近似保留区和尾部字段。
- 本次用户按拍摄顺序提供的两组样本显示：前两张「鲜艳」为 payload version 5，后两张
  「明快」为 payload version 6；两组总长度和大体布局相同，但 version 6 在头部之后更早
  出现非零表数据，说明不是单纯改一个风格名称。
- 同一设定的两张样本差异约 11.3%（鲜艳）/11.4%（明快）；跨设定首张样本差异约
  14.5%。由于手持拍摄存在构图、曝光和场景变化，这些数字只能证明载荷会变化，不能单独
  作为色彩语义或系数通道的结论。
- 这一步只报告版本、头部、字节布局、非零字节数和非零 plane 数，**不把 u16 槽位命名为
  色彩系数，也不声称已经知道其通道语义**。因此不会生成伪造的 Apple 摄影风格。
- `xtstyle` 是 HEIF `mime` item 内嵌私有数据；与 Apple 摄影风格 key1 的尺寸和布局不能
  直接类比，当前没有双向转换结论。

### 6.5 设备确认与解释

Step 2 结构诊断已落地到 `xdremux_huawei_inspect`：报告 `xtstyleVersion`、
`xtstyleHeaderFloat32`、`xtstyleObservedLayout`、非零字节/plane 数，以及 EXIF/GPS
只读摘要；这些字段只用于诊断和研究，不触发重编码。

- 通过 hdc 连接到实际设备：`HUAWEI Mate 70 Pro 优享版`（型号 `PLR-AL50`）。
- 2026-09-06 基线样本为 XMAGE **「鲜艳」**；本次新增一组 **「明快」**，两组均为标准
  4320×5760、1x、同一室内场景附近连续拍摄。
- 高像素模式本身不支持 XMAGE 风格；高像素文件没有 `xtstyle` 是预期行为，而不是漏写或损坏。
- 标准路径支持 XMAGE 风格；高像素路径仍可输出 ISO 21496-1 + HDR Vivid，但不提供 XMAGE 风格这一项。
- 受控焦段实验见 §6.8；本次不同设定差分见 §6.9。

### 6.6 对 XDRemux 的含义（初步）

1. **华为输入支持门槛低**：增益映射是标准 tmap/auxl 而非私有尾部——
   读路径只需识别 tmap 品牌 + HLG，不需要 container.rs 的 OPPO 尾部族逻辑
2. **输出兼容性假设（待真机验证）**：我们为 OPPO 转换生成的 ISO 21496-1 HEIC
   理论上鸿蒙图库可直接识别 HDR——需要在 Mate 70 Pro 上实测（解读 C 的关键实验）
3. **XMAGE 色卡 vs Apple 摄影风格**：两者都是「可编辑风格元数据 + 场景自适应系数」，
   存在做双向概念映射的可能（长期研究项，类比 styles 管线）

### 6.7 待办

- [x] 同一「鲜艳」设定下的标准/高像素三焦段配对已完成（6 张；见 §6.8）：高像素模式不支持 XMAGE 风格，`xtstyle` 只在标准路径出现
- [x] 已采集「鲜艳」/「明快」两种标准模式样本并确认 payload version 5/6 差异（见 §6.9）
- [x] 在 Apple Photos 中比较两组原图的编辑面板、导出和回读结果；编辑副本仍能显示 HDR
- [ ] 验证 233644 增益映射是否恒等（解码增益图看数值范围）
- [ ] it35 记录与 T/UWA 005 (HDR Vivid) 语法元素逐字段对应
- [x] xtstyle 固定字节形状初步确认：442368B = `u16le[6][192][192]`（只作布局观察）
- [ ] xtstyle plane/尾部字段的语义和系数布局仍待不同 XMAGE 设定样本验证
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

### 6.9 两种 XMAGE 设定样本：鲜艳 vs 明快（2026-09-07）

用户在同一台 PLR-AL50 上先以「鲜艳」拍摄两张，再切换「明快」拍摄两张；四张均为标准
4320×5760、1x、原始 HEIC，并通过文件管理器复制到 Docs 后由 hdc 拉取：

| 文件 | 设定（按拍摄顺序） | payload version | `xtstyle` 字节数 | 非零字节数 | SHA-256 前 16 位 |
|---|---|---:|---:|---:|---|
| `014239` | 鲜艳 | 5 | 442368 | 156830 | `4d98a3ec74f34f99` |
| `014240` | 鲜艳 | 5 | 442368 | 157084 | `3277bdc890e093eb` |
| `014245` | 明快 | 6 | 442368 | 161888 | `64fb896bb0374805` |
| `014246` | 明快 | 6 | 442368 | 163801 | `c10fc74d6da2c739` |

四张均为 Huawei HDR、`tmap` + base/gain-map graph、GPS/Orientation/焦段可读；因此此次实验
确认了：**XMAGE 设定切换会改变 `xtstyle` payload version 和载荷内容，而不会改变普通 Huawei
HDR 的直通判定。** 这仍不是 version 5/6 字段语义的完整逆向，也不足以推出 Apple 摄影风格映射。

### 6.10 Apple Photos 编辑/导出回读（2026-09-07）

用户将四张原始样本导入 Apple 照片，分别做了轻微调整，并导出 ZIP。`原片/` 与
`编辑/IMG_xxxx/IMG_xxxx.HEIC` 的 SHA-256 完全相同，说明原文件没有被覆盖；
`IMG_Exxxx.heic` 是 Apple Photos 重新渲染的副本，旁边还有 Apple `AAE` 调整 sidecar
（`com.apple.mobileslideshow` / `com.apple.photo`，format version 1.5）。

对四个编辑副本的结构回读结果一致：

- 不再含 Huawei `xtstyle`、`DfxData` 或 HDR Vivid `it35`；原始 payload version 5/6 均未被带入；
- Apple 重新建立了自己的 `tmap` + `dimg` gain-map graph，主图仍为 4320×5760，增益图为
  2160×2880，并保留 `nclx`/`clli` 和 EXIF Make/Model/GPS/焦段；
- 当前 Huawei 专用识别器将编辑副本报告为 `iso-tmap-heif`，而不是
  `huawei-hdr`；诊断器通过 tmap 的 primary/gain graph 识别了 Apple 重建的标准图，
  同时确认 `hasHuaweiPrivateMarker=false`。这是预期的安全结果：编辑副本已经是 Apple
  Photos 的新渲染结果，不能再按原始 Huawei 私有风格数据处理；
- 因此结论是：Apple Photos 可以把 Huawei 原图的视觉效果渲染进编辑副本，但**不会保留
  可继续编辑的 Huawei `xtstyle` 私有载荷**。原始 HEIC 必须始终保留。

用户将四个 `IMG_Exxxx.heic` 编辑副本重新导入 Apple 照片后确认仍能显示 HDR。
因此这完成了“编辑→导出→结构回读→再次导入 HDR 显示”验证：Apple Photos 保留了 HDR
视觉结果，但没有保留可继续编辑的 Huawei `xtstyle` 语义；也没有把编辑副本当作 Huawei
原图重新转换。

### 6.11 设备 Docs 目录中的负样本探针

为避免把 `tmap` 品牌本身误当作 Huawei，另外从设备 Docs 目录直接拉取了两个已有文件：

| 文件 | EXIF Make/Model | Huawei HDR 结果 |
|---|---|---|
| `IMG_3716.HEIC` | Apple / iPhone Air | `not-huawei`；无 Huawei marker、无完整 tmap graph |
| `IMG20260807131731.heic` | OPPO / OPPO Find X8 Ultra | `not-huawei`；无 Huawei marker、无完整 tmap graph |

这只是两张探索性负样本，不能替代完整误分类矩阵；规范 Huawei 样本仍以 PLR-AL50 原始 HEIC 为准。

## 7. 产出目标

- `docs/formats/huawei-xmage.md`：格式文档（结论无论是否可接入都写）
- 设备兼容矩阵加华为条目
- 若可接入：管线接入方案（华为无尾部——大概率是新增 tmap 输入识别路径 + categorize.rs 规则，而非 container.rs 尾部族）
