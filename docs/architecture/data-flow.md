# 数据流：转换与写回

> 本页描述两条主数据流的端到端路径。代码入口：Flutter 侧 `apple_oppo_workflow_service.dart` / `apple_oppo_workflow_page.dart`；Rust 侧 `lib.rs` 的 FFI 导出（`xdremux_convert_with_styles` 系列、`xdremux_writeback_returned_photo`）。

## 1. 总览

```
OPPO 手机                         iPhone
──────                            ──────
原始照片 (ProXDR HEIC)
    │ ① 生成 Apple 编辑副本
    ▼
apple-edit.heic ────────────────► Apple 照片 (摄影风格/编辑)
                                       │ 用户编辑并导出
                                       ▼
                              returned.heic ────► 传回 (AirDrop/文件)
    │ ② 写回：恢复原机水印 + OPPO 兼容结构
    ▼
OPPO 兼容输出 (oppo-final.heic)
```

四步工作流（v0.3.0 起简化）：**选原始照片 -> 生成 Apple 编辑副本 -> iPhone 编辑后传回 -> 写回输出**。中间 baseline 已删除：它带 gain map/tmap，二次转换会产生双增益映射图和重复引用结构。

## 2. 流程①：生成 Apple 编辑副本（`createAppleStylesCopy`）

donor 同时是后续写回的 donor（相机尾部最完整），两者必须配对保存。

```
OPPO 原始 HEIC
  │ heif-oxide 解码（SDR 基图，方向已应用）
  ▼
标准 ISO 基线 HEIC（Rust 重建容器）
  │ finalize_native_styles()
  │   ├─ styles_bplist.rs    构造 Apple 风格 bplist
  │   ├─ styles_graft.rs     cdsc 图移植（auxl 引用）
  │   ├─ styles_native.rs    原生风格数据（蒙版、天空分层）
  │   └─ styles_scaffold.rs  兜底脚手架
  ▼
apple-edit.heic（ISO 21496-1 增益映射 + 风格编辑图）
```

要点：

- **直接从 OPPO 原始照片转换**，不经过中间 baseline
- 增益映射：OPPO 私有 UHDR -> ISO 21496-1 tmap（增益映射图为独立 grid item，`dimg` 引用）
- 尺寸不一致时失败关闭；缺 `rear.depth` 直接跳过（人像）
- 输出可在 Apple 照片中继续编辑（保留风格图结构是关键）

## 3. 流程②：写回（`writebackReturnedPhoto`）

全平台统一走 Rust FFI（v0.3.1 起，见 `architecture/platform-backend.md`）：

```
returned.heic + donor(原始 HEIC)
  │ 1. 解码两者，尺寸校验（不一致 -> 失败）
  ▼
  │ 2. 水印恢复（watermark_codec::restore_visible_watermark）
  │   ├─ 首选：PNG 载荷路径（watermark + watermark.config -> 画布矩形）
  │   └─ 回退：边框带检测（detect_frame_bands -> 行区间复制）
  ▼
合成光栅
  │ 3. 512×512 tile -> x265_encode_tiles_oppo_sdr
  │    （BT.601 limited 数据 + full 标记，复刻 OPPO 渲染观感）
  ▼
  │ 4. rewrite_primary_grid：新 tile/grid item、pitm 切换、iloc/iref 重建
  ▼
  │ 5. 剥离旧 footer -> 追加 donor 完整 OPPO 尾部（12 条目）
  ▼
oppo-final.heic
```

输出模式（术语固定）：

- **OPPO 兼容**：恢复可见原机水印、元数据、OPPO 私有尾部数据
- **Apple 标准**：保留回传画面，不追加 OPPO 私有信息

失败关闭原则贯穿全程：水印检测不到、几何不匹配、尺寸不一致都直接失败，不输出猜测结果。

## 4. 平台后端选择

| 功能 | Windows | Android | macOS | iOS |
|---|---|---|---|---|
| 转换 / 写回 | Rust FFI | Rust FFI（.so via jniLibs） | Rust FFI | Rust FFI（静态库） |
| 解码预览 | WIC | ImageDecoder | ImageIO | ImageIO |
| 文件访问 | 文件系统 | SAF（不索取存储权限） | NSOpenPanel | PHPicker / Files |

Swift 后端（`AppleReturnedPhotoWritebackBridge` 等）保留为研究路径，默认不调用。Rust 核心在四平台都内建 x265（Android/iOS 交叉编译静态库，见 `build.rs` / `build_ios.sh`）。

## 5. 状态与检查点

- 工作流产物保存在应用目录 `xdremux_workflow/`（Android: `/data/data/<pkg>/app_flutter/`）
- checkpoint_service.dart 支持中断恢复：donor 与回传文件必须配对（文件名前缀）
- 前台服务（Android）保证后台转换存活
