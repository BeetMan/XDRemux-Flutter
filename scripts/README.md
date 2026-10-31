# Scripts

This directory contains checked-in helper scripts for local development, build, and verification workflows.

## Available scripts

- `analyze_oppo_portrait_depth_corpus.py` extracts OPPO portrait depth, header and config metrics from original HEIC files (see `docs/modules/portrait-pipeline.md`).
- `extract_oppo_gallery_yuv.py` extracts OPPO Gallery rectified NV21 guides and compares the primary, `src` and rank planes.
- `transplant_portrait_rend.py` replaces one equal-length Apple portrait REND XMP payload byte for byte (an `exiftool` experiment helper).
- `build_and_run.sh` is **stale**. It still builds and launches `apps/macos/XDRemuxApp`, which no longer exists, so it fails. For the native Apple app use `apps/apple/README.md`. For the Flutter macOS app use `flutter run -d macos` in `apps/flutter`.

Keep reusable automation here. One-off scratch scripts should stay outside the repository or under an explicitly named experiment directory.
