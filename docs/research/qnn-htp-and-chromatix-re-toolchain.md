# 高通 QNN HTP 模型静态权重还原与 Chromatix 逆向工具链

> 来源：提炼自 `OffLineM9`（小米 17 Ultra「徕卡一瞬 · M9」ROM 逆向工程）。
> 脚本归档位置：`tools/re-qnn-chromatix/`（含 `decode_tools/`、`rom_tools/`、`emu_src/`）。
> 适用范围：所有搭载骁龙 8 Gen 3 / 8 Elite（SM8650 / SM8750 / SM8850，HTP V73–V81）的 Android 旗舰机型（OPPO Find X8/X9 系列哈苏大师模式、小米 15/17 系列徕卡一瞬、vivo X200/X300 蔡司影调等）。

---

## 1. 为什么这套工具链极具价值？

现代移动端计算摄影的核心风格化能力（如小米 `StyleTrans`、OPPO 哈苏影调/超光影 AI、华为 XMAGE 色彩网络）通常分为两层：
1. **ISP 硬件/软件调参表（Qualcomm Chromatix `tuned.bin` + 厂商 3A Protobuf）**：控制 AE 测光偏置、AWB 色温锁定、GMA/TMC 全局色调曲线、CC 色度矩阵、2D LUT（色相/饱和度肩部压缩）。
2. **NPU 预编译上下文二进制（QNN HTP Context Binary）**：厂商不再随 ROM 下发可读的 `.onnx` 或 `.tflite`，而是下发经高通 `qnn-context-binary-generator` 离线编译给特定 Hexagon HTP 架构（如 V79/V81）的 **W8A16 HMX 机器码流与 Crouton 分块张量**。

传统逆向认为 QNN HTP Context Binary 是不可逆的黑盒。本工具链**首次打通了无真机、纯静态从编译后的 HTP Context Binary 无损还原浮点卷积权重（`.npz`）的全流程**，并配齐了 `qemu-aarch64` 直接驱动 ROM 原生 `.so` 导出调校表与对拍真值的脚手架。

---

## 2. 工具链目录结构（`tools/re-qnn-chromatix/`）

| 子目录 / 脚本 | 用途 |
|---|---|
| `decode_tools/superx.py` | 解析 Android 稀疏/非稀疏 `super.img`，按逻辑分区抽出 `odm_a.img`、`vendor_a.img`、`product_a.img`（配合 WSL `fsck.erofs --extract` 解包） |
| `decode_tools/a64.py` | 基于 `lief` + `capstone` 的纯 Python ARM64 静态逆向工具：字符串交叉引用 (`xref`)、函数边界识别 (`funcs`)、带符号/重定位注释的反汇编 (`func`)、调用图分析 (`calls`) |
| `rom_tools/minn.py` | 脱壳厂商模型外层容器（如小米 `.minn`：`NNiM` 0x1E 字节头 + 16 字节周期 XOR key `"legenddddddddddd"`）还原出标准 QNN Context Binary |
| `decode_tools/htpctx.py` | 解析 QNN HTP Context Binary：定位记录流起点、切分 Op 记录（`0x1303xxxx` 锚点）、提取 `Const` 张量元数据与算子名称表 |
| `decode_tools/htpgraph.py` | 恢复 HTP 静态计算图拓扑：按顺序分配张量 ID（Const=1、普通算子=1/输出、`@DummyOpN`=N、变长 Concat），校验全图锚点自洽性 |
| `decode_tools/htpblocks.py` | 解析 HTP 张量体：量化编码（`def: id\|0x80000000, zp, scale_f32`）、4D Shape 半字节编码、Crouton_16 / Crouton_8 块表寻址 |
| `decode_tools/htpflow.py` | HTP TCM/DDR 内存模拟器：按 2KB 页追踪最后写入者（含 Spill/Fill），恢复真实数据流连接关系与 Concat 通道拼接顺序 |
| `decode_tools/htpquant.py` | **核心**：高通 HMX W8A16 偏置块（Fi）与权重块（Xwb 3×3 / Xsb 1×1）反量化公式，无损还原 PyTorch `conv2d` 浮点权重 `(W, b, s_out, zp_out)` |
| `decode_tools/styletrans_export.py` | 将 HTP 图中的 ResNet/RDB 网络与 U-Net 网络一键导出为 `.npz` 浮点权重包 |
| `rom_tools/protodesc.py` & `protoprint.py` | 从 `.so`（如 `libmiaec.so`、`libmituning_datacenter.so`）二进制段自动搜索并抽出内嵌的 Protobuf `FileDescriptorProto`，无需 `.proto` 源码即可打印完整字段名 |
| `rom_tools/mipb.py` & `mituning.py` | 解析厂商 3A 二进制调参库（如 `odm/etc/camera/mi_tuning/*.bin`），支持 `LinkKey` 重定向解析与模式对比 |
| `rom_tools/cxtree.py` & `export_ipe.py` | 解析高通 Chromatix 7 `com.qti.tuned.*.bin` 的多级触发树（Sensor Mode → Usecase → Feature0 → DRC → Lux → CCT），导出 JSON 表 |
| `emu_src/chromatix.c` / `tmc.c` / `uhdr.c` | 在 `qemu-aarch64` + ROM `bionic/vendor` sysroot 下直接 `dlopen` 调用原厂 `camera.qcom.core.so`、`libhwliqinterface2.so`、`libultrahdr.so` 的宿主程序 |

---

## 3. 核心原理速查（供后续逆向其他机型参考）

