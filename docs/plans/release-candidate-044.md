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
- [ ] 提交功能修复到主线。
- [ ] Flutter 3.47.7 独立 SDK 与 CI 版本同步；只处理升级必需的依赖变化。
- [ ] 新 SDK 下测试、静态分析、Android 和 Windows 编译。
- [ ] 提交框架升级并交付验收包及检查清单。

## 验收边界

iOS PhotoKit 的单资产双资源保存、macOS/iOS 原生编译需 Mac/iPhone 验收。Android 独立保存 HEIF/MOV 不等于原生系统实况。Flutter OHOS 多文件分享尚未实现；鸿蒙原生已有独立的成对文档导出，不把本次 Flutter 修改当作原生已同步。

本次暂不升级正式应用版本号，不将主线提交等同于 0.4.4 / 原生 0.5.1 已发布。用户验收前保留正式发布门槛。

## 整合验证记录

- 采用现有主线/Live Photo 测试分支的镜像 lockfile，新增测试 dev dependency 仅将 path_provider_platform_interface 2.1.3 标为直接测试依赖。未纳入原 Windows 候选中与本轮无关的批量插件升级和 pub.dev 源切换。`pub get --enforce-lockfile` 通过。
- x265 复用本机已构建的目标静态库；新建候选工作区重新构建 Rust 默认 DLL 并用于实际 FFI 测试，不提交 DLL。libheif 回归使用此前已构建的固定版本 prefix，不改变默认发行 feature。
- 完整日志位于忽略的 target 下：flutter-baseline-tests.log、flutter-baseline-analyze.log、rust-default-tests.log、rust-libheif-tests.log。
