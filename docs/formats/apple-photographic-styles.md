# Apple 摄影风格 HEIC 结构

> 对应代码：`styles_native.rs` / `styles_graft.rs` / `styles_bplist.rs` / `styles_consts.rs`。
> 本页记录 Apple"摄影风格"文件的结构事实；生成管线的代码视角见 `modules/styles-pipeline.md`。

## 1. 与普通 Apple HEIC 的区别

普通 Apple HDR HEIC：主图 grid + tmap（ISO 21496-1 增益映射，`dimg` 指向 [主图, 增益映射图]）+ Exif。

摄影风格文件在此基础上追加**编辑图层**：

```
主图 grid（id 10081 一类）
tmap item（62 字节元数据）
增益映射图 grid（低分辨率，25 tile 典型）
delta grid（DELTA_ROWS × DELTA_COLS tile）   <- 风格增量层
linear item                                 <- 线性调色层
styleMetadata mime item（bplist）           <- 风格元数据
sky 蒙版 item + mime item                    <- 天空分层编辑
```

各编辑 item 通过 `cdsc` 关联回 `[主图, tmap]`，辅助层通过 `auxl` 挂到主图。Apple 照片靠这张引用图识别"这是可继续编辑的风格文件"。

## 2. 关键结构

### 2.1 tmap item

62 字素的增益映射元数据（ISO 21496-1 序列化）。`dimg` 引用目标 = [主图 grid, 增益映射图 grid]。写回时保留回传文件的 tmap 及其图结构（`fix(oppo): retain returned HDR gain-map graph`，v0.3.1）。

### 2.2 styleMetadata（bplist）

Apple 二进制 plist，编码风格元数据：tone/warmth 数值、风格标识、蒙版参数。本项目用自写 `BplistWriter`（`styles_bplist.rs`）生成，支持 bool/int/real/data/str/dict，不依赖第三方库，保证字节可控。容器探测见 conformance 的 `bplist.rs`。

### 2.3 天空蒙版

独立 item + 配套 mime 描述，供 Apple 照片做"只调天空"的分层编辑。生成路径见 `styles_native.rs` 的 sky 装配段。

## 3. 生成策略对比

| 路径 | 做法 | 用途 |
|---|---|---|
| `styles_native`（生产） | scaffold 骨架 + 从零装配全部风格 item | 主路径 |
| `styles_graft`（`graft_styles(standard, golden)`） | 从金样文件移植风格图结构 | 对拍验证、疑难样张兜底；返回 `GraftSummary` |
| 约束求解 / identity 回退 | （Swift 上游概念，golden corpus 里的 styles vs styles-identity） | 研究对照 |

## 4. 已知差异（与 Apple 原生文件对比）

- 天空蒙版 auxl 引用重复出现两次（待修）
- 部分 auxl 引用目标为 `[主图, tmap]` 而非仅主图（待修）
- 不承诺逐像素等价：目标是"Apple 照片中可继续编辑"，非字节级克隆

## 5. 验证清单

1. 直出文件能被 ColorOS 相册 / Windows WIC / heif-oxide 打开
2. Apple 照片打开后：显示摄影风格控件、编辑不破坏结构、导出往返正常
3. conformance：`inspect`/`dump` 的 JSON 结构 diff（见 `testing/conformance-suite.md`）
