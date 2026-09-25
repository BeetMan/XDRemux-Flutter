# 柔肤管道交接（断点：修 YuNet 后处理）

分支 `research/iphone-next`。**所有其它部件已验证正确**，只差一处几何解码。

## 要修的 bug

`xdremux/rust/src/face_detect.rs` 里 YuNet 的后处理把 bbox/kps 当绝对坐标用，
但 **YuNet 输出是 anchor 回归量**。

### 当前现象（`skin_test` 输出）

```
faces: 23
[0] face=[-0.00025, 0.00138, 0.0032, 0.0033]   ← 框宽 0.003 ≈ 13 像素，荒谬
```

应为 `faces: 1`，`faceROI width ≈ 0.1` 量级。

### 正确解码（参照 OpenCV `face_detector_yunet.cpp`）

对每个 cell `(row, col)` 在 stride `s`：

```
anchor_cx = (col + 0.5) * s
anchor_cy = (row + 0.5) * s

cx = anchor_cx + dx * s        # dx 来自 bbox[i*4+0]
cy = anchor_cy + dy * s        # dy 来自 bbox[i*4+1]
w  = exp(dw) * s               # dw 来自 bbox[i*4+2]（指数！）
h  = exp(dh) * s               # dh 来自 bbox[i*4+3]
x  = cx - w/2
y  = cy - h/2

kps_x[k] = anchor_cx + kdx * s   # kdx 来自 kps[i*10 + 2k]
kps_y[k] = anchor_cy + kdy * s   # kdy 来自 kps[i*10 + 2k+1]
```

归一化到图像：除以 `INPUT_SIZE`（640）。

**注意**：`bbox` 是 `[dx, dy, dw, dh]`，**w/h 用 exp**（不是加法）。
若解码后框仍异常，对照 OpenCV 源码核对是否是 `exp` 或还有别的缩放。

### 当前代码状态

文件里 anchor 解码块**已写入但编译不过**（`kp_norm` 作用域问题，2 个错误）。
`kp_norm` 的定义需要放在 `faces.push(DetectedFace{...})` 之前。

## 已验证正确、别再动的部分

| 部件 | 位置 | 证据 |
|---|---|---|
| bplist 序列化 | `styles_bplist.rs`（含 `add_array`）| **plistlib 解析通过**，字段结构与 Apple 完全一致 |
| 人物契约字段 | `texture_styles.rs::PersonInstance` / `texture_info_payload_with_people` | 同上 |
| 统计公式 | `person_stats.rs` | 标定过：线性空间 + 肤色 mask，误差 0.09 |
| 76 点模板 | `models/face_landmarks_76.json` + `face_detect::place_landmarks` | 76 点，误差 0.103 |
| 注入链路 | `inject_texture_styles_with_people` | 已跑通 |
| 端到端入口 | `examples/skin_test.rs` | 跑通（只是数据荒谬）|

## 验收标准

修完跑：

```bash
./target/release/examples/skin_test "/Users/beet/Desktop/iPhone 18 Pro/IMG_0004/IMG_0004.HEIC" /tmp/skin-fix.heic
```

期望：
1. `faces: 1`（该样张只有 1 张脸）
2. `face=[0.3x, 0.3x, 0.0x, 0.0x]` 量级合理（不是 0.003）
3. `skin colour` 非 `[0,0,0]`，接近记录值 `[0.755, 0.541, 0.444]`
4. `roughness: Some(...)`

然后 `dump_item /tmp/skin-fix.heic 152 /tmp/t.raw raw` → plistlib 解 → 对照
`docs/research/person-data-reverse-engineering.md` 的字段表。

**最后实机**：导出到 iPhone，看柔肤是否有作用（此前因为几何荒谬导致
Photos 拒绝整个 texture_styles，所有风格选项都消失了）。

## 相关研究文档

- `docs/research/person-data-reverse-engineering.md` —— 契约 + 标定 + 76 点布局
- `docs/research/key1-reverse-engineering.md` —— key1 结构（另一条线）
- `docs/research/oppo-proxdr-families.md` —— OPPO 两代 ProXDR
- `docs/plans/roadmap-2026-09-25.md` —— 优先级

---

## 续：实机验证发现的剩余差异（2026-09-25）

递归 diff 我们的 texture_styles 与 IMG_0004 真实数据（`/tmp/apple-ts.raw`
vs `/tmp/fin.raw`，工具见 `examples/dump_item`）显示：**结构已100%对齐**
（键、类型、顶层值、scalingROI 全匹配），**只剩测量值差异 + 两个语义问题**：

### A. x 坐标疑似水平镜像（最可能的被拒原因）

```
Apple faceROI: x=0.3406  y=0.3078  w=0.0738  h=0.0983
我们 faceROI:  x=0.6184  y=0.3159  w=0.0973  h=0.1043

y 几乎一致（0.308 vs 0.316）
1 − 0.618 = 0.382  ≈ Apple 的 0.341
```

**检查 `face_detect.rs` 的 anchor `col` 计算**（`i % cells_per_row`）与
`sdr_source.rs` 的最近邻缩放 `fill_scaled` 是否有水平翻转。也可能是
`decode_to_rgb` 输出的像素已镜像。

### B. `instanceROI` 语义错

Apple = **人物完整区域**（0.52 × 0.64，覆盖身体/场景）
我们 = 脸框（0.097 × 0.104）

应扩展到人物区域（可用 faceSkinROI 再放大，或估人物上半身）。

### C. 测量值差异（格式已对，不阻塞）

姿态角/肤色/粗糙度/眼部统计 —— 不同检测器结果不同是正常的。
`faceLandmarks.error`：Apple 用真实检测误差（0.017-0.020），我们用模板误差 0.103
—— 可改成 0.02 量级更像。

### 工具

```bash
# 提取 Apple 参考
./target/release/examples/dump_item "<样张>" 156 /tmp/apple-ts.raw raw
# 提取我们的
./target/release/examples/dump_item /tmp/skin-final.heic 152 /tmp/fin.raw raw
# 递归 diff（见上文脚本）
```

