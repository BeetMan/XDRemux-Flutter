# 0.4.4 候选整合与 Flutter 升级

日期：2026-10-15。用户授权：整合候选代码、将本次修复提交主线，再升级 Flutter，交付验收；不创建 tag、不发布 Release。

## 范围

- 基于远端 main `6e6a184b`，在独立工作区整合；不重置本地历史分叉的 main，不改原工作区未提交文件。
- 整合此前 JPEG HDR 元数据、可选 libheif 解码、Rust 主图预览、codec 诊断、Apple MakerNote 保留、Windows 测试工具，以及本次 Live Photo 完整导出、手机布局和安全区修复。
- 不包含电影模式、鸿蒙原生应用改动、签名配置、私有样片、预编译 DLL 和构建产物。libheif 仍为可选功能，不默认为所有平台启用。
- 功能整合与 Flutter 升级分别提交，方便回退。升级采用独立 SDK 路径，保留现有 C:/flutter 3.44.5，避免影响其他工作区及鸿蒙适配工具链。

## 任务

- [x] 核对远端 main 与各候选工作区；保留原工作区状态。
- [x] 汇入候选源码，合并 main.dart 的导出/UI 与 codec 诊断接入。
- [x] Flutter 3.44.5 下整合回归：141 passed；完整 analyze 无问题。Rust 默认核心 226 passed / 3 ignored，可选 libheif 核心 227 passed / 3 ignored。
- [x] 功能修复提交 `00a0068f`（59 个文件）已快进推送 origin/main；未改本地历史分叉的 main。
- [x] Flutter 3.47.7 / Dart 3.13.5 独立 SDK（C:/Users/Beet/.codex/sdks/flutter-3.47.7），提交指纹 abaf9c5237；6 处 CI/release 版本固定同步，apps/flutter/.fvmrc 记录版本。仅 SDK 需要的 matcher/meta/test_api/vector_math 4 个锁定依赖变化，业务插件不批量升级，镜像配置保留。
- [x] 新 SDK 下 141 项测试及完整静态分析通过，Android ARM64 debug 与 Windows x64 release 编译通过。测试宿主适配补丁后另行复测并记录；Windows 本地验收包显式开启 libheif，正式 CI 默认 feature 未改。
- [x] 框架升级单独提交，准备 Android 同证书签名测试 APK 与 Windows 完整便携包；验收清单见下文，未自动安装新包或发布 Release。

## 验收边界

iOS PhotoKit 的单资产双资源保存、macOS/iOS 原生编译需 Mac/iPhone 验收。Android 独立保存 HEIF/MOV 不等于原生系统实况。Flutter OHOS 多文件分享尚未实现；鸿蒙原生已有独立的成对文档导出，不把本次 Flutter 修改当作原生已同步。

本次暂不升级正式应用版本号，不将主线提交等同于 0.4.4 / 原生 0.5.1 已发布。用户验收前保留正式发布门槛。

## 整合验证记录

- 采用现有主线/Live Photo 测试分支的镜像 lockfile，新增测试 dev dependency 仅将 path_provider_platform_interface 2.1.3 标为直接测试依赖。未纳入原 Windows 候选中与本轮无关的批量插件升级和 pub.dev 源切换。`pub get --enforce-lockfile` 通过。
- x265 复用本机已构建的目标静态库；新建候选工作区重新构建 Rust 默认 DLL 并用于实际 FFI 测试，不提交 DLL。libheif 回归使用此前已构建的固定版本 prefix，不改变默认发行 feature。
- 完整日志位于忽略的 target 下：flutter-baseline-tests.log、flutter-baseline-analyze.log、rust-default-tests.log、rust-libheif-tests.log。
- 初次主线 CI 的 Conformance 与 OHOS Rust smoke 通过；Flutter Linux job 发现 2 项缩略图测试假定 Windows 原生通道。补丁 e062d2ff 添加仅供测试注入的 renderer，让缓存/队列测试跨宿主执行；生产默认 native/FFI 路径不变，不以跳过测试规避。
- Flutter 自动迁移 analysis_options.yaml，排除 build 与各原生平台生成目录；现有 lib/test/integration_test 仍分析。未升级 AGP/Kotlin；Android 构建存在 Kotlin 2.3.10 未来需至少 2.3.20 与 Java 8 源/目标兼容的预警，不使用跳过验证开关。
- e062d2ff 后新 SDK 完整回归仍为 141 passed，Android ARM64 与 Windows release 已重新增量编译。Windows 包内 FFI smoke：11/11 输入的转换、Styles 图结构、PNG 主图预览及原图哈希通过（合成 4:2:0/4:2:2/4:4:4/高位深/旋转和两个公开 Apple gain-map JPEG）。这是程序化包内调用，不冒充真实选择器或 Photos 编辑验收。

## 本地验收产物

- Android：`dist/XDRemux-Android-candidate-Flutter-3.47.7.apk`，SHA256 `8A337A401AAE66F4B07D2EDD5A3BBA25B9C475BE992B3C0C69A04502F0C6B38A`。发布证书与现有安装一致，debuggable，版本仍为 0.4.3+37；可保留数据覆盖安装，但会重启并可能丢失未开始转换的内存队列。本次未自动安装。
- Windows：`dist/XDRemux-Windows-x64-0.4.3-candidate-flutter3.47.7.zip`，16,508,770 bytes，SHA256 `174a0fcfaa5477ed9022f8675bd8f888f0119d059c3b04582e5f6c11be827223`。包含 libheif 1.23.4 / libde265 1.1.3 与本地 MSVC runtime、许可说明和候选验收说明，manifest 记录 37 个文件。不可只取 exe。
- SDK 升级不改应用正式版本号；不以本地 Windows feature-on 包替代所有平台的正式默认 decoder 构建。

## 用户验收清单

本候选仍使用 0.4.3+37 的应用版本标识，以包名和 Flutter 3.47.7 区分，尚未打正式 0.4.4 标签。Windows 便携版请完整解压到新目录，可能与已安装版共享设置；原图保留，选择独立输出目录。

1. Android：添加原始 OPPO/华为实况，三种模式往返切换时卡片不跳、不溢出；主页和照片详情按钮与系统导航条有留白；手势导航和三键导航分别验收。
2. Android：Live Photo 单项/全部/自动保存都能找到 HEIF 和 MOV；分享配对原文件有两个附件；静帧模式不附带无关 MOV；权限拒绝或部分失败不提示完整成功。
3. Windows：单选/多选/中文路径/拖放、彩色预览与方向、摄影风格开关、codec 诊断复制/导出、批量取消重试；转换实况后输出同 stem HEIF/MOV，两文件一起传输。
4. Apple：在 Mac 编译本次 main；iPhone 应用内直接保存后在照片中是一个可播放、有声音的 Live Photo；权限拒绝与再次保存、原件仍在；macOS Photos 导入和投送分别验收。此前一组产物经 Mac 投送到 iPhone 正常不替代这一步。
5. 鸿蒙原生 0.5.1 暂未同步本次源码，Flutter OHOS 多文件分享暂不支持，不计入本次两个本地验收包完成范围。
