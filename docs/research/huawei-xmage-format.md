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

## 5. 产出目标

- `docs/formats/huawei-xmage.md`：格式文档（结论无论是否可接入都写）
- 设备兼容矩阵加华为条目
- 若可接入：管线接入方案（大概率是 container.rs 加华为 tail 族 +
  categorize.rs 加识别规则）
