# XDRemux v0.2.1

跨平台可靠性修复 + macOS 原生优化。

- **修复 gain map 绿块/花屏（macOS）**：x265 批量编码时每个 gain tile 内嵌了 VPS/SPS/PPS，且切分逻辑有 bug（部分 tile 缺 IDR slice）。改为单帧循环编码——tile 0 保留参数集供 hvcC 提取，后续 tile 纯 IDR，符合 ImageIO 的 ISO gain-map 解码器要求。
- **修复 4:2:0/4:4:4 选择逻辑**：之前默认 4:4:4 导致 OPPO 图库识别失败。现在跟随 OPPO 兼容模式——开启时 4:2:0（OPPO 图库要求），关闭时 4:4:4（色度精度最佳，Windows/Android 原有行为）。
- **修复 hvcC profile 解析**：`sps_ptl`/`vps_ptl` 的 NAL 头偏移从 1 字节改为 2 字节，hvcC 正确记录 Main Still Picture profile（此前误标为 Main）。
- **ftyp 加 miaf brand**：macOS ImageIO 识别 ISO gain map 所需。
- **macOS GPU 硬件编码（VideoToolbox）**：设置页「GPU 硬件编码」开关现在 macOS 也可用。开启后用系统硬件编码器（VideoToolbox）编码 gain map，输出 4:2:0 全范围，与 x265 结果一致。失败自动回退软件编码。
- **macOS 原生 HEIC/HDR 缩略图**：照片墙改用 ImageIO 从完整 HEIC 解码（替代低质 EXIF 缩略图），并应用 HDR 增益映射，转换后图片亮度明显高于源图（HDR 效果对比清晰）。
- **源/转换后缩略图切换**（macOS only）：转换完成的卡片左下角显示「转换后/源」切换按钮，点击切换 HDR 渲染与原始 SDR。
- **窗口最小尺寸限制**：macOS/Windows 最小窗口 480×800（手机竖屏比例），UI 已自适应窄屏（<600 宽切紧凑模式，<480 切极简模式）。
- **iOS 版骨架创建**（本次不发布）：iOS 工程已创建，Rust core + x265 交叉编译静态库，FFI 链接已解决（`-u` 符号保留 + force_load）。功能待完善。

签名与之前版本一致，可直接覆盖安装。版本号 `0.2.1+14`。
