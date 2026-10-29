# 柔肤管道交接

分支 `research/iphone-next`。最新断点在下面「当前断点（2026-10-29）」；
其后的各节按时间顺序保留，YuNet 解码（`ea1d6de`）与 9-25 的容器损坏都已解决。

## 当前断点（2026-10-29）

### 结论：`c630b93` 根治了 9-25 的容器损坏，根因是 mime infe 缺 `content_type`

样张 `IMG_0004.HEIC`，`skin_test` 全流程（faces: 1 → 转换 → person 数据 → 实例遮罩）：

- 输出能被 ImageIO 解码：`sips -s format png` 成功（4284×5712），顶层 box、iinf 153 项、
  iloc 全部 extent 都在文件内。
- 新增的 infe 与 Apple 的 157/158 **逐字节一致**（除 item id）：
  hvc1 `flags=1, name=""`；mime `flags=1, name="", content_type="application/rdf+xml"`。
- **二分**（临时改 `inject_instance_mask` 里两行 infe 后重编译，均已还原）：

  | 变体 | mask infe | XMP infe | sips |
  |---|---|---|---|
  | 修复前 | flags 0 | `make_infe_box(.., "mime", 0)`（无 content_type）| ✗ Cannot extract image |
  | 只加 hidden | flags 1 | `make_infe_box(.., "mime", 1)` | ✗ |
  | 只加 content_type | flags 0 | `make_mime_infe_box_named(.., 0, "")` | ✓ |
  | `c630b93` | flags 1 | `make_mime_infe_box_named(.., 1, "")` | ✓ |

  ⇒ 唯一决定性的是 **mime infe 必须带 content_type**；hidden 标志不影响解码（保留是为了与 Apple 一致）。
  全仓只有这一处用 `make_infe_box` 造 mime 项，已无同类隐患。

### 新发现：Apple 的实例遮罩是**正式辅助图**（9-25 的布局记录有误）

用 `ipma`/`iref` 逐项解析（`all_items` 把 auxC 字节打印成乱码，导致之前误读为「无 auxC」）：

| | Apple 157（遮罩）| Apple 158（XMP）|
|---|---|---|
| 属性 | `ispe 768×576`、`pixi`、**`auxC(tag:apple.com,2026:photo:aux:semanticpersoninstances)!`**、`hvcC!`、`irot!` | 无 |
| iref | **`auxl 157 → [46 主图, 154 tmap]`** | **`cdsc 158 → [157]`** |

140/141（`urn:mpeg:hevc:2015:auxid:2`）与 142–151（portraiteffectsmatte 等）也是同样的「辅助图 + cdsc XMP」成对结构。

`cdf13b7` 已让 `inject_instance_mask` 写出 ispe + pixi + auxC(essential) + hvcC(essential)、
`auxl → [primary, tmap]`、`cdsc xmp → mask`。验证：输出可解码、主图像素与改动前逐像素一致、
遮罩流可被 ffmpeg 解码、`cargo test -p xdremux-core --lib` 273 passed。**未加 `irot`**（见下 2）。

### 遮罩内容与 person 数据：仍与 Apple 不同

- **遮罩像素**：Apple 157 是**整个人的软分割**（256 级灰度，>127 覆盖 48 919 px，
  bbox x=0.266 y=0.068 w=0.474 h=0.582，存储方向）；我们的 `face_matte` 只是脸框二值图
  （4 480 px，约 Apple 的 9%）。
- **`instanceROI` ≈ 遮罩 bbox 以中心放大 ~1.09**：Apple ROI = (0.2396, 0.0417, 0.5195, 0.6372)，
  遮罩 bbox(>32) = (0.264, 0.066, 0.478, 0.585)，中心 (0.503, 0.359) vs (0.499, 0.360)，宽高比值 1.087/1.089。
  只有一张样片，是假设不是定论。我们的 instanceROI 是启发式 (0.003, 0.138, 0.730, 0.341)，差得远。
- **faceROI** 已接近（x 0.316/0.341、y 0.284/0.308、w 0.104/0.074、h 0.097/0.098）；9-25 的水平镜像问题不复存在。
  肤色 (0.682, 0.577, 0.486) vs Apple (0.755, 0.541, 0.444)；右眼颜色/bimodal 偏差最大
  （0.348/0.202/0.141, bimodal=true vs 0.606/0.430/0.354, false）——疑似右眼 ROI 落在头发/阴影上。
- `skin_test` 两次运行输出不逐字节一致（差异在 mdat 尾部遮罩流附近），疑似 x265 线程非确定性；不影响正确性，做回归比对时注意。

### 下一步（按优先级）

1. **实机验证**：把 `skin_test` 输出（现在的布局与 Apple 结构一致、可解码）导入 iPhone/Photos，
   看 Texture Style/柔肤选项是否出现。之前三个文件都是坏的，这是第一次有合法容器可测。
