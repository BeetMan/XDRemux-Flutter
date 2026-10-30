# Standard key 1 色格判定（2026-10-30）

**问题**：上游 21Z121Z1/XDRemux PR #88（分支 `cursor/fix-proxdr-styles-key1-color-db95`，未合并）判定 Standard 风格的 key 1 不能用 primary→thumbnail 拟合：Photos 把 key 1 当 remove-style 多项式作用在**显示主图**上，而缩略图码 `S = scene × h / key4` 与主图差一个 gain-map 比值（含 h/key4 = 0.46 的曝光比），这个比值放不进有界二次多项式；clamp 后交叉项填满，在 Photos 编辑器里画出 12×9 红/绿/青色格。上游改为 `apple_style_standard_key1` 直接返回 identity，并加回放函数 `apple_style_apply_local` 与回归测试 `standard_key1_stays_identity_when_the_recovered_ratio_is_outside_the_box`。

我方 `xdremux/rust/src/styles_fit.rs::revert_local_style_data`（PR #33，P1-1）是同一设计（`bb66981b`）的移植，盒子更窄（±1/8 常数/一次、±1/16 二次；上游 `dfed3af` 后为 ±1/4、±3/16）。本会话只读上游 diff，不 cherry-pick。

## 方法

1. 回放函数：`styles_fit::apply_style_data` 已存在，与上游 `apple_style_apply_local` 同一数学（同一 spotlight 空间权重、同一亮度平面权重、half 值含 identity 对角）。本次补了 `plane_sum <= 0` 守卫、`mean_abs_chroma_delta`（上游同名指标）与两条单元测试：identity payload 不改像素；上游 RGB 增益 fixture 拟合后回放会改变色度（chroma > 0.02）。
2. `examples/styles_convert` 用现有管线转换 3 张 OPPO 样张（`test-media/sources/oppo-camera-heic/`），`examples/styles_key1_color_probe` 从输出文件**读回** styleMetadata 里的 51 840B key 1，在同一文件主图的 Linear Thumbnail 几何、显示方向线性光栅上回放，计算 ΔE76（CIE Lab, D65）、上游 chroma 指标、ΔL*、12×9 格均值色度偏移与相邻格差（cell-edge Δab），输出 before / after / ΔE 热图 / ×8 色度偏移图 PNG。
3. 对照：identity payload（应为 0）；`exposure-only` = 用同一主图、**不带增益图**重新拟合（thumbnail = primary × h / key4），用于分离曝光比与 gain-map 比值。

命令（仓库根目录）：

```bash
cargo test --release -p xdremux-core --lib styles_fit
cargo build --release -p xdremux-core --example styles_convert --example styles_key1_color_probe
for n in IMG20260802135928 IMG20260814202514 IMG20260822150037; do
  ./target/release/examples/styles_convert /Volumes/MacData/XDRemux/test-media/sources/oppo-camera-heic/$n.heic <out>/$n-styles.heic
done
./target/release/examples/styles_key1_color_probe <out> <out>/IMG20260802135928-styles.heic <out>/IMG20260814202514-styles.heic <out>/IMG20260822150037-styles.heic
```

## 结果（main `fa8930c` 管线，2026-10-30 本机）

| 样张 | 光栅 | file key1 ΔE76 mean / p95 / max | chroma | ΔL* mean | cell-edge Δab | exposure-only ΔE76 mean / p95 / max |
|---|---|---|---|---|---|---|
| IMG20260802135928（室内人像） | 1024×768 | 2.93 / 5.26 / 16.39 | 0.063 | −2.57 | 0.77 | 2.81 / 4.93 / 10.03 |
| IMG20260814202514（夜景车） | 1024×768 | 2.15 / 6.20 / 23.06 | 0.634 | −0.99 | 1.17 | 2.24 / 6.05 / 9.44 |
| IMG20260822150037（竖幅街景） | 988×1024 | 2.15 / 5.11 / 15.43 | 0.068 | −0.62 | 1.00 | 3.69 / 9.49 / 19.67 |

