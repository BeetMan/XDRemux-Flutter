# OPPO Find N3 / Find X8 Ultra ProXDR 采样分析

采样日期：2026-09-17（Find N3，9 张）、2026-09-10（Find X8 Ultra，2 张）
样张位置：`~/Downloads/IMG2026*.heic|jpg`（**不进 git**，与其它 fixture 一致）

## 核心结论

**OPPO 的 ProXDR 有两代不同的容器实现**，我们的管线两条都支持（9/9 转换成功）：

| 机型 | ProXDR 容器 | 提取路径 | 元数据 | 家族 | 增益图载体 |
|---|---|---|---|---|---|
| Find X8 Ultra（新旗舰）| HEIC | **manifest** | 20 floats | **x7** | `gainmap` 字段（284-314KB）|
| Find N3（老折叠屏）| HEIC | **float144** | 36 floats，`meta[0]=2.063` | **x6** | `mask` 字段（377-898KB JPEG）|
| Find N3（另一种）| **JPEG** | hdrgm XMP | 20 floats | x7 | MPF gain map（138-930KB）|

### 关键发现

1. **HEIC ProXDR 里没有字面量 `lhdr` 字符串** —— 它靠 float144 sentinel 扫描或 manifest
   识别。这解释了早期「扫遍 Desktop 找不到 ProXDR 文件」是**扫描方法的问题**，不是文件
   不存在。

2. **`mask` 就是增益图本体**。Find N3 的 LHDR 把增益图存在 `mask_data` 里（一个灰度 JPEG），
   转换时 `decode_jpeg_to_gray(mask_data)` 后写进输出的半分辨率增益 grid
   （3456×4608 主图 → 1728×2304 增益图，精确一半）。

3. **`family`（x6/x7）只是信息性标签**，只在 `xdremux_classify` 里返回给 UI，
   不影响转换逻辑。判断规则：`meta_floats[0] >= 3.0 || mode == "uhdr"` → x7。

4. **Find N3 的 ProXDR 会写成两种格式**：HEIC（LHDR）和 JPEG（Ultra HDR JPEG）。
   取决于拍摄设置。JPEG 那条走 Google Ultra HDR 规范（`hdrgm` XMP + MPF），
   不是 OPPO 私有格式。

## 9 张 Find N3 样张明细

| 文件 | 分辨率 | 大小 | 类型 | 转换路径 | 输出增益图 |
|---|---|---|---|---|---|
| `IMG20260917221713.heic` | 3456×4608 | 4.4MB | **ProXDR** | LHDR(float144) | 1728×2304 ✓ |
| `IMG20260917222537.heic` | 3008×4000 | 1.5MB | **ProXDR** | LHDR(float144) | 1504×2000 ✓ |
| `IMG20260917222540.heic` | 3456×4608 | 5.5MB | **ProXDR** | LHDR(float144) | 1728×2304 ✓ |
| `IMG20260917221623.jpg` | 3456×4608 | 8.6MB | **Ultra HDR JPEG** | UHDR | 1728×2304 ✓ |
| `IMG20260917222522.jpg` | 3456×4608 | 12.5MB | **Ultra HDR JPEG** | UHDR | 1728×2304 ✓ |
| `IMG20260917222428.heic` | 3008×4000 | 1.2MB | SDR | SDR 兜底 | ✓ |
| `IMG20260917222435.heic` | 3456×4608 | 2.4MB | SDR | SDR 兜底 | ✓ |
| `IMG20260917222502.heic` | 3008×4000 | 1.0MB | SDR | SDR 兜底 | ✓ |
| `IMG20260917222545.heic` | 3008×4000 | 1.3MB | SDR | SDR 兜底 | ✓ |

EXIF：`Make=OPPO Model=OPPO Find N3 Lens=OPPO Find N3 back camera`
（镜头分布含 70mm f/2.6 —— 长焦）。

## 验证状态

### 已验证（本地）
- 9/9 样张转换成功，含摄影风格的路径也走通
- 5 张 HDR 样张的输出都带**真实半分辨率增益图**（不是恒等增益图）
- x6（Find N3）与 x7（Find X8 Ultra）两条分支都跑通了转换
- Exif 保留（机型/镜头/时间）

### 未验证（需要真机）
- **Find N3 相册里 ProXDR 效果是否保留** —— 这是 HDR 转换的核心验收点
- 跨品牌互操作（把转换产物在 iPhone 上看）
- 摄影风格在 SDR 那 4 张上实机可用性

## 后续

1. **真机验证**：连 adb 后把 APK 装到 Find N3，转换样张后在自带相册看 HDR 效果
2. **纳入一致性语料**：这批样张小而快（1-12MB），适合进 CI 做每日回归，
   保护「OPPO ProXDR 转换」这条一直无法本地回归的路径
3. **x6 分支补测试**：目前 x6 分支靠真实样张验证，可以把 `meta[0]=2.063` 的
   元数据特征做成单测夹具
