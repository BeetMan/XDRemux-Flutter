# Motion Photo 解析器三方差分验证（2026-08-27）

> 对象：上游 Swift（`21Z121Z1/XDRemux @ 8930811`，v1.4）、上游 Python
> （同仓库 `xdremux_py/motion_photo.py`）、我们的 Rust 移植
> （`xdremux/rust/src/motion_photo.rs`，ae4e0e0）。

## 方法

12 个合成 fixture（`/tmp/mp-corpus`），三方探针输出统一 JSON，比对
判定结果（kind / still / video / pts / streams / primary / error）：

- Swift 探针：上游克隆临时 `mp-probe` executable（`OppoMotionPhotoParser.parse`，
  与 Python `parse_motion_photo` 同级的顶层入口）
- Python 探针：直接调 `xdremux_py.motion_photo`
- Rust 探针：`xdremux/rust/examples/mp_probe.rs`（已入库）

## 结果：12/12 判定一致

| fixture | 内容 | 三方判定 |
|---|---|---|
| 01 | JPEG Motion Photo V1 | `androidMotionPhotoV1`，范围/PTS 全同 |
| 02 | legacy MicroVideo | `legacyMicroVideoV1b`，全同 |
| 03 | HEIF mpvd | `androidHeifMotionPhotoV1`，全同 |
| 04 | OPPO 单码流 + LPEX v0 | `oppoLivePhoto` streams=1，全同 |
| 05 | OPPO 双码流 + LPEX v1 | `oppoLivePhoto` streams=2，primary=第一码流，全同 |
| 06/07 | 普通 JPEG / HEIC | 均判非动态照片 |
| 08 | 视频长度超文件大小 | 均拒绝 |
| 09 | XMP 含 DTD | 均拒绝（安全规则一致） |
| 10 | MotionPhotoVersion=2 | 均拒绝 |
| 11 | OPPO 纯厂商 tail 回退（无标准目录） | `oppoLivePhoto`，全同 |
| 12 | HEIF 目录长度与 mpvd 不符 | 均拒绝 |

## 已知的非语义差异（可接受）

1. **错误文案不同**：Swift 报枚举名（`arithmeticOverflow`、`invalidByteRange`、
   `malformedXMP`），Python/Rust 报描述字符串。判定（接受/拒绝）一致，
   文案不做对齐。
2. **XML 严格度**：Python 用 ElementTree（命名空间严格），Swift 与我们
   Rust（quick-xml）都不做命名空间解析。未声明 `Container:` 前缀的
   畸形 XMP 会被 Swift/Rust 接受而被 Python 拒绝。真实机型文件总是带
   命名空间声明，属可接受差异；本次 fixture 初版恰好踩到这个差异，
   也借此确认了三方在正常文件上行为一致。

## 边界

- OPPO 真机动态照片尚未验证（上游真实 fixture 为私有，未随 git 分发）；
  OPPO 路径目前只有合成 fixture 覆盖，等采样计划 E 组到货后复跑本验证。
- `motion_photo.rs` 未移植 LPEX 矩阵字段（EIS/crop matrices，Live Photo
  合成才需要），3a 阶段不影响。
