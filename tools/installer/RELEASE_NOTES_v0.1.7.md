# XDRemux v0.1.7

新功能与体验改进：

- **Android 分享接收**：相册或文件管理器中选中 HEIC → 分享 → XDRemux，文件直接进入转换队列，无需先打开 App 再找文件。
- **转换完成系统通知**：批量转换结束时弹出系统通知（Windows toast / Android notification），显示成功/跳过/失败数量，后台批量转换不用盯着。
- 修复 Windows toast 不显示的问题：Inno Setup 快捷方式增加 `AppUserModelID`，这是 WinRT toast 的前置条件。
- README 补 Android 截图。

版本号 `0.1.7+9`，继续使用稳定 release 签名密钥，可直接覆盖升级。
