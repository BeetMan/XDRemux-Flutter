#!/usr/bin/env python3
"""Probe two OPPO camera-tail entries against the layouts read from ColorOS
Gallery 17.24.12 (see oppo-gallery-17.24.12-20261114.md).

  filter.info              -> struct fields in on-disk order
  watermark.master.params  -> frame quad at len-56, read as corners, checked
                              against dp2Pixel(short side, margin dp, base 360)

Usage: python3 docs/research/oppo_gallery_tail_probe.py <file-or-dir>...
Standard library only. Reads files; writes nothing.
"""
import collections
import json
import os
import struct
import sys

# size.{left,top,right,bottom}Margin in dp, copied from
# assets/watermark_master_styles/<style>.json in the 17.24.12 APK.
STYLE_MARGINS_DP = {
    "hassel_style_1": (0, 0, 0, 60),
    "hassel_style_4": (10, 79, 10, 79),
    "hassel_style_master_mode_1": (10, 79, 10, 79),
}
BASE_IMAGE_SIZE = 360
# The file stores 5.1 as a 32-bit float, which is slightly below the double 5.1.
VERSION_5_1 = struct.unpack("<f", struct.pack("<f", 5.1))[0]


def tail_manifest(data):
    """Return (json_start, entries) for the OPPO tail manifest, or None."""
    start = data.rfind(b'[{"')
    if start < 0:
        return None
    end = data.find(b"]", start)
    while end > 0:
        try:
            return start, json.loads(data[start:end + 1].decode("utf-8"))
        except ValueError:
            end = data.find(b"]", end + 1)
    return None


def entry(data, json_start, entries, name):
    for item in entries:
        if item.get("name") == name:
            begin = json_start - item["offset"]
            return data[begin:begin + item["length"]]
    return None


def cstr(raw):
    return raw.split(b"\0")[0].decode("utf-8", "replace")


def primary_dims(data):
    """Stored frame size: first SOF of a JPEG, else the largest ispe (the grid
    item's full frame for OPPO HEIC)."""
    if data[:2] == b"\xff\xd8":
        pos = 2
        while pos + 9 < len(data) and data[pos] == 0xFF:
            marker, size = data[pos + 1], struct.unpack_from(">H", data, pos + 2)[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack_from(">HH", data, pos + 5)
                return w, h
            pos += 2 + size
        return 0, 0
    best, pos = (0, 0), data.find(b"ispe")
    while pos >= 0:
        w, h = struct.unpack_from(">II", data, pos + 8)
        if w * h > best[0] * best[1] and w < 65536 and h < 65536:
            best = (w, h)
        pos = data.find(b"ispe", pos + 4)
    return best


def dp2pixel(short_side, dp, base=BASE_IMAGE_SIZE):
    """MasterWatermarkElementProcessor.dp2Pixel(Size, double, int)."""
    value = int(dp * short_side / base)
    return value + 1 if value % 2 else value


def decode_filter_info(raw):
    out = collections.OrderedDict()
    names = ("version", "filterIntensity", "srcOrientation", "srcMirror",
             "softLightEnable", "softLightType", "filterEnable")
    out.update(zip(names, struct.unpack_from("<f6i", raw, 0)))
    out["filterType"] = cstr(raw[28:128])
    version = out["version"]
    if version >= 2.0 and len(raw) >= 132:
        out["colorTemperature"] = struct.unpack_from("<f", raw, 128)[0]
    if version >= 4.0 and len(raw) >= 140:
        out["luxIndex"], out["filterSaturation"] = struct.unpack_from("<2f", raw, 132)
    if version >= 5.0 and len(raw) >= 206:
        names = ("isPalette", "paletteAlgoUsed", "portraitMaskUsed", "filterTone")
        out.update(zip(names, struct.unpack_from("<4i", raw, 140)))
        out["captureMode"] = cstr(raw[156:206])
    if version >= VERSION_5_1 and len(raw) >= 220:
        # Camera files (Find X10, 228 bytes) keep 8 zero bytes at 208 and the
        # three values at 216. The 17.24.12 parser struct would put them at
        # 208; that 220-byte shape has no sample.
        names = ("avgLuma", "brightLuma", "darkLuma")
        out["lumaOffset"] = 216 if len(raw) >= 228 else 208
        out.update(zip(names, struct.unpack_from("<3f", raw, out["lumaOffset"])))
    if len(raw) > 140:
        # Raw 4-byte words from 140 on, so an unknown layout can be read by eye.
        out["wordsFrom140"] = ".".join(raw[o:o + 4].hex() for o in range(140, len(raw), 4))
    return out


def check_master_params(raw, dims):
    style = cstr(raw[4:68])
    left, top, right, bottom = (int(v) for v in struct.unpack_from("<4f", raw, len(raw) - 56 + 24))
    width, height = dims
    content = (right - left, bottom - top)
    margins = (left, top, width - right, height - bottom)
    line = (f"style={style} len={len(raw)} primary={width}x{height} "
            f"quad={left},{top},{right},{bottom} content={content[0]}x{content[1]} "
            f"margins={','.join(map(str, margins))}")
    verdict = None
    if style in STYLE_MARGINS_DP and width and height:
        expect = tuple(dp2pixel(min(content), dp) for dp in STYLE_MARGINS_DP[style])
        verdict = expect == margins
        line += f" dp2Pixel={','.join(map(str, expect))} match={verdict}"
    return line, verdict


def main(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            for folder, _, names in os.walk(path):
                files += [os.path.join(folder, n) for n in sorted(names)
                          if n.lower().endswith((".heic", ".heif", ".jpg", ".jpeg"))]
        else:
            files.append(path)
    counts = collections.Counter()
    for path in files:
        with open(path, "rb") as handle:
            data = handle.read()
        counts["files"] += 1
        manifest = tail_manifest(data)
        if not manifest:
            continue
        counts["with_tail"] += 1
        json_start, entries = manifest
        name = os.path.basename(path)
        raw = entry(data, json_start, entries, "filter.info")
        if raw and len(raw) >= 128:
            counts["filter.info"] += 1
            fields = decode_filter_info(raw)
            text = " ".join(f"{k}={v:.2f}" if isinstance(v, float) else f"{k}={v}"
                            for k, v in fields.items())
            print(f"{name} filter.info len={len(raw)} {text}")
        raw = entry(data, json_start, entries, "watermark.master.params")
        if raw and len(raw) >= 80:
            counts["watermark.master.params"] += 1
            line, verdict = check_master_params(raw, primary_dims(data))
            if verdict is not None:
                counts["dp2Pixel match" if verdict else "dp2Pixel mismatch"] += 1
            print(f"{name} watermark.master.params {line}")
    print("summary:", dict(counts))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