2. **遮罩方向 + `irot`**：我们的主图 item 1 是 `ispe 4284×5712 + irot`，Apple 主图是 `ispe 5712×4284 + irot`，
   而遮罩是 768×576 横向。先确认我们的主图存储方向与 face_roi 的「存储像素空间」是否一致，再决定是否给遮罩挂 `irot`
   （Apple 挂了主图同一个 irot）。
3. **人物分割替代脸框**：遮罩改为整人软分割（候选：源文件已有 portrait/person matte 时降采样复用；
   否则需要一个分割模型，和 YuNet 一样走 ort）。然后 `instanceROI = bbox(mask>32) × ~1.09`，再用更多样片校验系数。
4. 右眼统计：核对 76 点模板放出来的右眼区域。

### 工具（本轮新增在 scratchpad，未入库）

`heifcheck.py`（顶层/iinf/iloc 校验 + 指定 item 的 infe 原始字节）和 `props.py`（item 的 ipma 属性含 auxC URN、
iref 关系）—— 比 `all_items` 的 auxC 输出可靠，如需长期用可以入库到 `tools/`。

---

# 历史记录

## 断点：修 YuNet 后处理（已由 `ea1d6de` 解决）

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


---

## 断点：FSINC 实例遮罩（2026-09-25 傍晚）

**已确认的被拒根因**：`instanceMaskReferenceKey: 'FSINCInstanceMask9'` 是**必需**的，
但必须配真实的遮罩数据。

| | Apple IMG_0004 | 我们（v7/v8）|
|---|---|---|
| `fsincMattes` XMP | 41 处 | **0** |
| `FSINCInstanceMask9` | 2（引用 + XMP 定义）| 1（悬空）或 0 |

Apple 的 XMP 声明（在独立的 `mime` 项里）：

```xml
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
          xmlns:fsincMattes="http://ns.apple.com/fsinc/1.0/">
      <fsincMattes:InstanceMaskReferenceKey>FSINCInstanceMask9</fsincMattes:InstanceMaskReferenceKey>
      <fsincMattes:FSINCMatteVersion>0</fsincMattes:FSINCMatteVersion>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
```

### 已就绪的部件

- `semantic_mattes::face_matte(w, h, face_roi)` —— 把人脸框区域填白、其余填黑，
  用 x265 编码成 length-prefixed HEVC + hvcC（与 `black_matte` 同一路径）
- `texture_styles::PersonInstance::mask_reference: bool` —— 只有配了遮罩才写引用
  （当前默认 false，**要改回 true**）

### 还要做的

1. **确定 Apple 的 matte 项如何与 XMP 关联** —— dump IMG_0004 的全部 `mime` 项
   （`all_items`），找哪个携带实例遮罩像素；看它的 `infe`/`ipma`/`iref` 关联
2. 注入：matte 项（hvc1/mime）+ fsincMattes XMP 项 + 引用
3. 遮罩分辨率对齐（Apple 的 matte 通常是缩小图，见 `MATTE_W/MATTE_H`）

### 排查方法（已验证有效）

**别只在 bplist 里找差异** —— bplist 早就逐字段一致了（含叶子类型）。
问题在**容器**。用：

```python
for k in [b'fsincMattes', b'FSINCInstanceMask9', ...]:
    print(k, d.count(k))
```

对比 Apple 与我们的文件，差异会直接暴露。

### 另：macOS 相册验证

`Screencapture` 只能拍壁纸 —— 需要在 系统设置→隐私与安全性→屏幕录制 里授权，
才能截到 Photos 窗口做本地循环验证。

### Apple 的 FSINC 实例遮罩布局（已查清，IMG_0004）

| item | type | 尺寸 | 内容 |
|---|---|---|---|
| **157** | `hvc1` | **768×576** | 遮罩像素（HEVC，4695B）|
| **158** | `mime` | — | fsincMattes XMP 声明（462B）|

即 **`hvc1` 遮罩像素 + `mime` XMP 声明 成对**。缩放 ≈ 存储尺寸 / 7.425。

（另有 142-151 五对 `hvc1 2016×1512` + `mime`，是语义遮罩；66-88 十三个 357B `mime`
是 `FSINCMatteVersion` 声明。）

### 已就绪（编译通过）

- `semantic_mattes::face_matte(w, h, face_roi)` —— 人脸框填白/其余填黑，x265 →
  length-prefixed HEVC + hvcC
- `semantic_mattes::instance_mask_xmp(key)` —— 返回上面那段 XMP（含
  `InstanceMaskReferenceKey` + `FSINCMatteVersion`）
- `texture_styles::PersonInstance::mask_reference: bool`

### 还要写：`inject_instance_mask(data, face_roi, 768, 576)`

注入 2 个项。**正确的 API 名**（我第一次写错过，记下来）：

```
isobmff::make_infe_box(item_id, itype, flags)   // 不是 make_infe
isobmff::make_ispe_box(w, h)                    // 不是 make_ispe
isobmff::make_iloc_box(entries)                 // 生成整个 iloc box，不是单条 entry
isobmff::make_ipma_entry(item_id, &assocs, flags)
isobmff::parse_iloc(data, box_hdr)
isobmff::make_box(btype, payload)
```

