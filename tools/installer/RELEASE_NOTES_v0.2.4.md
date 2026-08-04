# XDRemux v0.2.4

核心转换与 ISO 21496-1 一致性修复，多机型验证。

- **修复硬件路径 gain map tile 头布局**：`assemble_prepared_tiles`（MediaCodec / VideoToolbox 硬件编码路径）与软件路径对齐——先从完整流提取 hvcC，再剥离每个 tile 的 VPS/SPS/PPS/SEI，使每个 tile 都是纯 IDR slice，解码器参数只放在 hvcC 中，匹配 libheif 的输出约定。
- **ISO 21496-1 对齐 Python/Swift 参考实现**：gain map 输出与上游参考实现逐字节一致（knee LUT 重建链、hvcC 数组、纯 IDR tile）。
- **修复嵌 HDR 的 JPEG 伪 QTI 尺寸头**：识别并拒绝伪装成 QuickTime 容器的尺寸头，避免误读。
- **README 适配说明更新**：多机型已验证（OPPO Find X8 Ultra 大师模式等），其他机型/模式遇到 bug 欢迎提交 Issue。
- 清理上游 Swift/Python 参考实现源码（已并入测试用例）。

版本号 `0.2.4+17`。Windows / macOS / Android 三个平台产物随本 Release 提供。
