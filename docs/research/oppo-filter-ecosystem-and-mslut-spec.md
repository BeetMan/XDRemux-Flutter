# OPPO / ColorOS Filter Ecosystem & `.MS-LUT` Binary Specification (Direction 4)

## 1. Overview

ColorOS Camera (`com.oplus.camera`) and ColorOS Gallery (`com.coloros.gallery3d`) share a non-destructive filter, Master Mode preset, and AI Color Palette (大师调色盘 / 影调) ecosystem built on two core binary formats:
1. **`.MS-LUT` (`Meishe` 3D LUT)**: The binary 3D LUT container consumed by `libmsnativefilter.so` (`MsRenderHDRTexture` / `MsRenderHardwareBuffer`) and `OCamFilterMeisheV2` in `libAlgoInterface.so`.
2. **`FileExtendedContainer` (`\0jxrs` tail)**: Appended after the base JPEG (`FF D9`) or HEIC ISO-BMFF boxes, carrying `src.image`, `filter.info`, `master.mode.preset.info`, `basictone.info`, `basictone.vig.table`, `ltw.data`, and `gain.data`.

`XDRemux` implements full bidirectional support for this ecosystem in [`oppo_filter_ecosystem.rs`](../../xdremux/rust/src/oppo_filter_ecosystem.rs) and [`mslut_and_tail_tool.py`](../../tools/oppo-filter-ecosystem/mslut_and_tail_tool.py).

---

## 2. Meishe `.MS-LUT` Binary Format (`17³` & `32³`)

### 2.1 Binary Header & Lattice Layout
All integers and floats are little-endian:

| Offset | Size | Type | Description |
| :--- | :--- | :--- | :--- |
| `0x00` | `8 B` | `[u8; 8]` | Magic ASCII signature `".MS-LUT "` (`2E 4D 53 2D 4C 55 54 20`) |
| `0x08` | `4 B` | `u32` | Version (`1`) |
| `0x0C` | `4 B` | `u32` | Cube dimension $N$ (`17` or `32`) |
| `0x10` | `8 B` | `u64` | Reserved (`0`) |
| `0x18` | `4 B` | `u32` | Flag (`0` for $17^3$, `1` for $32^3$) |
| `0x1C` | `4 B` | `u32` | Reserved (`0`) |
| `0x20` | `8 B` | `u64` | Coordinate table byte offset (`48` = `0x30`) |
| `0x28` | `8 B` | `u64` | RGB lattice data byte offset (`48 + 4 * N`: `116` for $N=17$, `176` for $N=32$) |
| `0x30` | `4*N B` | `f32[N]` | Uniform grid coordinates $i / (N - 1)$ for $i \in [0, N-1]$ |
| `data_offset` | `3*N³ B` | `u8[N³][3]` | 8-bit RGB lattice points in **R-fastest** order: `index = (b * N + g) * N + r` |

- Total file size for $N = 17$: $48 + 68 + 17^3 \times 3 = 14,855\text{ bytes}$.
- Total file size for $N = 32$: $48 + 128 + 32^3 \times 3 = 98,480\text{ bytes}$.

### 2.2 OPPO Display P3 $\leftrightarrow$ Rec.709 CSS Color 4 OkLCh Gamut-Mapped LUT Baking
OPPO Camera feeds Display P3 frames (encoded with the sRGB transfer function) directly into the `.MS-LUT` sampler, whereas standard `.cube` LUTs are authored for Rec.709 / sRGB. Directly applying a Rec.709 `.cube` to Display P3 values causes over-saturation and hue shifts.

`Cube3dLut::bake_to_mslut(..., LutColorTransform::OppoDisplayP3Rec709Oklch)` implements the exact colour-managed baking pipeline:
1. Decode input Display P3 lattice coordinate $(r, g, b) \in [0, 1]^3$ via sRGB EOTF to linear Display P3.
2. Transform linear Display P3 to linear Rec.709 via $M_{\text{P3}\to\text{709}}$.
3. Apply **CSS Color 4 OkLCh gamut mapping** (`JND = 0.02`, binary search on OkLCh chroma $C$ at constant lightness $L$ and hue $h$) to bring out-of-gamut P3 colours smoothly onto the Rec.709 gamut boundary without channel clipping hue twists.
4. Encode via sRGB OETF and trilinearly sample the `.cube` 3D LUT.
5. Decode the `.cube` output via sRGB EOTF, convert linear Rec.709 back to linear Display P3 via $M_{\text{709}\to\text{P3}}$, and re-encode with sRGB OETF to 8-bit `.MS-LUT` lattice values.

---

## 3. ColorOS Gallery `filter.info` Binary Layout (`140 B` v4 & `228 B` v5/v5.1)

