# 华为 Mate 70 HEIC → Apple 标准实施计划

> 分支：`research/huawei-xmage`。制定时间：2026-09-07。
> 规范样本：Mate 70 Pro 优享版（PLR-AL50）原始 HEIC，均通过 hdc 从设备文件路径直接拉取。
> 其他手机照片只作探索性线索，不作为实现依据。

## 1. 目标与边界

### 目标

把 Mate 70 Pro 相机产生的 Huawei HDR HEIC 接入 XDRemux 现有 Rust 主路径，输出已有的
**Apple 标准**模式：

```text
Huawei HEIC（ISO 21496-1 tmap + HDR Vivid）
  → 读取 base/gain map
  → 归一化 HDR 元数据与色彩路径
  → 复用现有 Apple tmap/gain-map writer
  → Apple Photos 可继续编辑的 HEIC
```

支持两种已确认输入路径：

- **标准模式**：4320×5760，包含 `xtstyle`（XMAGE 风格）
- **高像素模式**：约 5K–8K，明确**不支持 XMAGE 风格**，但仍包含 ISO 21496-1 + HDR Vivid

### 不做

- 暂不实现 XMAGE `xtstyle` → Apple Photographic Styles 的语义转换
- 不为高像素模式“恢复”不存在的 XMAGE 风格
- 暂不实现 Huawei JPEG 输入（之前样本元数据来源不可靠）
- 暂不生成 Huawei 专属 `it35` / `_cuva` 作为新的输出格式
- 暂不恢复华为原机水印（需要 Mate 70 原始带水印样本）
- 不新增“华为兼容”用户输出模式；输出仍只有 **OPPO 兼容 / Apple 标准**

## 2. 阶段计划

### Step 0：基线与兼容性闸门（先做，不改主路径）

**工作**

1. 固定 9 张 S0 样本清单：初始 HEIC ×3 + hdc 受控样本 ×6。
2. 为每张记录结构摘要（尺寸、焦段、item、tmap、gain map、`xtstyle`、HDR 标记、EXIF/GPS）。
3. 跑当前 `xdremux_classify` / `xdremux_inspect` / `iso_validate_probe`，记录当前行为：
   是成功、普通 HEIC、还是不支持。
4. 直接验证原始 Mate HEIC 在 Apple Photos 中是否已经能显示 HDR；这决定是否需要
   “完整重写”还是可以增加“标准兼容检查/轻量归一化”。

**验收**

- 9 张样本有可复现 manifest（照片不入 git）；
- 明确当前代码的失败边界；
- 原图在 Apple Photos 的显示、编辑、导出结果有记录。

### Step 1：只读识别与诊断

**工作**

- 新增 Huawei HEIC 识别器（建议放入 `huawei_heic.rs`，通用 box 解析复用 `isobmff.rs`）：
  - `ftyp` 是否含 `tmap`；
  - `tmap` item 与 `dimg` 引用；
  - `grid 'base'` / `grid 'gain map image'`；
  - gain map 的 `auxC` / item 关系；
  - HLG `nclx`、`clli`、`mdcv`、`it35`、`_cuva`；
  - `xtstyle` 是否存在及其字节长度/版本；
  - EXIF、GPS、Orientation、焦段和尺寸。
- 扩展 `categorize.rs` / `xdremux_classify`：华为 HDR 单独分类，不误报 OPPO LHDR/UHDR。
- 扩展 inspect JSON/FFI 报告：只读报告，不尝试转换。

**验收**

- 9 张样本全部识别为 Huawei HDR；
- 标准/高像素和 1x/0.6x/4x 的差异准确报告；
- 普通 HEIC、OPPO HEIC 不被误分类；
- 无样本时 fixture 门禁优雅跳过。

### Step 2：读取 Huawei tmap 图

**工作**

- 解析华为 `tmap` 图：primary base grid + gain-map grid + `dimg` tile 列表。
- 读取 `iloc` extent、`ipma` 属性、`ispe` 几何和 `hvcC`；处理 1024/2048 tile 两种路径。
- 解码 base 与 gain-map HEVC，确认 gain map 的通道布局、尺寸和数值域。
- 将结果转换成现有内部 gain-map 表示，不改变现有 OPPO/LHDR/UHDR 输入路径。

**验收**

