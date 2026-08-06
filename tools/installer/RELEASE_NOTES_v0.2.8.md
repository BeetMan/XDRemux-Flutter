# XDRemux v0.2.8

设置面板整理 + Android 稳定性修复。

- **设置面板重新整理**：主屏的「OPPO 兼容」快捷开关移除；Auto/X6/X7、OPPO 兼容模式、OPPO 相机尾部元数据、严格 ISO tmap 四项收进默认折叠的「高级模式」菜单，带红色警示「不建议更改，可能影响相册兼容性」——关闭 OPPO 兼容 + 不保留相机尾部会剥离 QTI 元数据，导致转换结果在 OPPO 相册中无法识别。
- **Android 缩略图崩溃修复**：解码失败的 HEIC 不再写入 `ConcurrentHashMap`（其禁止 null value，会抛 NPE 崩溃），改为只缓存成功结果，失败走 FFI 兜底。
- **Android 权限修复**：未授予「所有文件访问」时，真实路径 `File.exists()` 报告存在但 Rust 原生读取报 `Permission denied`。现在真实路径解析（MediaStore `_data` + DCIM 目录）仅在 all-files access 已授予时生效，未授权时统一走 content-URI 副本，预览与转换恢复正常；GPS 保留仍需授权。

版本号 `0.2.8+18`。Windows / Android 平台产物随本 Release 提供。
