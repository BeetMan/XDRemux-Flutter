# ReverseKey1 Core ML 评估（2026-08-25）

> Phase 2 方案 A 的第一轮 Mac 评估。上游版本：`21Z121Z1/XDRemux @ af6e448`
> （roadmap 快照即最新，无更新提交）。本地克隆：`../XDRemux-upstream`。

## 结论摘要

第一轮单样本评估后，用新收集的 34 张 OPPO 原生 HEIC（`~/Desktop/测试/Camera`）
做了批量评估：模型被接受 **5/34（15%）**，其余 29 张由语义代理拒收、回落 identity。

**关键结论**：模型快速路径对被拒收样本的输出与我们 Rust 路径完全等价
（identity），对 15% 的样本产生优于 identity 的场景匹配 key1。即接入模型路径
严格不劣于现状，但覆盖率有限；且准入代理依赖 Neutrino 私有 API，只能在 Apple
平台运行——跨平台 Rust 推理（方案 B）若不带等效代理门，85% 场景会输出
比 identity 更差的 key1，不可直接上。

## 批量结果（34 张 OPPO 原生 HEIC）

- 接受（模型 RMSE 优于 identity ≥2%）：
  `IMG20260822150052` (3.07→2.74)、`IMG20260822150209` (4.47→4.05)、
  `IMG20260822160011` (4.43→3.34)、`IMG20260822161524` (3.78→3.56)、
  `IMG20260822161527` (3.20→2.99)
- 拒收（identity）：其余 29 张。拒收样本中模型 RMSE 平均劣化 ~25%，
  代理的拒收判定是必要的。
- 模型推理本体 6.7–15.2ms/张；准入代理总耗时 ~0.1s；全转换 3.2–11s
  （大头是 Vision 语义蒙版与 HEVC 编码，与模型无关）。
- 批跑健壮性：首轮 6/34 瞬时失败（Vision 助手超时/资源竞争），
  逐张重跑全部成功；批量接入需加重试。

## 环境障碍：macOS 27 私有 API 破坏（已在本地克隆打补丁）

上游的 constrained solver 与模型准入代理都依赖 PhotoKit/Neutrino 私有 API，
在 macOS 27（本机）上原样崩溃，两处均已修复（补丁在上游本地克隆，未回传上游）：

| 位置 | 旧 API（macOS 15–26） | macOS 27 现状 | 补丁方式 |
|---|---|---|---|
| `learnnode_coefficient_probe.m` `RunNeutrinoStyleRender` | `-[PLPhotoEditSource initWithURL:type:image:useEmbeddedPreview:]` | 该类只剩 `initWithURL:type:useEmbeddedPreview:` | `instancesRespondToSelector:` 探测后走 3 参版本 |
| 同上 `SendClassApply` | `+[_NUStyleTransferApplyProcessor applyStyle:…deltaMap:colorSpace:…]` | 新增 `displacement:` 参数（插在 deltaMap 后） | `respondsToSelector:` 探测后走 11 参版本（displacement=nil） |

**影响判断**：macOS 27 上，上游 solver 路径（不带模型）直接崩溃；
模型路径也因准入代理内部调用同一探针而 100% identity 回退。
即"上游在 macOS 27 上不带补丁是整体不可用的"，打补丁后两条路径才恢复。

## 耗时（本机 M 系列，debug-dir 全开）

| 路径 | styles 段 | 总耗时 |
|---|---|---|
| 模型快速路径（含准入代理） | 3.4s | **3.9–5.4s** |
| constrained solver | 21.1s | 22.3s |
| 模型推理本体 | 0.006s（preprocess 0.094s） | — |

快速路径确实满足模型卡宣称的 3.8–5.6s 区间，相对 solver 有 ~5x 加速。

## 准入结果（关键质量信号）

语义代理（`--semantic-apply-key1-batch`）把 identity 与模型 key1 分别施加到
styled 缩略图，与 disabled 目标比 RMSE；改善 < 2% 则拒收。34 样本完整结果见上。模型卡自述：4 个有完整 Neutrino A/B 的 OPPO 场景中 3 个被接受、1 个被拒；
我们的 34 样本实测接受率 15%，远低于模型卡的 75%，**模型卡的场景覆盖声明
偏乐观，需以自有样本集为准**。

## 与我们 Rust 路径的对比

