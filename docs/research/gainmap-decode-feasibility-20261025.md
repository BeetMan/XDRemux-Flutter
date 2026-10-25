# 增益图（tmap）解码可行性（2026-10-25）

> 目标：给 Styles 线性缩略图补 HDR 高光，就需要把 ISO 21496 的 `tmap` 增益图解码后应用到 scene-linear base。当前 `styles-pipeline.md` §4 把"缺 tmap 增益图 tile 的 HEVC 解码"列为唯一阻塞点。本文记录第一次实测的结论。
> 结论：**解码路径有，但不能直接用现有解码器**——需要三选一（§4）。

## 1. 实测文件与结构（已实测）

样本：本移植从 OPPO ProXDR 源转换出的 Apple 兼容 HEIC（`test_130241.heic` → `e2e_out_130241.heic`）。

用 `cargo run --example gm_probe -- <file>`（本 PR 新增）实测：

| 项 | 结果 |
|---|---|
| `tmap` item | id=10243，payload **62B**，头 16 字节 `00 00 00 00 00 40 00 00 00 00 00 01 86 a0 00 03`（ISO 21496 metadata float block） |
| `dimg` 引用 | `tmap --dimg--> [10192(base grid 6144×8192), 10242(gain grid 3072×4096)]` |
| 增益图实际编码 | **单张 item 10246**，3072×4096，hvcC：profile_idc=**4(Rext)**、bitDepth=8、chromaFormat=**0(4:0:0 单色)**、lengthSize=4，payload 2869B（1 个 slice NAL） |
| idat 构造 | `iloc` 的 `construction_method=1`：tmap/grid 的 payload 在 `idat` 内，偏移相对 `idat` payload 起点；tile 数据在 `mdat`（method=0） |

两个实现坑（已修进探针）：
1. `PropertyInfo::raw` 含 8 字节 box 头，hvcC 字段偏移要 +8；
2. `meta` 是 full box，找 `idat` 子 box 要从 `meta.data_start + 4` 开始扫。

## 2. 解码器现状（已实测）

`rust_h265` **0.1.0 已经是 heif-oxide 的传递依赖**（`cargo tree -i rust_h265` → heif-oxide → xdremux-core），API 完整：`parse_annex_b`、`Decoder::decode_nal`、`Frame { y/u/v: PixelData, width, height, bit_depth }`，纯 Rust、跨平台可用。

但对本增益图直接解码失败：

```
decode error: Unsupported("only 4:2:0 (chroma_format_idc=1) supported")
```

即解码器**只支持 4:2:0**，而当前增益图是单色 4:0:0（OPPO mask 重建出来的灰度增益图，写入时是 mono）。

## 3. 为什么增益图是 4:0:0

增益图来自 OPPO UHDR/LHDR 的 mask/增益数据重建（`gainmap.rs` 的 Reinhard knee LUT 链），本质是**单通道**；写入端（`isobmff_write.rs`）按单色 8-bit 编码，所以 hvcC chromaFormat=0。仓库另有 `has_lossy_iso_gainmap_420` / `XDREMUX_GM_420` 机制，说明 4:2:0 增益图也是合法形态。

## 4. 三条可行路径（未实现，按优先级）

1. **改增益图编码为 4:2:0**（最小改动）：仓库已有 `gain_map_420_enabled()`（`hevc.rs`，`XDREMUX_GM_420=1` / cfg 开关）。若把增益图统一编码成 4:2:0，`rust_h265` 即可直接解码；代价是色度（对增益图无意义，只取 Y）与少量体积。风险：需确认 Apple Photos 接受 4:2:0 增益图（`has_lossy_iso_gainmap_420` 表明这是已知合法形态，但仍需真机验证）。
2. **给 `rust_h265` 加 4:0:0 支持**：单色解码可跳过全部色度路径，改动集中在 SPS/chroma 数组与残差/预测分支；属于对第三方 crate 的扩展（可 vendor patch 或上游 PR）。
3. **绕过解码**：转换管线内部本来就有重建后的增益图像素（`write_lhdr_iso_output` 的 `gainmap` 缓冲）。线性缩略图生成时直接传入该像素缓冲，**零解码**即可应用 HDR 增益；缺点只覆盖"本移植自己生成/转换"的文件，对纯 Apple 原生 tmap 文件（重编码场景）仍需要解码。

## 5. 未验证

- 增益图应用后的**绝对亮度**是否正确（需要与原生文件真机 A/B）；
- Apple Photos 对 4:2:0 增益图 + Main10 线性缩略图组合的接受度；
- Apple 原生 Styles 文件的增益图编码形态（可能同样是 4:0:0 或 4:2:0，手上暂无原生样本可测）。

## 6. 复现

```bash
cargo run -p xdremux-core --example gm_probe -- <converted.heic>
```

输出会打印 tmap payload、dimg 候选、hvcC chroma 直方图、单色 tile 候选与解码结果。
