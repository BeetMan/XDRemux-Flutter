# XDRemux Flutter + Rust 跨平台移植计划

> 状态: Phase 2 已完成；v0.1.6 Android release 文件导入修复已完成云端发版与真机验证
> 日期: 2026-07-07
> 最近更新: 2026-07-27 — v0.1.5 云端 APK 真实复测发现缺少 `libc++_shared.so`；v0.1.6 已在 Release workflow 增加 NDK C++ 运行库打包，并用云端 APK 在 OPPO 真机验证 HEIC 入队成功。
> 来源依据: `xdremux/python/`(参考实现)、`xdremux/swift-cli/XDRemux.swift`(生产真相源)、`apps/macos/XDRemuxApp/`(UI 参考)、`docs/design/repository-layout.md`、`apps/macos/XDRemuxApp/MIGRATION_PLAN.md`、`docs/releases/v1.2.md`

---

## 0. 背景与定位

XDRemux 把 OPPO/OnePlus/realme 的 ProXDR HEIC 转成 ISO 21496-1 HDR HEIC。现有实现:
- **Swift CLI**(`xdremux/swift-cli/`)—— 生产真相源,仅 macOS
- **Swift macOS App**(`apps/macos/XDRemuxApp/`)—— 仅 macOS
- **Python CLI**(`xdremux/python/`)—— 跨平台参考,但 ISOBMFF 处理有已知缺口(`auxC`/`auxl` 未真正写入)

本计划新增 **Rust 核心 + Flutter UI**,覆盖 Android / iOS / Windows / macOS。**不替换** Swift/Python(按 v1.2,Swift CLI 仍是 macOS 推荐入口),而是新增一条跨平台路径。

技术栈与可选的 `README_FLUTTER.md` 一致:Rust + Flutter + `dart:ffi`。

---

## 1. 关键技术结论(调研得出,决定后续架构)

1. **Swift 的 `.system` 输出路径依赖 Apple ImageIO**(`kCGImageDestinationEncodeToISOGainmap` 等),无法移植到 Windows/Android。因此 **Rust 跨平台路径必须走字节级 ISOBMFF 装配**(即 Python 与 Swift 的 `.hybrid`/`.passthrough` 路径)。 `.system` 不在跨平台范围内(后续可作 macOS 专属优化)。
2. **最佳移植基线 = Python 结构 + Swift 的正确盒子装配**。Python 已证明无 Apple API 也可工作,但 Python 的 `isobmff_patch.py` 定义了 `AUXC_BOX` 却没真正写入 `auxC`/`auxl`——这是致命缺口。Swift 的 hybrid 路径正确处理了盒子移植,应作为盒子装配的"正确性蓝本"。Rust 要把两者合并。
3. **EDR 计算要求 f32 精度**(原 Swift 用 `Float`,Python 用 `_f32` 来回打包)。Rust 必须全程 `f32`,常量逐字复制,禁止意外 promote 到 `f64`。
4. **UHDR 字段布局**(MIGRATION_PLAN 附录 A 是精确蓝图):
   ```
   metaFloats: [0..2]=ratioMin, [3]=pad, [4..6]=ratioMax, [7..9]=gamma,
   [10..12]=epsilonSdr, [13..15]=epsilonHdr, [16]=dispSdr, [17]=dispHdr,
   [18]=scale, [19]=type
   ```
   Python 与生产 Swift 的索引必须一致(App 的历史偏差已修)。
5. **OPPO 兼容四态**(`auto`/`on`/`tail`/`off`):`off` 出干净 Apple 输出;`on`/`tail` 在 EXIF UserComment 里 OR `0x20000000`;不再追加任何私有 `jxrs` 尾(v1.2 已明确)。tag-flag 前缀:`ASCIIOplus_`/`ASCIIoppo_`/`Oplus_`/`oplus_`/`oppo_`。OPPO LHDR 增益图需复制为 RGB(LHDR RGB-copy)。
6. **tmap 负载两种形态**:Apple 基线 62 字节 vs ImageIO-native 142 字节(用于 OPPO 兼容,注释明确"故意非严格 ISO 145 字节")。两种都要能生成。
7. **验证标准 = 与 Swift CLI 输出逐字节对比**(v1.2 正是这么验过的:byte-for-byte against origin/main)。这是贯穿全程的金标准。
8. **无真实样本入库**(repo 策略:大图不入 git)。`fixtures/`、`tests/` 目前只有 README。需要本地 gitignored 样本目录 + 合成 fixture。

---

## 2. 仓库布局(遵循 repo 约定,而非 README_FLUTTER 的简化版)

`README_FLUTTER.md` 提议根级 `rust/` + `lib/`,但这**与 `docs/design/repository-layout.md` 的约定冲突**(转换器入口归 `xdremux/`,图形壳归 `apps/`)。本计划采用 repo 约定:

