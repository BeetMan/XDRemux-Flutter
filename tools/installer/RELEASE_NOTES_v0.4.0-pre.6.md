# XDRemux v0.4.0-pre.6

这是 v0.4.0 的第 6 个预发布测试版本，重点修复 Ultra HDR JPEG 以及伪装成 `.heic` 扩展名的样张 HDR 无法识别的问题。

## 本版本更新

- **Ultra HDR JPEG 与伪装 .heic 格式全面识别支持**：
  - **双向容错识别链路**：针对 OPPO Find X10 / 大师模式或特定设置下生成的“文件后缀为 `.heic` 但实际格式为 JPEG”的样张（例如 `IMG...0245.heic`、`0232`、`0234` 等），入队分类器（`xdremux_classify`）及探针（`xdremux_inspect`）增加了对 Ultra HDR JPEG（MPF + hdrgm XMP）的双向识别与回退机制。
  - **UI 状态与徽章恢复正常**：此类照片入队后不再被误判为 SDR，能够正确亮起 `UHDR` 模式与 `X7` 世代徽章。
  - **全链路解析健壮性提升**：分瓦片编码入口 `xdremux_prepare_tiles` 与人像模式 `run_portrait` 统一接入 `extract_lhdr_or_uhdr_from_bytes`，确保各类封装模式下的 HDR 增益图与 EDR Headroom 均能正确提取与转换。
- **继承 v0.4.0-pre.5 的摄影风格升级**：
  - 动态 32×32 区域真实光照图计算（彻底消除底部水印白框导致的 12.5% 颜色分界断层）。
  - 主图 4:2:0 编码（彻底解决 OPPO 等安卓图库硬解黑屏）。
  - 竖屏自适应 6×5 Delta Grid 网格。

## 验收重点

1. **Find X10 等新机型大师模式照片**：将 `IMG...0245.heic` 等样张拖入软件，确认卡片正常亮起 `UHDR` / `X7` 徽章，并能正常完成转换。
2. **标准 Ultra HDR JPEG 样张**：测试 `.jpg` / `.jpeg` 格式的 Ultra HDR 样张，确认入队识别与转出效果一致。