结构照抄 `inject_semantic_mattes`（iinf / ipco+ipma / iloc 两遍 / splice），
但只有 2 项、**无 auxC URN**：

- mask 项：`hvc1`，ipma = ispe + hvcC(essential)
- xmp 项：`mime`，无属性
- 两项都不建 `iref`（Apple 的实例遮罩不挂在主图上） —— **有误，见顶部 10-29：Apple 用 auxC + auxl + cdsc**
- 数据追加到 `mdat` 末尾

最后：把 `PersonInstance::mask_reference` 改成 **true**，由 `skin_test` 调用注入。

### 验证

```python
d=open(out,'rb').read()
assert d.count(b'FSINCInstanceMask9')>=2   # 引用 + XMP 声明
assert d.count(b'fsincMattes')>=3
```

### ⚠️ 断点：inject_instance_mask 的 splice 仍会损坏容器

**症状**：注入后 `all_items` 能读出 153 项（iinf/iloc 解析正常），
但 `sips -g pixelWidth` 返回 `<nil>` —— 图像解不出。
注入**之前**的中间产物正常（3456/4284）。

**已修的三个容器 bug**（都在 splice 里）：
1. `meta` box 头 size 未更新 → 后续 box 全部错位
2. `mdat` box 头 size 未更新 → 同上
3. `meta` 少了 4 字节 version/flags
4. `head_delta` 漏了 iloc 自身增长量（已用两遍法测出 `d_iloc`）

**还剩一个**没找到。怀疑方向：
- `ipco` 属性计数 `ipco_children.len()` 是否与 ipma 索引一致（1-based）
- 拷贝的间隙 `data[content_end..mdat.box_start]`（若原 meta 与 mdat 之间无间隙则为空）
- 尾部 `data[(mdat.box_start+mdat.size)..]` 是否重复/丢失

**最快的定位法**：把 `inject_instance_mask` 的输出与输入做 **box 逐个 diff**，
看哪一层结构变了但不该变：

```python
import struct
def boxes(d, start, end):
    out=[]; off=start
    while off+8<=end:
        sz=struct.unpack('>I',d[off:off+4])[0]; t=d[off+4:off+8]
        out.append((t, off, sz)); off+=sz
    return out
```

对比注入前后的顶层 box、meta 子 box、ipco 属性 —— 差异会直接指向出错处。

**注意**：不要在文件损坏的状态下发给用户测试。加个保险：
注入后用 `sips` 或解析校验，失败就回退到注入前的字节。

### 断点 2：inject_instance_mask —— 已排除 10 个假设，剩 1 个

> **10-29 已解决**：根因是 XMP 的 mime infe 缺 content_type（下文怀疑 1 的方向是对的），`c630b93` 修复，二分证据见顶部。

**现象**：`sips -s format png` 报 `Cannot extract image from file`。
对照：注入前（v7）能转 PNG，注入后（v15）不能。

**已逐项验证为正确**（别再重复查这些）：

| 检查 | 结果 |
|---|---|
| 顶层 box（ftyp/meta/mdat）| ✓ 尺寸精确加和 |
| iloc 全部 extents 偏移 | ✓ item 2 提取内容与 v7 **逐字节一致** |
| ipma 关联（含 mask 项）| ✓ `dump_item` 全部 `hvcC matched` |
| ipco 前缀 | ✓ 新属性追加在末尾 |
| iinf | ✓ `all_items` 读出 153 项 |
| 新增 2 项 | ✓ 153=hvc1 768×576、154=mime |
| pitm | ✓ 未改动 |
| 跳过 ipma 注入仍失败 | ⇒ **问题不在属性区** |

**仍未定位**。剩余怀疑（按概率）：
1. **`make_infe_box` 生成的 infe 与原文件格式不符** —— 对比我生成的两条 infe
   与原文件的 infe 原始字节（版本、flags、item_name/content_type 字段）
2. **mdat 头 size 计算** —— 虽然顶层加和对，但 sips 可能按 mdat size 读
3. **`idat`/`grpl`/`iref` 顺序** —— meta 子 box 顺序在注入前后是否真的一致
4. **grid 的 `dimg` iref** —— 若主图是 grid，tile 引用是否受影响

**下一轮第一步**：把 `make_infe_box(mask_id,"hvc1",0)` 的输出与
原文件里任一 `hvc1` 项的 infe **逐字节对比**。infe 格式差异会让严格解析器
拒绝整个 iinf，从而拒绝文件 —— 这与「all_items 能读、sips 不能」的现象吻合。

**务必加自检**（这条最重要）：

```rust
// 注入后必须验证，失败就回退到注入前的字节
fn decodes(data: &[u8]) -> bool {
    // 用 heif-oxide 解一次，或至少校验 iloc extents 落在 mdat 内
}
```

我发了 3 个损坏文件让用户测试，浪费了往返。**生成即自检。**
