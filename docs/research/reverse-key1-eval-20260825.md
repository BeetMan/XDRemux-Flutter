# ReverseKey1 Core ML 评估（2026-08-25）

> Phase 2 方案 A 的第一轮 Mac 评估。上游版本：`21Z121Z1/XDRemux @ af6e448`
> （roadmap 快照即最新，无更新提交）。本地克隆：`../XDRemux-upstream`。

## 结论摘要

模型快速路径在本机**端到端可跑通**，但三个测试样本全部被语义代理拒收，
落回 identity。距离"质量显著优于现状"的验收门槛，目前证据不足：
瓶颈是样本集（上游训练用的 5 张 OPPO 原生 HEIC 不随 git 分发）。

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
styled 缩略图，与 disabled 目标比 RMSE；改善 < 2% 则拒收：

| 样本 | identity RMSE8 | 模型 RMSE8 | 判定 |
|---|---|---|---|
| 我方 `original.heic`（OPPO 夜景，真训练域） | 1.993 | 3.932 | **拒收 → identity** |
| 上游 fixture `20260312_135609`（Samsung，域外） | 3.066 | 3.814 | 拒收（预期） |
| 上游 fixture `20260312_135610`（Samsung，域外） | 3.034 | 3.797 | 拒收（预期） |

模型卡自述：4 个有完整 Neutrino A/B 的 OPPO 场景中 3 个被接受、1 个被拒。
我方这张 OPPO 样本恰好落在"拒收"侧。单样本不能证伪模型，但也说明
"拿到模型就赢"不成立——场景覆盖是真实门槛。

## 与我们 Rust 路径的对比

对同一张 `original.heic` 提取 styleMetadata 的 51,840 字节 key1 lattice：

- 我们 Rust `styles_native` 输出 == identity（逐字节一致）
- 上游模型路径最终输出 == identity（模型被拒后的回退）
- 上游 solver 输出 ≠ identity（mae 0.0196，真实逐场景调整）

即：**在该样本上，我们的输出和上游模型路径的产物在 key1 层面完全等价**，
但都落后于 solver 的真实拟合。plist schema 三方一致（17 键，key "1" 为
12×9×8×10×3 Float16 lattice）。

## 下一步建议

1. **补样本**：从用户 OPPO 设备收集 ≥5 张不同场景（白天/夜景/人像/天空）的
   原生 HEIC，重跑模型路径，看接受率是否复现模型卡的 3/4。
2. **solver 结果接回我们侧**：上游 solver（22s 级）在本机已可用，其
   `constrained-solver` 产物可作为我们 Rust key1 质量的对照锚点。
3. **补丁处置**：macOS 27 两处补丁建议以 issue/PR 形式回传上游（本地克隆
   `XDRemux-upstream` 工作区保留，未提交）。
4. 方案 B（Rust 侧推理）暂缓：先确认方案 A 的接受率证据。
