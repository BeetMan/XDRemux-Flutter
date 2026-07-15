#!/usr/bin/env python3
"""Emit a canonical inspect JSON for an XDRemux source file.

Mirrors the Rust `xdremux-conformance inspect` output schema
(`xdremux-conformance/1`) so that the Rust compare tool can diff the two
implementations' views of the same input.

Usage:
    python3 -m xdremux.conformance.inspect <input.heic> <output.json>
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Optional

# Ensure sibling modules resolve when invoked as a script.
_HERE = Path(__file__).resolve()
_PROJECT_ROOT = _HERE.parents[3]
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from xdremux.python import container, edr, iso21496  # noqa: E402
from xdremux.python.isobmff_patch import (  # noqa: E402
    _build_iso_gainmap_metadata_payload,
    _build_imageio_native_tmap_config,
    _build_tmap_config,
    _first_number,
)

SCHEMA_VERSION = "xdremux-conformance/1"
IMPLEMENTATION = "python"
PYTHON_VERSION = "0.1.0"
MAX_META_FLOATS = 32


def _md5_hex(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def _hex(data: bytes) -> str:
    return data.hex()


def _build_iso_meta(extracted: container.ExtractedLHDR) -> Optional[dict[str, Any]]:
    if extracted.mode == "uhdr":
        if len(extracted.meta_floats) >= 20:
            meta = iso21496.build_iso21496_metadata_from_uhdr(extracted.meta_floats)
        else:
            # Synthesize a minimal multichannel IsoMeta for short UHDR lists.
            scale = float(extracted.meta_floats[18]) if len(extracted.meta_floats) > 18 else 1.0
            ratio_max = max(
                (float(extracted.meta_floats[4]) if len(extracted.meta_floats) > 4 else 0.0),
                (float(extracted.meta_floats[5]) if len(extracted.meta_floats) > 5 else 0.0),
                (float(extracted.meta_floats[6]) if len(extracted.meta_floats) > 6 else 0.0),
            )
            cap_max = ratio_max.bit_length() - 1 if ratio_max > 0 else 0  # log2
            # Use math.log2 to match the Rust implementation
            import math
            cap_max = math.log2(ratio_max) if ratio_max > 0 else 0.0
            meta = {
                "gainMapMin": [0.0, 0.0, 0.0],
                "gainMapMax": [cap_max, cap_max, cap_max],
                "gamma": [1.0, 1.0, 1.0],
                "offsetSdr": [0.0, 0.0, 0.0],
                "offsetHdr": [0.0, 0.0, 0.0],
                "hdrCapacityMin": 0.0,
                "hdrCapacityMax": cap_max,
                "baseRenditionIsHDR": False,
                "scale": scale,
            }
    else:
        scale = edr.edr_scale_calculator(list(extracted.meta_floats))
        meta = iso21496.build_iso21496_metadata(scale)
    return meta


def _synthesize_info_floats(meta: dict[str, Any]) -> list[float]:
    """Reconstruct a 20-float info block matching Rust's synthesize_info_floats."""
    def exp(v: float) -> float:
        return 2.0 ** v if v > 0.0 else 1.0
    gm_min = list(meta.get("gainMapMin", [0.0, 0.0, 0.0]))
    gm_max = list(meta.get("gainMapMax", [0.0, 0.0, 0.0]))
    gamma = list(meta.get("gamma", [1.0, 1.0, 1.0]))
    offset_sdr = list(meta.get("offsetSdr", [0.0, 0.0, 0.0]))
    offset_hdr = list(meta.get("offsetHdr", [0.0, 0.0, 0.0]))
    while len(gm_min) < 3: gm_min.append(0.0)
    while len(gm_max) < 3: gm_max.append(0.0)
    while len(gamma) < 3: gamma.append(1.0)
    while len(offset_sdr) < 3: offset_sdr.append(0.0)
    while len(offset_hdr) < 3: offset_hdr.append(0.0)
    return [
        exp(gm_min[0]), exp(gm_min[1]), exp(gm_min[2]),
        1.0,
        exp(gm_max[0]), exp(gm_max[1]), exp(gm_max[2]),
        gamma[0], gamma[1], gamma[2],
        offset_sdr[0], offset_sdr[1], offset_sdr[2],
        offset_hdr[0], offset_hdr[1], offset_hdr[2],
        exp(meta.get("hdrCapacityMin", 0.0)),
        exp(meta.get("hdrCapacityMax", 0.0)),
        float(meta.get("scale", 1.0)),
        1.0 if meta.get("baseRenditionIsHDR", False) else 0.0,
    ]


def _extract_xmp_field(xmp: str, element: str) -> Optional[str]:
    needle_open = f"<{element}>"
    needle_close = f"</{element}>"
    start = xmp.find(needle_open)
    if start < 0:
        return None
    start += len(needle_open)
    end = xmp.find(needle_close, start)
    if end < 0:
        return None
    return xmp[start:end].strip()


def _payload_entry(data: bytes) -> dict[str, Any]:
    return {
        "size": len(data),
        "md5": _md5_hex(data),
        "first16": _hex(data[:16]),
    }


