#!/usr/bin/env python3
"""Extract OPPO Gallery rectified NV21 guides and compare primary/src/rank."""

from __future__ import annotations

import argparse
from io import BytesIO
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

try:
    from inspect_oppo_heif import inspect
except ModuleNotFoundError:
    common_git_dir = Path(
        subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=Path(__file__).resolve().parent,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()
    ).resolve()
    sys.path.insert(0, str(common_git_dir.parent / "scripts"))
    from inspect_oppo_heif import inspect


ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
HEADER_SIZE = 0x300


def decompress_zstd(frame: bytes) -> bytes:
    executable = shutil.which("zstd")
    if executable is None:
        raise RuntimeError("zstd executable is required")
    process = subprocess.run(
        [executable, "-d", "--stdout", "--quiet"],
        input=frame,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(message or f"zstd exited with status {process.returncode}")
    return process.stdout


def nv21_to_rgb(frame: bytes, width: int, height: int) -> Image.Image:
    expected = width * height * 3 // 2
    if len(frame) != expected:
        raise ValueError(f"NV21 frame has {len(frame)} bytes, expected {expected}")
    y = np.frombuffer(frame, dtype=np.uint8, count=width * height).reshape(height, width)
    vu = np.frombuffer(frame, dtype=np.uint8, offset=width * height).reshape(height // 2, width)
    v = vu[:, 0::2].repeat(2, axis=0).repeat(2, axis=1).astype(np.float32)
    u = vu[:, 1::2].repeat(2, axis=0).repeat(2, axis=1).astype(np.float32)
    c = np.maximum(y.astype(np.float32) - 16.0, 0.0)
    d = u - 128.0
    e = v - 128.0
    rgb = np.stack(
        (
            1.164383 * c + 1.596027 * e,
            1.164383 * c - 0.391762 * d - 0.812968 * e,
            1.164383 * c + 2.017232 * d,
        ),
        axis=-1,
    )
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), mode="RGB")


def apply_orientation(image: Image.Image, orientation: int) -> Image.Image:
    operations = {
        2: Image.Transpose.FLIP_LEFT_RIGHT,
        3: Image.Transpose.ROTATE_180,
        4: Image.Transpose.FLIP_TOP_BOTTOM,
        5: Image.Transpose.TRANSPOSE,
        6: Image.Transpose.ROTATE_270,
        7: Image.Transpose.TRANSVERSE,
        8: Image.Transpose.ROTATE_90,
    }
    operation = operations.get(orientation)
    return image.transpose(operation) if operation is not None else image.copy()


def locate_trailing_rectified_pair(decoded: bytes) -> tuple[int, int, int]:
    candidates: set[tuple[int, int]] = set()
    for offset in range(0, HEADER_SIZE - 7, 4):
        width, height = struct.unpack_from("<II", decoded, offset)
        if 64 <= width <= 8192 and 64 <= height <= 8192 and width % 2 == 0 and height % 2 == 0:
            candidates.add((width, height))
    for width, height in candidates:
        pair_bytes = width * height * 3
        offset = len(decoded) - pair_bytes - 8
        if offset >= HEADER_SIZE and struct.unpack_from("<II", decoded, offset) == (width, height):
            return offset, width, height
    raise ValueError("no trailing [width,height,master NV21,slave NV21] group found")


