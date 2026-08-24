# Android 集成

> 代码：`apps/flutter/android/`。包名 `io.github.beetman.xdremux`（发布）/ `com.example.xdremux`（MainActivity 包路径，历史遗留）。

## 1. 文件访问原则

**SAF（Storage Access Framework），不默认索取存储权限。**

- 导入：ACTION_OPEN_DOCUMENT / receive_sharing_intent（相册分享直达）
- 导出：MediaStore 写入或 SAF 保存对话框，分享走系统分享面板
- 工作流产物：应用私有目录 `app_flutter/xdremux_workflow/`（`/data/data/<pkg>/`），调试时用 `adb exec-out run-as <pkg> cat <path>` 拉取（注意：`adb shell` 会有 CRLF 污染，必须 exec-out）

## 2. 原生组件

| 组件 | 职责 |
|---|---|
| `MainActivity.kt` | 四个 MethodChannel（电池 / HEVC 探测 / 硬编码 / 缩略图） |
| `MediaCodecHevcEncoder.kt` | MediaCodec 硬件 HEVC 编码（硬件_encoder 服务探测/使用） |
| `flutter_foreground_task` | 后台转换前台服务 + 通知 |
| `receive_sharing_intent`（固定 1.8.1） | 接收相册分享 |

## 3. 构建配置（历史踩坑，勿动）

- **compileSdk 36 / build-tools 36.0.0**：GitHub runner 无 Android API 37；根 `build.gradle.kts` 强制 library 插件 compileSdk=36
- **JVM target 分插件对齐**：`receive_sharing_intent` -> 17，`flutter_foreground_task` -> 11（统一会炸 `Inconsistent JVM-target compatibility`）
- `receive_sharing_intent` 锁 1.8.1（新版行为变化）
- 原生库：`cargo ndk -t arm64-v8a -o apps/flutter/android/app/src/main/jniLibs build --release -p xdremux-core` -> `libxdremux_core.so` + `libc++_shared.so`

## 4. 真机调试速查

```bash
export MSYS_NO_PATHCONV=1   # Git Bash 必须
adb install -r app-debug.apk
adb exec-out run-as io.github.beetman.xdremux ls app_flutter/xdremux_workflow/
adb exec-out run-as io.github.beetman.xdremux cat app_flutter/xdremux_workflow/xxx.heic > out.heic
```

验证矩阵：ColorOS 相册打开 / Windows 照片（WIC）打开 / heif-oxide 解码（交叉参考）。
