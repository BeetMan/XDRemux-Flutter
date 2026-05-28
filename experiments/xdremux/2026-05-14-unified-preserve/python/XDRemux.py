#!/usr/bin/env python3
"""XDRemux — Convert OPPO/OnePlus/realme ProXDR HEIC to ISO 21496-1 HDR HEIC.

Cross-platform Python implementation. Replaces Apple ImageIO / CoreGraphics
with pillow-heif + Pillow + numpy.

Usage:
    xdremux.py convert --input <file.heic> [--output <out.heic>] [--debug-dir <dir>] [--oppo-compat]
    xdremux.py batch --input-dir <dir> [--output-dir <dir>] [--glob <pattern>] [--oppo-compat]
"""

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    __package__ = "xdremux.python"

from . import container, edr, iso21496


def cmd_convert(args: argparse.Namespace) -> int:
    """Convert a single ProXDR HEIC file."""
    input_path = Path(args.input)

    if not input_path.exists():
        print(f"error: input not found: {input_path}", file=sys.stderr)
        return 1

    output_path = Path(args.output) if args.output else input_path

    if output_path != input_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        lhdr = container.extract_lhdr(str(input_path))
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if lhdr.mode == "uhdr":
        iso_meta = iso21496.build_iso21496_metadata_from_uhdr(lhdr.meta_floats)
        edr_scale = iso_meta.get("scale", 1.0)
    else:
        edr_scale = edr.edr_scale_calculator(list(lhdr.meta_floats))
        iso_meta = iso21496.build_iso21496_metadata(edr_scale)

    print(f"  mode: {lhdr.mode}")
    print(f"  edr_scale: {edr_scale:.4f}")
    print(f"  gainMapMax: {iso_meta['gainMapMax'][0]:.4f}")
    print(f"  hdrCapacityMax: {iso_meta['hdrCapacityMax']:.4f}")

    try:
        from . import gainmap, heif_io
        import numpy as np
        import io
        from PIL import Image

        base_image = None
        exif_data = None
        reencode = getattr(args, "reencode", False)
        passthrough = False if reencode else getattr(args, "passthrough", True)

        if not passthrough:
            from pillow_heif import open_heif

            data = heif_io.read_heic(str(input_path))
            base_image = data["base_image"]

            # Extract source EXIF for normal-mode re-encode.
            # Passthrough copies the original EXIF item at the ISOBMFF layer.
            try:
                src_heif = open_heif(str(input_path))
                exif_data = src_heif[0].info.get("exif") if hasattr(src_heif, '__getitem__') else src_heif.info.get("exif")
            except Exception:
                pass

            if base_image is None:
                print("error: HEIC decode failed — install pillow-heif for full conversion", file=sys.stderr)
                return 1

        # Resolve gain map
        if lhdr.mode == "uhdr":
            gm_data = lhdr.gainmap_data
            gm_img = None
            if gm_data:
                try:
                    gm_img = Image.open(io.BytesIO(gm_data))
                except Exception:
                    pass
        else:
            mask_data = lhdr.mask_data
            if mask_data is None:
                print("error: no mask data found", file=sys.stderr)
                return 1
            mask_np = np.array(Image.open(io.BytesIO(mask_data)))
            gm_img = gainmap.reconstruct(mask_np, edr_scale, lhdr.meta_floats[0])

        if passthrough:
            heif_io.write_heic_passthrough(
                str(input_path),
                str(output_path),
                gm_img,
                iso_meta,
                lhdr=lhdr,
                oppo_compat=args.oppo_compat,
            )
        else:
            heif_io.write_heic(
                str(output_path),
                base_image,
                gm_img,
                iso_meta,
                oppo_compat=args.oppo_compat,
                lhdr=lhdr,
                exif_data=exif_data,
            )

        if args.debug_dir:
            debug_dir = Path(args.debug_dir) / input_path.stem
            debug_dir.mkdir(parents=True, exist_ok=True)
            debug = {
                "input": str(input_path),
                "mode": lhdr.mode,
                "edr_scale": edr_scale,
                "iso_meta": iso_meta,
                "floats": list(lhdr.meta_floats),
            }
            (debug_dir / "meta.json").write_text(json.dumps(debug, indent=2))

    except ImportError:
        print("Metadata extraction only (install pillow-heif + Pillow + numpy for full conversion)")
        print(json.dumps({
            "mode": lhdr.mode,
            "edr_scale": edr_scale,
            "gainMapMax": iso_meta["gainMapMax"][0],
        }, indent=2))

    verb = "overwritten" if output_path == input_path else f"-> {output_path}"
    print(f"converted {input_path.name} {verb}")
    return 0


def cmd_batch(args: argparse.Namespace) -> int:
    """Batch convert ProXDR HEIC files."""
    input_dir = Path(args.input_dir)

    if not input_dir.is_dir():
        print(f"error: input dir not found: {input_dir}", file=sys.stderr)
        return 1

    output_dir = Path(args.output_dir) if args.output_dir else input_dir
    if output_dir != input_dir:
        output_dir.mkdir(parents=True, exist_ok=True)

    glob_pattern = args.glob or "*.heic"
    files = sorted(input_dir.glob(glob_pattern))
    converted, failed = 0, 0
    for f in files:
        out = output_dir / f.name
        args2 = argparse.Namespace(input=str(f), output=str(out),
                                    debug_dir=args.debug_dir,
                                    oppo_compat=args.oppo_compat,
                                    passthrough=args.passthrough,
                                    reencode=args.reencode)
        ret = cmd_convert(args2)
        if ret == 0:
            converted += 1
        else:
            failed += 1

    print(f"batch complete: {converted} converted, {failed} failed")
    return 0 if failed == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Convert OPPO ProXDR HEIC to ISO 21496-1 HDR HEIC",
    )
    sub = parser.add_subparsers(dest="command")

    c = sub.add_parser("convert")
    c.add_argument("--input", required=True)
    c.add_argument("--output")
    c.add_argument("--debug-dir")
    c.set_defaults(oppo_compat=False, passthrough=True, reencode=False)
    c.add_argument("--oppo-compat", action="store_true", dest="oppo_compat",
                   help="Add OPPO Gallery compatibility metadata")
    c.add_argument("--no-oppo-compat", action="store_false", dest="oppo_compat",
                   help=argparse.SUPPRESS)
    c.add_argument("--passthrough", action="store_true", dest="passthrough",
                   help=argparse.SUPPRESS)
    c.add_argument("--reencode", action="store_true", dest="reencode",
                   help="Decode and re-encode the base image instead of preserving source HEVC")

    b = sub.add_parser("batch")
    b.add_argument("--input-dir", required=True)
    b.add_argument("--output-dir")
    b.add_argument("--glob")
    b.add_argument("--debug-dir")
    b.set_defaults(oppo_compat=False, passthrough=True, reencode=False)
    b.add_argument("--oppo-compat", action="store_true", dest="oppo_compat",
                   help="Add OPPO Gallery compatibility metadata")
    b.add_argument("--no-oppo-compat", action="store_false", dest="oppo_compat",
                   help=argparse.SUPPRESS)
    b.add_argument("--passthrough", action="store_true", dest="passthrough",
                   help=argparse.SUPPRESS)
    b.add_argument("--reencode", action="store_true", dest="reencode",
                   help="Decode and re-encode the base image instead of preserving source HEVC")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "convert":
        return cmd_convert(args)
    elif args.command == "batch":
        return cmd_batch(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
