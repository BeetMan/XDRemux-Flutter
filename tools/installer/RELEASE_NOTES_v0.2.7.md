# XDRemux v0.2.7

Windows 原生预览图修复、桌面卡片格式徽章、批量拖入性能优化。

- **Windows 原生缩略图（WIC）**：修复旧机型 HEIC（如 OPPO X6 系列，无内嵌 EXIF 缩略图）预览图损坏/黑白问题。Windows 版现在通过系统 WIC（Windows Imaging Component）解码 HEIC 主图像生成彩色高清预览，与 macOS（ImageIO）、Android（ImageDecoder）对齐。需要系统安装「HEIF 图像扩展」与「HEVC 视频扩展」（Microsoft Store 免费，装机时通常在「照片」打开过 HEIC 已自带）；未安装时自动回退到 Rust 内嵌缩略图提取。
- **预览分辨率提升**：缩略图长边 256 → 512px，桌面网格卡显示不再模糊。
- **批量拖入流畅度**：缩略图解码移到后台线程（WIC 解码不再阻塞 UI），并发请求去重 + 限流，一次拖入大量照片不再卡顿。
- **桌面卡片格式徽章**：LHDR/UHDR + X6/X7 机型徽章与拍摄模式同步显示到桌面网格卡（此前仅移动列表卡），全平台统一。
- **Windows 构建修复**：CMake 增加 `/utf-8`，修复中文系统（代码页 936）下 UTF-8 源文件触发 C4819 被 `/WX` 升级为硬错误的问题。
- **CI 缓存修复**：release 流程（tag 触发）的 x265 缓存改为 `restore-keys` 回退 main 分支缓存，发版不再每次重新编译 x265。

版本号 `0.2.7+17`。Windows / Android 平台产物随本 Release 提供。