def fit_panel(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    panel = Image.new("RGB", size, "black")
    fitted = ImageOps.contain(image.convert("RGB"), size)
    panel.paste(fitted, ((size[0] - fitted.width) // 2, (size[1] - fitted.height) // 2))
    return panel


def contact_sheet(items: list[tuple[str, Image.Image]], output: Path) -> None:
    panel_size = (460, 620)
    title_height = 34
    columns = 3
    rows = (len(items) + columns - 1) // columns
    canvas = Image.new("RGB", (panel_size[0] * columns, (panel_size[1] + title_height) * rows), "white")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=17)
    for index, (title, image) in enumerate(items):
        x = index % columns * panel_size[0]
        y = index // columns * (panel_size[1] + title_height)
        canvas.paste(fit_panel(image, panel_size), (x, y + title_height))
        draw.text((x + 10, y + 7), title, fill="black", font=font)
    canvas.save(output, quality=95)


def extract(input_path: Path, output_dir: Path) -> dict[str, object]:
    report = inspect(input_path)
    entries = {entry.get("name"): entry for entry in report.get("extension_tail", {}).get("entries", [])}
    depth_entry = entries.get("rear.depth")
    src_entry = entries.get("src.image")
    if depth_entry is None or src_entry is None:
        raise ValueError("input must contain rear.depth and src.image")

    source = input_path.read_bytes()
    encoded = source[int(depth_entry["start"]):int(depth_entry["end"])]
    magic_offset = encoded.find(ZSTD_MAGIC)
    if magic_offset < 0:
        raise ValueError("rear.depth does not contain a Zstandard frame")
    decoded = decompress_zstd(encoded[magic_offset:])
    depth_width, depth_height = struct.unpack_from("<II", decoded, 0)
    plane_size = depth_width * depth_height
    rank = decoded[HEADER_SIZE:HEADER_SIZE + plane_size]

    pair_offset, guide_width, guide_height = locate_trailing_rectified_pair(decoded)
    frame_size = guide_width * guide_height * 3 // 2
    master_start = pair_offset + 8
    master = decoded[master_start:master_start + frame_size]
    slave = decoded[master_start + frame_size:master_start + 2 * frame_size]

    src_bytes = source[int(src_entry["start"]):int(src_entry["end"])]
    with Image.open(BytesIO(src_bytes)) as src_reader:
        orientation = int(src_reader.getexif().get(274, 1))
        src_display = apply_orientation(src_reader.convert("RGB"), orientation)
    rank_display = apply_orientation(Image.frombytes("L", (depth_width, depth_height), rank), orientation)
    rank_color = ImageOps.colorize(rank_display, black="#091833", mid="#24b3a8", white="#fff29a")
    master_display = apply_orientation(nv21_to_rgb(master, guide_width, guide_height), orientation)
    slave_display = apply_orientation(nv21_to_rgb(slave, guide_width, guide_height), orientation)

    output_dir.mkdir(parents=True, exist_ok=True)
    outer_path = output_dir / "outer_primary_display.jpg"
    subprocess.run(
        ["sips", "-s", "format", "jpeg", str(input_path), "--out", str(outer_path)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    with Image.open(outer_path) as outer_reader:
        outer_display = ImageOps.exif_transpose(outer_reader).convert("RGB")
        outer_display.save(outer_path, quality=95)

    outputs = {
        "outer_primary": outer_path,
        "src_display": output_dir / "src_image_display.jpg",
        "rank_color": output_dir / "rank_color_display.png",
        "rectified_master": output_dir / "rectified_master_display.jpg",
        "rectified_slave": output_dir / "rectified_slave_display.jpg",
        "comparison": output_dir / "primary_src_depth_rectified_comparison.jpg",
        "outer_vs_src_difference": output_dir / "outer_vs_src_difference_99pct.png",
        "report": output_dir / "report.json",
    }
    src_display.save(outputs["src_display"], quality=95)
    rank_color.save(outputs["rank_color"])
    master_display.save(outputs["rectified_master"], quality=95)
    slave_display.save(outputs["rectified_slave"], quality=95)
    contact_sheet(
        [
            ("outer primary (final OPPO render)", outer_display),
            ("src.image (unbaked)", src_display),
            ("rank/depth", rank_color),
            ("rectified master NV21", master_display),
            ("rectified slave NV21", slave_display),
        ],
        outputs["comparison"],
    )

    difference_metrics: dict[str, float] | None = None
    if outer_display.size == src_display.size:
        outer_array = np.asarray(outer_display, dtype=np.float32)
        src_array = np.asarray(src_display, dtype=np.float32)
        channel_difference = np.abs(outer_array - src_array)
        pixel_difference = channel_difference.max(axis=2)
        percentile_99 = float(np.percentile(pixel_difference, 99))
        difference_image = np.clip(
            pixel_difference * (255.0 / max(percentile_99, 1.0)),
            0,
            255,
        ).astype(np.uint8)
        Image.fromarray(difference_image, mode="L").save(outputs["outer_vs_src_difference"])

        mean_squared_error = float(np.mean((outer_array - src_array) ** 2))
        reduced_size = rank_display.size
        outer_reduced = np.asarray(outer_display.resize(reduced_size, Image.Resampling.LANCZOS), dtype=np.float32)
        src_reduced = np.asarray(src_display.resize(reduced_size, Image.Resampling.LANCZOS), dtype=np.float32)
        reduced_difference = np.abs(outer_reduced - src_reduced).max(axis=2).reshape(-1)
        rank_values = np.asarray(rank_display, dtype=np.float32).reshape(-1)
        low_cut = float(np.percentile(rank_values, 10))
        high_cut = float(np.percentile(rank_values, 90))
        difference_metrics = {
            "channel_mae": float(channel_difference.mean()),
            "psnr_db": float(20.0 * math.log10(255.0 / math.sqrt(mean_squared_error))) if mean_squared_error else float("inf"),
            "pixel_max_difference_p50": float(np.percentile(pixel_difference, 50)),
            "pixel_max_difference_p95": float(np.percentile(pixel_difference, 95)),
            "pixel_max_difference_p99": percentile_99,
            "rank_difference_pearson": float(np.corrcoef(rank_values, reduced_difference)[0, 1]),
            "lowest_rank_decile_mean_difference": float(reduced_difference[rank_values <= low_cut].mean()),
            "highest_rank_decile_mean_difference": float(reduced_difference[rank_values >= high_cut].mean()),
        }
    result: dict[str, object] = {
        "source": str(input_path),
        "depth_dimensions": [depth_width, depth_height],
        "rectified_pair_offset": pair_offset,
        "rectified_dimensions": [guide_width, guide_height],
        "orientation": orientation,
        "model_output_after_rectified_pair": False,
        "rendered_bokeh_frame_present": False,
        "outer_vs_src_difference": difference_metrics,
        "outputs": {key: str(value) for key, value in outputs.items()},
    }
    outputs["report"].write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = extract(args.input.expanduser().resolve(), args.output_dir.expanduser().resolve())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"error: {error}\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
