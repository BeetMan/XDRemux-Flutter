# XDRemuxApp 迁移计划

> 2026-05-23 状态: 本文件是 2026-05-14 的迁移草案，部分差异清单已被当前 `Sources/XDRemuxCore.swift` 和队列化 App 实现覆盖。当前发布化目标与验收计划以 `docs/plans/active/xdremuxapp-release-goal-20260523.md` 为准。

基于 `swift/XDRemux.swift` (CLI) 为真实来源，将 `XDRemuxApp` 补齐到功能与稳健性对等。

---

## 0. 双端关系总览

```
CLI (XDRemux.swift)                     App (XDRemuxApp)
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│  LHDRExtractor                  │   │  LHDRExtractor                  │
│  ├─ locateManifest()            │   │  ├─ locateManifest()            │
│  ├─ calibrateDataBase()         │   │  ├─ calibrateDataBase()         │
│  ├─ materializeBlocks()         │   │  ├─ extractBlock() [按需]        │
│  ├─ extractMeta(from:blocks:)   │   │  ├─ extractMeta(from:dataBase:) │
│  └─ extractMask()               │   │  └─ extractMask()               │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  MaskDecoder                    │   │  MaskDecoder                    │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  EDRScaleResolver               │   │  EDRScaleResolver               │
│  ├─ resolve(metaFloats:mode:)   │   │  ├─ resolve(metaFloats:mode:)   │
│  │  └─ UHDR index: [0,4,7,..]  │   │  │  └─ UHDR index: [0,3,6,..]  │
│  │                              │   │  │  ← BUG: 索引偏移错误         │
│  └─ edrScaleCalculator()        │   │  └─ edrScaleCalculator()        │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  GainMapReconstructor           │   │  GainMapReconstructor           │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  ISOHDRWriter                   │   │  ISOHDRWriter                   │
│  ├─ write(gainMapEncodeMode:)   │   │  ├─ write() [无 encode mode]    │
│  ├─ writeWithPreserveReencode() │   │  │                              │
│  └─ writeHEIC()                 │   │  └─ writeHEIC()                  │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  ProductGainMapWriter           │   │  [不存在]                        │
│  ├─ buildUHDRPrivate...()      │   │                                  │
│  └─ writeUHDRPrivate...()      │   │                                  │
├─────────────────────────────────┤   ├─────────────────────────────────┤
│  CLI Argument Parsing           │   │  SwiftUI + ViewModel             │
│  ├─ convert / batch 子命令       │   │  ├─ drag-drop + file picker    │
│  ├─ --family, --gainmap-encode  │   │  ├─ 硬编码 .auto，无配置面板     │
│  ├─ --oppo-compat / --debug-dir │   │  └─ 不暴露选项                  │
│  └─ --output-dir / glob         │   │                                  │
└─────────────────────────────────┘   └─────────────────────────────────┘
```

---

## 1. 已知差异清单

### 1.1 `XDRemuxCore.swift` — UHDR 字段索引偏移 (紧急 Bug)

**文件**: `Sources/XDRemuxCore.swift`  
**位置**: `EDRScaleResolver.resolve()` `case .uhdr` 分支

CLI 使用的 UHDR 字段映射（3‑channel per‑channel 布局）：

```
Index:  0   1   2 | 3   4   5 | 6   7   8 | 9  10  11 | 12  13  14 | 15  16  17  18
Field: ratioMin   | ratioMax  | gamma      | epsilonSdr | epsilonHdr | dispSdr dispHdr scale  type
```

App Core 当前的字段映射存在系统性索引偏差。**应当统一为 CLI 布局**，否则 UHDR 文件的 ratioMax、gamma、epsilonSdr、epsilonHdr、displayRatioHdr、scale 全部取到错误值。

**影响范围**: 所有 UHDR 模式的转换都会输出错误的 gain map 元数据。

### 1.2 `ISOHDRWriter` — Gain Map 编码模式缺失

| 模式 | CLI | App Core | 影响 |
|------|-----|----------|------|
| `default` | ✅ | ✅ (硬编码) | 正常 |
| `auto` | ✅ | ❌ | 无法启用 UHDR 直通 |
| `force-444` | ✅ | ❌ | 无法测试/验证 |
| `private-444` | ✅ | ❌ | 无法测试/验证 |
| `preserve-reencode` | ✅ | ❌ | 无法保持源文件增益映射编码 |

### 1.3 UHDR 私有增益映射直通

CLI 额外实现了 `buildUHDRPrivateGainMapIntermediate()` 和 `writeUHDRPrivatePassThroughDefault()`，通过 ISOBMFF 盒子手术实现 UHDR 文件的无损直通。App 完全没有此能力。