### 3.1 高通 HTP W8A16 卷积权重反量化公式（`htpquant.py`）

高通 HTP Prepare 库（`libQnnHtpPrepare.so`）将 `W8A16`（8-bit 对称/非对称权重 + 16-bit 激活）编译进 HMX 硬件矩阵单元时：

1. **常量数据基址 $B$ 的定位**：
   - 所有偏置块（Fi）的物理文件偏移均满足 $\text{addr} \equiv \text{0xD0} \pmod{256}$（或 64 字节对齐）。
   - 张量记录中的偏移字段 `data_off` 转为物理地址公式：
     $$\text{addr} = B + (\text{data\_off} \ \& \ \text{0xFFFF}) \times 64 \quad \text{或} \quad B + (\text{data\_off} - \text{0x40000004})$$
2. **权重块排布（`Xwb` 3×3 与 `Xsb`/`Xpb` 1×1）**：
   - `int8` 存储，逐输出通道量化（每通道最大绝对值 127 或 128）。
   - 按 $32 \times 32$ 通道分块（每 tap $1024\text{ B}$）。
   - 块内偏移：`off = (ci // 4) * 128 + co * 4 + (ci % 4)`。
   - **重要陷阱**：$3\times 3$ 卷积核的 9 个 tap 在每一行内 **$k_x$ 是倒序存放的**：
     $$\text{tap} = k_y \times 3 + (2 - k_x)$$
   - Tile 遍历顺序：$3\times 3$ `Xwb` 为 `[co_blk][ci_blk][tap]`；$1\times 1$ `Xsb/Xpb` 为 `[ci_blk][co_blk]`。
3. **偏置与缩放块（Fi，每 32 个输出通道占 $512\text{ B}$）**：
   - 分为 $g \in \{0, 1\}$ 两组，每组含 16 对 `(m0, m1)`（`uint32`）和 16 对 `(bias, 0)`（`int32`）。
   - **通道映射**：输出通道号 $c = 2k + g$（其中 $k \in [0, 15]$ 为组内序号，$g \in [0, 1]$ 为组号）。
   - **22-bit 尾数与指数提取**（HMX 模式 6，`0x2EEDCE8`）：
     $$\text{mant22} = \left( ((\text{m1}_{[16]} \ll 10 \mid \text{m1}_{[0:10]}) \ll 11) \mid (\text{m0}_{[0:10]} \ll 1) \mid \text{m0}_{[31]} \right) \oplus \text{0x200000}$$
     $$e = \text{m0}_{[10:15]}, \quad F = \text{mant22} \cdot 2^{e - 45}$$
   - **还原浮点权重 $W$ 与浮点偏置 $b$**：
     由于 HMX 硬件按原始 `uint16` 激活累加，编译期已从 `bias` 中预扣了 $\text{zp}_{\text{in}} \cdot \sum q / 256$，因此：
     $$W[c, \dots] = q[c, \dots] \cdot F_c \cdot \frac{s_{\text{out}}}{s_{\text{in}}}$$
     $$b[c] = 256 \cdot F_c \cdot s_{\text{out}} \cdot \left( \text{bias}_c + \frac{\text{zp}_{\text{in}} \cdot \sum_{i,y,x} q[c, i, y, x]}{256} \right)$$
   - **激活截断（ReLU / Clip 的实现方式）**：
     HTP 卷积算子不设单独的 ReLU 节点，而是利用输出张量的 `uint16` 量化范围实现截断（当 $\text{zp}_{\text{out}} = 0$ 时即为 ReLU）：
     $$y_{\text{float}} = \text{clamp}\left(\text{conv2d}(x, W, b), \ (0 - \text{zp}_{\text{out}}) \cdot s_{\text{out}}, \ (65535 - \text{zp}_{\text{out}}) \cdot s_{\text{out}}\right)$$

---

### 3.2 `qemu-aarch64` 无真机运行高通/厂商原生相机库（`emu_src/`）

当静态反编译某段复杂插值算法（如 `libhwliqinterface2.so` 的 TMC202 锚点膝点计算，或 `camera.qcom.core.so` 的 `TuningDataManager`）耗时过长时：
1. 从 ROM 解包 `/system/lib64`、`/vendor/lib64`、`/odm/lib64` 组成 sysroot。
2. 伪造 `/sys/devices/soc0/soc_id`（例如 SM8850 填入 `660`）。
3. 使用 `aarch64-linux-gnu-gcc` 编译轻量宿主 C 程序（见 `emu_src/chromatix.c` / `tmc.c`），通过 `dlopen` 加载目标 `.so`，直接传入模式分支字符串（如 `0=0,1=1,5=1,21=7`）导出任意场景下的插值前/插值后真值表。

---

## 4. 后续在 XDRemux 中的拓展方向

1. **OPPO Find X8 / X9 Ultra「哈苏大师模式（Hasselblad Master Mode）」离线复刻**：
   - OPPO 同样基于 SM8750/SM8850 平台，相机参数位于 `/odm/lib64/camera/com.qti.tuned.*.bin` 及 `/odm/etc/camera/`，可用同一套 `cxtree.py` + `htpquant.py` 拆解大师模式的色彩矩阵、中间调压暗曲线、暗角与 NPU 影调模型。
2. **华为 XMAGE `xtstyle` 完整色彩映射还原**：
   - 结合 `a64.py` 与 `qemu-aarch64` 宿主程序，直接加载华为相机色彩引擎 `.so` 对标准色卡做黑盒/白盒联合标定，补齐 `docs/plans/huawei-to-apple-plan.md` 中的 XMAGE 风格映射。
