# Flutter 应用结构

> 代码：`apps/flutter/`。页面、服务、状态管理的代码视角；数据流见 `architecture/data-flow.md`，后端选择见 `architecture/platform-backend.md`。

## 1. 页面清单

| 页面 | 文件 | 说明 |
|---|---|---|
| 主工作流 | `apple_oppo_workflow_page.dart` | "一帧影像，动用两台手机"四步工作流（产品主入口） |
| 批量整理 | `organize_page.dart` | 批量转换/整理 |
| 人像实验室 | `apple_portrait_page.dart` | 入口已隐藏，设置开关保留（研究功能） |
| Rust 人像 | `rust_portrait_page.dart` | Rust 人像探针页 |

页面是 StatefulWidget + 本地状态；工作流状态（步骤、文件路径、输出模式）不落全局 store，持久化交给 checkpoint_service。

## 2. 服务层

见 `architecture/overview.md` §3 的服务清单表。分层规则：

- **UI 页面只调 service**，不直接摸 FFI / MethodChannel
- `xdremux_service.dart` 是 Rust FFI 的唯一门面：负责平台分流、`Isolate.run` 包装、JSON 报告 -> 异常 的翻译
- `apple_oppo_workflow_service.dart` 编排工作流三动作：`createAppleStylesCopy` / `writebackReturnedPhoto` / `preserveAppleReturnedPhoto`

## 3. 模型

- `app_models.dart`：输出模式（**OPPO 兼容 / Apple 标准**，术语固定）、转换选项
- `checkpoint_model.dart`：检查点持久化模型（donor 与回传文件配对）

## 4. 原生桥（MethodChannel）

Android `MainActivity.kt`：

| Channel | 职责 |
|---|---|
| `xdremux/battery` | 电池/省电状态（后台转换决策） |
| `xdremux/hevc-probe` | MediaCodec HEVC 能力探测 |
| `xdremux/hw-encode` | 硬件编码（`MediaCodecHevcEncoder.kt`） |
| `xdremux/thumbnail` | ImageDecoder 缩略图 |

macOS/iOS：Swift 后端桥（研究路径，见 `architecture/platform-backend.md` §4）+ iOS Share Extension（`ios/Share Extension/ShareViewController.swift`，接收相册分享）。

## 5. 更新机制

`update_service.dart`：静默查 GitHub `/releases/latest`（自动跳过 pre-release），有新版时 SnackBar 提示。不做强制更新、不做自更新。

## 6. 术语规范（UI 文案）

统一使用：**Apple 照片 / OPPO 原始照片 / 原机水印 / 元数据 / OPPO 私有尾部数据**；输出模式只说 **OPPO 兼容 / Apple 标准**。7/11 档策略等内部细节不进 UI。
