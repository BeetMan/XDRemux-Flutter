# XDRemux

将 OPPO / OnePlus / realme 设备拍摄的 ProXDR HEIC 照片转换为标准 ISO 21496-1 HDR HEIC。

转换后的照片可在 macOS、iOS、Android 等支持 HDR 显示的系统中查看。

## 快速开始

### Flutter App（推荐）

下载对应平台的 Release，或从源码构建：

```bash
cd apps/flutter
flutter pub get
flutter build macos --debug
```

### Rust CLI

```bash
cargo build --workspace --release
./target/release/xdremux-conformance convert input.heic output.heic
```

### Rust 核心库

```bash
cargo build -p xdremux-core --release --lib
# 产出: target/release/libxdremux_core.dylib (macOS)
#       target/release/libxdremux_core.so   (Linux)
#       target/release/xdremux_core.dll    (Windows)
```

FFI 接口：

| 函数 | 用途 |
|------|------|
| `xdremux_version()` | 返回版本号 |
| `xdremux_inspect(path)` | 解析 HEIC，返回 mode / family / edr_scale / gainMapMax |
| `xdremux_convert(in, out, config)` | 转换 ProXDR → ISO HDR |
| `xdremux_verify_output(path)` | 验证输出是否包含 ISO gain map |
| `xdremux_free_result(r)` | 释放 inspect/convert 返回的结果 |

### 输出模式

| 模式 | 参数 | 结果 |
|------|------|------|
| 标准 ISO（默认） | `oppo_compat=0` | ISO 21496-1 HDR，保留源 Base Image |
| OPPO 相册兼容 | `oppo_compat=1` | HEVC Main Still Picture 4:2:0 |

## 一致性验证

Rust 核心库与原版 Python 实现经过四层自动化验证：

| 层级 | 比对内容 | 结果 |
|------|---------|------|
| Tier 1 | LHDR/UHDR 数值（mode, meta_floats, edr_scale） | ✅ 14/14 pass |
| Tier 2 | GainMapMetadata 二进制载荷（62B/142B/144B） | ✅ MD5 一致 |
| Tier 3 | ISOBMFF 结构（ftyp, pitm, iinf, iref, ipco, ipma, iloc） | ✅ 65/245 items |
| Tier 4 | SDR base 像素 bit-exact，增益图瓦片可解码 | ✅ |
| Apple ImageIO | `CGImageSourceCopyAuxiliaryDataInfoAtIndex` | ✅ Pass |

运行验证：

```bash
python3 tests/conformance/driver.py \
  --sample-dir <sample-dir> \
  --out-report conformance_report.md
```

## 仓库结构

| 路径 | 用途 |
|------|------|
| `xdremux/rust/` | Rust 核心库 |
| `xdremux/swift-cli/` | Swift CLI（Apple ImageIO 参考实现） |
| `xdremux/python/` | Python CLI（跨平台参考实现） |
| `apps/flutter/` | Flutter 跨平台 App |
| `apps/macos/XDRemuxApp/` | macOS SwiftUI App |
| `tests/conformance/` | 跨实现一致性验证 |
| `fixtures/` | 测试样本说明 |
| `scripts/` | 构建脚本 |

## 已知限制

- 转换后回到 OPPO 相册编辑再保存，HDR Gain Map 可能丢失。
- 转换前请备份原始文件。