identity 对照三张均为 0。完整输出（含 12×9 格表）：

```text
<out>/IMG20260802135928-styles.heic
  raster 1024x768, key1 identity=false
  file key1      ΔE76 mean 2.93  p95 5.26  max 16.39 | chroma 0.0634 | ΔL* mean -2.57 | cell-edge Δab 0.77
  12×9 cell map of |mean (Δa*, Δb*)| (rows = y cells, columns = x cells):
      3.3   5.8   5.7   3.4   0.4   1.2   0.9   0.2   0.4   0.4   1.3   2.4
      1.2   1.9   2.0   1.1   0.7   0.9   0.5   0.2   1.7   1.3   0.6   0.4
      1.2   1.2   0.9   1.1   0.6   1.4   0.1   0.4   1.1   0.8   0.7   0.0
      1.7   1.2   0.7   1.0   1.6   2.0   0.4   0.5   0.7   0.7   0.4   0.3
      1.8   1.4   0.7   1.0   1.6   2.2   0.5   0.7   0.7   0.9   0.5   0.3
      1.1   1.1   0.6   0.8   0.7   1.1   0.2   0.9   0.5   1.4   1.4   0.4
      1.2   1.3   0.9   0.5   1.5   0.3   0.3   0.9   0.9   1.1   1.1   0.3
      1.7   1.8   0.9   0.7   1.4   0.2   0.0   0.9   0.9   0.2   0.7   1.2
      1.0   0.9   0.5   0.6   1.0   0.3   0.7   0.8   0.8   0.6   1.2   1.6
  identity       ΔE76 mean 0.00  p95 0.00  max 0.00 | chroma 0.0000 | ΔL* mean +0.00 | cell-edge Δab 0.00
  exposure-only  ΔE76 mean 2.81  p95 4.93  max 10.03 | chroma 0.0587 | ΔL* mean -2.54 | cell-edge Δab 0.65
  wrote <out>/IMG20260802135928-styles-{before,after,deltae,chroma}.png
<out>/IMG20260814202514-styles.heic
  raster 1024x768, key1 identity=false
  file key1      ΔE76 mean 2.15  p95 6.20  max 23.06 | chroma 0.6338 | ΔL* mean -0.99 | cell-edge Δab 1.17
  12×9 cell map of |mean (Δa*, Δb*)| (rows = y cells, columns = x cells):
      0.5   0.6   0.7   0.4   0.1   0.1   0.1   0.0   0.1   0.7   1.7   0.1
      1.4   1.2   1.3   0.6   1.2   0.7   0.1   0.5   0.5   0.8   1.6   0.0
      7.0   4.9   7.3   3.6   0.9   1.7   0.5   0.2   1.2   0.6   1.1   0.1
      1.6   1.1   1.7   1.3   2.1   2.0   0.6   1.2   1.7   0.4   0.5   0.8
      0.7   0.4   0.8   0.5   0.3   0.7   0.5   1.1   3.1   1.7   0.6   0.5
      3.1   2.1   0.8   2.4   2.9   4.7   3.0   0.8   2.1   2.5   0.5   0.3
      1.9   0.6   2.0   5.2   4.9   4.3   1.4   0.5   0.4   0.7   0.3   0.3
      1.5   0.5   1.8   4.4   3.2   1.3   0.2   0.3   0.3   0.4   0.3   0.4
      1.1   0.9   1.5   1.9   1.8   1.0   0.1   0.1   0.2   0.1   0.3   0.4
  identity       ΔE76 mean 0.00  p95 0.00  max 0.00 | chroma 0.0000 | ΔL* mean +0.00 | cell-edge Δab 0.00
  exposure-only  ΔE76 mean 2.24  p95 6.05  max 9.44 | chroma 0.0965 | ΔL* mean -2.06 | cell-edge Δab 0.47
  wrote <out>/IMG20260814202514-styles-{before,after,deltae,chroma}.png
<out>/IMG20260822150037-styles.heic
  raster 988x1024, key1 identity=false
  file key1      ΔE76 mean 2.15  p95 5.11  max 15.43 | chroma 0.0676 | ΔL* mean -0.62 | cell-edge Δab 1.00
  12×9 cell map of |mean (Δa*, Δb*)| (rows = y cells, columns = x cells):
      0.4   0.4   0.6   0.2   0.4   0.2   0.3   0.2   0.2   0.4   0.5   0.4
      1.5   0.7   0.4   1.1   2.2   1.1   2.5   2.2   2.4   2.0   1.7   0.6
      1.6   4.2   1.5   1.5   1.8   0.9   2.5   0.5   1.2   0.5   0.6   0.7
      1.5   2.1   1.5   1.6   0.9   0.9   1.9   4.0   2.4   1.6   0.8   0.6
      0.2   0.1   0.5   0.4   0.9   1.2   2.3   1.6   1.3   1.4   1.5   0.9
      0.0   0.1   0.5   0.1   1.0   0.5   0.9   0.9   0.4   0.9   0.5   0.3
      0.3   0.4   0.4   0.8   2.4   1.6   1.3   2.2   1.7   0.6   0.8   0.2
      0.5   0.8   0.8   0.8   1.0   0.8   0.6   0.7   0.9   0.5   0.9   0.7
      0.2   0.1   0.2   0.1   0.1   0.0   0.4   0.4   0.6   0.7   0.6   0.7
  identity       ΔE76 mean 0.00  p95 0.00  max 0.00 | chroma 0.0000 | ΔL* mean +0.00 | cell-edge Δab 0.00
  exposure-only  ΔE76 mean 3.69  p95 9.49  max 19.67 | chroma 0.0454 | ΔL* mean -3.31 | cell-edge Δab 0.61
  wrote <out>/IMG20260822150037-styles-{before,after,deltae,chroma}.png
```

