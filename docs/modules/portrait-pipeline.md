# 人像模式管线（portrait pipeline）

> 对应代码：`portrait.rs`（主流程）、`portrait_depth.rs`（rear.depth 解析与 disparity 标定）、`portrait_graft.rs` / `portrait_scaffold.rs`（图移植/脚手架，结构与 styles 同族）、`portrait_consts.rs`。
> UI 入口：独立"人像实验室"页面已隐藏（`apple_portrait_page.dart`），设置开关保留。

## 1. 任务

把 OPPO 人像模式的私有深度数据（尾部 `rear.depth` / `rear.depth.config`）转换为 Apple 人像模式可用的 disparity/深度结构，使 iPhone 上能继续调整景深/光圈。

## 2. run_portrait 主流程

```
input (OPPO 原始 HEIC, 含 rear.depth)
  │ parse_depth: 解析 rear.depth（ranks 平面 + exponentiation + config）
  │   - decision.scale() 选定 disparity scale（无可用值 -> Err）
  ▼
build_disparity(ranks, exponentiation, scale)
  │   -> disparity_u8 平面 + float min/max
  ▼
REND 动态记录构造
  │   - focus: config 焦点窗口的 rank 中位数（p50 标定）归一化
  │   - headroom: LHDR/UHDR meta_floats[17]（线性比）换算为档（stops）
  ▼
portrait_scaffold / portrait_graft（结构与 styles 管线同构）
  ▼
输出（Apple 人像深度结构）
```

## 3. disparity 标定（portrait_depth.rs，R5 研究阶段）

- 物理公式：`focal * baseline / (disparity * distance)`，取焦点窗口中位 rank
- 内部 disparity 与 rank 的关系：`internal_disparity = 65535 - normalized * rank_maximum`
- scale 决策输出 JSON 诊断（含 rationale 字段），探针 `r5_portrait_probe` 可独立运行
- **现状**：标定为研究性质，精度未最终定稿（低优先级持续项）

## 4. 边界规则

- 尾部缺 `rear.depth` / `rear.depth.config` -> 跳过人像处理，不影响主转换（不报错）
- 深度平面尺寸与主图不匹配 -> 失败关闭
- `front.depth` 等前置深度条目目前不消费（仅尾部保留策略涉及，见 `formats/oppo-proxdr.md` §4）

## 5. Portrait + Styles 元数据与几何约束

- Styles 保留已有完整 Apple MakerNote（含未知标签和 UUID）；缺字段时仅合并 Styles 所需的 43/84。Apple 偏移以 MakerNote 起点为基准，不是 TIFF 起点。当前 portrait 模板已含相同的 Styles flags，整段保持不变。若不完整的 note 扩展目录需移动未知的 out-of-line UNDEFINED 数据，则明确报错，不猜测其内部偏移；已验证的自相对 tag84 plist 除外。
- CustomRendered 使用正确的 `0xA401 / SHORT / count=1`，保留 `DigitalZoomRatio (0xA404)`。值 **9** 来自 Swift 参考源码；本次未找到可核对的本地 golden EXIF，也不代表已证明 Photos 的能力开关含义。
- 水印识别新增严格限定的 `version=1 / hassel_style_1 / 14185 bytes` packed 布局，校验源尺寸、方向、全幅 crop.region、已观察到的零起点和边界；两张 192113/192141 样本内容为 `(0,0,3072,4096)`，外框 `3072×4608`。旧 aligned 对称边框格式仍支持，未知 packed 布局不做任意浮点扫描。
- 焦点与 disparity/人物/头发平面共享旋转、居中 cover crop、padding 映射；焦点只归一化一次。上述样本半幅 aux 的底部 256 行为零，不覆盖水印。
- 本修复不改变主图像素、HDR 策略、REND 强度或研究性标定。仍需在同一 Apple 设备上验证 Portrait 光圈控件、Styles 编辑保存、边缘对齐和 HDR；Windows 结构验证不能替代 Photos 验收。

回归测试：`cargo test --offline -p xdremux-core --lib`（`portrait_tests.rs`、`styles_scaffold_tests.rs`）。

## 6. 诊断

- `xdremux_diagnose_portrait` FFI 入口（Dart 侧人像页使用）
- conformance：`portrait.rs` / `portrait_depth.rs` 对拍模块
- macOS 研究路径：`PortraitDepthDiagnostics.swift`、`PortraitCalibrationResearch.swift`