### 1.4 `ISOHDRWriter.write()` 签名差异

**CLI**:
```swift
static func write(baseImageURL:gainMap:style:outputURL:oppoCompat:gainMapEncodeMode:)
```

**App Core**:
```swift
static func write(baseImageURL:gainMap:style:outputURL:oppoCompat:sourceData:)
```

App Core 缺少 `gainMapEncodeMode` 参数，多了一个 `sourceData`（但 `XDRemuxCore.convert()` 里未传入）。

### 1.5 OPPO 兼容策略差异

| 方面 | CLI | App Core |
|------|-----|----------|
| UserComment 搜索 | `patchedOppoUserComment()` — 搜索 `oplus_`、`oplus.`、`OPLUS_UHDR` 等多种前缀 | 简单搜索 `oplus_` |
| 后缀格式 | `oplus_<flags \| 0x20000000>` | 相同 |
| 额外 OPPO 数据块 | 构建完整 UHDR 扩展尾块（header + data + manifest + footer + `jxrs`） | 仅追加 UserComment |

### 1.6 元数据提取策略

CLI 使用 `materializeBlocks()` 预构建 `[String: Data]` 字典，而 App Core 使用按需 `extractBlock(named:)`。前者一次性扫描所有 manifest entry 并构建完整映射，后者每次调用重新定位 entry。两种策略结果等价，但按需方案在调用次数多时性能略低。

### 1.7 其他小差异

| 项目 | CLI | App Core | 备注 |
|------|-----|----------|------|
| `GainMapReconstructor` 数据读取 | `[UInt8](mask.data)` 直接构造数组 | `withUnsafeBytes` 零拷贝绑定 | App Core 更优 |
| `makeSDRBaseImage()` | 定义且可能使用 | 定义但未调用 | 功能等价 |
| `kCGImageDestinationEncodeGainMapSubsampleFactor` | 门控在 macOS 26.0 | 不存在 | 未来 API |
| `CalibrationTrace.StrictPath` | 零值填充 | 零值填充 | 一致 |

---

## 2. 迁移行动项

### 阶段 1 — 紧急 Bug 修复

**目标**: 消除 UHDR 字段索引错误，确保 App 输出与 CLI 一致。

| # | 文件 | 行号 | 改动 |
|---|------|------|------|
| 1.1 | `Sources/XDRemuxCore.swift` | 919-953 | 修正 UHDR 字段索引为 CLI 布局 |
| 1.2 | `Sources/XDRemuxCore.swift` | 934 | `ratioMax` → `metaFloats[4]` |
| 1.3 | `Sources/XDRemuxCore.swift` | 935 | `gamma` → `metaFloats[7]` |
| 1.4 | `Sources/XDRemuxCore.swift` | 936 | `epsilonSdr` → `metaFloats[10]` |
| 1.5 | `Sources/XDRemuxCore.swift` | 937 | `epsilonHdr` → `metaFloats[13]` |
| 1.6 | `Sources/XDRemuxCore.swift` | 938-939 | `displayRatioSdr/Hdr` → `metaFloats[16]` / `metaFloats[17]` |
| 1.7 | `Sources/XDRemuxCore.swift` | 940 | `scaleVal` → `metaFloats[18]` |
| 1.8 | `Sources/XDRemuxCore.swift` | 948-952 | per-channel 索引改为 `(0-2, 4-6, 7-9, 10-12, 13-15)` |
| 1.9 | `Sources/XDRemuxCore.swift` | 919 | guard 计数条件 `>= 20` (CLI 检查 20 个值) |

**验证**:
```bash
# 用同一 UHDR 样本分别通过 CLI 和 App 转换，比对输出
python3 -c "
import hashlib
for f in ['cli_output.heic', 'app_output.heic']:
    h = hashlib.sha256(open(f, 'rb').read()).hexdigest()
    print(f, h)
"
```

### 阶段 2 — 核心引擎补齐

**目标**: 使 `XDRemuxCore.swift` 的公共 API 覆盖 CLI 的所有转换控制。

#### 2.1 添加 `GainMapEncodeMode`

在 `Family` 枚举旁添加：

```swift
enum GainMapEncodeMode: String, CaseIterable, Codable {
    case auto
    case defaultMode = "default"
    case force444 = "force-444"
    case private444 = "private-444"
    case preserveReencode = "preserve-reencode"
}
```

#### 2.2 注入 Gain Map 私有像素格式常量

```swift
private let gainMap444PixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
```

