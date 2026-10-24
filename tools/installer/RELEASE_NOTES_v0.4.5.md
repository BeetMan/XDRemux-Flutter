# v0.4.5 — JPEG 色彩修复、iPhone Duo 适配与 Linux 预览

本版为 Flutter `0.4.5+39` / Rust `0.4.5`，包含 Windows、Android、macOS、iOS、Linux（预览）与 Flutter HarmonyOS 六平台安装包。维护者已确认本轮验收无问题，并于 2026-10-25 授权发布。

## iPhone Duo 与 Apple 平台

- 适配 iPhone Duo 的 trailing vertical bar，将工具按钮放入系统预留的侧边区域；宽屏/双屏布局优化主操作位置，队列较长时仍能方便地开始转换。普通设备保留既有安全区布局。
- 修复部分 HDR HEIC 在 iOS 上显示为黑色缩略图的问题：原生缩略图经过明确的 8-bit sRGB 上下文后再编码，异常黑图交给 Rust 预览回退。macOS 同步规范化处理；这只影响界面预览，不把 HDR 转换输出改成 SDR。
- 新增 Apple Silicon iOS 模拟器核心构建脚本，区分真机/模拟器 x265 归档，并修复干净构建时 Rust 与 C 依赖部署目标不一致导致的链接问题。
- iOS 发包显式使用 Xcode 27.1 / iOS 27.1 SDK，并编译探针验证 Duo API；不为旧 SDK 删除 Duo 功能。**构建 SDK 要求不等于最低系统版本**，应用部署目标仍为 iOS 15.0，新接口继续受运行时可用性检查保护。
- Duo 适配包含已接入的侧栏和主操作布局；UIHinge 驱动的折叠态专用布局尚未接入，不承诺所有姿态或目标图库功能完全一致。

## 六平台安装与发布范围

- 目标产物：Windows x64、Android ARM64、macOS Apple Silicon、iOS ARM64、Linux x64（预览）、Flutter HarmonyOS ARM64。
- Linux 打包现由统一发布 workflow 调用，与 Windows、Android、macOS、iOS 一起检查成功状态及附件存在性；缺少任何一类 CI 产物时不创建 Release。手动预检仍不发布。
- Flutter 鸿蒙使用独立 OHOS Flutter SDK，本地构建 profile AOT、debug:true 的 unsigned HAP，供开发签名侧载；不改变现有签名配置，也不代表免签安装。
- Android 安装包明确只支持 ARM64：修正 Flutter 默认 ABI 集合的叠加，避免携带缺少 Rust 核心的 32 位/x86_64 引擎、误使不支持的设备安装后失败；新增 APK 原生库架构与完整性检查。正式签名保持不变。
- Windows ARM64 仍为不可交付的实验性任务，不列入本轮六平台承诺。鸿蒙原生采用独立版本线，已另行发布 0.5.2，本轮不重打或改动该版本。

## JPEG 色彩配置保留

- 修复带 P3、sRGB 等 RGB ICC 的 JPEG 转 HEIC 时丢失源色彩配置的问题，不限小米品牌。HDR JPEG 与现有普通 JPEG 摄影风格源重建路径均保留原始 RGB ICC，不先压到 sRGB，也不按相机名或 profile 描述猜色域。
- ICC 写入 HEIC 主图及主图瓦片的 `colr/prof`；配套 `nclx` 与主图 HEVC VUI 明确使用实际编码的 BT.709 YCbCr 矩阵及全范围，不再同时声称源像素是 BT.709 色域/传递函数。原编码质量与增益图处理方式不变，无 ICC 的输入保留既有行为。
- 校验 ICC 分段序号、缺段、重复、大小、头部及 tag 范围。当前直接保留 RGB ICC v2/v4；CMYK/灰阶 ICC 或不支持的 profile 明确报错，不把未经色彩管理转换的像素套上错误配置。
- 两张用户原图的 Apple 标准 / OPPO 兼容转换均通过回归；MIX Flip 2 的 632 字节 ICC 逐字节保留，完整照片和水印画布尺寸仍为 3072×4572。其错误 MPF 主图长度没有被用于截断 JPEG，未新增宽泛的损坏数据容错。
- 独立 libheif 1.23.4 与 LittleCMS 读回验证：P3、sRGB 色块两种输出均保留原 ICC，色块中心最大 RGB 误差 1/255；整幅测试图经同一 ICC 转为 sRGB 后各通道平均绝对误差不超过 0.51/255（含边界与有损编码影响）。FFprobe 核对 HEVC VUI 与容器声明一致。

