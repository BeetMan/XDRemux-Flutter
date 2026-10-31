# 平台行为矩阵（Windows / Android / macOS / iOS / 鸿蒙；Linux 与原生 Apple 见 §1.1）

> 用于冻结平台边界，避免导入、输出和队列逻辑继续分叉。

## 1. 平台职责

| 能力 | Windows | Android | macOS | iOS | 鸿蒙 |
|---|---|---|---|---|---|
| 默认引擎 | Rust | Rust | Rust | Rust | Rust |
| 输入入口 | 文件选择器、桌面拖拽、分享导入 | 文件/媒体选择器、分享导入 | 文件选择器、桌面拖拽、Apple 照片拖入 | PHPicker、Files 文件选择器、分享导入 | file_picker（vendored）、PhotoViewPicker 图库原图、sendData 分享 |
| 输入副本 | 直接使用用户可访问路径 | 必要时复制 `content://` 到临时目录，再物化到持久输入目录 | 直接使用用户可访问路径 | 选择器返回临时文件，复制到持久输入目录 | file:// URI 拷到缓存后物化 |
| 输出目录 | 用户配置目录 / 输出目录 | App 专属外部目录 `output/` | 用户配置目录 / 输出目录 | App Documents `output/` | App 私有目录，可保存图库 |
| 输出到系统图库 | 不提供 | `Gal.putImage`，支持相册分类 | 不提供 | `Gal.putImage`，支持相册分类 | PhotoAccessHelper（gallery_saver fork） |
| 分享 | `share_plus` | `share_plus` | `share_plus` | Runner 原生 `UIActivityViewController` | share_extend（vendored fork） |
| 打开输出 | Explorer 定位 | `open_filex` + `image/*` | Finder 定位 | `open_filex` + HEIC UTI | open_filex fork |
| 批量后台 | 托盘 / 桌面进程 | Foreground Service | 托盘 / 桌面进程 | 不承诺后台持续转换 | 桌面级进程（无前台服务需求） |

### 1.1 不在上表中的目标（2026-10-31）

- **Linux x64（Flutter，预览发布）**：Rust FFI（`bundle/lib` 内的 .so）；XDG Desktop Portal 文件选择与 GTK 拖放；无平台原生解码通道（缩略图走 Rust 回退）；不提供保存到系统图库与托盘；「在文件夹中显示」用 `xdg-open` 打开所在目录。依据：`architecture/platform-backend.md`、`main.dart` `_revealInExplorer`。其余行未逐项核对，补列前需实机确认。
- **原生 Apple（SwiftUI，`apps/apple`，未发布）**：文件导入、拖放、iOS PhotosPicker（保留 HEIC 原始字节）；输入复制到容器内，journal 以 `~/…` 存容器内路径；iOS 以 `.photo` + `.pairedVideo` 写入照片库，macOS 用保存面板 / 选文件夹整组存储 / 访达定位；不产出 `.pvt`。计划 P4 要求逐项对照本矩阵的 macOS / iOS 两列，差异要么修掉要么写入本页。依据：`docs/plans/apple-native.md` P3 执行记录。

## 2. 当前导入流程

### Windows

1. 文件选择器或原生拖拽得到路径。
2. 过滤 `.heic` / `.heif`。
3. 进入统一分类和队列；独立人像模式实验室页面及其入口当前在所有平台关闭，设置中的人像模式开关保留。
4. 输出路径由用户配置决定。

### Android

1. 请求媒体权限。
2. 没有 `MANAGE_EXTERNAL_STORAGE` 时询问用户是否授权。
3. 选择器返回 `content://` 时优先尝试真实 MediaStore 路径；否则通过原生 `ContentResolver` 复制原始字节。
4. 持久化到 App 输入目录后进入统一队列。
5. 这样区分是为了尽量保留 OPPO HEIC 的 GPS，同时兼容 scoped storage。

### iOS

1. “添加”按钮弹出“从相册选择 / 从文件选择”。
2. PHPicker 仅导入具有 HEIC/HEIF 原始资源的照片。
3. Files 入口仍使用 `file_picker`。
4. 两条路径最终都进入相同的导入、预检查、分类和队列流程。

## 3. 已确认的产品规则

- Rust 是所有平台与所有前端（Flutter、鸿蒙原生、原生 Apple）的默认且唯一的产品转换引擎；Swift/Vision 后端只是研究路径。
- 输入照片先物化为 App 可持续访问的副本，再进入队列。
- Android 的“所有文件访问”不是必需权限；只用于尝试保留原始路径和 GPS。
- Android 用户拒绝该权限时仍允许继续导入，但使用 `content://` 原始字节副本。
- Windows 不显示“保存到相册”，只提供文件系统操作、分享和打开。
- 移动端已完成输出卡片使用“保存到相册 / 分享 / 打开”，队列管理使用重试、移出和清除已完成。

## 4. Apple / OPPO 文件往返文案与能力

统一使用以下词汇：

- **Apple 照片**：指 Apple Photos App；不再在产品文案中写“Apple 相册”。
- **OPPO 原始照片**：指来自 OPPO 手机的原始照片（donor）；“原机水印”指该文件中的可见水印。
- **可见原机水印**：指已经绘制在图像画面中的水印，不等同于水印元数据。
- **元数据**：对应 metadata；**OPPO 私有尾部数据**：对应 OPPO footer。
- **Apple 标准**：表示不追加 OPPO 私有信息的输出模式，不宣称 Apple 官方逐像素或私有协议等价。
- **OPPO 兼容**：表示恢复 OPPO 兼容结构、元数据和尾部数据的输出模式。

各平台写回统一使用 Rust HEIF 编解码器（x265 全平台内建），行为一致：

| 平台 | Apple 标准输出 | OPPO 兼容输出 |
|---|---|---|
| Windows / Android / macOS / iOS / 鸿蒙 | Rust HEIF 编解码器；可按 OPPO 原始照片恢复可见原机水印，不追加 OPPO 私有信息 | Rust HEIF 编解码器恢复可见原机水印、元数据和 OPPO 私有尾部数据 |

macOS / iOS 仍保留 Swift/ImageIO 写回实现作为研究路径，但默认不再调用。

未勾选“恢复原机水印”时，保留 iPhone 回传画面；OPPO 兼容模式仍会写回 OPPO 元数据和尾部数据。

## 5. 下一轮审计重点

1. ~~Android 各系统版本及 OPPO 设备上确认权限降级路径。~~（2026-08-27 真机回归覆盖）
2. Windows 输出目录、重名覆盖和 Explorer 定位行为统一文案。
3. ~~三端统一「取消、失败、重试、清除」的状态转换。~~（五端已统一走同一队列模型）
4. 将平台行为矩阵中的规则补成自动化测试和 Release 验收清单。
