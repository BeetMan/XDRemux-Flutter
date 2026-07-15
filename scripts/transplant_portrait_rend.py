#!/usr/bin/env python3
"""Replace one equal-length Apple portrait REND XMP payload byte-for-byte."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


TAG = "-XMP-depthBlurEffect:RenderingParameters"


def rendering_parameters(path: Path) -> str:
    metadata = json.loads(
        subprocess.check_output(["exiftool", "-j", TAG, str(path)], text=True)
    )[0]
    value = metadata.get("RenderingParameters")
    if not isinstance(value, str) or not value:
        raise ValueError(f"{path} does not expose Apple RenderingParameters")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--donor", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    source_value = rendering_parameters(args.input)
    donor_value = rendering_parameters(args.donor)
    source_payload = source_value.encode("ascii")
    donor_payload = donor_value.encode("ascii")
    if len(source_payload) != len(donor_payload):
        parser.error("source and donor REND payload lengths differ")

    data = args.input.read_bytes()
    if data.count(source_payload) != 1:
        parser.error("source REND does not occur exactly once in the container")
    output_data = data.replace(source_payload, donor_payload, 1)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output_data)
    if rendering_parameters(args.output) != donor_value:
        args.output.unlink(missing_ok=True)
        parser.error("output REND verification failed")
    print(f"transplanted {len(donor_payload)}-byte REND without changing container layout")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
