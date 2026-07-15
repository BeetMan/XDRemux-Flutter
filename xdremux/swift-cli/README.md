# Swift CLI

This directory contains the Swift command-line converter.

Run it from the repository root:

```bash
swift xdremux/swift-cli/XDRemux.swift convert --input IMG_001.heic
```

## Product modes

- no switch: standard ISO output, complete metadata-tail preservation, and up
  to HEVC RExt 4:4:4 Gain Map when the source channel structure permits;
- `--oppo-compatible`: OPPO Gallery-compatible Main Still Picture 4:2:0;
- `--apple-portrait`: OPPO portrait resources converted to the Apple portrait
  graph, without retaining a second large OPPO portrait tail.

`--oppo-compatible` and `--apple-portrait` are mutually exclusive. Existing
4:2:0 sources are never promoted to 4:4:4 because missing chroma cannot be
recovered.

## Apple portrait conversion

OPPO portrait conversion is opt-in:

```bash
swift xdremux/swift-cli/XDRemux.swift convert \
  --apple-portrait \
  --input IMG_001.heic \
  --output IMG_001_apple_portrait.heic

swift xdremux/swift-cli/XDRemux.swift batch \
  --apple-portrait \
  --input-dir photo_dump/ \
  --output-dir apple_portraits/
```

The switch requires the recoverable `rear.depth + rear.depth.config +
src.image` resource set. The UserComment portrait bit is the strong route; an
explicit conversion may recover a missing bit and emits a warning. XDRemux
maps OPPO portrait/pet/hair planes to Apple mattes and uses Vision person
segmentation only when the OPPO subject plane is empty. Face-attention Vision
analysis supplies Focus.

Batch mode filters non-portrait inputs. Apple portrait output is mutually
exclusive with OPPO-compatible preservation and omits the redundant large
OPPO portrait tail. Explicitly enabling both modes is an error.

The `src.image` base and gain map are encoded once. The final container reuses
those first-assembly HEVC payloads byte-for-byte after the auxiliary images are
authored. The CLI requires `zstd` on `PATH` to decode OPPO `rear.depth`.

The decoded `rear.depth` header supplies the per-rank disparity scale, avoiding
the old fixed depth interval. The Apple auxiliary graph is selected from real
1x, 2x/Fusion, 3x tele, or 5x tetraprism `REND`/calibration profiles. Within a
profile, reference dimensions, principal point, distortion center, and
PixelSize follow Apple's observed continuous-crop representation while
intrinsic fx remains fixed. Disparity is not multiplied by focal length a
second time. Real OPPO lens and zoom identity stays in primary EXIF.

Cross-focal blur matching remains experimental until the profile-selected
outputs pass the full Photos f/1.4/source/f/16 device matrix.

The Apple simulated aperture is taken from the OPPO portrait edit state in
`rear.depth.config` when available, then from EXIF `FNumber`; `f/1.4` is only a
last-resort compatibility fallback. The resolved value is written as
`depthBlurEffect:SimulatedAperture`.

Without `--apple-portrait`, XDRemux uses its normal gain-map conversion path
and reattaches the original OPPO portrait private tail byte-for-byte. It does
not synthesize Apple depth, matte, Focus, or portrait metadata.

Do not place macOS app project files here; app shells belong under `apps/macos/`.
