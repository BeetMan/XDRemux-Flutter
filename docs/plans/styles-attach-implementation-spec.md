# 实现规格：摄影风格 3 — 任意照片全链路

> 交给子 agent / 新 session 的完整实现规格。
> 项目：/Users/beet/Documents/XDRemux Playground/XDRemux-Flutter
> 分支：main（最新含全部实验结论和工具链）

## 目标

让 app 的「摄影风格 3」功能支持**任意照片输入**（不只 OPPO ProXDR），
通过在转换前合成恒等增益图让现有管线接受任意 HEIC/JPEG 输入。

## 已验证事实（不需要重新实验）

- PS3 契约（styles + texture_styles + 12 matte + maker note）在
  **OPPO 转换管线产出的容器**上实机验证可用（质感/胶片/颗粒/光晕）
- 注入器（inject_uri_metadata_item / inject_semantic_mattes / 
  replace_item_payload）在标准容器上完全正常
- 原位 TIFF 重建（upsert_maker_note_in_tiff）在非标准容器上会让 Photos 崩溃
- **结论**：非 OPPO 输入必须走完整转换管线产出标准容器，不能原位注入

## 现有管线（不需要改）

```
OPPO ProXDR HEIC 输入
→ extract_lhdr_or_uhdr_from_bytes（提取增益图数据）
→ prepare_lhdr_tiles / prepare_uhdr_tiles（解码+准备 tile YUV 数据）
→ [Dart 硬件编码 or x265 软件编码]（tile_streams）
→ assemble_prepared_tiles（组装标准 HEIC 容器）
→ styles_native（scaffold + styles 项 + PS3 契约）
→ 输出
```

这条管线在 OPPO 输入上完整工作。问题：它要求输入是 OPPO ProXDR 格式。

## 需要实现的内容

### 1. SDR 输入预处理（新函数）

文件：`xdremux/rust/src/uhdr_jpeg.rs`

新增函数 `synthesize_uhdr_from_sdr`：
- 输入：任意 JPEG 的 bytes
- 输出：带恒等增益图的 Ultra HDR JPEG bytes

实现：在原始 JPEG 后面追加：
1. XMP APP1 segment 含 hdrgm 元数据（GainMapMin=0, GainMapMax=0, 
   Gamma=1.0, HDRCapacityMin=0, HDRCapacityMax=0 → 即 gain 1.0 无提升）
2. MPF APP2 segment（Multi-Picture Format）指向一个 1×1 灰色 gain map JPEG
3. gain map JPEG 本身（已有一段现成代码可以复用 `IDENTITY_GAINMAP_JPEG`）

参考 `uhdr_jpeg::parse` 了解它期望的格式：
- `walk_segments` 找 `MPF\0` APP2 → 提取 gain map JPEG 位置
- gain map JPEG 的 XMP 需要 `hdrgm` 块（HDRCapacityMin/Max, GainMapMin/Max 等）
- `hdrgm_to_meta_floats` 转换为 20-float 元数据

或者更简单：直接在 Rust 里构造一个假 Ultra HDR JPEG：
- 取原始 JPEG 的 SOI + 所有 segment（直到 EOI）
- 在 EOI 前插入 XMP APP1（hdrgm 元数据）和 MPF APP2（指向 gain map）
- gain map JPEG = 一个预制的 1×1 灰色 JPEG（已有 `IDENTITY_GAINMAP_JPEG`）

### 2. HEIC 输入支持

文件：`xdremux/rust/src/uhdr_jpeg.rs` 或 `xdremux/rust/src/container_build.rs`

非 JPEG 输入（HEIC 等）：Flutter 侧解码 → 重编码为 JPEG → 传给上述路径。

Dart 侧改动：
- 在转换流程中，非 OPPO 输入（classify mode == null）：
  1. Flutter `ui.instantiateImageCodec` 解码为 RGBA
  2. 用 `dart:ui` `Image.toByteData(format: rawRgba)` 获取像素
  3. 编码为 JPEG（`dart:image` 或平台通道 ImageIO）
  4. 传给 Rust FFI 的 SDR 路径

### 3. 转换流程集成

文件：`apps/flutter/lib/main.dart` 的 `_convertOne` 函数

现有路由（已实现）：
```dart
if (runConfig.applePhotographicStyles3) {
  final cls = await XdRemuxService.classify(item.inputPath);
  final isOppo = (cls['mode'] as String?)?.isNotEmpty == true;
  oppoAttachFallback = isOppo;
  if (!isOppo) {
    // → SDR 路径
  }
}
```