上述自动色彩验证为主机文件级验证，不代表所有设备、图库、HDR 显示或摄影风格编辑完全一致；PNG/HEIF 等其他格式的源色彩管理与 CMYK/灰阶 ICC 转换不在本轮范围。

## JPEG HDR 兼容性（Issue #11）

- 修复部分小米 / 红米 Ultra HDR JPG 在 0.4.4 中被误显示为 SDR、无法转换的问题：照片包含当前不支持版本的 ISO 元数据时，允许使用同一增益图对应的有效 Adobe HDR XMP，继续生成 HDR HEIC。
- 回退仅针对 ISO 版本不支持，不放宽数据截断、重复 ISO 段、非法数值等校验；Adobe 回退也必须通过命名空间、版本、数值、范围与 SDR 底图检查。无法可靠解析时仍明确失败，不静默丢掉 HDR。
- Flutter 照片详情新增“HDR 解析失败”与原因，信息复制中一并保留错误；不会把解析失败当作“无（SDR）”。EXIF 可继续显示。
- 使用 Issue #11 原始 JPEG 验证 Apple 标准与 OPPO 兼容两种输出，均通过 HDR 增益图结构检查，亮度倍率约 2.18×，原图哈希不变。此验证是 Windows 主机上的共享 Rust 核心实测，不替代 Android、Apple Photos 或其他平台真机验收。

本轮不增加通用 SDR JPG → HEIC 模式，不启用伪 HDR，不改变默认编码质量或签名。鸿蒙原生为独立版本 0.5.2；Flutter 主线 0.4.5 不替代原生发布标签及其独立验收记录。

## Linux 桌面预览

- 新增 GTK 桌面目标、拖放 / 命令行导入、Rust FFI、AppImage/tar.gz 打包和用户级安装。移除 Linux 不使用的托盘/JNI 插件，系统托盘和完成通知暂未接入。
- 修正 Cargo 库查找路径及安装路径特殊字符转义；Ubuntu libnuma 通过 HTTPS 下载并校验包和缓存 SHA256，x265 缓存与较新发行版隔离。
- Ubuntu 22.04 构建和打包通过，核心最高 GLIBC 需求为 2.35；Linux 仍按预览支持发布，不代表所有发行版已完整验收。

## 验证与安装说明

- 六平台预检通过；主线 CI / Conformance 全部通过。Rust 自动回归 258 passed / 7 ignored，两项显式启用的原图回归通过；本地 Flutter 145 项测试通过。
- Android 仅 ARM64，最低 Android API 24；正式签名证书 SHA256 与 v0.4.4 一致，可在兼容设备上覆盖升级。
- iOS IPA 未签名，需自行签名侧载；使用 iOS 27.1 SDK 构建，最低部署目标仍为 iOS 15.0。
- Flutter 鸿蒙附件为 profile AOT / debug:true unsigned HAP，需匹配包名、证书和设备范围的开发签名，不是免签包或应用市场分发包。统一相册保存及 Live Photo 配对分享限制不变。
- Flutter 鸿蒙附件 SHA256：`C43C01A4031150658D38496CACCFF22406E9289254B2F73C7B6691AE10630C1F`，复用维护者验收过的相同文件；全部资产另提供 `SHA256SUMS.txt`。
- 维护者确认本轮验收通过；未提供逐设备/逐场景明细，不扩写为代理已完成六平台全部实机验收。完整构建证据和范围见[发版记录](https://github.com/BeetMan/XDRemux-Flutter/blob/main/docs/plans/release-045-preflight.md)。