PNG（会话 scratchpad，未入库）：`<scratch>/out/<stem>-{before,after,deltae,chroma}.png`。

## 判读

- **机理复现**：三张的 key 1 都不是 identity，回放到主图后色度确实被改写，偏移按 12×9 格分布（格表里相邻格 0.x ↔ 4–7 的跳变；×8 色度图可见格状/块状的品红↔绿交替），这正是上游描述的"交叉项填满"现象。
- **来源是曝光比，不是增益图**：`exposure-only`（无增益图重拟合）给出几乎相同的 ΔE 均值与 ΔL*，说明仅 h/key4 = 0.46 这一项就已超出盒子，与上游"a nearly gray gain map still does it"一致；增益图只把最大值（高光）从 ~10 推到 16–23。
- **幅度**：我方盒子（±1/8、±1/16）下 ΔE76 均值 2–3、p95 5–6、最大 16–23，ΔL* −0.6 ~ −2.6；超过 JND（≈2.3）但没到上游宽盒子（±1/4、±3/16）报告的"红/绿/青色格"量级。也就是说：拟合没有达到目标（key 1 RMSE 只比 identity 低 25–38%，见 §4.1 原记录），却付出了可见的、与内容/格位相关的色偏。
- **未验证**：Photos 真实渲染（本模型是拟合端假设的消费端；Photos 编辑器拉滑块时的实际观感要靠维护者截图）；上游宽盒子在我方样张上的幅度未测（常量在 `styles_fit.rs`，本会话不改生产路径）。

## 建议（去留）

**Standard 的 key 1 回 identity**（与上游 #88 同向），保留 key 3 GTC 与 HDR 线性缩略图（它们不作用在主图上，不产生色格）。实施时只需让 `fit_style_state` 不再把 `revert_local_style_data` 的结果写进 `style_state.key1`（或在 `styles_native.rs` 的注入处跳过 key 1），保留拟合与回放函数作诊断；`fit_style_state_beats_identity_on_scene_pair` 中 key 1 的断言随之改为文档性测试。本会话未改生产路径。