```
xdremux/
├── core/
│   └── rust/                      # Rust 核心(新增,呼应 design 文档构想的 xdremux/core/swift/)
│       ├── Cargo.toml
│       ├── src/
│       │   ├── lib.rs             # FFI 导出 + ConversionResult
│       │   ├── container.rs       # LHDR/UHDR 提取、QTI/manifest/box 扫描、校准
│       │   ├── edr.rs             # EDR scale(f32,精确常量)
│       │   ├── gainmap.rs         # LUT 重建
│       │   ├── iso21496.rs        # XMP、UHDR 20-float、tmap 负载、hdrgm
│       │   ├── isobmff.rs         # 盒解析与装配(大模块,合并 Python+Swift)
│       │   ├── hevc.rs            # 增益图 HEVC 瓦片编码(libheif/x265)
│       │   ├── heif_io.rs         # 写出编排
│       │   └── exif.rs            # UserComment / OPPO tag 补丁
│       └── tests/
├── python/                        # 保留
├── swift-cli/                     # 保留
└── core/swift/                    # (未来,不在本计划范围)

apps/
└── flutter/                       # Flutter 应用(新增,呼应 apps/macos/)
    ├── lib/
    │   ├── main.dart
    │   ├── models/                # ConversionConfig、QueueItem、Statuses(镜像 macOS ViewModel)
    │   ├── services/
    │   ├── ffi/                   # xdremux_ffi.dart
    │   ├── screens/
    │   └── widgets/
    ├── android/  ios/  windows/  macos/
    └── pubspec.yaml

fixtures/
└── synthetic/                     # 提交:手造的小型盒子级测试片段
trial/                             # gitignored:用户放入真实 ProXDR 样本(沿用 PROJECT_SETUP 惯例)
docs/
└── plans/active/xdremux-flutter-port-20260707.md  # 本文件
```

> ⚠️ 决策点 A:布局。我推荐上述 repo 约定版本。若你更想要 README_FLUTTER 的根级 `rust/`+`lib/`(上手更快、CI 更简单),告诉我。

---

## 3. FFI 设计

**原则:FFI 暴露"单文件转换 + 验证",批量循环与断点续传逻辑放 Dart 侧**(只是文件簿记,放 Dart 让 UI 进度更自然)。

```rust
// 转换结果(owned,调用方负责 free)
#[repr(C)]
pub struct ConversionResult {
    pub success: bool,
    pub mode: *mut c_char,          // "lhdr" | "uhdr"
    pub family: *mut c_char,        // "x6" | "x7"
    pub edr_scale: f64,
    pub gain_map_max: f64,
    pub error_message: *mut c_char,
}

#[repr(C)]
pub struct ConvertConfig {
    pub family: u8,            // 0=auto 1=x6 2=x7
    pub oppo_compat: u8,       // 0=off 1=auto 2=on 3=tail
    pub branch: u8,            // 0=system(仅 macOS) 1=hybrid(默认) 2=passthrough
}

#[no_mangle] pub extern "C" fn xdremux_version() -> *mut c_char;
#[no_mangle] pub extern "C" fn xdremux_inspect(input: *const c_char) -> InspectResult;        // M1
#[no_mangle] pub extern "C" fn xdremux_convert(input, output, cfg, result_out: *mut ConversionResult) -> bool;  // M3+
#[no_mangle] pub extern "C" fn xdremux_verify_output(path: *const c_char) -> bool;            // M4
#[no_mangle] pub extern "C" fn xdremux_free_result(*mut ConversionResult);
```

Dart 侧用 `Isolate`/`compute` 跑 FFI 调用避免 UI 卡顿。子文件进度(瓦片编码)留作 future——先报单文件完成。

---

## 4. 里程碑(每个都有可验证验收门槛;M3 最难)

### M0 — 骨架与 FFI 冒烟(1–2 天)
- 落地 §2 布局;`cargo init --lib` 产出 `cdylib` + `staticlib`;
- Flutter `flutter create` 入 `apps/flutter/`;pubspec 接 `ffi`/`file_picker`/`path_provider` 等;
- FFI:`xdremux_version()` 回字符串,Flutter 打印。
- **验收**:Windows 上构建 Rust 库,Flutter 桌面跑起来显示 "Rust core v0.1 connected"。同时做一个 **HEVC 编码器 spike**(见风险 R1)。

### M1 — 容器 + EDR 提取(无输出)(2–3 天)
- 移植 `container.rs`(QTI/manifest、两模式、Swift 的校准打分)、`edr.rs`(f32 + 精确常量 + `f[33]` 旁路 + knee);
- 针对解码后的样本字节数组做单元测试;
- FFI `xdremux_inspect`。
- **验收**:对真实 ProXDR HEIC 输出 mode+family+EDR,与 Python CLI 的诊断一致。

### M2 — 增益图重建 + XMP/tmap(2–3 天)
- `gainmap.rs`(4 个 LUT、exponents 0.625/2.2、256 字节行对齐、knee for v<3)、`iso21496.rs`(XMP、UHDR 20-float、62/142 字节 tmap);
- 单元测试:已知 EDR → 已知 LUT 输出。
- **验收**:重建的增益图像素 vs Python 阶段输出一致。

