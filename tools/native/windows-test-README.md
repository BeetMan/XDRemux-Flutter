# XDRemux Windows libheif test build

Local Windows x64 portable test build, based on 0.4.3+37. Not an official release.
Extract the entire ZIP into a new directory, then run `xdremux.exe`.
Do not copy only the EXE or replace DLLs inside an existing installation.
No development PATH or Python installation is required to run this app.

Enabled: pure-Rust Apple / ISO gain-map JPEG metadata compatibility, and opt-in
libheif SDR HEIC fallback for unsupported 4:2:2 / 4:4:4 inputs (8/10/12-bit controls
tested). For plain SDR HEIC, enable Photographic Styles in the app to use the
existing SDR conversion workflow. PQ/HLG tone mapping is not provided.

Known limitations: Apple JPEG + Styles can still reject opaque MakerNote data;
real failing screenshots, full color/ICC/alpha/grid corpus and Photos-device
acceptance remain unverified. Portable runs may share settings with installed
XDRemux because this is not an isolated user-profile build. Keep original photos
and test in a separate output directory.

Bundled native libraries and copied upstream notices:
- libheif 1.23.4: https://github.com/strukturag/libheif/tree/4e14f5942c1732ace9611b9522cc991501445463
- libde265 1.1.3: https://github.com/strukturag/libde265/tree/ba62bf4cfb3242f3bf0a45617ff09e35236e4d82
- Notice files: `data/licenses/`.

The Rust core is built with `--features libheif-decoder`. The portable package
contains `xdremux_core.dll`, `heif.dll`, `libde265.dll` and Flutter runtime files.
The MSVC redistributable runtime is packaged app-locally as well.
Dependency sources/build recipe remain separate from the runtime package; this
local test does not claim a completed public-release license/compliance review.
