# 合成输出 vs iPhone 原生：文件级差异清单（2026-09-02）

> 目标：把合成文件的格式对齐到 iPhone 原生水准。
> 样本：iPhone Air IMG_3716（琥珀色，1x）vs 我们 `/tmp/lp-final6/大师 3x_iso.heic`。

## A. 容器/条目层

| # | 差异 | iPhone | 我们 | 影响 | 可修性 |
|---|---|---|---|---|---|
| 1 | styleMetadata 条目名 | `metadata` | `styleMetadata` | 实验证明两者都被接受；不是完全一致 | 直接改名，低风险 |
| 2 | tmap 元数据格式 | **62B** 紧凑格式（15×u32，版本头 0x00400000） | **142B** ISO 21496-1（35×u32，0x00C00000） | 增益图元数据版本不同；显示正常但非同构 | 需逆向 Apple 紧凑格式语义 |
| 3 | XMP 条目组织 | 2 个无名 XMP（453/445B）关联 gain-map/delta grid | 3 个 XMP + 1 个显式 `hdrgm-xmp` 命名条目 | 结构不同但语义等价 | 中 |
| 4 | Exif 体积/厂商块 | 2968B，Apple MakerNote | 18358B，OPPO MakerNote | **结构性保留**（OPPO 水印恢复依赖）；style 入口不受影响 | 不改 |
| 5 | Exif 偏移头 | `[0,0,0,6]+Exif\0\0` | 一致 | — | ✓ |

## B. styleMetadata 内容层

| # | key | iPhone | 我们 | 说明 |
|---|---|---|---|---|
| 6 | `0` 协议号 | **16** | 15 | iPhone Air/iOS 26 原生=16 |
| 7 | `1` key1 格点 | 场景自适应微调（每 tile 不同） | identity（对角=1，其余 0） | 核心差异；通用模型嫁接已验证可行 |
| 8 | `6` 场景统计 | 场景实测（whitePoint 0.858、p98 0.739…） | golden 常量（**whitePoint=0.0、p98=1.0064 异常**） | 需图像解码算直方图分位数 |
| 9 | `7` PersonMasksValidHint | **0.0**（无人场景） | -1.0 | 上游用 -1 表示「无可信人」，但 Apple 原生写 0.0 |
| 10 | `h` | 1.8944（每图） | 1.8384（常量） | 应随图计算 |
| 11 | `i` 增益范围 | (-0.0089, 0.1132, 7.58) | (0, 0.0763, 7.35) 常量 | 应从实际 gain map 推导；且原生允许负 range min |

## C. 分级行动清单

**第一档：直接对齐（低风险，纯写值）**
- [ ] 条目改名 `styleMetadata` → `metadata`
- [ ] key0 = 16
- [ ] PersonMasksValidHint：无人时写 0.0（对齐 Apple 原生语义）

**第二档：需要计算（中等工作量）**
- [ ] key `i`：从实际 gain map 推导 OriginalRangeMin/Max/Gain（Rust 已有 gain map 解码）
- [ ] key `h`：随图计算
- [ ] key `6` 场景统计：解码主图算 p02~p98/whitePoint/highKey（十个 dict × 9 值）
- [ ] key `1`：接入通用模型预测（管线已验证，真机验收已过）

**第三档：逆向/保留**
- [ ] tmap 62B 紧凑格式逆向（Apple 版本头 0x00400000 的字段语义）
- [ ] Exif/OPPO MakerNote：保留不动（与「格式一致」冲突，但功能必需）
- [ ] XMP 条目组织重构（与 auxC 关联对齐）

## 与 Photos 行为的关系

已验证的事实：上述差异（1/2/3/4/6/8/9/10/11）**全部不影响**风格入口出现、
滑块响应、编辑保存重开。差异的意义在于「格式保真」本身——向 iPhone 原生
看齐能最大化未来 iOS 版本兼容性，并消除未知的隐式校验风险。
