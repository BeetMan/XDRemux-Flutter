# 摄影风格：上游 v1.4 逻辑研究 + 与我们实现的对比（2026-09-02）

> 上游源码：`XDRemuxAppleFeatures/PhotographicStyles/`（8383 行 Swift）。
> 我们的实现：`xdremux/rust/src/styles_native.rs`（identity key1）。

## key1 lattice 精确布局（已解码）

51840 字节 = 25920 个 Float16 = **864 tiles × 30 值**：

- **tileCount = 12 × 9 × 8 = 864**（12×9 空间网格 × 8 亮度级）
- **blockValueCount = 10 × 3 = 30**（10 个二次多项式基项 × 3 输出通道）
- 多项式基（`basis(red,green,blue)`）：`[1, R, G, B, R², RG, RB, G², GB, B²]`
- 每个值 = 该 tile/基项/通道 的多项式系数，语义：**线性未编辑图 → 风格化渲染图** 的映射
- **Identity**：每 tile 内 index {3,7,11} = 1.0（即 R_out=R、G_out=G、B_out=B 的线性恒等），其余 0
  - SHA-256 校验值：`43e0ae73...`（上游硬编码为「已验证的 CMImaging 系数布局」）
- **条目数**：864 tiles × 3 通道 = 2592 个 1（与我们的 dump 吻合）

**修正确认**：此前我们把布局猜成「12×9×8×10×3 嵌套」是错的；实际是 **864 个 tile 的扁平序列 × 每 tile 30 值**，identity 的 one-hot 在每 tile 的固定 index {3,7,11}。

## 上游 constrained solver 完整流程

```
1. 渲染 target："disabled"（关闭风格）的 Neutrino 渲染 @1024px
2. 渲染 identity：key1=identity 的 Neutrino 渲染
3. 初始化：fitGlobalPolynomial(identity渲染 → disabled渲染)
   - 每通道 10 项二次多项式，Huber 权重（阈值 4/255）
   - 高光/阴影（≤2/≥253）权重 ×0.25
   - 采样 ≤100k 像素
4. 精化 ×2 轮：
   - 12 个直接参数（constant→R/G/B、R/G/B→R/G/B 的线性系数）
     * 二次项系数（indices 12..30）不直接自由——仅 model-seeded 路径可达
   - 数值 Jacobian：每参数 ε=1/32 的 Neutrino 重渲染
   - Gauss-Newton 更新 + 编辑器响应目标（hue/rg 约束的 hinge 行）
   - 线搜索 [1, 0.5, 0.25, 0.125]，系数界限：线性 ±1/8、二次 ±1/16
5. 准入门：编辑器响应包络（tone RMSE8 ≤ 9.6 等）
6. Fail-closed：回归时直接报错，不回退 identity
```

关键参数化：`directParameterIndices = [0,1,2,3,7,11]`，即 identity 位置上的
constant + 线性项系数。参数名：`constantToR/G/B`（截距）、`RToR/G/B`、`GToR/G/B`、
`BToR/G/B`（对角+交叉线性）。

## ReverseKey1 模型快速路径（对照）

- 输入：styled + unstyled 256×256 缩略图 → 12 通道
- 输出：34560 维（有效 25920），baseline+multiscale 融合（candidate 权重 0.625）
- 准入：语义代理（hue/rg RMSE 改善 ≥2%），10s 有界
- 我们实测（34 张 OPPO）：接受率 15%，被拒时回落 identity

## styleMetadata plist 各 key 含义（上游对照）

| key | 类型 | 含义（上游证实/推断） |
|---|---|---|
| 0 | int | styleVersion？iPhone 原生=**16**，我们=15 |
| 1 | bytes[51840] | key1 lattice（f16 LE） |
| 2 | bool | 存在标志 |
| 3 | bytes[516] | GTC（全局色调曲线，256 采样 f16 对） |
| 4 | float | baseGain（我们的 4.0 = `baselineExposure` clamp 后；iPhone=4.738） |
| 5 | int | 模式标志（identity=0 / 我们的=2） |
| 6 | dict[10] | 各图像区域的色调映射参数（ToneMapped/Linear × SkinBased 等） |
| 7 | dict[3] | PeopleRatio / PersonMasksValidHint / SkinRatio |
| c | bytes[2048] | toneLightMap（32×32 f16） |
| d | bytes[2048] | linearLightMap（32×32 f16） |
| e/f | int | 32 / 32（c/d 的分辨率声明） |
| g | int | 0x4C303068（常量标记，全部文件一致） |
| h | float | baseGain 的另一来源（iPhone=2.0985 vs 我们=1.8384，来源不同） |
| i | dict | {OriginalRangeMin, OriginalRangeMax, Gain} 增益图范围 |
| j | float | 1.0 |
| k | bool | 未知标志（全 false） |

## 与我们 Rust 实现的差异总结

| 能力 | 上游 | 我们 | 差距评级 |
|---|---|---|---|
| styleMetadata 结构 | ✓ | ✓（已验证一致） | 无 |
| identity key1 | ✓ | ✓（逐字节一致） | 无 |
| **constrained solver** | Neutrino 渲染 + Gauss-Newton | ✗ 无 | **核心差距**（依赖 Apple 私有渲染） |
| ReverseKey1 推理 | CoreML | ✗ | 可跨平台（模型数学是纯 MLP） |
| 编辑器响应准入门 | hue/rg hinge 约束 | ✗ | 依赖 Neutrino 渲染 |
| 全局多项式拟合 | 10 项 × 3 通道 Huber | ✗ | **可跨平台实现**（纯数学） |
| delta map / 线性缩略图 | ✓ | ✓（identity tile） | 结构一致 |
| 语义蒙版（sky/skin） | Vision + SegFormer | ✓（Vision 阶段等价） | 无 |
| GTC 校准 | 84 个原生 GTC 拟合 | ✗（用常量） | 依赖 Apple 渲染采样 |

## 可行方向评估

1. **跨平台 solver 不可行**：Jacobian 需要 Neutrino 逐参数重渲染，这是 Apple 私有渲染管线，无法绕过。
2. **多项式拟合可跨平台但缺渲染对**：`fitGlobalPolynomial` 本身是纯数学，但需要
   (identity 渲染, disabled 渲染) 像素对——这两张图只有 Neutrino 能渲染。
3. **有希望的组合**：ReverseKey1 模型（跨平台可推理）给出初始 key1，
   但缺少准入校验（Neutrino 门禁）→ 无法保证 Photos 端不报错。
   需要实测 Photos 对「模型 key1 + OPPO 图像」的容忍度。
4. **A 组 iPhone 风格样本**：可提供「真实拟合 key1」的参照，验证
   identity 与拟合 key1 在 Photos 编辑器中的行为差异。

## 结论

摄影风格的「入口出现」已经解决（identity key1 + 正确结构）。
「编辑加载报错」（style+pair 组合）和「真实风格拟合」都指向同一个缺口：
**缺少与 Apple Neutrino 渲染管线的等价实现**。在 Rust 侧继续逆向
Neutrino 的渲染数学不现实；可行的路径是：
- 短期：Live Photo 与摄影风格保持互斥（已实现）
- 中期：用 A 组 iPhone 风格样本确定 Photos 编辑器加载的确切校验范围
- 长期：跟踪上游 Rust 重写（他们的 execution coordinator 可能解决渲染依赖）
