# 会话交接更新：2026-09-02 深夜（摄影风格研究全线收官）

> 接前文。本段覆盖当晚全部工作：语义层机制破解、sky matte A/B 定论、
> AAE 编辑格式破译。研究侧至此全部闭环。

## 当前状态

- HEAD `09441b6`（本轮全部已推送）
- 测试：Rust 134 + conformance 12 全绿
- 用户样本（不入 git）：`~/Documents/XDRemux Playground/samples/portraits-20260902/`（6 张人像 + 1 张编辑版）
- A/B 实验产物：`/tmp/XDRemux-skyA-zero.heic`、`/tmp/XDRemux-skyB-real.heic`（若 /tmp 清空可从 IMG20260822161608 重跑）

## 本轮完成（按时间序）

1. **V3 stats graft**（e1b1b95）：key6 实算统计 + key7 原生语义嫁接，真机通过
   - bplist 动态 objectRefSize（对象 >255 时 1→2 字节，否则引用错位）
   - v2 bin 布局：[key1 51840][unc f32][gtc 516][lightmaps 4096][scalars 12][stats 72][key7 12]
2. **人像样本组破解**（357494b）：hint 三态（0 无人 / -1.0 拍摄时蒙版 / +1.0 编辑时重算）、
   key0=16 拍摄/15 编辑、j=1.0 拍摄/1.3 编辑、人像模式拍摄永不写 styleMetadata（5/5）
3. **辅助层图谱全解**（6c85b37）：styledeltamap（½ 像素 10-bit grid，512=中性增益图）、
   linearthumbnail（固定 1024×768 10-bit 4:2:0 彩色）、semanticskymatte（长边≤2016 8-bit 单色）
   —— 全部 auxl→[主图, tmap]
4. **sky matte 去重修复**（54e9f98）：scaffold+styles 两阶段重复写蒙版；
   两遍 meta 组装的 iloc 条目集必须完全一致（否则偏移漂移 16B 全毁）
   注意：tests/conformance/src/styles_native.rs 是管线的镜像副本，修 bug 要两边同步
5. **A/B 真机实验 + 定论**（91aab90, 1d98ae6）：Photos 风格编辑**不消费 sky matte**
   （唯一变量蒙版 → 编辑渲染逐字节相同）；Photos 从不回写原 HEIC（MD5 实证）
6. **AAE 编辑格式破译**（09441b6）：SemanticStyle {tone, cast, color, intensity}，
   base64+zlib+JSON，编辑状态 100% 存侧车；2120 的 styleMetadata 非编辑回写（证伪）

## 悬案与新方向

1. **2120 谜团**：其 styleMetadata（key0=15/j=1.3/hint=+1.0）来源不明——不是编辑回写
   （已证伪）。可能拍摄时写入？j=1.3 语义待重估。样本：samples/portraits-20260902/IMG_2120.HEIC
2. **cast→key1 映射**：AAE 参数（cast/tone/color）是编辑侧 solver 输入格式；
   捕获同一编辑前后 key1 可反推确定性映射（研究价值高）
3. **linear thumbnail 真生成**：唯一实质占位（路径明确：解码→线性化→1024×768→10-bit HEVC）
4. **Live Photo + 预测风格组合真机测试**：仍悬置（之前失败是 identity+pair）
5. **v0.4.0 正式版发布**：用户搁置中，研究已收官可以考虑
6. **上游同步 P2**：14 fixtures、容器加固

## 关键工具/路径备忘

- 预测：`/tmp/univ_style_predict.py`（CoreML）+ `/tmp/stats_compute.py`（v2 stats 追加）
- A/B 流程：conformance `convert` → `sky-matte`（SegFormer, ~/.xdremux/models/）→
  `XSTYLES_SKY_RAW=<raw> conformance styles` → `styles_universal_graft` 嫁接
- ISO BMFF 解析：`/tmp/mp_extract.py`；HEVC tile 解码：hvcC 参数集 + annexB + ffmpeg
- 上游模型：`../XDRemux-upstream/Models/UniversalPhotographicStyleStateNet.mlpackage`

---

# 会话交接：2026-09-02 工作收尾（前段）

> 本文档为压缩上下文后恢复工作的入口。涵盖：v0.4 功能线状态、Live Photo +
> 摄影风格组合研究结论、Apple 样本数据、后续规划。

## 一、当前仓库状态

- 分支：`main`，HEAD `3f22692`
- 版本：pubspec `0.4.0+21`（v0.4.0-pre.1 已发布，CI 有全部六平台资产）
- 上游参考：`21Z121Z1/XDRemux @ 8930811`（本地克隆 `../XDRemux-upstream`）
- 上游可执行产物：`.build/release/xdremux`（macOS）、`xdremux_py`（Python，已装
  pillow/piexif/numpy/pillow-heif）

## 二、今日完成的三大块

### 1. Motion Photo → Apple Live Photo（Phase 3b 核心）

- `motion_photo.rs`：四格式解析（Android V1/MicroVideo/HEIF mpvd/OPPO LPEX 双码流）
- `uhdr_jpeg.rs`：Ultra HDR JPEG 输入（MPF + hdrgm）
- `live_photo.rs`：Live Photo 配对合成
  - MOV 侧：ftyp 改 qt、moov 重写（content identifier + still-image-time 元数据轨）
  - 静帧侧：MakerNote 追加 tag 0x0011（content identifier）
  - 已通过上游 Python 验证器（`validate_live_photo_movie`）
