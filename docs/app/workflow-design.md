# 工作流设计（四步状态机）

> UI：`apple_oppo_workflow_page.dart`；编排：`apple_oppo_workflow_service.dart`；持久化：`checkpoint_service.dart`。

## 1. 四步流程

```
① 选择 OPPO 原始照片 ──► ② 生成 Apple 编辑副本 ──► ③ iPhone 编辑后传回 ──► ④ 写回输出
        (SAF/文件选择)        (createAppleStylesCopy)      (分享/拖放导入)      (writebackReturnedPhoto)
```

设计史：v0.3.0 前是五步（含中间 baseline）；baseline 会带增益映射图，二次转换产生**双增益映射图 + 重复引用结构**，已删除。现行方案**直接从 OPPO 原始照片做单次 styles 转换**，原始照片同时充当后续写回的 donor。

## 2. 关键约束

1. **donor 配对**：步骤①选择的原始照片 = 步骤④的写回 donor（其相机尾部含最完整的水印/元数据）。两者必须配对保存，不配对则写回质量降级（水印恢复失败）
2. **产物目录**：`<app>/xdremux_workflow/`，文件名前缀配对（如 `IMG20260819191729.apple-edit.heic` 与 `IMG_3506.oppo-final.heic`）
3. **输出模式**（步骤④选择）：OPPO 兼容（恢复可见原机水印 + 元数据 + OPPO 私有尾部数据）/ Apple 标准（保留回传画面，不追加 OPPO 私有信息）
4. **恢复原机水印开关**：不勾选时保留 iPhone 回传画面；OPPO 兼容模式仍写回元数据和尾部数据

## 3. 检查点与恢复

- checkpoint_service 按 donor 记录进行到的步骤与相关文件路径
- 中断后重进：检测到已有配对产物时提示续跑或重来
- Android 后台转换依赖前台服务保活（见 `android-integration.md`）

## 4. 失败路径

所有失败向用户呈现为可读错误（对应 Rust 报告的 `errorMessage`），典型：

- 水印恢复失败（检测不到画布/边框带）-> 失败关闭，不输出半成品
- 尺寸不一致 / 容器结构异常 -> 同上
- 写回成功但自检（`outputValid`）失败 -> 视为失败