#### 2.3 扩展 `ISOHDRWriter.write()` 签名

```swift
static func write(
    baseImageURL: URL,
    gainMap: GainMapRaster,
    style: HDRToneMapStyle,
    outputURL: URL,
    oppoCompat: Bool = false,
    gainMapEncodeMode: GainMapEncodeMode = .auto
) throws
```

- 添加 `gainMapEncodeMode` 参数
- 移除 `sourceData` 参数（或保留为 `@available(*, deprecated)` 兼容）
- 在 `writeHEIC()` 调用时传入编码模式

#### 2.4 移植 `patchedOppoUserComment()`

从 CLI 复制 `patchedOppoUserComment(in sourceData: Data) -> String?` 函数。搜索前缀列表:
```swift
let oppoPrefixes = ["oplus_", "oplus.", "OPLUS_UHDR"]
```

#### 2.5 移植 `ProductGainMapWriter` / 私有增益映射直通

仅在必要时进行。包含以下子任务：
- `ISOBMFFBox` 解析：解析 ftyp/meta/mdat/iloc/iinf/iprp/idat/iref/grpl 盒子
- `ISOBMFFILocEntry` / `ISOBMFFIPMAEntry` 结构
- `buildUHDRPrivateGainMapIntermediate()` — 在现有 HEIC 中注入增益映射条目
- `writeWithPreserveReencode()` — 双重编码路径

此部分为低优先级，不影响正常 LHDR/UHDR 转换。

### 阶段 3 — ViewModel 补齐

**目标**: `XDRemuxViewModel` 暴露 CLI 的所有配置选项并正确收集错误。

#### 3.1 添加配置模型

```swift
struct ConversionConfig {
    var family: Family = .auto
    var outputDirectory: URL?
    var oppoCompat: Bool = false
    var gainMapEncodeMode: GainMapEncodeMode = .auto
    var debugDirectory: URL?
    var fileNameSuffix: String = "_iso"
}
```

#### 3.2 添加文件结果类型

```swift
struct FileResult: Identifiable {
    let id = UUID()
    let inputURL: URL
    let outputURL: URL
    let success: Bool
    let errorMessage: String?
}
```

#### 3.3 ViewModel 新增属性

```swift
@Observable
final class XDRemuxViewModel {
    // 现有
    var state: AppState
    var totalFiles: Int
    var processedCount: Int
    var failedCount: Int
    var currentFileName: String

    // 新增
    var config: ConversionConfig
    var results: [FileResult]
    var visibleErrors: [String]       // 最近 N 条错误
}
```

#### 3.4 `processFiles()` 方法改造

1. 读取 `config.outputDirectory` 确定输出路径
2. 构建完整参数传入 `XDRemuxCore.convert()`
3. 捕获 `XDRemuxError` 转为 `FileResult` 追加到 `results`
4. 错误信息同时显示在 UI（非仅 console）

#### 3.5 取消语义统一

当前取消后进入 `.completed` 状态。建议改为在 `cancelTask()` 中 `resetState()` 回到 `.idle`，并在 UI 上显示"已取消"的中间状态。

### 阶段 4 — UI 扩展

**目标**: 提供配置面板和文件结果视图。

#### 4.1 配置面板

- 使用 `.sheet()` 呈现
- Family: `Picker` (`auto` / `x6` / `x7`)
- 输出目录: `NSOpenPanel` 选择，显示路径
- OPPO 兼容: `Toggle`
- Gain map 编码: `Picker` (auto / default / force-444 / private-444 / preserve-reencode)

#### 4.2 进度视图增强

```swift
// processingView 新增内容
List(viewModel.results.prefix(20)) { result in
    HStack {
        Image(systemName: result.success ? "checkmark" : "xmark")
        Text(result.inputURL.lastPathComponent)
        if let err = result.errorMessage {
            Text(err).foregroundStyle(.red).font(.caption)
        }
    }
}
```

#### 4.3 完成视图增强

- 成功数 / 失败数 / 总数
- 失败文件列表（可展开查看错误详情）
- "在访达中显示" 快捷按钮

### 阶段 5 — 长期改进

| 项目 | 说明 | 优先级 |
|------|------|--------|
| SPM 支持 | 添加 `Package.swift` 以便 CLI 测试和 CI | 低 |
| 单元测试 | `XCTest` 覆盖 `EDRScaleResolver` 和 `LHDRExtractor` | 中 |
| 调试视图 | 集成本地 `--debug-dir` 输出展示（meta 字段、增益映射直方图） | 低 |
| 国际化 | 提供 `en.lproj` / `zh-Hans.lproj` Localizable strings | 低 |
| Asset Catalog | 应用图标 | 低 |