- UI：卡片四档策略（跳过/仅静帧/静帧+视频/Live Photo），默认跳过

### 2. Live Photo 与摄影风格组合 —— 研究结论（重要）

**关键发现矩阵**（用户实机验证）：

| 组合 | Live 配对 | 风格入口 | 编辑加载 |
|---|---|---|---|
| 静帧 style 状态，无 0x0011 | ✗ | ✓ | ✓ |
| style + 追加 0x0011 | ✓ | ✓ | **✗ 报错「无法加载编辑内容」** |
| 无 style + 追加 0x0011 | ✓ | — | ✓ |

**结论**：Photos 对「声明了 style 状态的 Live Photo」走联合编辑加载路径，
我们静态结构已全部对齐仍失败。**已确认与 key1 内容无关**（identity 和真实
key1 都触发入口；「中性」风格 key1 也不是 identity，ΔRMS 0.02~0.28 都被接受）。

**产品决策**（已实现）：Live Photo 档强制关闭 styles（`_convertOne` 里
`runConfig.applePhotographicStyles = false`），两功能保持互斥。相关代码保留
（`append_live_photo_entry`、`replace_item_payload`、风格实验 FFI）。

### 3. Apple key1 结构研究（iPhone Air 样本）

**key1 lattice 精确布局**：
```
51840 字节 = 864 tiles(12×9×8) × 30 f16(10 项二次多项式 × 3 通道)
基函数：[1, R, G, B, R², RG, RB, G², GB, B²]
Identity：每 tile index {3,7,11} = 1.0
```

**iPhone Air 实测数据**：
- 12 张室外原生：ΔRMS 0.02~0.04（Apple 默认处理非 identity）
- 7 张室内风格：琥珀/金/玫瑰金/珠光/中性/冷调玫瑰/耀目，ΔRMS 0.05~0.28
- 风格差异在 const/线性系数偏移方向；珠光色 key0=131088（特殊）

**上游 constrained solver 逻辑**（已完整研究）：
Neutrino 渲染 → 全局多项式拟合（Huber）→ Gauss-Newton 精化（12 参数，
ε=1/32 Jacobian）→ 编辑器响应准入门。依赖 Apple 私有渲染，跨平台不可行。

## 三、代码位置速查

| 模块 | 路径 | 说明 |
|---|---|---|
| Live Photo 合成 | `xdremux/rust/src/live_photo.rs` | MOV 写入 + MakerNote 追加 + pair 校验 |
| 配对校验 FFI | `xdremux_live_photo_pair_valid` | 整理页资产分组用 |
| 风格实验 FFI | `xdremux_style_experiment` | 保留，后续研究用 |
| 整理页 | `apps/flutter/lib/organize_page.dart` | 已加资产感知分组（静态/实况照片） |
| 工作流页 | `apps/flutter/lib/apple_oppo_workflow_page.dart` | OPPO→Apple 回传 |
| 上游对比文档 | `docs/research/styles-upstream-logic-comparison.md` | key1 布局+solver 研究 |
| 待同步清单 | `docs/plans/upstream-sync-remaining.md` | v1.4 剩余未同步项 |
| 采样计划 | `docs/plans/sample-collection-202608.md` | A~E 组 |
| 路线图 | `docs/plans/v0.4-roadmap.md` | Phase 1-4 |

## 四、后续规划（优先级排序）

### P0：稳定发布 v0.4.0（去掉 -pre.1）
- 收尾 Live Photo 档（纯配对无风格）回归验证
- 发布正式 v0.4.0（版本 bump + 重打标签）

### P1：整理页资产感知 + provenance（已部分完成）
- [x] 整理页资产分组（静态/实况照片目录 + 配对校验）
- [ ] 批量恢复时 MOV 侧 provenance 校验
- [ ] 转换输出 MOV 已存在时按序号避让
- [ ] 跳过报告区分「格式不支持」/「已是转换产物」

### P2：摄影风格 —— 已定案关闭（2026-09-02）
- 用户拍板：转换目标只是 Apple 可编辑格式，identity 状态满足需求
- 非身份 key1 被 Photos 接受已证真（通用模型嫁接真机验收全通过）
- 集成任务取消；研究成果归档于 docs/research/styles-upstream-logic-comparison.md
- 嫁接 API（replace_style_metadata/StyleStateOverride）保留备用

### P3：Motion Photo 批量/恢复
- 批量 checkpoint 恢复
- 14 个上游 fixtures 移植测试

## 五、关键决策记录

1. Live Photo 与摄影风格互斥（功能可用性优先）
2. OPPO 回写保留 donor 完整 canvas + graph（非 mask）
3. Apple 标准输出用 Rust 新建 Styles graph（不保旧编辑状态）
4. 不把用户照片加入 git；样本放 `~/Desktop/测试/` 或 `~/Desktop/室外照片/`
5. 实验代码保留不删（`live_photo.rs` append 路径、实验 FFI）

## 六、环境备忘

- 上游验证器：`python3 -c "import sys; sys.path.insert(0,'/Users/beet/Documents/XDRemux Playground/XDRemux-upstream')"`
- 上游 CLI：`/Users/beet/Documents/XDRemux Playground/XDRemux-upstream/.build/release/xdremux`
- 我们探针：`cargo run -q --release -p xdremux-core --example styles_diag -- <file>`
- macOS 27 私有 API 补丁：上游已合并（#32），本地工作区有对应改动
- 测试：`cargo test -p xdremux-core`（134 passed）、`flutter test`（20 passed）