- 9 张样本 base/gain map 均可解码；
- gain map 尺寸、Orientation、旋转后的几何关系正确；
- heif-oxide 与系统/ffmpeg 解码结果无结构性差异；
- 不修改源文件，不依赖 Huawei 私有 DfxData/xtstyle 才能得到 HDR。

### Step 3：归一化到 Apple 标准输出

**工作**

- 复用 `iso21496.rs` 与 `isobmff_write.rs` 的 Apple tmap writer。
- 将 Huawei HLG/HDR Vivid 输入转换成 Apple 输出所需的内部 `IsoMeta`；具体 transfer/
  luminance 映射必须由 Step 0 的 Apple Photos 实测决定，不凭名称猜测。
- 默认保留：EXIF、GPS、Orientation、拍摄时间、相机基本信息。
- 默认不把 Huawei 私有 `xtstyle`、DfxData、`it35` 原样塞进 Apple 输出；报告中说明已检测到，
  但不声称已完成 XMAGE → Apple 风格转换。
- 输出只走现有 **Apple 标准**分支；OPPO 兼容写回保持回归不变。

**验收**

- 标准模式和高像素模式都能输出可解码 HEIC；
- 输出包含 Apple tmap + base/gain map；
- EXIF/GPS/Orientation 保留；
- 无重复或悬空 item、iref、ipma、iloc；
- 旧 OPPO、UHDR JPEG、普通 HEIC 回归全过。

### Step 4：Apple Photos 真机闭环

**验证矩阵**

| 输入 | 输出 | 检查 |
|---|---|---|
| Mate 标准模式 | Apple 标准 | Apple Photos HDR 显示、继续编辑、导出 |
| Mate 高像素模式 | Apple 标准 | 同上；确认无 XMAGE 风格不影响 HDR |
| 1x / 0.6x / 4x | Apple 标准 | 尺寸、色彩、Orientation、GPS |
| 夜景/人像（后续样本） | Apple 标准 | 不误损 depth/辅助图 |

**验收门槛**

- Apple Photos 显示 HDR，无黑屏、灰屏、增益错位；
- Photos 内编辑后导出仍可读；
- iPhone/macOS ImageIO 可读；
- 与原图 EXIF/GPS 对照一致；
- 失败时报告清楚区分：不支持格式、解码失败、输出验证失败。

### Step 5：产品接入与文档

- Flutter 选图/拖入保持 HEIC 入口不变；只更新分类 chip、诊断报告和失败文案。
- 不在 UI 展示 X6/X7 或 Huawei 内部格式标签；设置页排障信息可显示输入类型。
- 更新 `docs/formats/huawei-xmage.md`、设备兼容矩阵、FFI 契约和平台验证记录。
- 增加本地 fixture 门禁：照片/模型不入 git，缺 fixture 时跳过而不是让 CI 失败。
- 完成后再决定是否从 research 分支合并到主线；不自动创建 release tag。

## 3. 技术风险与决策点

| 风险 | 处理 |
|---|---|
| Huawei HLG 与 Apple EDR/ISO gain map 的映射关系不等同 | 先做原图 Apple Photos 验证，再定 `IsoMeta` 映射 |
| Huawei `tmap` item 的 62B payload 与我们的 Apple payload 不同 | 只复用图结构读取；输出由现有 Apple writer 重新生成 |
| 高像素 base 尺寸与标准模式不同 | 以 `ispe`/tile graph 动态读取，不写死 4320×5760 |
| `xtstyle` 是 Huawei 私有量化数据 | 第一版只检测/报告，不做语义转换 |
| DfxData / HDR Vivid 私有元数据被 Apple 拒绝 | Apple 输出默认不 graft 华为私有 item，仅保留安全 EXIF/GPS |
| 原始 Huawei HEIC 已被 Apple Photos 直接接受 | 优先考虑无损保留/轻量兼容路径，避免不必要重编码 |

## 4. 当前下一步

**先执行 Step 0，不改 Rust 主路径：**

1. 在 Mate 70 上保留 9 张 S0 原图；
2. 生成样本 manifest 与现有探针基线；
3. 测试 Mate 原图进入 Apple Photos 的原生行为；
4. 根据结果决定 Step 1 的报告字段和 Step 2 是否必须完整解码。