对同一张 `original.heic` 提取 styleMetadata 的 51,840 字节 key1 lattice：

- 我们 Rust `styles_native` 输出 == identity（逐字节一致）
- 上游模型路径最终输出 == identity（模型被拒后的回退）
- 上游 solver 输出 ≠ identity（mae 0.0196，真实逐场景调整）

即：**在该样本上，我们的输出和上游模型路径的产物在 key1 层面完全等价**，
但都落后于 solver 的真实拟合。plist schema 三方一致（17 键，key "1" 为
12×9×8×10×3 Float16 lattice）。

## 下一步建议

1. **已完成**：34 张 OPPO 原生 HEIC 多样本批量评估（接受率 15%）。
2. **已完成**：Rust 侧 key1 改进尝试（见下节「key1 结构与可预测性研究」）——
   结论是安全改进空间很小，identity 应保留为跨平台默认。
3. **补丁处置**：~~macOS 27 两处补丁建议以 issue/PR 形式回传上游（本地克隆
   `XDRemux-upstream` 工作区保留，未提交）。~~ 2026-09-06：上游已自行修复，
   无需回传；本地补丁作废，下次拉上游 main 即可。
4. 方案 B（Rust 侧推理）**不建议按原设计推进**：代理门依赖 Neutrino 私有 API，
   非 Apple 平台没有等效判定，裸跑模型会让 85% 场景劣于 identity。
   可行变体：Apple 平台接入完整模型路径（严格不劣于现状），
   非 Apple 平台维持 identity。

## key1 结构与可预测性研究（Rust 算法改进尝试，2026-08-25）

目标：能否让我们 Rust 的 key1 从 identity 变为逐场景真实调整，而不依赖
Apple 私有 API。方法：用上游 solver 产出 29 张样本的 key1 作为参照真值，
分析结构、尝试用可跨平台计算的特征预测。

### 结构发现（有价值，可复用）

key1 的 25920 个 Float16 看似复杂，实际结构非常规整：

- identity 是 one-hot 锚点：每个 (空间 12×9, 亮度 8, 通道 3) 组合只在
  10 个段中的 `s=c+1` 处置 1（RGB 三通道各一个锚点），其余为 0，
  共 2592 个 1。
- solver 相对 identity 的 delta 只在小数点后两位（±0.03），且
  **按段投为常量（10 维向量）后与 solver 全量在代理 RMSE 上差距 <2%（29/29）**，
  均值上还略优于 solver（2.907 vs 2.940）。即 solver 输出的空间/亮度细节
  对最终渲染度量几乎不可感知，有效自由度 = 每照片 10 个数。
- 推論：Rust 侧的 key1 生成器只需接受一个 10 维段调整向量即可达到
  solver 级效果，无需 25920 维全量拟合。

### 可预测性结论（负面结果）

尝试用可跨平台计算的特征预测这 10 维 delta（ridge 回归，LOO 评估）：

- 特征集 A：SDR 亮度均值/方差/饱和度 + 10 段亮度直方图 → LOO mae 0.0143
- 特征集 B：A + ProXDR gain map 特征（alternateHeadroom/displayRatioHdr/gainMapMax）
  → LOO mae 0.0143
- 基线（全预测 0 = identity）：0.0151

改进仅 5%，在 29 样本下不具有统计意义；各特征与目标的单相关 |r| ≤ 0.4。
更关键的是：**连上游模型的 10 维 delta 与 solver 的 delta 相关性也只有
r=0.286，mae 反而劣于全零基线**（0.0159 vs 0.0151）。模型之所以仍有 15%
接受率，是因为渲染度量对 key1 是多对一的——代理比较的是渲染结果而非
delta 本身。

### 结论

- solver 本身在代理度量上也只在 18/29（62%）样本上优于 identity——
  这个任务里 identity 本来就是强基线，边际收益空间小。
- 任何无门禁的 key1 估计器（统计回归或裸模型）都有 40–85% 场景劣化的风险，
  **不应在跨平台 Rust 路径上发布**。identity 保持默认是正确的。
- Apple 平台的质量提升只能走原生路径（模型 + Neutrino 代理门），
  与我们「Apple 原生为研究路径」的架构边界一致。
- 副产品：若未来接入模型/solver，Rust 侧 key1 载体只需支持
  10 维段调整（identity + per-segment offset），代码改动量很小。