### M3 — HEVC 编码 + ISOBMFF 单文件写出( hardest,5–8 天)
- `hevc.rs` 接 libheif/x265 编码 512×512 瓦片;
- `isobmff.rs` 盒树装配(auxC、dinf、irot、nclx PQ/sRGB、pixi、CLLI、hvcC、ispe、ipma、iloc v1、iref dimg/cdsc/auxl、grpl/altr、tmap、hdrgm XMP;ftyp 补 `tmap`/`MiHE`/`miaf`/`MiHB`);
- LHDR 单文件端到端转换(干净模式,无 OPPO)。
- **验收(金标准)**:输出在 Apple Photos 显示 HDR;**与 Swift CLI 输出逐字节一致**。不一致即回到盒子装配找差异。

### M4 — UHDR + OPPO 兼容 + 输出验证(3–4 天)
- UHDR 20-float → ISO 元;OPPO UserComment 补丁(`exif.rs`,TIFF/IFD 写 tag `0x9286`);142 字节 tmap;`xdremux_verify_output`(查 ISO 增益图辅助结构:auxC + tmap + iref,而非仅文件存在)。
- **验收**:UHDR 样本 + OPPO-compat 样本与 Swift 一致。

### M5 — Flutter UI 对等(4–5 天)
- 镜像 macOS `ConversionConfig`(family、outputDirectory、oppoCompatibility 四态、inputProcessingBranch、skipExisting、maxConcurrentJobs、fileNameSuffix、debugDirectory);
- 队列模型 + 状态(pending/running/converted/skippedExisting/failed/cancelled + OutputPlanStatus);
- 拖拽、文件选择器、缩略图、设置 sheet、完成汇总(成功/失败数、错误详情、打开输出目录)。
- **验收**:单文件与批量的可用 UX(手动用真实样本)。

### M6 — 批量 + 断点续传(2–3 天)
- Dart 侧 JSONL checkpoint:header(configHash、jobs、startedAt)+ 每文件 item(status、inputSize、inputMtimeNs、error);签名续传;`skipExisting` + `verify_output` 复核;零失败才删 checkpoint;输出路径碰撞预检。
- **验收**:中途杀掉重启,续传不重做已成功的文件。

### M7 — 跨平台安卓构建(2–3 天)
- `cargo` + NDK 出 `aarch64-linux-android`/`armv7-linux-androideabi`/`x86_64-linux-android` 的 `.so`;Flutter `android/` 装载;`permission_handler` 处理存储权限。
- **验收**:APK 装到设备,真实转换一张。iOS 留后续(需 Xcode、本机暂缺)。

---

## 5. 风险登记

| # | 风险 | 级别 | 缓解 |
|---|------|------|------|
| R1 | **HEVC 编码器跨平台可用性与许可证**。x265 是 GPL2,对 MIT 发行有顾虑;Windows 上 libheif 拉 x265 走 vcpkg。 | 高 | M0 做编码器 spike:能否用 libheif + 许可证可接受的编码后端;Android 考虑平台 `MediaCodec` 做增益图 HEVC。先确认再过 M3。 |
| R2 | 字节级 ISOBMFF 正确性(offset/session、iloc v0→v1、auxC/auxl 接线——Python 就漏了 auxC) | 高 | 逐字节对比 Swift CLI 作为每里程碑验收门。 |
| R3 | EDR 的 f32 精度漂移 | 中 | 单元测试锁定精确常量与若干已知样本的 EDR 值;全程 `f32`。 |
| R4 | 无入库样本,无法回归 | 中 | `trial/`(gitignored)放用户提供真实 ProXDR;`fixtures/synthetic/` 放小合成分片做盒子级单测。 |
| R5 | OPPO "ImageIO-native" 142 字节 tmap 是逆向 Apple 得来,无 Apple API 要复刻 | 中 | 按字节数据复刻;M4 用 OPPO 样本对比 Swift 验证。 |
| R6 | iOS 构建需 Xcode,本机 Windows 暂不可做 | 低 | iOS 推迟到有 Mac 环境;M7 先交付 Android + Windows。 |

---

## 6. 决策锁定 ✅ (2026-07-07)

- **决策 A — 仓库布局**:锁定 repo 约定版: `xdremux/core/rust/` + `apps/flutter/`，遵循 design/repository-layout.md
- **决策 B — 首个输出路径**:锁定 `.hybrid`(字节手术)，`.system`(Apple-only)与`.passthrough`(最复杂)后置
- **决策 C — 批量/断点**:锁定 Dart 侧，FFI 只暴露单文件转换 + 验证
- **决策 D — 样本策略**:锁定 `trial/`(gitignored真实样本) + `fixtures/synthetic/`(提交小分片)两层策略
- **决策 E — M0 spike**:锁定 M0 先做 HEVC 编码器 spike，避免 M3 撞墙

---

## 7. 不在本次范围

- `.system` Apple-ImageIO 路径(跨平台无法做,macOS 专属优化另议)
- iOS 构建(待 Mac)
- CI/CD、发布自动化
- 调试视图(meta 字段、增益图直方图)等长期改进项(见 MIGRATION_PLAN 阶段 5)
