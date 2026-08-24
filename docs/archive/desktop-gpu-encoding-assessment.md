# 桌面 GPU 加速 HEVC 编码评估

> 整理日期：2026-07-31
> 状态：**暂缓**（仅评估，未实现）。前置参考：Android 端已通过 MediaCodec 实现硬件编码（见 `android-hardware-encoding-plan.md`），桌面端尚未做。

## 背景

README 路线图曾列「GPU 加速 HEVC 编码（h265_amf / hevc_nvenc 替代 libx265 软件编码）」。
`docs/next-phase-plan.md` 暂缓项表已有初步结论：x265 软编码在 512×512 tile 上已够快，GPU 编码器对 tiny tile 增益有限。本文档补充完整评估，供后续决策。

## 现状

- 桌面端（Windows / macOS）当前走 **x265 静态链接软编码**（全平台同一路径）。
- Windows 已启用 x265 SIMD 汇编（AVX2），v0.1.9 实测 9MB ProXDR HEIC ~8.6s，其中 tile 编码只占一部分（JPEG 解码、gain map 重建、tile 切分、ISOBMFF 组装各占时间）。
- Android 端硬件编码（MediaCodec）单 tile ~40ms，但那是 ARM 无 SIMD 软编才慢；桌面 SIMD 后瓶颈已不在编码器。

## 桌面 GPU 编码器选项

| 编码器 | 厂商 | Windows 可用性 | 集成途径 |
|--------|------|----------------|----------|
| **NVENC** | NVIDIA | N 卡驱动自带 | ffmpeg `hevc_nvenc`，或 Rust 绑定 nvEncodeAPI |
| **AMF** | AMD | A 卡驱动自带 | ffmpeg `hevc_amf`，或 Rust 绑定 AMF |
| **QSV** | Intel | 核显/独显 | ffmpeg `hevc_qsv`，或 Media Foundation H.265 |
| **Media Foundation** | 微软 | 系统级，任意支持 H.265 的硬件 | Windows MF API（Rust 无成熟绑定） |
| **VideoToolbox** | Apple | macOS | `hevc_videotoolbox`（ffmpeg）或 Swift |

## 关键约束

1. **桌面 GPU HEVC 编码器只支持 4:2:0**（NVENC/AMF/QSV 均无 4:4:4 HEVC 编码）。桌面当前输出 4:4:4 RGB gain map（iOS/兼容性保证），切 GPU 会降级到 4:2:0——与 Android 硬件路径相同的问题。
2. **集成途径都不理想**：
   - ffmpeg 子进程（`hevc_nvenc` 等）：需要重新引入 ffmpeg 依赖（v0.1.9 刚移除了 Windows ffmpeg 捆绑），且每个 tile 起一个子进程开销大（或需长驻进程 + 帧流协议）。
   - Rust 侧平台 FFI 绑定：nvEncodeAPI / AMF 绑定工作量大、N 卡/A 卡/Intel 分平台维护。
3. **收益不对称**：512×512 单帧 tiny tile，GPU 编码器启动/会话开销占比高，吞吐未必超过 SIMD x265；真正的瓶颈在解码/重建/组装，非编码器。

## 结论

- **不建议近期做**。桌面 x265 软编已够快；GPU 编码带来 4:2:0 降级 + 平台特定复杂度 + 依赖引入，收益有限。
- **若未来做**（如追求极限吞吐或省电），推荐路径：
  1. 复用 Android 硬件路径的「prepare → 外部编码 → assemble」分离架构（`xdremux_prepare_tiles` / `xdremux_assemble_tiles` 已通用化），桌面侧实现一个「外部编码器」实现。
  2. 优先 Windows Media Foundation（系统级、覆盖 N/A/I 三家）而非 ffmpeg 子进程；macOS 用户已在用 VideoToolbox（用户 Mac 侧处理）。
  3. 接受 4:2:0 输出，或仅对大图/批量场景启用，与 OPPO 兼容模式冲突时回退 4:4:4 x265。

## 触发时机

- 用户报告桌面软编过慢（当前无此类反馈）。
- 需要批量转换超大图库时，先测桌面实际瓶颈分布再决定是否值得。
- 引入 ffmpeg 作为通用多媒体后端（当前无此计划）。

## 决策记录

- 2026-07-31：评估完成，**暂缓**。与 `next-phase-plan.md` 暂缓项表一致。README 路线图保留该条但标注「待评估」。