---

## 3. 架构约束

### 3.1 不跨层耦合

```
XDRemuxCore.swift     ← 纯转换引擎，零 UI 依赖
XDRemuxViewModel.swift ← 状态管理，调用 Core
ContentView.swift     ← 纯视图，从 ViewModel 读取
```

此分层已正确保持，迁移不破坏。

### 3.3 配置传递模式

使用 `ConversionConfig` 结构体传递到 `XDRemuxCore.convert()`，而非扩展参数列表：

```swift
static func convert(
    inputURL: URL,
    outputURL: URL,
    config: ConversionConfig
) throws -> SampleReport
```

这样添加新配置项不改变函数签名。

### 3.4 输出文件命名

App 使用 `_iso.heic` 后缀（原地替换在 GUI 下有数据丢失风险）。当用户指定输出目录时保持原始文件名。

---

## 4. 不纳入范围

- CLI `batch` 子命令的 glob 匹配（App 的批量处理使用 macOS 原生文件选择器）
- ISOBMFF 完全解析器（仅 UHDR 私有增益映射所需的 subset）
- 跨平台支持（保持 macOS 15.0+）
- CI/CD 配置

---

## 5. 验证策略

### 5.1 每次改动后

```bash
# 编译
xcodebuild -project XDRemuxApp.xcodeproj -target XDRemuxApp

# 用 3 个 LHDR + 3 个 UHDR 样本转换
# 比对 CLI 输出哈希
```

### 5.2 阶段验收标准

| 阶段 | 验收标准 |
|------|----------|
| 1 | UHDR 转换输出 SHA256 与 CLI 100% 一致 |
| 2 | 所有 `GainMapEncodeMode` 可通过 API 传入 |
| 3 | ViewModel 暴露全部配置；错误可见 |
| 4 | 配置面板功能完整；结果列表展示正确 |

---

## 6. 文件影响矩阵

| 文件 | 阶段 1 | 阶段 2 | 阶段 3 | 阶段 4 |
|------|--------|--------|--------|--------|
| `Sources/XDRemuxCore.swift` | 修索引 | 扩 API + 移植 | — | — |
| `Sources/XDRemuxViewModel.swift` | — | — | 重写 | — |
| `Sources/ContentView.swift` | — | — | — | 扩 UI |
| `Sources/XDRemuxApp.swift` | — | — | — | — |
| `Sources/VisualEffectView.swift` | — | — | — | — |
| `project.yml` | — | — | — | — |

---

## 7. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| UHDR 索引修正破坏现有输出 | 低 | 中 | 阶段 1 验证确保与 CLI 一致 |
| `GainMapEncodeMode` 扩展导致 `writeHEIC()` 行为变化 | 中 | 高 | `auto` 模式保持与当前相同行为 |
| OPPO 兼容移植后影响非 OPPO 设备 | 低 | 低 | `oppoCompat` 默认为 `false` |
| `ConversionConfig` 结构体引入后与现有 `convert()` 调用不兼容 | 中 | 中 | 向后兼容重载或一次性迁移 |

---

## 附录 A: CLI UHDR 字段布局参考

```swift
// XDRemux.swift EDRScaleResolver.resolve() case .uhdr

metaFloats[0] = ratioMin (R)
metaFloats[1] = ratioMin (G)
metaFloats[2] = ratioMin (B)
metaFloats[3] = padding
metaFloats[4] = ratioMax (R)
metaFloats[5] = ratioMax (G)
metaFloats[6] = ratioMax (B)
metaFloats[7] = gamma (R)
metaFloats[8] = gamma (G)
metaFloats[9] = gamma (B)
metaFloats[10] = epsilonSdr (R)
metaFloats[11] = epsilonSdr (G)
metaFloats[12] = epsilonSdr (B)
metaFloats[13] = epsilonHdr (R)
metaFloats[14] = epsilonHdr (G)
metaFloats[15] = epsilonHdr (B)
metaFloats[16] = displayRatioSdr
metaFloats[17] = displayRatioHdr
metaFloats[18] = scale
metaFloats[19] = type
```

## 附录 B: 关键文件链接

- CLI 来源: `../XDRemux.swift` (3435 行)
- App Core: `Sources/XDRemuxCore.swift` (1951 行)
- ViewModel: `Sources/XDRemuxViewModel.swift` (149 行)
- ContentView: `Sources/ContentView.swift` (229 行)
- 项目配置: `project.yml`

---

*生成日期: 2026-05-14*
*基于 CLI commit: `XDRemux.swift@HEAD`*
