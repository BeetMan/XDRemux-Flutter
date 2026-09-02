# 上游 v1.4 未同步项清单（2026-09-02）

> v1.4 对比基础：`21Z121Z1/XDRemux @ 8930811`。同步状态详见会话记录，
> 本清单只列**剩余未做**项，按优先级排序。

## P1（小改动，建议下个版本）—— ✅ 全部完成（2026-09-02, 02dbdd9）

- [x] **批量恢复 provenance 校验**：恢复时 `livePhotoPairValid` 校验 HEIC+MOV 配对，
  缺失/不匹配降级 failed 待重转。
- [x] **不静默覆盖已有 Live Photo 资源**：MOV/导出视频序号避让（`X 2.mov`）。
- [x] **更清晰的报告**：新增 `skippedPolicy` 状态区分「按策略跳过」与「已是转换产物」。

## P2（需要设计）

- [ ] **14 个版本化 Motion Photo fixtures 移植**：上游回归资产，可直接用于我们的
  conformance 测试。
- [ ] **严格的 HEIF/ISO-BMFF 边界检查**：上游加固的容器校验规则。
- [x] **styles+pair 组合档**：2026-09-03 终局实验（预测非身份 key1 + pair）与 identity+pair
  同样失败——联合编辑加载是 Apple 结构性拦截，与风格内容无关。互斥转为永久设计约束，
  本项关闭（见 docs/research/native-fidelity-gap.md 终局实验节）。

## 已确认不可行 / 无需同步

- ~~ReverseKey1 模型跨平台推理~~（方案 B，Neutrino 门禁限制）
- ~~Python 实现~~（我们是 Rust 主路径）
- CLI（我们是 GUI）
