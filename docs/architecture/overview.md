# 系统总览

> XDRemux：将 OPPO / OnePlus / realme 的 ProXDR HEIC 转换为 ISO 21496-1 HDR HEIC，并面向 OPPO 图库或 Apple 照片生成对应格式。核心工作流："一帧影像，动用两台手机"。

## 1. 仓库布局

```
XDRemux-Flutter/
├── xdremux/rust/            # Rust 核心引擎（~20K 行）
│   ├── src/
│   │   ├── container.rs        # HEIF 容器层：tail 解析/重建、水印几何
│   │   ├── isobmff.rs          # ISO BMFF box 解析
│   │   ├── isobmff_write.rs    # box 构造（iloc/iref/ipma/iinf/meta 重建）
│   │   ├── hevc.rs             # x265 编码（tile 策略、色彩路径）
│   │   ├── gainmap.rs          # 增益映射转换（UHDR -> ISO 21496-1）
│   │   ├── iso21496.rs         # ISO 21496-1 元数据
│   │   ├── edr.rs              # EDR/亮度处理
│   │   ├── exif.rs             # EXIF 读写
│   │   ├── categorize.rs       # 输入文件分类
│   │   ├── jpeg_decode.rs      # JPEG 解码（增益映射载荷）
│   │   ├── styles_bplist.rs    # Apple 二进制 plist 写入器
│   │   ├── styles_scaffold.rs  # 风格容器脚手架
│   │   ├── styles_native.rs    # 原生风格装配（蒙版/天空分层）
│   │   ├── styles_graft.rs     # 从金样移植风格图
│   │   ├── portrait*.rs        # 人像模式（disparity/depth/graft/scaffold）
│   │   ├── watermark_codec.rs  # 水印恢复（画布路径 + 边框带检测）
│   │   ├── x265_ffi.rs         # x265 FFI 绑定
│   │   ├── x265_helper.c       # C++ 桥（picture/param 结构体字段）
│   │   └── lib.rs              # FFI 导出层（23 个 C ABI 函数）
│   ├── examples/               # 诊断探针（styles_diag/wb_probe/tail_dump 等）
│   └── build_ios.sh            # iOS 交叉编译（x265 + Rust 静态库）
├── apps/flutter/            # Flutter 跨平台应用
│   ├── lib/
│   │   ├── apple_oppo_workflow_page.dart   # 主工作流 UI（四步）
│   │   ├── apple_portrait_page.dart        # 人像实验室（入口隐藏，设置开关保留）
│   │   ├── organize_page.dart              # 批量整理
│   │   ├── services/                       # 见下
│   │   └── ffi/xdremux_ffi.dart            # Dart FFI 绑定
│   ├── macos/XDremuxMacBackend/            # macOS Swift 后端（研究路径）
│   └── ios/SwiftBackend/                   # iOS Swift 后端（研究路径）
├── tests/conformance/       # 一致性测试套件（独立 crate）
├── tools/installer/         # Inno Setup 安装脚本 + 发布说明
└── .github/workflows/       # CI/发布流水线
```

## 2. 分层架构

```
┌─────────────────────────────────────────────┐
│ Flutter UI（页面 + 服务）                     │
│   apple_oppo_workflow / organize / portrait  │
├─────────────────────────────────────────────┤
│ Dart FFI 绑定（xdremux_ffi.dart）            │
│   Isolate 隔离 + JSON 报告协议               │
├─────────────────────────────────────────────┤
│ Rust 核心（libxdremux_core）                 │
│   转换 / 写回 / 分类 / 缩略图 / 进度          │
│   x265 静态内建（四平台）                     │
├─────────────────────────────────────────────┤
│ 平台层（解码预览 / 文件访问 / 前台服务）       │
│   WIC / ImageDecoder / ImageIO / SAF        │
└─────────────────────────────────────────────┘
```

核心设计原则：

1. **Rust 核心承载全部媒体处理**，四平台行为一致；平台原生 API 只做 UI 集成辅助（解码预览、文件选择、通知）
2. **失败关闭**：格式不认识、几何不匹配、尺寸不一致都直接报错，不输出猜测结果
3. **输出可编辑优先**：目标是"Apple 照片里能继续编辑 / ColorOS 图库里像原机照片"，不承诺与 Apple 原生逐像素等价

## 3. Flutter 服务层

| 服务 | 职责 |
|---|---|
| `apple_oppo_workflow_service` | 主工作流编排：生成 Apple 副本、写回、保留模式 |
| `xdremux_service` | Rust FFI 调用门面（含平台分流） |
| `conversion_backend` | 后端选择（Rust / Swift） |
| `checkpoint_service` + `checkpoint_model` | 中断恢复（donor 与回传文件配对） |
| `picked_file_resolver` | 工作流文件选择（保留 GPS） |
| `file_action_service` / `drop_file_service` | 打开/分享/拖放 |
| `foreground_service` / `notification_service` | Android 后台转换保活 |
| `tray_service` | 桌面托盘 |
| `hardware_encoder` | 硬件编码探测 |
| `update_service` | 静默检查 GitHub Release（自动跳过 pre-release） |

## 4. 版本与发布

- 版本号单一来源：Rust `Cargo.toml`（v0.3.1 起应用报告的核心版本从 Cargo 读取）
- 资产命名：`XDRemux-<平台>-<完整tag版本><-Setup>.<后缀>`，pre-release 含 `-pre.N`
- 发布说明手写在 `tools/installer/RELEASE_NOTES_v*.md`，tag 与 Release 文案由维护者掌控
- 详见 `operations/releasing.md`（待写）
