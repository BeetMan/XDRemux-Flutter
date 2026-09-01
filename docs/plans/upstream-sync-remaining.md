# 上游 v1.4 未同步项清单（2026-09-02）

> v1.4 对比基础：`21Z121Z1/XDRemux @ 8930811`。同步状态详见会话记录，
> 本清单只列**剩余未做**项，按优先级排序。

## P1（小改动，建议下个版本）

- [ ] **批量恢复 provenance 校验**：上游在 batch resume 复用已有资源对前验证源文件
  provenance。我们的 checkpoint 已有 size+mtime 校验，但 Live Photo 配对输出（HEIC+MOV）
  复用时未校验 MOV 侧一致性。实现：恢复时用 `livePhotoPairValid` 校验已有配对。
- [ ] **不静默覆盖已有 Live Photo 资源**：转换输出 MOV 已存在时应按序号避让而不是覆盖。
- [ ] **更清晰的报告**：区分「格式不支持」与「已是转换产物」两类跳过。

## P2（需要设计）

- [ ] **14 个版本化 Motion Photo fixtures 移植**：上游回归资产，可直接用于我们的
  conformance 测试。
- [ ] **严格的 HEIF/ISO-BMFF 边界检查**：上游加固的容器校验规则。
- [ ] **styles+pair 组合档**：当前互相冲突（style 编辑加载失败），等 A 组 iPhone
  风格样本逆向后再决定是否重开。相关代码已保留（`append_live_photo_entry`）。

## 已确认不可行 / 无需同步

- ~~ReverseKey1 模型跨平台推理~~（方案 B，Neutrino 门禁限制）
- ~~Python 实现~~（我们是 Rust 主路径）
- CLI（我们是 GUI）
