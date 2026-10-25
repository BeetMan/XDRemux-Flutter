#!/usr/bin/env python3
"""
OPPO / ColorOS Camera & Gallery Filter Ecosystem CLI Tool (Direction 4)
=======================================================================

Provides standalone command-line utilities for:
1. `mslut-to-cube`: Convert Meishe `.MS-LUT` (17^3 / 32^3) binary LUTs to Adobe `.cube`.
2. `cube-to-mslut`: Bake Adobe `.cube` 3D LUTs into OPPO `.MS-LUT` (with optional
   OPPO Camera Display P3 <-> Rec.709 CSS Color 4 OkLCh gamut mapping).
3. `inspect-tail`: Inspect OPPO `FileExtendedContainer` (`\\0jxrs`) tail entries,
   decoding `filter.info` (v4 140B & v5/v5.1 228B), `master.mode.preset.info` (496B),
   `basictone.info` (8216B), and `basictone.vig.table` (884B).
4. `inject-filter`: Non-destructively inject or update `filter.info` (and optionally
   `master.mode.preset.info` and `src.image`) in an OPPO JPEG or HEIC file.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import struct
import sys
from typing import Dict, List, Optional, Tuple

MSLUT_MAGIC = b".MS-LUT "
MSLUT_CORE_HEADER_LEN = 48
FILTER_INFO_V4_LEN = 140
FILTER_INFO_V5_LEN = 228
MASTER_PRESET_LEN = 496

M_P3_TO_709 = (
    (1.22494018, -0.22494018, 0.0),
    (-0.04205695, 1.04205695, 0.0),
    (-0.01963755, -0.07863605, 1.09827360),
)

M_709_TO_P3 = (
    (0.82246197, 0.17753803, 0.0),
    (0.03319420, 0.96680580, 0.0),
    (0.01708263, 0.07239744, 0.91051993),
)


def srgb_eotf(v: float) -> float:
    x = max(0.0, min(1.0, v))
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def srgb_oetf(l_val: float) -> float:
    x = max(0.0, min(1.0, l_val))
    return x * 12.92 if x <= 0.0031308 else 1.055 * (x ** (1.0 / 2.4)) - 0.055


def mat3_mul(m: Tuple[Tuple[float, float, float], ...], v: Tuple[float, float, float]) -> Tuple[float, float, float]:
    return (
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    )


def _cbrt(x: float) -> float:
    return math.copysign(abs(x) ** (1.0 / 3.0), x)


def linear_srgb_to_oklab(rgb: Tuple[float, float, float]) -> Tuple[float, float, float]:
    r, g, b = rgb
    l_ = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m_ = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s_ = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    )


def oklab_to_linear_srgb(lab: Tuple[float, float, float]) -> Tuple[float, float, float]:
    l_val, a, b = lab
    l_ = (l_val + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m_ = (l_val - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s_ = (l_val - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (
        4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
        -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
        -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_,
    )


def gamut_map_oklch_rec709(rgb_lin: Tuple[float, float, float]) -> Tuple[float, float, float]:
    if all(-1e-6 <= c <= 1.0 + 1e-6 for c in rgb_lin):
        return (
            max(0.0, min(1.0, rgb_lin[0])),
            max(0.0, min(1.0, rgb_lin[1])),
            max(0.0, min(1.0, rgb_lin[2])),
        )
    orig_lab = linear_srgb_to_oklab(rgb_lin)
    l_val = orig_lab[0]
    if l_val <= 0.0:
        return (0.0, 0.0, 0.0)
    if l_val >= 1.0:
        return (1.0, 1.0, 1.0)
    c = math.hypot(orig_lab[1], orig_lab[2])
    if c < 1e-9:
        v = oklab_to_linear_srgb((l_val, 0.0, 0.0))
        return tuple(max(0.0, min(1.0, x)) for x in v)  # type: ignore[return-value]
    ha, hb = orig_lab[1] / c, orig_lab[2] / c
    jnd, eps = 0.02, 0.0001
    lo, hi = 0.0, c
    best = tuple(max(0.0, min(1.0, x)) for x in rgb_lin)
    while hi - lo > eps:
        mid = 0.5 * (lo + hi)
        cur_lab = (l_val, mid * ha, mid * hb)
        cur_rgb = oklab_to_linear_srgb(cur_lab)
        if all(0.0 <= x <= 1.0 for x in cur_rgb):
            best = cur_rgb
            lo = mid
        else:
            clipped = tuple(max(0.0, min(1.0, x)) for x in cur_rgb)
            c_lab = linear_srgb_to_oklab(clipped)  # type: ignore[arg-type]
            de = math.sqrt(sum((a - b) ** 2 for a, b in zip(cur_lab, c_lab)))
            if de < jnd:
                best = clipped
                if jnd - de < eps:
                    break
                lo = mid
            else:
                hi = mid
    return best  # type: ignore[return-value]


def parse_mslut(data: bytes) -> Tuple[int, List[float], List[Tuple[int, int, int]]]:
    if len(data) < MSLUT_CORE_HEADER_LEN or data[:8] != MSLUT_MAGIC:
        raise ValueError("Invalid .MS-LUT header")
    version, n, _res10, _flag, _res1c, coord_off, data_off = struct.unpack_from("<IIQIIQQ", data, 8)
    coords = list(struct.unpack_from(f"<{n}f", data, coord_off))
    pts = n * n * n
    rgb = []
    for i in range(pts):
        off = data_off + i * 3
        rgb.append((data[off], data[off + 1], data[off + 2]))
    return n, coords, rgb


def encode_mslut(n: int, rgb: List[Tuple[int, int, int]]) -> bytes:
    coord_off = MSLUT_CORE_HEADER_LEN
    data_off = MSLUT_CORE_HEADER_LEN + n * 4
    flag = 1 if n == 32 else 0
    header = bytearray(MSLUT_MAGIC)
    header += struct.pack("<IIQIIQQ", 1, n, 0, flag, 0, coord_off, data_off)
    for i in range(n):
        header += struct.pack("<f", i / (n - 1))
    body = bytearray()
    for r, g, b in rgb:
        body.extend((r & 0xFF, g & 0xFF, b & 0xFF))
    return bytes(header + body)


def parse_cube(text: str) -> Tuple[int, List[Tuple[float, float, float]]]:
    n: Optional[int] = None
    table: List[Tuple[float, float, float]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        up = line.upper()
        if up.startswith(("TITLE", "DOMAIN_MIN", "DOMAIN_MAX")):
            continue
        if up.startswith("LUT_3D_SIZE"):
            n = int(line.split()[1])
            continue
        parts = line.split()
        if len(parts) >= 3:
            table.append((float(parts[0]), float(parts[1]), float(parts[2])))
    if n is None or len(table) != n * n * n:
        raise ValueError(f"Invalid .cube file (N={n}, entries={len(table)})")
    return n, table


def sample_cube(n: int, table: List[Tuple[float, float, float]], r: float, g: float, b: float) -> Tuple[float, float, float]:
    scale = n - 1
    pr = max(0.0, min(1.0, r)) * scale
    pg = max(0.0, min(1.0, g)) * scale
    pb = max(0.0, min(1.0, b)) * scale
    r0 = min(int(math.floor(pr)), n - 2)
    g0 = min(int(math.floor(pg)), n - 2)
    b0 = min(int(math.floor(pb)), n - 2)
    fr, fg, fb = pr - r0, pg - g0, pb - b0
    out = [0.0, 0.0, 0.0]
    for db in (0, 1):
        wb = fb if db else (1.0 - fb)
        for dg in (0, 1):
            wg = fg if dg else (1.0 - fg)
            for dr in (0, 1):
                wr = fr if dr else (1.0 - fr)
                w = wr * wg * wb
                px = table[((b0 + db) * n + (g0 + dg)) * n + (r0 + dr)]
                out[0] += w * px[0]
                out[1] += w * px[1]
                out[2] += w * px[2]
    return (max(0.0, min(1.0, out[0])), max(0.0, min(1.0, out[1])), max(0.0, min(1.0, out[2])))


def parse_filter_info(data: bytes) -> Dict[str, object]:
    if len(data) < FILTER_INFO_V4_LEN:
        raise ValueError(f"filter.info too short ({len(data)} bytes)")
    version, strength, orient, soft_type, is_soft, res14, is_enable = struct.unpack_from("<f6i", data, 0)
    ft_raw = data[0x1C:0x80].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    cct, lux, gain = struct.unpack_from("<3f", data, 0x80)
    info: Dict[str, object] = {
        "version": round(version, 2),
        "byteLength": len(data),
        "filterStrength": strength,
        "orientation": orient,
        "softLightType": soft_type,
        "isSoftLight": bool(is_soft),
        "reserved14": res14,
        "isFilterEnable": bool(is_enable),
        "filterType": ft_raw,
        "colorTemperature": round(cct, 2),
        "luxIndex": round(lux, 3),
        "filterGain": round(gain, 3),
    }
    if len(data) >= FILTER_INFO_V5_LEN:
        is_pal, pal_algo, pal_sat, pal_tone = struct.unpack_from("<4i", data, 0x8C)
        cap_mode = data[0x9C:0xD8].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        avg_luma, bright_luma, dark_luma = struct.unpack_from("<3f", data, 0xD8)
        info.update({
            "isPalette": bool(is_pal),
            "paletteAlgoUsed": bool(pal_algo),
            "paletteSaturation": pal_sat,
            "paletteTone": pal_tone,
            "captureMode": cap_mode,
            "sceneAvgLuma": round(avg_luma, 3),
            "sceneBrightLuma": round(bright_luma, 3),
            "sceneDarkLuma": round(dark_luma, 3),
        })
    return info


def build_filter_info(
    filter_type: str,
    strength: int = 100,
    orientation: int = 0,
    soft_light_type: int = 0,
    is_soft_light: bool = False,
    is_palette: bool = False,
    palette_saturation: int = 0,
    palette_tone: int = 0,
    capture_mode: str = "common",
) -> bytes:
    buf = bytearray(FILTER_INFO_V5_LEN)
    version = 5.1 if is_palette else 4.0
    struct.pack_into(
        "<f6i",
        buf,
        0,
        version,
        strength,
        orientation,
        soft_light_type,
        1 if is_soft_light else 0,
        0,
        1,
    )
    ft_bytes = filter_type.encode("utf-8")[:99]
    buf[0x1C : 0x1C + len(ft_bytes)] = ft_bytes
    struct.pack_into("<3f", buf, 0x80, 5500.0, 180.0, 1.0)
    struct.pack_into(
        "<4i",
        buf,
        0x8C,
        1 if is_palette else 0,
        1 if is_palette else 0,
        palette_saturation,
        palette_tone,
    )
    cm_bytes = capture_mode.encode("utf-8")[:59]
    buf[0x9C : 0x9C + len(cm_bytes)] = cm_bytes
    struct.pack_into("<3f", buf, 0xD8, 60.0, 280.0, 10.0)
    return bytes(buf)


def parse_oppo_tail(data: bytes) -> Optional[Tuple[int, List[Tuple[str, int, bytes]]]]:
    footer_pos = data.rfind(b"\x00jxrs")
    if footer_pos < 0:
        return None
    scan_start = max(0, footer_pos - 16384)
    json_end = data.rfind(b"]", scan_start, footer_pos)
    if json_end < 0:
        return None
    json_start = data.rfind(b"[{", scan_start, json_end + 1)
    if json_start < 0:
        return None
    manifest = json.loads(data[json_start : json_end + 1].decode("utf-8"))
    if not manifest:
        return None
    raw_entries: List[Tuple[int, str, int, bytes]] = []
    min_start = json_start
    for e in manifest:
        off = int(e["offset"])
        ln = int(e["length"])
        abs_start = json_start - off
        if abs_start < 0 or abs_start + ln > json_start:
            return None
        min_start = min(min_start, abs_start)
        raw_entries.append((abs_start, str(e["name"]), int(e.get("version", 1)), data[abs_start : abs_start + ln]))
    raw_entries.sort(key=lambda item: item[0])
    entries = [(name, ver, payload) for _abs, name, ver, payload in raw_entries]
    return min_start, entries


def upsert_oppo_tail(data: bytes, updates: Dict[str, Optional[bytes]]) -> bytes:
    parsed = parse_oppo_tail(data)
    if parsed is not None:
        base_end, entries = parsed
    else:
        base_end, entries = len(data), []

    names = [n for n, _, _ in entries]
    for k, v in updates.items():
        if k in names:
            idx = names.index(k)
            if v is None:
                entries.pop(idx)
                names.pop(idx)
            else:
                entries[idx] = (k, entries[idx][1], v)
        elif v is not None:
            entries.append((k, 1, v))
            names.append(k)

    out = bytearray(data[:base_end])
    if not entries:
        return bytes(out)

    starts: List[int] = []
    payload_len = 0
    for _name, _ver, payload in entries:
        starts.append(payload_len)
        out.extend(payload)
        payload_len += len(payload)

    manifest = []
    for (name, ver, payload), st in zip(entries, starts):
        manifest.append({
            "length": len(payload),
            "name": name,
            "offset": payload_len - st,
            "version": ver,
        })

    json_bytes = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
    footer_size = len(json_bytes) + 9
    out.extend(json_bytes)
    out.extend(b"\x00jxrs")
    out.extend(struct.pack("<I", footer_size))
    return bytes(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="OPPO / ColorOS Filter Ecosystem & .MS-LUT Tool")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_m2c = sub.add_parser("mslut-to-cube", help="Convert .MS-LUT to .cube")
    p_m2c.add_argument("input", type=pathlib.Path)
    p_m2c.add_argument("output", type=pathlib.Path)
    p_m2c.add_argument("--title", default="Exported_OPPO_MS_LUT")

    p_c2m = sub.add_parser("cube-to-mslut", help="Bake .cube to .MS-LUT")
    p_c2m.add_argument("input", type=pathlib.Path)
    p_c2m.add_argument("output", type=pathlib.Path)
    p_c2m.add_argument("--dim", type=int, default=32, choices=[17, 32])
    p_c2m.add_argument("--direct-srgb", action="store_true", help="Disable Display P3 <-> Rec.709 OkLCh gamut mapping")

    p_ins = sub.add_parser("inspect-tail", help="Inspect OPPO FileExtendedContainer tail & filter.info")
    p_ins.add_argument("input", type=pathlib.Path)

    p_inj = sub.add_parser("inject-filter", help="Non-destructively inject filter.info into OPPO JPEG/HEIC")
    p_inj.add_argument("input", type=pathlib.Path)
    p_inj.add_argument("output", type=pathlib.Path)
    p_inj.add_argument("--filter-type", required=True)
    p_inj.add_argument("--strength", type=int, default=100)
    p_inj.add_argument("--orientation", type=int, default=0)
    p_inj.add_argument("--soft-light-type", type=int, default=0)
    p_inj.add_argument("--soft-light", action="store_true")
    p_inj.add_argument("--palette", action="store_true")
    p_inj.add_argument("--palette-saturation", type=int, default=0)
    p_inj.add_argument("--palette-tone", type=int, default=0)
    p_inj.add_argument("--no-src-image", action="store_true")

    args = parser.parse_args()

    if args.cmd == "mslut-to-cube":
        n, _coords, rgb = parse_mslut(args.input.read_bytes())
        lines = [
            f'TITLE "{args.title}"',
            f"LUT_3D_SIZE {n}",
            "DOMAIN_MIN 0.0 0.0 0.0",
            "DOMAIN_MAX 1.0 1.0 1.0",
        ]
        for r, g, b in rgb:
            lines.append(f"{r / 255.0:.6f} {g / 255.0:.6f} {b / 255.0:.6f}")
        args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(json.dumps({"success": True, "dimension": n, "output": str(args.output)}))
        return 0

    if args.cmd == "cube-to-mslut":
        src_n, table = parse_cube(args.input.read_text(encoding="utf-8"))
        n = args.dim
        rgb_out: List[Tuple[int, int, int]] = []
        for ib in range(n):
            b_in = ib / (n - 1)
            for ig in range(n):
                g_in = ig / (n - 1)
                for ir in range(n):
                    r_in = ir / (n - 1)
                    if args.direct_srgb:
                        ro, go, bo = sample_cube(src_n, table, r_in, g_in, b_in)
                    else:
                        p3_lin = (srgb_eotf(r_in), srgb_eotf(g_in), srgb_eotf(b_in))
                        rec709_lin = mat3_mul(M_P3_TO_709, p3_lin)
                        rec709_map = gamut_map_oklch_rec709(rec709_lin)
                        srgb_in = (srgb_oetf(rec709_map[0]), srgb_oetf(rec709_map[1]), srgb_oetf(rec709_map[2]))
                        srgb_out = sample_cube(src_n, table, *srgb_in)
                        rec709_out_lin = (srgb_eotf(srgb_out[0]), srgb_eotf(srgb_out[1]), srgb_eotf(srgb_out[2]))
                        p3_out_lin = mat3_mul(M_709_TO_P3, rec709_out_lin)
                        ro, go, bo = (srgb_oetf(p3_out_lin[0]), srgb_oetf(p3_out_lin[1]), srgb_oetf(p3_out_lin[2]))
                    rgb_out.append((
                        int(round(max(0.0, min(1.0, ro)) * 255.0)),
                        int(round(max(0.0, min(1.0, go)) * 255.0)),
                        int(round(max(0.0, min(1.0, bo)) * 255.0)),
                    ))
        out_bytes = encode_mslut(n, rgb_out)
        args.output.write_bytes(out_bytes)
        print(json.dumps({"success": True, "dimension": n, "byteLength": len(out_bytes), "output": str(args.output)}))
        return 0

    if args.cmd == "inspect-tail":
        data = args.input.read_bytes()
        parsed = parse_oppo_tail(data)
        if parsed is None:
            print(json.dumps({"hasOppoTail": False, "fileSize": len(data)}, indent=2, ensure_ascii=False))
            return 0
        base_end, entries = parsed
        report: Dict[str, object] = {
            "hasOppoTail": True,
            "baseMediaEnd": base_end,
            "entries": [{"name": k, "version": v, "length": len(b)} for k, v, b in entries],
        }
        for k, _v, b in entries:
            if k == "filter.info":
                report["filterInfo"] = parse_filter_info(b)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    if args.cmd == "inject-filter":
        data = args.input.read_bytes()
        parsed = parse_oppo_tail(data)
        base_end = parsed[0] if parsed else len(data)
        has_src = any(k == "src.image" for k, _, _ in (parsed[1] if parsed else []))
        fi_bytes = build_filter_info(
            filter_type=args.filter_type,
            strength=args.strength,
            orientation=args.orientation,
            soft_light_type=args.soft_light_type,
            is_soft_light=args.soft_light,
            is_palette=args.palette,
            palette_saturation=args.palette_saturation,
            palette_tone=args.palette_tone,
        )
        updates: Dict[str, Optional[bytes]] = {"filter.info": fi_bytes}
        if not args.no_src_image and not has_src:
            updates["src.image"] = data[:base_end]
        out_bytes = upsert_oppo_tail(data, updates)
        args.output.write_bytes(out_bytes)
        print(json.dumps({"success": True, "output": str(args.output), "filterInfo": parse_filter_info(fi_bytes)}, ensure_ascii=False))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
