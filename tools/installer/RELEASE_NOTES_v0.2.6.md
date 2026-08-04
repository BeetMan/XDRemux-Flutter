# XDRemux v0.2.6

GPS 保留、权限体验简化、全平台格式徽章。

- **修复 OPPO UserComment patch（对齐 Swift iloc-extent 方法）**：重写 Exif 补丁——按 iloc extent 定位 Exif item，沿 TIFF IFD 链找 UserComment 条目，追加调整后的值并重写 count/offset，对每个 cm=0 的 extent 按 Swift `adjustedExtentForOppoUserCommentPatch` 平移。彻底消除旧方案（扫描整个 mdat 拼接字节）导致的 **GPS 丢失、绿块、OPPO 相册误判全景** 三大问题。5 个样本（LHDR x6/x7 + UHDR x7）全部验证通过。
- **Android 保留照片 GPS**：OPPO MediaProvider 通过 content URI 读取 HEIC 时必然清除 GPS ASCII 字段（LatRef/LonRef/Date）。新增「所有文件访问」（MANAGE_EXTERNAL_STORAGE）授权，通过真实文件路径读取，GPS 完整保留。选择照片时弹出一次性说明对话框（去授权 / 继续不保留位置），设置页也有对应入口。
- **Android 文件选择器简化**：统一从相册选择 HEIC（系统已过滤格式），去掉了独立文件选择器；缩略图改为系统 ImageDecoder + 串行线程池，彻底修复选多张图时预览闪动 / 黑白 / OOM 崩溃。
- **输出父目录自动创建**：清理输出文件夹后无需重启应用即可继续转换（对齐 Swift `ensureDirectory`）。
- **全平台格式徽章**：队列卡片显示 LHDR/UHDR + X6/X7 机型徽章与拍摄模式，桌面网格卡与移动列表卡统一（Windows / macOS / Android 通用）。转换状态徽章位置固定、进度条不再溢出、转换完成缩略图不再闪动。
- **Windows 构建修复**：CMake 增加 `/utf-8`，修复中文系统（代码页 936）下 UTF-8 源文件触发 C4819 被 `/WX` 升级为硬错误的问题。

版本号 `0.2.6+16`。Windows / Android 平台产物随本 Release 提供。
