# v0.4.5 — JPEG 色彩修复、iPhone Duo 适配与 Linux 预览（尚未发布）

候选版本为 Flutter `0.4.5+39` / Rust `0.4.5`。当前为发布准备阶段：手动预检只生成构建产物，不创建 tag 或 GitHub Release，不修改已有附件；下列变化尚未包含在已发布的 v0.4.4 安装包中。

## iPhone Duo 与 Apple 平台

- 适配 iPhone Duo 的 trailing vertical bar，将工具按钮放入系统预留的侧边区域；宽屏/双屏布局优化主操作位置，队列较长时仍能方便地开始转换。普通设备保留既有安全区布局。
- 修复部分 HDR HEIC 在 iOS 上显示为黑色缩略图的问题：原生缩略图经过明确的 8-bit sRGB 上下文后再编码，异常黑图交给 Rust 预览回退。macOS 同步规范化处理；这只影响界面预览，不把 HDR 转换输出改成 SDR。
- 新增 Apple Silicon iOS 模拟器核心构建脚本，区分真机/模拟器 x265 归档，并修复干净构建时 Rust 与 C 依赖部署目标不一致导致的链接问题。
- iOS 发包显式使用 Xcode 27.1 / iOS 27.1 SDK，并编译探针验证 Duo API；不为旧 SDK 删除 Duo 功能。**构建 SDK 要求不等于最低系统版本**，应用部署目标仍为 iOS 15.0，新接口继续受运行时可用性检查保护。
- 真机旋转、折叠时工具栏跟随、HDR/ICC 图库显示及 Live Photo 保存仍需要候选包验收；模拟器结果不代替真机验收。

## 六平台候选与发布流程

- 目标产物：Windows x64、Android ARM64、macOS Apple Silicon、iOS ARM64、Linux x64（预览）、Flutter HarmonyOS ARM64。
- Linux 打包现由统一发布 workflow 调用，与 Windows、Android、macOS、iOS 一起检查成功状态及附件存在性；缺少任何一类 CI 产物时不创建 Release。手动预检仍不发布。
- Flutter 鸿蒙使用独立 OHOS Flutter SDK，本地构建 profile AOT、debug:true 的 unsigned HAP，供开发签名侧载；不改变现有签名配置，也不代表免签安装。
- Windows ARM64 仍为不可交付的实验性任务，不列入本轮六平台承诺。鸿蒙原生保持独立 0.5.1 版本线，本轮不自动同步或升版。

## JPEG 色彩配置保留

- 修复带 P3、sRGB 等 RGB ICC 的 JPEG 转 HEIC 时丢失源色彩配置的问题，不限小米品牌。HDR JPEG 与现有普通 JPEG 摄影风格源重建路径均保留原始 RGB ICC，不先压到 sRGB，也不按相机名或 profile 描述猜色域。
- ICC 写入 HEIC 主图及主图瓦片的 `colr/prof`；配套 `nclx` 与主图 HEVC VUI 明确使用实际编码的 BT.709 YCbCr 矩阵及全范围，不再同时声称源像素是 BT.709 色域/传递函数。原编码质量与增益图处理方式不变，无 ICC 的输入保留既有行为。
- 校验 ICC 分段序号、缺段、重复、大小、头部及 tag 范围。当前直接保留 RGB ICC v2/v4；CMYK/灰阶 ICC 或不支持的 profile 明确报错，不把未经色彩管理转换的像素套上错误配置。
- 两张用户原图的 Apple 标准 / OPPO 兼容转换均通过回归；MIX Flip 2 的 632 字节 ICC 逐字节保留，完整照片和水印画布尺寸仍为 3072×4572。其错误 MPF 主图长度没有被用于截断 JPEG，未新增宽泛的损坏数据容错。
- 独立 libheif 1.23.4 与 LittleCMS 读回验证：P3、sRGB 色块两种输出均保留原 ICC，色块中心最大 RGB 误差 1/255；整幅测试图经同一 ICC 转为 sRGB 后各通道平均绝对误差不超过 0.51/255（含边界与有损编码影响）。FFprobe 核对 HEVC VUI 与容器声明一致。

上述为主机文件级验证，不代表所有平台预览、图库、HDR 显示或摄影风格编辑已完成色彩验收；PNG/HEIF 等其他格式的源色彩管理与 CMYK/灰阶 ICC 转换不在本轮范围。

## JPEG HDR 兼容性（Issue #11）

- 修复部分小米 / 红米 Ultra HDR JPG 在 0.4.4 中被误显示为 SDR、无法转换的问题：照片包含当前不支持版本的 ISO 元数据时，允许使用同一增益图对应的有效 Adobe HDR XMP，继续生成 HDR HEIC。
- 回退仅针对 ISO 版本不支持，不放宽数据截断、重复 ISO 段、非法数值等校验；Adobe 回退也必须通过命名空间、版本、数值、范围与 SDR 底图检查。无法可靠解析时仍明确失败，不静默丢掉 HDR。
- Flutter 照片详情新增“HDR 解析失败”与原因，信息复制中一并保留错误；不会把解析失败当作“无（SDR）”。EXIF 可继续显示。
- 使用 Issue #11 原始 JPEG 验证 Apple 标准与 OPPO 兼容两种输出，均通过 HDR 增益图结构检查，亮度倍率约 2.18×，原图哈希不变。此验证是 Windows 主机上的共享 Rust 核心实测，不替代 Android、Apple Photos 或其他平台真机验收。

本轮不增加通用 SDR JPG → HEIC 模式，不启用伪 HDR，不改变默认编码质量、签名或已发布资产。鸿蒙原生仍为独立版本 0.5.1；主线提升到 0.4.5 不代表原生分支已同步升级。

## 验证与发布状态

- Linux 预览集成 PR #12：新增 GTK 桌面目标、拖放 / 命令行导入、Rust FFI 查找、AppImage / tar.gz 打包和用户级安装。Linux 不使用的托盘 / JNI 插件从构建中移除，不改变其他平台的产品门禁。
- 审查补丁修正 Cargo 库相对路径、安装目录特殊字符转义；Ubuntu libnuma 下载及缓存校验 SHA256，Ubuntu 22.04 x265 缓存与较新系统隔离。Linux PR 自动执行只读构建和打包，发布附件仍需独立手动授权步骤，不随合并自动发布。
- Linux 仍为预览平台；既有 v0.4.4 预览附件不变。本轮回归与构建检查不替代 Linux 发行版桌面和目标图库验收。
- PR #12 合并前的 GitHub CI 全部通过；Ubuntu 22.04 实际构建并打包 0.4.5 AppImage/tar.gz，核心最高 GLIBC 需求为 2.35，附件上传仅为 workflow artifact，未上传 Release。WSL 另验证 3 种安装路径和 4 种 libnuma 缓存/下载校验场景。

- 升版后 Rust 自动回归 258 passed / 7 ignored，两项显式启用的原图回归通过；Flutter 143 项测试通过，FFI 实读核心版本 `0.4.5` 与主 pubspec 一致。
- 修复按共享 Rust 核心实现，已做 Windows 主机验证；Android、macOS、iOS 与鸿蒙的安装包和目标图库仍需在正式发布前验收。
- 正式对外下载仍为 v0.4.4。待验收后再决定是否创建 `v0.4.5` 标签与发布安装包。