SDR 路径改为：
1. 调用 Rust FFI `xdremux_convert_sdr(inputPath, outputPath)`（新 FFI）
   - 内部：JPEG 解码 → 合成 UHDR → synthesize → prepare → encode → assemble
   - 输出：标准 HEIC 容器（含增益图结构）
2. 然后 `attach_styles(outputPath, outputPath)` 添加 PS3 契约
3. 标记转换完成

### 4. 新 FFI 函数

文件：`xdremux/rust/src/lib.rs`

```rust
#[no_mangle]
pub extern "C" fn xdremux_convert_sdr(
    input_path: *const c_char,
    output_path: *const c_char,
) -> *mut c_char {  // JSON result
    // 1. read input
    // 2. if not JPEG → error (Dart pre-converts)
    // 3. uhdr_jpeg::parse → UhdrJpeg (with identity gain map for SDR)
    // 4. uhdr_jpeg::synthesize_source_container → HEIC container
    // 5. styles_native(&container) → styles scaffold + styles item
    // 6. inject_texture_styles → texture_styles item
    // 7. inject_semantic_mattes → 12 mattes
    // 8. write output
    // return JSON {"status":"ok"} or {"status":"error","message":"..."}
}
```

### 5. Dart FFI 绑定

文件：`apps/flutter/lib/ffi/xdremux_ffi.dart`

```dart
static final _convertSdr = _lib.lookupFunction<
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>),
    ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>)
>('xdremux_convert_sdr');

static Map<String, dynamic> convertSdr(String inputPath, String outputPath) {
  final ptr = _convertSdr(inputPath.toNativeUtf8(), outputPath.toNativeUtf8());
  final json = ptr.toDartString();
  // free ptr via xdremux_free_string
  return jsonDecode(json);
}
```

## 关键文件

| 文件 | 用途 |
|---|---|
| `xdremux/rust/src/uhdr_jpeg.rs` | Ultra HDR JPEG 解析/合成 + SDR 回退 |
| `xdremux/rust/src/styles_native.rs` | styles scaffold + styles 项 |
| `xdremux/rust/src/semantic_mattes.rs` | 12 matte 注入 |
| `xdremux/rust/src/texture_styles.rs` | texture_styles 注入 |
| `xdremux/rust/src/styles_attach.rs` | attach（注入 + note 合并）|
| `xdremux/rust/src/lib.rs` | FFI 入口 |
| `apps/flutter/lib/ffi/xdremux_ffi.dart` | Dart FFI 绑定 |
| `apps/flutter/lib/main.dart` | 转换流程路由 |

## 已有探针（可参考/复用）

| 探针 | 用途 |
|---|---|
| `examples/sdr_convert.rs` | SDR JPEG → synthesize（已有雏形）|
| `examples/attach_test.rs` | 契约附加（已验证）|
| `examples/attach_bisect.rs` | 组合矩阵测试 |
| `examples/build_test.rs` | 容器构建测试 |

## 验证步骤

1. `cargo build --release -p xdremux-core --example sdr_convert` 编译通过
2. `sdr_convert test.jpg output.heic` → sips 读 output.heic → pixelWidth 正常
3. `attach_test output.heic output-styles.heic` → 全套契约注入
4. `iso_validate_probe output-styles.heic` → 结构验证
5. iOS 构建装机 → 导入相册 → 摄影风格编辑出现且可用

## 注意事项

- `uhdr_jpeg::parse` 的 SDR 回退已实现（`IDENTITY_GAINMAP_JPEG` + `neutral_meta_floats`）
  —— 直接生效，不需要额外改动
- `synthesize_source_container` 内部调用 `decode_jpeg_to_rgb` 解码 JPEG
  —— 输入必须是 JPEG（HEIC 由 Dart 预转 JPEG）
- styles_native 内部调用 scaffold() —— 需要 tmap + gain grid，
  synthesize_source_container 的输出没有这些 → 需要检查 scaffold 是否报错
  → 如果报错，需要在 synthesize 时额外添加最小 tmap + 增益 grid
- `uhdr_jpeg::parse` 的 SDR 回退已在上一轮实现并提交
  —— 关键代码在 uhdr_jpeg.rs 的 `IDENTITY_GAINMAP_JPEG` 和 `neutral_meta_floats`
