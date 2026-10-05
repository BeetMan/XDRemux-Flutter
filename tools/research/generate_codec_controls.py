"""Generate NEW synthetic codec controls; never consumes personal photos."""
import argparse
import struct
from pathlib import Path

from PIL import Image
import pillow_heif


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--extended", action="store_true",
                        help="Also generate 10/12-bit and rotated non-420 controls")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    image = Image.new("RGB", (128, 96))
    image.putdata([((x * 2) % 256, (y * 3) % 256, (x * 11 + y * 7) % 256)
                   for y in range(96) for x in range(128)])
    image.save(args.output_dir / "sdr.jpg", quality=90)
    for chroma in ("420", "422", "444"):
        pillow_heif.from_pillow(image).save(args.output_dir / f"synthetic-{chroma}.heic",
                                          quality=90, chroma=chroma)
    if args.extended:
        high_depth = b"".join(struct.pack("<H", value * 257) for value in image.tobytes())
        for bits in (10, 12):
            for chroma in ("422", "444"):
                pillow_heif.encode("RGB;16", image.size, high_depth,
                                   args.output_dir / f"synthetic-{chroma}-{bits}bit.heic",
                                   quality=90, chroma=chroma, bit_depth=bits)
        orientation = Image.Exif()
        orientation[274] = 6
        pillow_heif.from_pillow(image).save(args.output_dir / "synthetic-444-rotated.heic",
                                          quality=90, chroma="444", exif=orientation)
    print(f"Generated {9 if args.extended else 4} synthetic controls under {args.output_dir}")


if __name__ == "__main__":
    main()
