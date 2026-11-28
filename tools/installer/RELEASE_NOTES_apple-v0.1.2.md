# XDRemux SwiftUI 0.1.2（预发布）

iOS / iPadOS / macOS 的原生 SwiftUI 版（`0.1.2`，build `9`），和 Flutter `v0.4.8` 共用同一个 Rust 内核（`0.4.8`）。
Bundle ID `io.github.beetman.xdremux.swiftui`，桌面显示名为 **`XDRemux`**；与 Flutter 版（`io.github.beetman.xdremux`，自 `0.4.8` 起在 macOS / iOS / HarmonyOS 上显示名为 **`XDRemux Flutter`**）是两个独立应用，可以同机安装、互不覆盖、各自独立保存数据。Flutter 版仍是 Apple 平台的正式推荐版本，本版用独立标签 `apple-v0.1.2` 发布，不接管 Latest。

## 0.1.2 更新内容

### 内核升级至 0.4.8

- **VideoToolbox 硬件编码默认启用（GitHub 包带双编码器切换）**：默认优先调用 Apple VideoToolbox 硬件编码器；本发布包同时内建 x265 软件编码器（`vt+x265`），可在设置里切换编码器，硬件编码在批处理中异常时会自动回退到 x265 完成剩余任务。
- **统一写入规范 ISO `tmap`**：移除旧「严格 ISO tmap」选项，所有输出统一写符合 ISO 21496-1 的 `62/142` 字节 `tmap`，消除错位字节导致第三方相册不认的问题（旧配置文件与队列记录中保留的字段仍可兼容读取）。
- **摄影风格增强**：较大主图的 delta map 按约 5/7 尺寸缩放（修复在 Apple「照片」编辑风格时出现绿色网格的问题）；支持为已转换 ISO HDR HEIC 与「摄影风格 2」照片继续叠加「摄影风格 2 / 3」且保留原有 HDR；在开启「实况 + 摄影风格」时改为逐视频帧生成线性缩略图与色调曲线，并加固视频时间范围与取消保护。
- **人像与 Live Photo 发布加固**：纳入 OPPO / ColorOS 17.24 人像横屏帧布局、镜像与深度读取修复、尾部大师水印画面矩形边框还原及 `hdrgm-xmp` MIME 校验修复；Live Photo 输出改为临时文件校验后原子落盘，失败自动回滚。

### SwiftUI 原生端界面与安装包

- **新应用图标**：全平台同步换为增益图设计的新图标。
- **全屏照片查看器**：在详情页轻点图片进入全屏查看，支持双指 / 双击缩放、拖动平移、左右滑动或键盘方向键翻页、轻点隐藏控制栏与下拉关闭；翻到未转换的 OPPO 照片时自动渲染全尺寸 HDR 预览，退出时回到全屏中最后浏览的那张照片。
- **全图按压对比 SDR 与按比例显示**：详情页与全屏查看均支持按住照片任意位置对比 SDR、松手恢复 HDR；非 ProXDR 源（如已是 ISO HDR 的 HEIC）改为按进口原图尺寸展示详情预览。
- **列表、进度与互传收件箱优化**：iOS「全部存入照片」显示实时存入进度条与完成状态；iPhone Duo 侧边栏合并清理菜单并把「局域网互传」放回导入入口旁；打开「互传」标签或页面时立即刷新收件箱列表。
- **macOS 安装窗与签名**：`XDRemux-Apple-macOS-0.1.2.dmg` 采用带 `/Applications` 拖拽指引的安装窗口，并使用 Developer ID 签名及 Apple 公证（以构建记录与实际校验为准）。

## 安装

### macOS（Apple Silicon，macOS 14 起）

1. 下载 `XDRemux-Apple-macOS-0.1.2.dmg`，打开后将 `XDRemux.app` 拖入「应用程序」（可与 Flutter 版 `XDRemux Flutter.app` 并存）。
2. 本包已使用 Developer ID（`W94G5B6VGC`）签名并完成 Apple 公证装订，正常从「应用程序」双击即可打开，首次授权照片或文件夹访问按系统提示允许即可。只有 Apple Silicon 包，不支持 Intel Mac。

### iOS / iPadOS（iOS 17 起，需签名侧载）

下载 `XDRemux-Apple-iOS-0.1.2-unsigned.ipa`。这是**未签名 IPA**，不能在「文件」App 里直接安装，也不是 App Store / TestFlight 包。
请用自己的 Apple ID / 开发证书，通过可信的签名侧载工具重新签名后安装，并按工具要求完成开发者模式或证书信任设置；
有效期、设备范围和刷新要求由所用账号、证书与工具决定。

- 使用相册导入或存入照片时需要允许照片权限，局域网互传需要「本地网络」权限。
- 分享面板里的 `XDRemux` 入口依赖 App Group `group.io.github.beetman.xdremux.swiftui`：签名时如果工具没有给主应用和扩展签上同一个 App Group，该入口会不可用，其余功能不受影响。
- `SHA256SUMS.txt` 与 `BUILD_RECORD.txt` 可用于核对下载文件哈希、提交版本与构建记录。

## 验证范围与已知边界

- 宿主自动检查与构建结果见本次发布记录与附件 `BUILD_RECORD.txt`（待本次打包检查结果写入）。
- iOS 未签名 IPA 保留为 `unsigned` 侧载产物；真机上的重签侧载安装、Share Extension App Group 行为及物理实机全景验收需按所用签名方式自行核对。
- 没有应用内更新检查；新版本请看本项目 Releases。