Verified against `libAlgoInterface.so` (`OCamFilterMeisheV2::seedPaletteFilterInfoSkeleton`, `fillFilterInfoBySceneV2`, `updatePaletteBasicToneFilterInfoFlags`) and 29 real OPPO Find X10 captures:

| Offset | Size | Type | Field Name | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` (`0`) | `4 B` | `f32` | `version` | `4.0` (`0x40800000`) for Master/classic filter; `5.0` (`0x40a00000`) or `5.1` (`0x40a33333`) for AI Palette |
| `0x04` (`4`) | `4 B` | `i32` | `filterStrength` | Filter intensity (`0..=100`, default `100`) |
| `0x08` (`8`) | `4 B` | `i32` | `orientation` | Source capture orientation (`0`, `90`, `180`, `270`) |
| `0x0C` (`12`) | `4 B` | `i32` | `softLightType` | `0` = 朦胧 (1/4 Black Mist), `1` = 柔美 (Ricoh HDF), `2` = 梦幻 (White Mist) |
| `0x10` (`16`) | `4 B` | `i32` | `isSoftLight` | `0` = disabled, `1` = enabled |
| `0x14` (`20`) | `4 B` | `i32` | `reserved14` | Reserved (`0`) |
| `0x18` (`24`) | `4 B` | `i32` | `isFilterEnable` | `1` when filter/palette is active |
| `0x1C` (`28`) | `100 B` | `char[100]` | `filterType` | NUL-padded UTF-8 filter token (e.g. `"qing_tou.bin"`, `"portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin"`) |
| `0x80` (`128`) | `4 B` | `f32` | `colorTemperature` | Scene CCT in Kelvin (e.g. `5757.0`) |
| `0x84` (`132`) | `4 B` | `f32` | `luxIndex` | Scene Lux Index (e.g. `172.734`) |
| `0x88` (`136`) | `4 B` | `f32` | `filterGain` | Filter gain / HDR ratio (e.g. `1.830`, `1.000`) — **end of 140-byte v4 struct** |
| `0x8C` (`140`) | `4 B` | `i32` | `isPalette` | **v5 extension**: `1` for Palette mode (大师调色盘), `0` for classic/Master filter |
| `0x90` (`144`) | `4 B` | `i32` | `paletteAlgoUsed` | `1` when Palette capture algorithm ran, `0` otherwise |
| `0x94` (`148`) | `4 B` | `i32` | `paletteSaturation` | Palette saturation adjustment (`-100..=100`, default `0`) |
| `0x98` (`152`) | `4 B` | `i32` | `paletteTone` | Palette tone / contrast parameter (e.g. `89`, `38`, `0`) |
| `0x9C` (`156`) | `60 B` | `char[60]` | `captureMode` | NUL-padded UTF-8 capture mode string (e.g. `"common"`) |
| `0xD8` (`216`) | `4 B` | `f32` | `sceneAvgLuma` | Scene average luminance (e.g. `50.785`) |
| `0xDC` (`220`) | `4 B` | `f32` | `sceneBrightLuma` | Scene bright luminance (e.g. `234.638`) |
| `0xE0` (`224`) | `4 B` | `f32` | `sceneDarkLuma` | Scene dark luminance (e.g. `11.036`) — **end of 228-byte v5/v5.1 struct** |

---

## 4. `master.mode.preset.info` (`496 B`), `basictone.info` (`8216 B`) & `basictone.vig.table` (`884 B`)

- **`master.mode.preset.info` (`496` bytes)**:
  - `+0x00`: `f32 version` (`1.0`)
  - `+0x04`: `i32 intensity` (`0..=100`, default `100`)
  - `+0x08`: `i32 reserved` (`0`)
  - `+0x0C..+0x84` (`120` bytes): `presetTitle` (`"无"`)
  - `+0x84`: `i32 presetId` (`101`)
  - `+0x88..+0xEC` (`100` bytes): `filterIndexStr` (`"0"`, `"1"`, etc.)
  - `+0xEC..+0x150` (`100` bytes): `filterName` (`"标准"`, `"清透"`, `"童话"`, etc.)
  - `+0x150..+0x1F0` (`160` bytes): Master tuning parameters.
- **`basictone.info` (`8216` bytes)**:
  - `16³` FP16 (`8192` bytes) BasicTone 3D LUT + `24`-byte header/footer (`version = 1.0`, `dither_strength_10bit = 5.0`).
- **`basictone.vig.table` (`884` bytes)**:
  - `13 × 17 = 221` IEEE-754 `f32` radial lens vignette gain mesh (`~0.828 .. 1.000`).
