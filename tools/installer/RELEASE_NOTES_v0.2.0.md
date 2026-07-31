# XDRemux v0.2.0

正式版——Android 硬件编码（GPU 加速）与可靠性修复。

- **GPU 硬件编码（实验，默认关闭）**：设置页新增「GPU 硬件编码」开关。开启后 Android 用 MediaCodec 硬件编码 gain map，单 tile ~40ms，比软件 x265 快一个数量级（实测 18-tile UHDR 大图全硬件编码，无回退）。注意：开启后 gain map 降至 4:2:0（画质微降），目前仅在骁龙 8 Elite（OPPO/OnePlus/realme）上验证通过；任何失败自动回退软件编码，不会产出坏文件。
- **修复硬件编码花屏（绿色方块）**：高通 NV12 半平面编码器的 V-plane 视图 limit 少 1 字节，导致 gain map 的 V 色度通道整个丢失。改为 U/V 交错写入共享缓冲，色度完整保留（实测解码 V 平面从全 0 恢复到正常 127）。
- **修复 hvcC 参数错误**：从 SPS 正确解析 profile/level（此前从 VPS 错误偏移读取，MediaCodec 流会得到错误的 level，部分解码器直接报错）。
- **修复 OPPO 兼容模式的 tmap 选择**：硬件路径的 tmap/XMP 现跟随用户的 OPPO 兼容模式设置，与软件路径一致。

签名与 v0.1.9 一致，可直接覆盖安装。版本号 `0.2.0+13`。
