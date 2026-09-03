# cast→key1 映射研究：定论（2026-09-03）

> 实验目标：反推 Photos 风格语义参数（cast/tone/color/intensity）→ key1
> delta grid 的映射。样本：IMG_1591 转换件（identity 状态）× 7 种 cast，
> 真机 Photos 编辑 + 「所有照片数据」回传（IMG_3754~3766）。

## 实验

- 基线：我们转换+identity 嫁接的 HEIC（`/tmp/combo_style.heic`，key0=16/j=1.0）
- 7 份逐字节相同的副本，分别套 TanWarm / GoldWarm / BlushWarm /
  BrightPop / Neutral / Cool / DreamyHues（tone/color/intensity 各张略有
  浮动，反而多覆盖参数空间）
- 每组三件套：原片（编辑回写）+ .AAE 侧车 + IMG_E* 烘焙件

## 结果（决定性）

**7 个 cast 的编辑回写 styleMetadata 与 identity 基线逐字节相同**
（key0/key1/j/key7/所有字段，ΔRMS = 0.0000，864 tile 全零差）。

- 语义参数 100% 存 AAE 侧车，渲染时由 Photos 私有 solver 即时计算，
  **从不落盘为 key1**
- 烘焙件 IMG_E* 无 styleMetadata（67 items，风格辅助层全剥）——与此前
  「AirDrop 照片模式剥 styleMetadata」一致
- 2120 谜团随之闭合：其 styleMetadata 是编辑管线写回的「当前状态」，
  key0=15/j=1.3 是管线标记，**key1 本身从未被 cast 修改**

### AAE 格式勘误

`adjustmentData` 非「base64+zlib」，而是 **raw deflate（windowBits=-15）
的 JSON**；SemanticStyle 字段确认为 `{version, tone, enabled, cast,
intensity, color}`，cast 取值为枚举字符串
（TanWarm/GoldWarm/BlushWarm/BrightPop/Neutral/Cool/DreamyHues）。

## 补验（2026-09-03 深夜，回应单案例质疑）

第二轮 ×2 样本，BrightPop + 大幅参数偏移（tone −0.26/color +0.53 与
tone −0.20/color −0.74）：

- A：OPPO 天空照转换件（identity 状态，不同图像源）—— key1 ΔRMS=0
- B：IMG_3716 **Apple 原生风格拍摄件**（真实非 identity key1）—— key1
  ΔRMS=0，styleMetadata 全字段一致
- 像素对照：B 的烘焙件 vs 原片均值差 +10.8（ΔB 通道 −14，暖化可见），
  渲染层确实在变

覆盖矩阵：跨图像源 × 跨状态来源（嫁接 identity / Apple 原生态）× 大
参数偏移，全部零变化。「cast 不落盘为 key1」为定论。

附：解析坑两枚——原生件 styleMetadata item 名为 `metadata`（我们写的
叫 `styleMetadata`），mp_extract 的 ctype 'uri ' 带尾空格需 strip。

## 结论

1. **文件层不存在 cast→key1 映射可反推**——语义→数学的变换只存在于
   Photos 运行时 solver，key1 是拍摄/嫁接时定的「基础状态」，不随后续
   语义编辑变化
2. 唯一提取路径 = **渲染反推**（identity 渲染 vs IMG_E* 烘焙渲染，逐
   tile 拟合等效多项式）。这是上游 constrained solver 的路线：样本获取
   依赖真机逐张渲染，跨图像泛化性存疑，产品化价值低——**研究关闭**
3. 产品含义：转换侧写 identity 状态是唯一正确姿势；语义编辑本来就是
   Photos 在渲染层做的事，文件层无从也不应预置

## 样本归档

`test-media/sources/cast-study/`（7 组原片+AAE+烘焙件，未入 git）；
解析脚本 `/tmp/aae_parse.py`（AAE raw-deflate JSON 解析）。
