# XDRemux 技术文档索引

面向贡献者与逆向研究者的技术文档体系。产品介绍见根目录 `README.md`。

## 阅读路径

**新人上手**：overview -> data-flow -> platform-backend
**排障定位**：platform-backend（先确定看哪份代码）-> 对应模块页
**格式逆向**：formats/ 全部 + `docs/standards/`（ISO 标准中译）
**改 FFI**：ffi-contract（必读契约）
**发版**：operations/releasing

## 架构（architecture/）

| 文档 | 内容 |
|---|---|
| [overview.md](architecture/overview.md) | 仓库布局、四层架构、服务清单、版本策略 |
| [data-flow.md](architecture/data-flow.md) | 转换与写回两条主数据流、平台后端矩阵 |
| [platform-backend.md](architecture/platform-backend.md) | 各平台实现路径、文件访问规则、打包踩坑 |
| [ffi-contract.md](architecture/ffi-contract.md) | Dart↔Rust FFI 契约、内存协议、导出清单 |

## 格式逆向（formats/）-- 本项目核心资产

| 文档 | 内容 |
|---|---|
| [oppo-proxdr.md](formats/oppo-proxdr.md) | ProXDR 文件解剖、尾部 manifest、LHDR/UHDR、尾部策略 |
| [oppo-watermark.md](formats/oppo-watermark.md) | 两类水印、画布几何、边框带检测校准、编码约定 |
| [apple-photographic-styles.md](formats/apple-photographic-styles.md) | 风格编辑图层结构、bplist、生成策略 |
| [iso-21496-1-gainmap.md](formats/iso-21496-1-gainmap.md) | 增益映射转换与编码约束 |
| [hevc-hevc-conventions.md](formats/hevc-hevc-conventions.md) | 范围/矩阵/传输函数实测约定、双解码器验证法、陷阱清单 |

## Rust 模块（modules/）

| 文档 | 内容 |
|---|---|
| [container-isobmff.md](modules/container-isobmff.md) | 容器解析/重建、rewrite_primary_grid 手术模板 |
| [hevc-x265.md](modules/hevc-x265.md) | 编码 API 面、调用纪律、四平台 x265 构建 |
| [styles-pipeline.md](modules/styles-pipeline.md) | 风格管线 scaffold->assemble、引用图语义 |
| [watermark-restore.md](modules/watermark-restore.md) | 水印恢复 API 与不变量 |
| [portrait-pipeline.md](modules/portrait-pipeline.md) | 人像深度转换、disparity 标定现状 |

## 应用（app/）

| 文档 | 内容 |
|---|---|
| [flutter-app.md](app/flutter-app.md) | 页面/服务/模型结构、术语规范 |
| [workflow-design.md](app/workflow-design.md) | 四步工作流状态机、donor 配对、检查点 |
| [android-integration.md](app/android-integration.md) | SAF 原则、原生组件、构建锁死项、调试速查 |
| [apple-integration.md](app/apple-integration.md) | macOS dylib 打包、iOS 静态库、分发现状 |

## 测试与运维

| 文档 | 内容 |
|---|---|
| [testing/conformance-suite.md](testing/conformance-suite.md) | 对拍套件、golden corpus、加用例流程 |
| [operations/building.md](operations/building.md) | 四平台构建、变体说明 |
| [operations/releasing.md](operations/releasing.md) | 发版清单、资产命名、历史踩坑 |
| [operations/ci.md](operations/ci.md) | 三 workflow 剖析、runner 矩阵 |

## 路线图

- [`docs/plans/v0.4-roadmap.md`](plans/v0.4-roadmap.md)：当前版本路线图（Phase 1 质量闭环 → Phase 2 ReverseKey1 评估 → Phase 3 动态照片 → Phase 4 性能与分发）

## 历史文档

- `docs/standards/`：ISO 21496-1 / 23008-12 中译（formats/ 页面的标准依据，仍在引用）
- `docs/validation/`：平台行为矩阵（**在维护**，排障时对照）
- `docs/archive/`：历史阶段计划、交接备忘、一次性验证报告（v0.3.0 前）。仅作考古参考，内容可能与现状不符

## 维护纪律

1. 发版检查单含"相关 docs/ 页面是否更新"
2. 代码注释引用文档页（如 `// see docs/formats/oppo-watermark.md §band-detection`）
3. `docs/` 在 .gitignore 中，新增文档需 `git add -f`
4. 中文为主，box 名/字段名保留英文
