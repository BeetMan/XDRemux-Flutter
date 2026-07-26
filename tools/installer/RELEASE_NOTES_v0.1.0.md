# XDRemux v0.1.0

首个公开发布版本。将 OPPO / OnePlus / realme 设备拍摄的 ProXDR HEIC 照片转换为标准 ISO 21496-1 HDR HEIC，转换后可在 macOS、iOS、Android、Windows 等支持 HDR 显示的系统上查看。

核心转换逻辑由 Rust 实现（原版 [XDRemux](https://github.com/21Z121Z1/XDRemux) 为 Swift + Python），UI 由 Flutter 构建。

## 下载

| 平台 | 文件 | 说明 |
|------|------|------|
| Windows (x64) | `XDRemuxSetup-0.1.0.exe` | Inno Setup 安装包（~12MB），双击安装，免管理员权限 |
| Android (arm64) | `app-release.apk` | 直接安装 |

## 已实现功能

### 转换

- LHDR（X6 系列）→ ISO 21496-1 HDR HEIC（gray gain map）
- UHDR（X7 系列）→ ISO 21496-1 HDR HEIC（RGB gain map）
- OPPO 相册兼容模式（RGB gain map + 142B tmap + BT.2020 PQ colr）
- EXIF 方向感知（gain map transpose + canonical tmap ispe + irot quarter-turns）
- ISO HDR 元数据：XMP hdrgm:*、tmap box、auxC URN、tone map LUTs
- EXIF UserComment patch（`tail` 标记 OPPO 路由）
- 拍摄模式分类（15 种 OPPO 拍摄模式：普通拍照 / 大师模式 / 人像 / 夜景 / 全景 / 延时 / 超清 / 证件照 / 贴纸 / 超级文本 / 合影 / 双重曝光 / 美颜 / 专业模式 / RICOH GR）
- 输出验证（`xdremux_verify_output`）
- Bit-exact SDR base image（源文件直达，不重新编码）
- HEVC 编码全平台 x265 静态链接（无需安装 ffmpeg）

### Windows 应用

- 拖拽 HEIC 文件到窗口（原生 `WM_DROPFILES`）
- 多文件队列，并行转换（可配置 1–4 线程），实时瓦片级进度条
- OPPO 兼容模式 7 档开关 / 相机尾部元数据 11 档策略 / 严格 ISO tmap 选项
- 自定义输出目录或文件名后缀、按拍摄模式分目录输出
- 缩略图预览、跳过已有有效输出、断点续传
- 深色/浅色主题、中文界面
- 独立"按拍摄模式整理"页（扫描 → 预览 → 复制分类）
- 自动更新检查（启动时查询 GitHub Releases）

### Android 应用

- 多文件队列转换，实时进度
- 保存到图库（MediaStore；开启按拍摄模式分目录时按模式分相册）
- 分享 / 系统图库打开
- 缩略图预览（Rust FFI 提取 EXIF 内嵌 JPEG）
- 断点续传

## 一致性验证

- 120 个 Rust 单元测试全部通过
- Tier 1–4 跨实现一致性（vs 原版 Python）通过
- Apple ImageIO 验证通过

## 已知限制

- 仅接受 `.heic` 文件
- 转换后回到 OPPO 相册编辑再保存，HDR Gain Map 可能丢失
- Android 缩略图依赖 EXIF 内嵌 JPEG，部分文件可能无缩略图
- Windows 首次运行可能弹 SmartScreen 提示（点"更多信息 → 仍要运行"）
