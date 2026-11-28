# XDRemux 鸿蒙原生版 0.5.5

同步主线 `v0.4.8`，共享 Rust 内核升至 `0.4.8`（与 Flutter v0.4.8 相同）。原生 App 元数据为 `0.5.5` / code `50500`；桌面显示名为 **`XDRemux`**（包名 `io.github.beetman.xdremux.arkui`），与升级后的 Flutter 版 **`XDRemux Flutter`**（`io.github.beetman.xdremux`）独立发布、互不覆盖。

## 更新内容

### 共享 Rust 内核 0.4.8

- **统一规范 ISO `tmap`**：移除旧「严格 ISO tmap」选项，所有输出统一写 ISO 21496-1 规范的 `62/142` 字节 `tmap`，消除第三方相册兼容隐患；既有设置与队列记录中保留的旧字段仍向后兼容。
- **鸿蒙全模式 4:2:0 增益图与风格叠加**：鸿蒙平台所有输出模式下的三通道增益图统一采用 4:2:0 编码；已转为 ISO HDR HEIC 或「摄影风格 2」的照片继续叠加「摄影风格 2 / 3」时不再丢失原有 HDR；较大主图的 delta map 按约 5/7 尺寸缩放。
- **OPPO / ColorOS 17.24 人像、水印与 Live Photo 安全发布**：纳入 17.24 人像横屏帧布局 / 镜像 / 深度修复、尾部大师水印边框还原、动态照片 MP4 尾部裁剪与 `hdrgm-xmp` MIME 校验修复；Live Photo 输出改走事务式发布与失败回滚。
- **OHOS 编解码构建优化**：为鸿蒙端 x265 启用 ARM64 NEON 汇编优化。

### 鸿蒙原生端界面与稳定性

- **新图标与 HarmonyOS 7 基线**：换为增益图设计新图标；工程构建目标与最低兼容统一至 HarmonyOS 7 / API 26（`compatibleSdkVersion: 26.0.0`、`targetSdkVersion: 26.0.0`）。
- **图库交互与浏览**：大图详情支持长按照片任意位置对比 SDR（隐藏 HDR 图层并在屏幕尺寸生成预览），修复 HDR/SDR 切换按钮点按热区，进入大图详情时伴随暗色背景过渡；图库三列网格与横向缩略图条按需懒加载并缓存正立缩略图，减轻大量照片导入时的卡顿。
- **互传与数据持久化**：打开「互传」标签时立即刷新收件箱列表，切换可发现状态时保留已显示收件箱；修复「发送到其他设备」连带旧请求列表的问题，将图库索引与队列日志写入改为串行合批，提升导入与转换落盘稳定性。

## 安装与升级

- 下载 `XDRemux-HarmonyOS-Native-0.5.5-unsigned.hap`。本包是开发自签用 **Debug unsigned HAP**（`app.debug:true`），Rust 核心保持 Release 优化。
- 应用名 **`XDRemux`**，包名 `io.github.beetman.xdremux.arkui`，ARM64，版本 `0.5.5` / code `50500`。请使用匹配包名、证书和目标设备的开发 Profile 自签；不是免签安装包或应用市场上架包。
- 现有 `.arkui` 用户使用相同签名可覆盖升级并保留数据；Flutter 版 **`XDRemux Flutter`**（`io.github.beetman.xdremux`）与原生版身份、沙箱和签名互相独立，可同机共存但不可互相覆盖安装。
- 权限要求保持为 `ohos.permission.INTERNET` 与 `ohos.permission.GET_NETWORK_INFO`（仅用于局域网互传）；要求 HarmonyOS 7 / API 26 及以上系统。
- 附件 `SHA256SUMS.txt` 可用于校验下载文件。

## 验证与使用范围

- 宿主回归与包校验通过：`20` 份鸿蒙模型/队列/互传/图库 Node 测试、`5` 项 HAP verifier 单测及 C++ PS3 辅助回归全通过；HAP 解包校验确认包名 `io.github.beetman.xdremux.arkui`、版本 `0.5.5` / code `50500`、`compatibleApi: 26`、`app.debug: true` / `buildMode: debug`、无签名记录、ZIP CRC 全部正常、包内核心含 `0.4.8` 版本且 `libentry.so` 所需的 32 个 `xdremux_*` 符号及全部 55 个桥接/库依赖符号均可解析。
- 本轮尚未在鸿蒙真机上安装与实测 `0.5.5` 包，设备侧已验范围与未验项沿用 `0.5.4` 说明（「存入相册」、分享、选择照片发送、网段扫描发现及与 iPhone / Android LocalSend 的直接互传仍待真机验证）。
- 转换保持前台运行；人像、摄影风格、Live Photo 与局域网互传仍含实验能力。未启用可选 libheif 解码器。

原生版本使用独立标签 `harmony-v0.5.5`，不接管 Flutter 版的 Latest 下载入口。