def _iso_meta_to_block(meta: Optional[dict[str, Any]]) -> Optional[dict[str, Any]]:
    if meta is None:
        return None
    channel_count = 3 if any(meta.get(f, [0.0, 0.0, 0.0])[:3] for f in
                              ("gainMapMin", "gainMapMax", "gamma", "offsetSdr", "offsetHdr")) else 1
    # Detect by listing present values: a single value lists to length 1.
    first_field = meta.get("gainMapMax", [0.0])
    if isinstance(first_field, (list, tuple)) and len(first_field) == 1:
        channel_count = 1
    return {
        "channel_count": channel_count,
        "gain_map_min": list(meta.get("gainMapMin", [0.0])),
        "gain_map_max": list(meta.get("gainMapMax", [0.0])),
        "gamma": list(meta.get("gamma", [1.0])),
        "offset_sdr": list(meta.get("offsetSdr", [0.0])),
        "offset_hdr": list(meta.get("offsetHdr", [0.0])),
        "hdr_capacity_min": float(meta.get("hdrCapacityMin", 0.0)),
        "hdr_capacity_max": float(meta.get("hdrCapacityMax", 0.0)),
        "base_rendition_is_hdr": bool(meta.get("baseRenditionIsHDR", False)),
        "scale": float(meta.get("scale", 1.0)),
    }


def build_json(input_path: Path, extracted: container.ExtractedLHDR) -> dict[str, Any]:
    iso_meta_dict = _build_iso_meta(extracted)

    family = "x7" if (extracted.meta_floats and extracted.meta_floats[0] >= 3.0) or extracted.mode == "uhdr" else "x6"
    edr_scale = iso_meta_dict.get("scale", 1.0) if iso_meta_dict else 1.0

    # Limit meta_floats dump to keep diffs small but mark truncation.
    truncated = len(extracted.meta_floats) > MAX_META_FLOATS
    meta_floats_dump = list(extracted.meta_floats[:MAX_META_FLOATS])

    info_floats = _synthesize_info_floats(iso_meta_dict) if iso_meta_dict else None

    payloads: dict[str, Any] = {}
    if info_floats is not None:
        # Apple 62B and ImageIO 142B both take a 20-float info block.
        # We synthesize the same info block that Rust uses.
        apple_payload = _build_tmap_config(iso_meta_dict, oppo_compat=False)
        payloads["apple_62"] = _payload_entry(apple_payload)
        imageio_payload = _build_imageio_native_tmap_config(iso_meta_dict)
        payloads["imageio_142"] = _payload_entry(imageio_payload)
        # Strict ISO 21496-1 144B payload
        iso_payload = _build_iso_gainmap_metadata_payload(iso_meta_dict)
        payloads["iso21496"] = _payload_entry(iso_payload)

    xmp_block: Optional[dict[str, Any]] = None
    if iso_meta_dict is not None:
        xmp = iso21496.format_hdrgm_xmp(iso_meta_dict)
        xmp_bytes = xmp.encode("utf-8")
        xmp_block = {
            "length": len(xmp_bytes),
            "md5": _md5_hex(xmp_bytes),
            "hdrgm": {
                "version": _extract_xmp_field(xmp, "hdrgm:Version") or "",
                "gainMapMax": _extract_xmp_field(xmp, "hdrgm:GainMapMax") or "",
                "gainMapMin": _extract_xmp_field(xmp, "hdrgm:GainMapMin") or "",
                "hdrCapacityMax": _extract_xmp_field(xmp, "hdrgm:HDRCapacityMax") or "",
            },
        }

    return {
        "schema": SCHEMA_VERSION,
        "implementation": IMPLEMENTATION,
        "version": PYTHON_VERSION,
        "source": str(input_path),
        "lhdr": {
            "mode": extracted.mode,
            "meta_floats": meta_floats_dump,
            "meta_floats_truncated": "true" if truncated else "false",
            "mask_data_len": len(extracted.mask_data) if extracted.mask_data else None,
            "gainmap_data_len": len(extracted.gainmap_data) if extracted.gainmap_data else None,
            "container_status": "ok",
        },
        "edr_scale": float(edr_scale),
        "family": family,
        "iso_meta": _iso_meta_to_block(iso_meta_dict),
        "tmap_payloads": payloads,
        "xmp": xmp_block,
    }


def run(input_path: Path, output_path: Path) -> int:
    try:
        extracted = container.extract_lhdr(str(input_path))
    except Exception as e:  # noqa: BLE001 - report any failure as a JSON error
        err = {
            "schema": SCHEMA_VERSION,
            "implementation": IMPLEMENTATION,
            "version": PYTHON_VERSION,
            "source": str(input_path),
            "lhdr": {
                "mode": f"error: {e}",
                "meta_floats": [],
                "meta_floats_truncated": "false",
                "mask_data_len": None,
                "gainmap_data_len": None,
                "container_status": f"error: {e}",
            },
            "edr_scale": 0.0,
            "family": "x6",
            "iso_meta": None,
            "tmap_payloads": {
                "apple_62": None,
                "imageio_142": None,
                "iso21496": None,
            },
            "xmp": None,
        }
        with output_path.open("w", encoding="utf-8") as f:
            json.dump(err, f, indent=2)
        return 0  # not an error from the script's perspective; the file is the report

    data = build_json(input_path, extracted)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: inspect_heic.py <input.heic> <output.json>", file=sys.stderr)
        sys.exit(2)
    sys.exit(run(Path(sys.argv[1]), Path(sys.argv[2])))
