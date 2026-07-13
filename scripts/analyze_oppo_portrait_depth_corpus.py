#!/usr/bin/env python3
"""Extract OPPO portrait depth/header/config metrics from original HEIC files."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import statistics
import struct
import subprocess
from pathlib import Path

def percentile(values: list[int], fraction: float) -> int:
    return values[int((len(values) - 1) * fraction)]


def original_candidates(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.glob("IMG*.heic")
        if "（" not in path.name and " (" not in path.name and "_" not in path.stem
    )


def exif_rows(paths: list[Path]) -> list[dict[str, object]]:
    command = [
        "exiftool",
        "-j",
        "-n",
        "-FileName",
        "-UserComment",
        "-FocalLength",
        "-FocalLengthIn35mmFormat",
        "-DigitalZoomRatio",
        "-FNumber",
        "-DateTimeOriginal",
        *(str(path) for path in paths),
    ]
    return json.loads(subprocess.check_output(command))


def extension_entries(data: bytes) -> list[dict[str, object]]:
    marker = max(data.rfind(b"jxrs"), data.rfind(b"wtmk"))
    if marker < 0:
        return []
    json_end = marker - 1 if marker > 0 and data[marker - 1] == 0 else marker
    json_start = data.rfind(b"[{", 0, json_end)
    if json_start < 0:
        return []
    manifest = json.loads(data[json_start:json_end].decode("utf-8"))
    entries: list[dict[str, object]] = []
    for item in manifest:
        if not isinstance(item, dict):
            continue
        try:
            length = int(item["length"])
            offset = int(item["offset"])
        except (KeyError, TypeError, ValueError):
            continue
        start = json_start - offset
        end = start + length
        if 0 <= start <= end <= len(data):
            entries.append({**item, "start": start, "end": end})
    return entries


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    """Return the storage dimensions from the first JPEG in src.image."""
    if not data.startswith(b"\xff\xd8"):
        raise ValueError("src.image does not start with JPEG SOI")
    cursor = 2
    sof_markers = {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    }
    while cursor + 4 <= len(data):
        if data[cursor] != 0xFF:
            cursor += 1
            continue
        while cursor < len(data) and data[cursor] == 0xFF:
            cursor += 1
        if cursor >= len(data):
            break
        marker = data[cursor]
        cursor += 1
        if marker in {0x01, 0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if cursor + 2 > len(data):
            break
        segment_length = int.from_bytes(data[cursor : cursor + 2], "big")
        if segment_length < 2 or cursor + segment_length > len(data):
            break
        if marker in sof_markers and segment_length >= 7:
            height = int.from_bytes(data[cursor + 3 : cursor + 5], "big")
            width = int.from_bytes(data[cursor + 5 : cursor + 7], "big")
            return width, height
        cursor += segment_length
    raise ValueError("unable to find JPEG SOF dimensions in src.image")


def analyze(path: Path, exif: dict[str, object]) -> dict[str, object] | None:
    file_data = path.read_bytes()
    entries = extension_entries(file_data)
    depth_entry = next((entry for entry in entries if entry.get("name") == "rear.depth"), None)
    config_entry = next(
        (entry for entry in entries if entry.get("name") == "rear.depth.config"),
        None,
    )
    src_entry = next((entry for entry in entries if entry.get("name") == "src.image"), None)
    if depth_entry is None or config_entry is None or src_entry is None:
        return None

    src_image = file_data[src_entry["start"] : src_entry["end"]]
    src_width, src_height = jpeg_dimensions(src_image)

    encoded_depth = file_data[depth_entry["start"] : depth_entry["end"]]
    decoded_depth = subprocess.check_output(
        ["zstd", "-d", "-q", "-c"],
        input=encoded_depth,
    )
    depth_width, depth_height = struct.unpack_from("<II", decoded_depth, 0)
    ranks = decoded_depth[768 : 768 + depth_width * depth_height]
    if len(ranks) != depth_width * depth_height:
        raise ValueError("truncated rank plane")

    config = file_data[config_entry["start"] : config_entry["end"]]
    config_width, config_height, focus_x, focus_y = struct.unpack_from("<4i", config, 4)
    blur_strength = struct.unpack_from("<i", config, 276)[0]
    config_fnumber = struct.unpack_from("<f", config, 292)[0]
    config_distance = struct.unpack_from("<i", config, 296)[0]
    sample_scale, focal_length_depth, stereo_baseline = struct.unpack_from(
        "<fff", decoded_depth, 0x18
    )
    near_object_flag = decoded_depth[0x27]
    near_object_confidence = struct.unpack_from("<f", decoded_depth, 0x28)[0]
    plant_object_flag = decoded_depth[0x2C]
    min_disparity_u16, max_disparity_u16 = struct.unpack_from("<HH", decoded_depth, 0x2E)
    disparity_exponentiation = decoded_depth[0x32]
    plane_size = depth_width * depth_height
    plane_cursor = 768 + plane_size
    plane_stats: dict[str, object] = {}
    for name, flag_offset in (("hair", 0x24), ("portrait", 0x25), ("pet", 0x26)):
        present = decoded_depth[flag_offset] != 0
        plane_stats[f"{name}_flag"] = int(present)
        if present and plane_cursor + plane_size <= len(decoded_depth):
            plane = decoded_depth[plane_cursor : plane_cursor + plane_size]
            plane_stats[f"{name}_min"] = min(plane)
            plane_stats[f"{name}_max"] = max(plane)
            plane_stats[f"{name}_nonzero_fraction"] = sum(value != 0 for value in plane) / plane_size
            plane_cursor += plane_size
        else:
            plane_stats[f"{name}_min"] = ""
            plane_stats[f"{name}_max"] = ""
            plane_stats[f"{name}_nonzero_fraction"] = ""
    # RenderInfo begins at 0x180. Producer-side native logs and stores identify
    # these fields as object_distance, aecLuxIdx, and appZoomRatio respectively.
    header_object_distance = struct.unpack_from("<i", decoded_depth, 0x1B4)[0]
    header_aec_lux_index = struct.unpack_from("<f", decoded_depth, 0x1B8)[0]
    header_app_zoom_ratio = struct.unpack_from("<f", decoded_depth, 0x1BC)[0]

    ordered = sorted(ranks)

    # configWidth/configHeight describe the algorithm canvas (normally
    # 900x1200), but focusX/focusY are stored in src.image's raw JPEG pixel
    # coordinates. The rank and subject planes use that same storage direction.
    focus_rank_x = min(
        depth_width - 1,
        max(0, round(focus_x / src_width * depth_width)),
    )
    focus_rank_y = min(
        depth_height - 1,
        max(0, round(focus_y / src_height * depth_height)),
    )
    local: list[int] = []
    for y in range(max(0, focus_rank_y - 10), min(depth_height, focus_rank_y + 11)):
        row = y * depth_width
        local.extend(
            ranks[
                row + max(0, focus_rank_x - 10) : row + min(depth_width, focus_rank_x + 11)
            ]
        )
    local.sort()
    focus_rank_median = float(statistics.median(local))
    # The producer kernel stores an inverse normalized 16-bit disparity:
    # rank/255 = normalized^(1/exponentiation). All current samples use 1,
    # while a non-1 package requires undoing that power before min/max.
    rank_power = max(1, disparity_exponentiation)
    normalized_focus = (focus_rank_median / 255.0) ** rank_power
    focus_internal_disparity16 = 65_535.0 - (
        min_disparity_u16
        + normalized_focus * (max_disparity_u16 - min_disparity_u16)
    )

    return {
        "file": path.name,
        "date": exif.get("DateTimeOriginal", ""),
        "physical_focal_mm": exif.get("FocalLength", ""),
        "equivalent_focal_mm": exif.get("FocalLengthIn35mmFormat", ""),
        "digital_zoom": exif.get("DigitalZoomRatio", 1) or 1,
        "exif_fnumber": exif.get("FNumber", ""),
        "config_fnumber": config_fnumber,
        "config_distance": config_distance,
        "blur_strength": blur_strength,
        "config_width": config_width,
        "config_height": config_height,
        "src_width": src_width,
        "src_height": src_height,
        "focus_x": focus_x,
        "focus_y": focus_y,
        "focus_rank_x": focus_rank_x,
        "focus_rank_y": focus_rank_y,
        "depth_width": depth_width,
        "depth_height": depth_height,
        "header_sample_scale": sample_scale,
        "header_fx_depth": focal_length_depth,
        "header_baseline": stereo_baseline,
        "header_near_object_flag": near_object_flag,
        "header_near_object_confidence": near_object_confidence,
        "header_plant_object_flag": plant_object_flag,
        "header_min_disparity_u16": min_disparity_u16,
        "header_max_disparity_u16": max_disparity_u16,
        "header_disparity_exponentiation": disparity_exponentiation,
        "header_object_distance": header_object_distance,
        "header_aec_lux_index": header_aec_lux_index,
        "header_app_zoom_ratio": header_app_zoom_ratio,
        **plane_stats,
        "depth_trailing_after_same_size_planes": len(decoded_depth) - plane_cursor,
        "manifest_names": ";".join(str(entry.get("name", "")) for entry in entries),
        "src_image_bytes": next(
            (int(entry["length"]) for entry in entries if entry.get("name") == "src.image"),
            0,
        ),
        "rear_depth_compressed_bytes": int(depth_entry["length"]),
        "rear_depth_decoded_bytes": len(decoded_depth),
        "effective_fx_src": focal_length_depth * src_width / depth_width,
        "rank_min": ordered[0],
        "rank_p01": percentile(ordered, 0.01),
        "rank_p10": percentile(ordered, 0.10),
        "rank_p25": percentile(ordered, 0.25),
        "rank_p50": percentile(ordered, 0.50),
        "rank_p75": percentile(ordered, 0.75),
        "rank_p90": percentile(ordered, 0.90),
        "rank_p99": percentile(ordered, 0.99),
        "rank_max": ordered[-1],
        "rank_p99_p01": percentile(ordered, 0.99) - percentile(ordered, 0.01),
        "rank_p90_p10": percentile(ordered, 0.90) - percentile(ordered, 0.10),
        "rank_focus": ranks[focus_rank_y * depth_width + focus_rank_x],
        "rank_focus_local_median": focus_rank_median,
        "rank_focus_local_p10": percentile(local, 0.10),
        "rank_focus_local_p90": percentile(local, 0.90),
        "focus_internal_disparity16": focus_internal_disparity16,
        "focus_internal_disparity16_over_fx": (
            focus_internal_disparity16 / focal_length_depth
        ),
        "rank_unique": len(set(ranks)),
        "file_sha256": hashlib.sha256(file_data).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_csv", type=Path)
    args = parser.parse_args()

    paths = original_candidates(args.input_dir)
    metadata = exif_rows(paths)
    rows = [
        row
        for path, exif in zip(paths, metadata)
        if (row := analyze(path, exif)) is not None
    ]
    if not rows:
        raise SystemExit("no OPPO rear portrait-depth samples found")

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.output_csv.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to {args.output_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
