# Android 硬件编码（MediaCodec HEVC）规划

> 整理日期：2026-07-31
> 前置状态：v0.1.9 正式版已发布；MediaCodec 探针已集成；4:2:0 gain map 可行性已在 OPPO PKJ110（骁龙 8 Elite / SM8750）真机验证通过（OPPO 图库提亮/编辑正常，iOS 相册 HDR 增强正常）。

## 背景

当前 Android 转换瓶颈在 gain map 的 HEVC 编码——x265 软件编码（NEON 加速后 ~8.6s/张）。目标是用 MediaCodec 硬件编码器提速（预期 8.6s → 1-2s）。

**已确认的关键事实**（探针 + 4:2:0 测试）：
- 设备只有 4:2:0 硬件编码器，无 4:4:4（`config444Flexible: ok` 是 configure() 假阳性）
- 4:2:0 gain map 在 OPPO 图库和 iOS 相册都正常工作
- gain map tile 是 512×512 偶数尺寸，MediaCodec 4:2:0 可直接喂
- Android 无 SELinux 限制问题（编码是进程内调用，不走子进程）

## 架构决策

**编码器分离**：Rust 侧新增可插拔的 tile 编码接口，x265 和 MediaCodec 作为两个实现。

```
当前: isobmff_write → encode_hevc_tile_gray/rgb (x265 in-process)
目标: isobmff_write → [x265 | MediaCodec] 任选
```

- MediaCodec 实现在 Dart/原生层（`MediaCodec` API）
- Rust 侧负责生产 YUV420 帧数据并交给 Dart
- 失败时无缝回退 x265（软编保底）

## 实施步骤

### 阶段 1：Rust 暴露"帧数据"接口
- 新增 FFI `xdremux_encode_tile_pixels(...)`：把 tile 的 RGB/灰度像素 → YUV420 平面（复用已验证的 `rgb_to_yuv420`）
- 返回 YUV 数据给 Dart，不编码

### 阶段 2：Dart 封装 MediaCodec 编码器
- `MediaCodecHevcEncoder` 类：`encode(yuv420, w, h) -> HEVC` 单帧
- 内部：创建编码器（`video/hevc`，4:2:0）、喂 input buffer、收 output buffer、拼 HEVC NAL
- 收尾：从第一个输出 NAL 提取 VPS/SPS/PPS 生成 hvcC（复用 `extract_hvcc_config`）

### 阶段 3：编排 + 回退
- 优先试 MediaCodec（探测可用 → 首帧编码 → 成功则用），失败回退 x265
- 加"硬件编码"开关（设置页，默认开）

### 阶段 4：打包 + 验证
- CI 不变（Android 构建已含 NDK）
- 真机验证：速度提升、画质、回退路径

## 风险与权衡

| 风险 | 影响 | 缓解 |
|------|------|------|
| 硬件编码器质量/一致性 | 画质下降、芯片间不一致 | 保留 x265 回退；跑速度+画质对比 |
| 多 tile 拼接细节 | 多 tile 时序/参考帧 | gain map 每 tile 独立关键帧，无跨 tile 依赖 |
| 冷门芯片无 HEVC 编码器 | 硬件编码不可用 | 回退 x265 |
| 功耗/温控降频 | 高温反而更慢 | 真机长测；必要时限制并发 |

## 工作量预估

| 阶段 | 工作量 |
|------|--------|
| 1. Rust 帧数据接口 | 0.5 天 |
| 2. Dart MediaCodec 封装 | 1.5 天（难点：output buffer 时序） |
| 3. 编排 + 回退 | 0.5 天 |
| 4. 打包 + 真机验证 | 1 天 |
| **合计** | **约 3.5 天** |

最快收益路径：先做阶段 1+2+4 的最小闭环（验证速度提升量），再补回退和开关。

## 待决策

- [ ] Android 是否所有 tile 都走硬件编码，还是只给大图/高分辨率用
- [ ] 硬件编码默认开启，还是先做出来测过再定
- [ ] 后续是否把 x265 回退路径也统一到 4:2:0（现在默认 4:4:4，与硬件路径不一致）
