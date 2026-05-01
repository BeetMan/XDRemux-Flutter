"""OPPO/OnePlus ProXDR HEIC container parsing.

Extracts LHDR (144-byte local.hdr.meta.data) and UHDR
(80-byte local.uhdr.gainmap.info + variable gainmap data)
from the OPPO private extension region of HEIC files.

Supports both QTI Debug marker and manifest-only container formats.
"""

import json
import struct
from typing import Optional


QTI_MARKERS = (b"QTI Debug", b"QTI ")
FLOAT_144 = struct.pack("<f", 144.0)


class ExtractedLHDR:
    """Result of LHDR metadata extraction."""
    def __init__(self, mode: str, meta_bytes: bytes, meta_floats: tuple,
                 mask_data: Optional[bytes] = None, gainmap_data: Optional[bytes] = None,
                 manifest_entries: Optional[list] = None,
                 ext_start: int = 0, file_data: Optional[bytes] = None):
        self.mode = mode          # "lhdr" or "uhdr"
        self.meta_bytes = meta_bytes
        self.meta_floats = meta_floats
        self.mask_data = mask_data
        self.gainmap_data = gainmap_data
        self.manifest_entries = manifest_entries
        self.ext_start = ext_start
        self.file_data = file_data


def find_extension_start(data: bytes) -> int:
    """Find the start of the OPPO extension region via QTI Debug marker."""
    for marker in QTI_MARKERS:
        pos = data.find(marker)
        if pos != -1:
            box_start = pos - 4
            box_size = struct.unpack(">I", data[box_start:box_start + 4])[0]
            return box_start + box_size
    raise ValueError("QTI extension marker not found")


def parse_manifest(data: bytes) -> tuple[list[dict], int, int] | None:
    """Parse JSON manifest from the extension region tail.

    Returns (entries, json_start_offset, json_end_offset) or None.
    """
    json_start = data.rfind(b"[{")
    if json_start == -1:
        return None
    json_end = data.find(b"]", json_start)
    if json_end == -1:
        return None
    try:
        entries = json.loads(data[json_start:json_end + 1])
    except (ValueError, json.JSONDecodeError):
        return None
    return entries, json_start, json_end + 1


def _score_lhdr_meta(floats: tuple) -> int:
    """Score a 36-float candidate for LHDR metadata validity."""
    score = 0
    if abs(floats[2] - 144.0) < 0.01:
        score += 5
    if abs(floats[5] + 1.0) < 0.01:
        score += 3
    if abs(floats[18] - 10.0) < 0.01:
        score += 2
    if abs(floats[19] - 6.0) < 0.01:
        score += 2
    if 2.0 <= floats[0] <= 5.0:
        score += 2
    if 0.0 <= floats[29] <= 2000.0:
        score += 1
    return score


def _extract_lhdr_meta_float144(data: bytes) -> tuple[bytes, tuple] | None:
    """Scan for 144-byte LHDR metadata block using float144 sentinel."""
    best, best_sc = None, 0
    off = 0
    while True:
        hit = data.find(FLOAT_144, off)
        if hit == -1:
            break
        start = hit - 8
        if 0 <= start < start + 144 <= len(data):
            f = struct.unpack("<36f", data[start:start + 144])
            sc = _score_lhdr_meta(f)
            if sc > best_sc:
                best_sc, best = sc, (data[start:start + 144], f)
        off = hit + 1
    return best


def _extract_lhdr_meta_manifest(data: bytes) -> tuple[bytes, tuple] | None:
    """Extract LHDR meta via manifest offset calculation."""
    manifest = parse_manifest(data)
    if manifest is None:
        return None
    entries, json_start, _ = manifest
    for entry in entries:
        if entry.get("name") == "local.hdr.meta.data" and entry.get("length", 0) >= 144:
            phys = json_start - entry["offset"]
            if 0 <= phys < phys + 144 <= len(data):
                f = struct.unpack("<36f", data[phys:phys + 144])
                if 2.0 <= f[0] <= 5.0:
                    return data[phys:phys + 144], f
    return None


def _find_jpeg_in_data(data: bytes, target_length: int | None = None) -> bytes | None:
    """Find a JPEG blob in raw bytes, optionally matching target length."""
    jpeg_start = b"\xff\xd8\xff"
    pos = 0
    while True:
        hit = data.find(jpeg_start, pos)
        if hit == -1:
            return None
        end_marker = data.find(b"\xff\xd9", hit + 3)
        if end_marker != -1:
            blob = data[hit:end_marker + 2]
            if target_length is None or abs(len(blob) - target_length) < 64:
                return blob
            pos = end_marker + 2
        else:
            pos = hit + 1


def extract_lhdr(path: str) -> ExtractedLHDR:
    """Extract LHDR or UHDR metadata and mask/gainmap from a HEIC file."""
    data = open(path, "rb").read()

    # Try QTI marker first
    try:
        ext_start = find_extension_start(data)
        ext = data[ext_start:]
    except ValueError:
        # No QTI marker — scan entire file
        ext_start = 0
        ext = data

    manifest = parse_manifest(ext)

    # Check for UHDR entries
    if manifest:
        entries = manifest[0]
        info_entry = next((e for e in entries if e["name"] == "local.uhdr.gainmap.info"), None)
        data_entry = next((e for e in entries if e["name"] == "local.uhdr.gainmap.data"), None)
        if info_entry and data_entry:
            json_start = manifest[1]
            info_start = json_start - info_entry["offset"]
            info_bytes = ext[info_start:info_start + info_entry["length"]]
            info_floats = struct.unpack("<20f", info_bytes)

            data_start = json_start - data_entry["offset"]
            gainmap_bytes = ext[data_start:data_start + data_entry["length"]]

            return ExtractedLHDR(
                mode="uhdr",
                meta_bytes=info_bytes,
                meta_floats=info_floats,
                gainmap_data=gainmap_bytes,
                manifest_entries=entries,
                ext_start=ext_start,
                file_data=data,
            )

    # Try float144 scan
    result = _extract_lhdr_meta_float144(ext)
    if result is None:
        # Fallback: manifest-based extraction
        result = _extract_lhdr_meta_manifest(data if ext_start == 0 else ext)
    if result is None:
        raise ValueError("Failed to locate LHDR metadata block")

    meta_bytes, floats = result

    # Extract mask JPEG
    mask_entry = None
    if manifest:
        mask_entry = next((e for e in manifest[0]
                          if e["name"] == "local.hdr.linear.mask"), None)
    mask_data = None
    if mask_entry:
        json_start = manifest[1]
        mask_start = json_start - mask_entry["offset"]
        mask_data = ext[mask_start:mask_start + mask_entry["length"]]
    else:
        mask_data = _find_jpeg_in_data(ext)

    return ExtractedLHDR(
        mode="lhdr",
        meta_bytes=meta_bytes,
        meta_floats=floats,
        mask_data=mask_data,
        manifest_entries=manifest[0] if manifest else None,
        ext_start=ext_start,
        file_data=data,
    )
