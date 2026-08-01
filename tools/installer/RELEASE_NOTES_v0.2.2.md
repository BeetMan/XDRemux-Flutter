# XDRemux v0.2.2

iOS 版首次发布（TestFlight 之外的手动签名安装），全平台细节完善。

- **iOS 版可用**：iPhone 真机验证通过。Rust core + x265 静态库、原生 HEIC/HDR 缩略图（ImageIO）、GPU 硬件编码（VideoToolbox）全部就位，转换速度与效果与 macOS 版一致。
- **iOS 系统分享**：新增 Share Extension——在相册/文件里直接「分享 → XDRemux」导入 HEIC，自动跳转 app 开始转换（app group 传输，免费开发者账号可签名）。
- **保存到相册**（Android/iOS）：转换完成后底部出现「存到相册」图标按钮；点单个缩略图也有「保存到相册」（按拍摄模式分相册）；菜单保留「全部保存到相册」。
- **iOS 文件集成**：开启 Files App 可见性（「文件 → 我的 iPhone → XDRemux」可管理输入/输出）；设置页新增「打开输出目录」一键跳转 Files；新增缓存/输出目录大小查看与一键清除。
- **新图标 + 正名**：iOS 换上与 macOS 一致的自定义图标（已去 alpha 通道）；iOS/macOS 显示名统一为 **XDRemux**（macOS 产物改为 XDRemux.app）。
- **修复 OPPO 兼容默认关闭**：`loadConfig()` 的兜底值漏改导致全新安装默认仍是「关」。已修复——新装/未动过开关的用户默认开启；已存过「关」的设备不受影响（手动开一次即记住）。
- **底部操作栏防换行**：添加/存相册改为纯图标按钮，中间主按钮文字不再被挤压换行（Android/iOS 同步）。
- **设置页文案**：「GPU 硬件编码」说明精简，去掉「实验」标记（三平台均已验证）。

iOS 安装：免费 Apple ID 签名（7 天有效），需开启开发者模式并信任证书；正式分发（TestFlight/App Store）需要付费开发者账号。版本号 `0.2.2+15`。
