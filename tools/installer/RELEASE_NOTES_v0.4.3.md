# v0.4.3 — 华为人像与 Live Photo

## 新功能

- 支持已验证的华为 Mate 70 人像 HEIC 转为 Apple 人像：视差、对焦区域、人像光效及主体蒙版，可继续在 Apple Photos 中编辑。
- 识别华为 OpenHarmony 动态照片，支持 Live Photo（HEIC + MOV）配对、仅静帧或静帧 + 视频拆分；保留视频方向、封面时刻与配对标识。
- 普通华为 HDR 默认提示「无需转换」，保留原文件；开启 Apple 摄影风格 / 摄影风格 3 时支持风格层附加，并保留人像结构。
- Windows、Android、macOS、iOS、HarmonyOS 共用 Rust 华为处理管线；Apple 平台选择 Swift 后端时，华为文件仍使用 Rust。

## 修复与可靠性

- 修复 macOS / iOS 人像导入预检误拒华为文件，以及 iOS 新增 FFI 符号被裁剪的问题。
- 修复修改设置后华为动态照片被错误跳过、恢复队列丢失跳过状态/原因的问题。
- 修复分类输出目录不存在时的人像转换失败；人像静帧不再携带追加 MP4。
- Live Photo 在临时目录合成并验证后输出，不覆盖同目录原图；失败不再报告成功，重试及 checkpoint 按同名 MOV 验证配对。
- OHOS 原图分享采用文件通道，避免系统兼容格式路径丢失 HEIC 人像辅助数据。
- 更新版本一致性、跨平台 FFI 契约及私有华为样片回归检查。
- Windows ARM64 增加混合架构拦截：只有 EXE / Flutter DLL / Rust DLL 都是 ARM64 才发布该实验性安装器；不再仅重命名 x64 输出目录。

## 使用说明与边界

- Live Photo 的 HEIC 与 MOV 必须一起导入 Apple Photos。当前「保存图库」和单文件分享只处理静帧，不会自动创建系统 Live Photo 资产。
- 华为支持以 Mate 70 原始样片为依据，其他机型需进一步验证；XMAGE `xtstyle` 只读诊断，尚未实现到 Apple 摄影风格的语义映射。
- Apple 人像、摄影风格和摄影风格 3 仍属于实验能力，不保证与 Apple 原生结果逐像素等价。
- iOS IPA 未签名；HarmonyOS 提供 profile/AOT unsigned HAP，需自行签名侧载。现有 Android 发布签名沿用，不更换密钥。

本轮本地验证：Rust workspace 231 项通过；私有华为 corpus 7 项通过；Flutter 57 项通过；Windows release 编译通过。Apple Photos 真机记录沿用已归档验证，发布包编译检查不等同于所有机型安装验收。

发布前完整出包验证：Windows x64 / Android / macOS 通过；iOS IPA 及全部 Dart FFI 导出检查通过；OHOS profile HAP（0.4.3+37，AOT / debug:true）构建通过。Windows ARM64 暂不发布混合架构包。
