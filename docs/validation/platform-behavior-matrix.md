# Windows / Android / iOS 平台行为矩阵

> 用于冻结平台边界，避免导入、输出和队列逻辑继续分叉。

## 1. 平台职责

| 能力 | Windows | Android | iOS |
|---|---|---|---|
| 默认引擎 | Rust | Rust | Rust |
| 输入入口 | 文件选择器、桌面拖拽、分享导入 | 文件/媒体选择器、分享导入 | PHPicker 相册、Files 文件选择器、分享导入 |
| 输入副本 | 直接使用用户可访问路径 | 必要时复制 `content://` 到临时目录，再物化到持久输入目录 | 选择器返回临时文件，复制到持久输入目录 |
| 输出目录 | 用户配置目录 / 输出目录 | App 专属外部目录 `output/` | App Documents `output/` |
| 输出到系统图库 | 不提供 | `Gal.putImage`，支持相册分类 | `Gal.putImage`，支持相册分类 |
| 分享 | `share_plus` | `share_plus` | Runner 原生 `UIActivityViewController` |
| 打开输出 | Explorer 定位 | `open_filex` + `image/*` | `open_filex` + HEIC UTI |
| 批量后台 | 托盘 / 桌面进程 | Foreground Service | 不承诺后台持续转换 |

## 2. 当前导入流程

### Windows

1. 文件选择器或原生拖拽得到路径。
2. 过滤 `.heic` / `.heif`。
3. 进入统一分类、Portrait 预检查和队列。
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

- Rust 是 Windows、Android、iOS 的默认转换引擎。
- 输入照片先物化为 App 可持续访问的副本，再进入队列。
- Android 的“所有文件访问”不是必需权限；只用于尝试保留原始路径和 GPS。
- Android 用户拒绝该权限时仍允许继续导入，但使用 `content://` 原始字节副本。
- Windows 不显示“保存到相册”，只提供文件系统操作、分享和打开。
- 移动端已完成输出卡片使用“保存到相册 / 分享 / 打开”，队列管理使用重试、移出和清除已完成。

## 4. 下一轮审计重点

1. Android 各系统版本及 OPPO 设备上确认权限降级路径。
2. Windows 输出目录、重名覆盖和 Explorer 定位行为统一文案。
3. 三端统一“取消、失败、重试、清除”的状态转换。
4. 将平台行为矩阵中的规则补成自动化测试和 Release 验收清单。
