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
| [live-photo-pvt.md](formats/live-photo-pvt.md) | Apple Live Photo `.pvt` 包结构、写入规则、照片 App 导入验证 |

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
| [flutter-app.md](app/flutter-app.md) | 页面/服务/模型结构、术语规范、双语层 |
| [workflow-design.md](app/workflow-design.md) | 四步工作流状态机、donor 配对、检查点 |
| [motion-photo-ui-design.md](app/motion-photo-ui-design.md) | 动态照片四档策略、识别时机、3a/3b 设计记录 |
| [android-integration.md](app/android-integration.md) | SAF 原则、原生组件、构建锁死项、调试速查 |
| [apple-integration.md](app/apple-integration.md) | macOS dylib 打包、iOS 静态库、分发现状 |

## 测试与运维

| 文档 | 内容 |
|---|---|
| [testing/conformance-suite.md](testing/conformance-suite.md) | 对拍套件、golden corpus、加用例流程 |
| [testing/styles-hdr-device-checklist.md](testing/styles-hdr-device-checklist.md) | Styles HDR 缩略图真机 A/B 测试清单（样本矩阵、自动预检、Photos 步骤、判定口径） |
| [operations/building.md](operations/building.md) | 跨平台构建（含 Linux 本地开发）、变体说明（含鸿蒙 hap） |
| [operations/releasing.md](operations/releasing.md) | 发版清单、资产命名、鸿蒙本地发布、历史踩坑 |
| [operations/ci.md](operations/ci.md) | 四 workflow 剖析、runner 矩阵 |
| [operations/current-status.md](operations/current-status.md) | **当前开发状态快照**：版本/分支地图/能力现状/已知风险/下一步 |

## 写作与证据规范

| 文档 | 内容 |
|---|---|
| [style-guide.md](style-guide.md) | 术语表、文档类型与模板、证据三类标记（已实测/推断/未验证）、排版与双语规则、提交前清单 |

## 研究记录（research/）

| 文档 | 内容 |
|---|---|
| [local-transfer-poc.md](research/local-transfer-poc.md) | 内置传输 P0：固定 LocalSend Rust 核心、Windows/Android 双向保真及平台边界 |
| [harmonyos-support.md](research/harmonyos-support.md) | 鸿蒙支持研究全记录（已落地为正式平台） |
| [motion-photo-parser-differential.md](research/motion-photo-parser-differential.md) | Motion Photo 解析器 Swift/Python/Rust 三方差分（12/12） |
| [styles-upstream-logic-comparison.md](research/styles-upstream-logic-comparison.md) | key1 布局 + constrained solver 研究（研究闭环定案） |
| [styles-upstream-20261024-gap.md](research/styles-upstream-20261024-gap.md) | 上游 Styles 分支 vs 我方差距（2026-10-25，含差距矩阵与 P0 建议） |
| [x265-main10-feasibility-20261025.md](research/x265-main10-feasibility-20261025.md) | x265 Main10（10-bit）可行性：multilib 构建/链接配方、单帧 Rext 坑、接入风险 |
| [gainmap-decode-feasibility-20261025.md](research/gainmap-decode-feasibility-20261025.md) | tmap 增益图解码可行性：item 布局实测、rust_h265 仅支持 4:2:0、三条可行路径 |
| [cast-to-key1-study.md](research/cast-to-key1-study.md) | cast→key1 映射研究（结论：不存在文件级映射） |
| [reverse-key1-eval-20260825.md](research/reverse-key1-eval-20260825.md) | ReverseKey1 Core ML 批量评估（34 样本） |
| [native-fidelity-gap.md](research/native-fidelity-gap.md) | 合成输出 vs iPhone 原生差距分析（含联合编辑终局实验） |
| [upstream-issue-macos27-private-api.md](research/upstream-issue-macos27-private-api.md) | macOS 27 私有 API issue 草稿（已关闭：上游自修） |
| [oppo-gallery-17.10.5.md](research/oppo-gallery-17.10.5.md) | ColorOS 相册 17.10.5 静态阅读：HDR / 编辑 / 人像机制、OPPO 尾部布局实测、Find X8 Ultra 前置人像与大水印 |
| [upstream-20261030.md](research/upstream-20261030.md) | 上游 PR #83–#88 进展与差距矩阵（2026-10-30）：Standard key1 identity 争议、GPLv3 改授权、研究仓迁移；含 P0/P1/P2 规划 |

## 路线图

- [内置局域网文件传输开发计划](plans/local-transfer-plan.md)：LocalSend 互操作、独立 Rust 服务、Flutter 收发及照片资源分组（2026-10-17，P0 Windows/Android 验证通过，P1 待开发）。

- [`docs/plans/v0.4-roadmap.md`](plans/v0.4-roadmap.md)：当前版本路线图（Phase 1 质量闭环 ✅ → Phase 2 ReverseKey1 评估关闭 → Phase 3 动态照片 ✅ → Phase 4 性能与分发）
- [`docs/plans/huawei-to-apple-plan.md`](plans/huawei-to-apple-plan.md)：Mate 70 原生 HDR 识别、XMAGE 风格、人像与 Live Photo 研究计划（普通 HDR 无需转换）
- [`docs/plans/sample-collection-202608.md`](plans/sample-collection-202608.md)：样本采集计划（A~E 组状态见 v0.4-roadmap 与设备兼容矩阵）

## 历史文档

- `docs/standards/`：ISO 21496-1 / 23008-12 中译（formats/ 页面的标准依据，仍在引用）
- `docs/validation/`：平台行为矩阵 + 设备兼容矩阵（**在维护**，排障时对照）
- `docs/archive/`：历史阶段计划、交接备忘、已完成清单与一次性验证报告。仅作考古参考，内容可能与现状不符

## 维护纪律

完整规则见 [style-guide.md](style-guide.md)（术语表、文档模板、证据三类标记）。要点：

1. 发版检查单含"相关 docs/ 页面是否更新"；发版/合并后更新 [operations/current-status.md](operations/current-status.md)
2. 代码注释引用文档页（如 `// see docs/formats/oppo-watermark.md §band-detection`）
3. `docs/` 在 .gitignore 中，新增文档需 `git add -f docs/<path>`
4. 中文为主，box 名/字段名保留英文；术语按 style-guide §1.2 锁定写法
5. 技术断言必须标「已实测 / 推断 / 未验证」并给可复现证据；**CI 绿 ≠ 真机验收**
6. 引用上游（21Z121Z1/XDRemux）必须写 `branch @ commit` 与是否已并入 `upstream/main`，不能把未合并分支说成"上游已支持"

