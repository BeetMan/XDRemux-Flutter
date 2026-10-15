# Windows codec 测试版 02：更新与验收

基于 `integrate/huawei-portrait-live`，应用版本仍为 **0.4.3+37**。
本地便携测试版，不是正式 Release；本轮未提交、推送或修改 CI 默认 codec 配置。
解压整个 ZIP 到新目录，再运行 exe。不要把 DLL 混入旧安装目录。
普通便携版仍可能共享已安装应用的偏好；请先记下原设置，使用独立输出目录和原图副本。

## 本次更新

1. WIC 失败后，用后台 Rust 解码主图生成彩色 PNG 预览，不再扫描 gain map。
   可选 libheif 处理非 4:2:0 SDR；缩略图尺寸、输入/声明尺寸检查、串行 Rust 解码、
   32 MiB / 128 项缓存；缓存清空不再丢失等待任务，同路径文件变更会更新缓存。
2. 设置底部新增「Codec 能力与诊断」：真实 core/libheif/decoder 版本、能力和
   JSON 复制/导出。报告不含照片、路径、EXIF、GPS 或原始错误。
   错误分类是已知字符串的提示，不等于已证明根因；计数是本进程错误展示次数。
3. Windows 真实应用集成测试使用隔离偏好与 checkpoint，不修改用户应用配置。
   覆盖 drop 导入、重复去重、强制 Rust 预览兜底、Styles 开关往返、诊断界面、
   真实转换、损坏项隔离、输出与 Styles 图结构、原图哈希。
4. Apple JPEG + Styles：两张 public gain-map v1/v2 参考样片转换通过，原有 51 个
   MakerNote 字段的类型、计数和 payload 字节保留，新增 tag84，UUID 不改。
   原 note 有足够零填充时，不搬移未知 payload；否则仅接受受限数值矩阵布局和
   验证过的自相对 scalar/container bplist。Data/UID/未知 opaque 格式仍拒绝。

tag2 的字段命名参考 [ExifTool Apple.pm](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Apple.pm)；
16×16 小端 u16、数值 ≤1023 的矩阵布局是对本地参考样片的有限观察，
不是 Apple 公布的通用规范，也不能据此宣称所有私有数据兼容。
预览是 SDR；尺寸预检不是内存沙箱或硬超时，峰值 RSS / 恶意流压力测试尚未完成。

## 自动验证

- 默认 Rust：224 passed，3 ignored；native feature：225 passed，3 ignored。
- 另行执行 ignored Apple JPEG MakerNote 语料测试：通过（两个输入）。
- metadata 专项：13 passed，1 fixture-dependent ignored。
- Flutter 全部测试：63 passed。iOS 全符号保留文本契约通过，未做 iOS 目标构建。
- Windows Debug runner + release feature-on core：6 项队列，5 成功、1 故意失败；
  5 张 PNG 预览、设置开关、5 个输出/Styles 图与原图哈希通过。
- 最终 Release ZIP 的独立加载、预览、转换与 SHA256：见平台计划中的最终构建记录。

应用集成报告保存在仓库外临时目录，公开样片/合成控制输入不打进测试包。

## 需要你手动验证

### 必测

- [ ] **实际添加文件**：文件选择器单选、多选、中文/空格路径、取消选择；文件夹导入和
  真实资源管理器拖放。全部能正常入队、重复不增加、取消不留下假条目。
- [ ] **失败原图和预览**：之前失败的 iPhone 截图（特别是 IMG_0008.HEIC）、真实
  4:4:4 / 10-bit 和旋转照片。照片墙彩色、方向/比例正确，不是灰度 gain map。
  未装 HEIF 扩展的 Windows 上也试一次；无需为测试卸载现有扩展，可用另一台/虚拟机。
- [ ] **转换开关**：上述 SDR HEIC 开启「Apple 照片摄影风格（Rust）」后转换；
  Apple HDR JPEG 分别关闭/开启 Styles，验证无意外 SDR 降级、原图不变、输出能打开。
  无法安全扩展的 MakerNote 应提示明确失败，不应静默删除数据或冒充成功。
- [ ] **诊断复制/导出**：设置底部应见 libheif 1.23.4，decoder 为 libde265 1.1.3。
  Copy 和 Export JSON 都可用，UTF-8 JSON 能打开；取消保存不报成功；检查无原图路径/GPS。
- [ ] **批量稳定性**：20–50 张大图混合，含坏文件；导入期间滚动/打开设置不明显卡住；
  取消、重试、清空再添加不挂起；托盘恢复窗口正常。留意峰值内存与耗时。

### 发布门槛

- [ ] **Apple Photos 真机**：把输出导入 iPhone/macOS Photos，确认 HDR 显示和
  Styles 真正可编辑，重复导入/编辑/导出也正常。文件可打开或图结构校验通过不等于可编辑。
- [ ] **原有功能回归**：华为人像输出可调景深；华为/OPPO Live 的静帧与视频配对、
  动态播放和时长正常；原有 OPPO HDR 相册兼容不退化。
- [ ] **干净 Windows**：无 Flutter/Rust/VS/开发 PATH 的机器完整解压运行，验证 DLL
  不缺失、预览/转换可用；不要只拷贝 exe。当前未做干净虚拟机验收。

反馈建议：测试包编号、Windows/Photos 版本、输入来源与格式、相关开关、实际错误、
诊断 JSON；若方便，再单独提供失败样片（报告不会自动携带照片）。

## 重跑应用测试

在 `apps/flutter` 使用项目已固定的依赖及镜像；设置两个包内依赖路径环境变量
`XDREMUX_WINDOWS_RUST_DLL`、`XDREMUX_WINDOWS_LIBHEIF_PREFIX`。

```powershell
flutter test integration_test/windows_codec_e2e_test.dart -d windows --no-pub `
  --dart-define=CODEC_TEST_ROOT=<controls-02> `
  --dart-define=APPLE_JPEG_TEST_ROOT=<libultrahdr/tests/data>
```

此命令启动测试 runner，不是发布二进制的自动 UI 验收；最终 ZIP 另做包内 FFI smoke。
