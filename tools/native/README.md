# Optional HEIC decode fallback

`libheif-decoder` is an opt-in Rust Cargo feature. It is **not enabled in the
default app or release builds**. JPEG metadata improvements do not need it.

The normal decoder remains heif-oxide. Only its specific unsupported-chroma
error triggers native retry, after the existing clli/mdcv essential-bit handling.
Corrupt containers, missing boxes and other codec errors are not silently retried.

Native code calls libheif's primary-image decode, requests packed 8-bit RGB,
applies HEIF transforms, and uses EXIF orientation only when no HEIF rotation /
mirror is declared. It never writes the source, replaces gain maps, or handles
Live / portrait resources. The existing SDR pipeline subsequently builds an
identity gain map and styles container. Alpha is discarded by this SDR RGB API.

## Windows x64 developer build

Prerequisites: Git, CMake, MSVC C++ workload, Rust MSVC target. Pick a **new**, local,
external build directory. The script pins libheif 1.23.4 and libde265 1.1.3 by commit,
builds shared libraries without encoders or plugin loading, and installs only into
that directory. It does not change machine PATH or install system software.

```powershell
./tools/native/build-libheif.ps1 -BuildRoot C:/codec-deps/new-build -Generator 'Visual Studio 18 2026'
$env:XDREMUX_LIBHEIF_PREFIX = 'C:/codec-deps/new-build/prefix'
$env:PATH = "$env:XDREMUX_LIBHEIF_PREFIX/bin;" + $env:PATH
cargo test -p xdremux-core --lib --features libheif-decoder
cargo build --release -p xdremux-core --lib --features libheif-decoder
cargo build --release -p xdremux-core --example codec_poc --example codec_regression --features libheif-decoder
```

The example `codec_regression <NEW-output-directory> <input>...` exercises the
production FFI conversion and JPEG hardware-prepare path, validates the emitted
gain-map graph, records application color-space flags and checks source SHA-256.
It requests clean output and strict tmap. SDR sources request Apple Styles;
real HDR JPEGs exercise HDR conversion without Styles by default. Pass `--styles`
to force the separate Styles gate for all sources. Apple JPEGs with opaque
out-of-line MakerNote data can still be refused by the existing Styles writer;
the native/HDR compatibility change does not bypass that preservation check.
It is not a Photos-device
acceptance test and does not prove HDR pixel accuracy.

For a packaged Windows build, `heif.dll` and `libde265.dll` must be placed beside
the executable, along with the usual Rust/Flutter artifacts. Adding the prefix to
PATH above is a **developer test only**, not a release packaging solution. The
current GitHub release workflow has not been changed to enable this feature.

### Local Flutter Windows test bundle

Windows CMake supports explicit, environment-only opt-in to a separately built
Rust DLL and libheif prefix. It copies both codec DLLs, notices and the MSVC
redistributable runtime beside the application. Default release CI is unchanged.
JNI is excluded using a filtered build-directory copy of the generated plugin
list, so the generated source does not need editing and Windows needs no JVM.

```powershell
$env:XDREMUX_LIBHEIF_PREFIX = 'C:/codec-deps/new-build/prefix'
$env:CARGO_TARGET_DIR = "$PWD/target/windows-libheif-test"
cargo build --release -p xdremux-core --lib --features libheif-decoder
$env:XDREMUX_WINDOWS_RUST_DLL = "$env:CARGO_TARGET_DIR/release/xdremux_core.dll"
$env:XDREMUX_WINDOWS_LIBHEIF_PREFIX = $env:XDREMUX_LIBHEIF_PREFIX
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
Push-Location apps/flutter
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
Pop-Location
```

Use new portable output paths and keep the whole `runner/Release` layout except
debug symbols. Include `windows-test-README.md` and notices. A test bundle shares
the normal app's user preferences; it is not a separate installed-app identity.

`apps/flutter/tool/windows_package_smoke.dart` exercises the app's existing Dart
FFI bindings against the **absolute packaged DLL** with a package-local DLL
search directory (not a development PATH). It writes to a new report directory,
verifies output and Styles graphs and hashes sources before/after. Run via Dart
with `--packages=apps/flutter/.dart_tool/package_config.json`, passing bundle,
new report directory and inputs. This is not UI/file-picker/thumbnail validation
or a clean-Windows-VM acceptance test.

## Bounds and limitations

- Up to 256 MiB compressed input, 64 Mi-pixels output, 4096 tiles; libheif keeps its
  other default limits and receives a 512 MiB total native-memory budget.
- Four codec threads and one concurrent native fallback per process. A 30-second
  cooperative cancellation callback is **not a hard process timeout**.
- PQ / HLG inputs are explicitly rejected here: no HDR tone mapper is installed.
- Output allocation, dimensions, row stride, errors, C++ exceptions and ownership
  are checked at the native/Rust boundary. Core C FFI structs retain their layouts.
- Runtime/header API minimum is 1.23.4. Header/library paths must match the Rust
  target; a Windows library must never be reused for Android/OHOS/iOS.
- This does not resolve all ICC color management, alpha retention, RAW / AVIF, or
  proprietary auxiliary-image contracts.

## Release gates still open

Only Windows x64 is verified in this change. Other target builds, dynamic-library
packaging/rpath/signing, actual 4:4:4 screenshot acceptance, performance, and full
pixel/color conformance remain pending. Do not flip default features before these
checks and dependency-distribution review.

OHOS packaging must include all target-ABI native dependencies in the app's
`entry/libs/<ABI>` (including the C++ shared runtime where required); an arbitrary
desktop library search path is not an app packaging strategy. These requirements
were checked with the DevEco documentation skill, not validated by an OHOS build
or device test. No OHOS signing or build-profile configuration changed.

The extended control generator accepts `--extended` to produce 4:2:2 / 4:4:4
10/12-bit and EXIF-orientation controls in a **new** external directory. Check the
reported hvcC bit depths; requested encoder settings alone are not evidence.
Windows x64 tests verified these inputs and an EXIF-only rotated small-image
Styles conversion. Real-device screenshots, alpha, HDR color and grid corpus
coverage remain separate gates.

libheif and libde265 have their own licenses (not the core's MIT license). Keep the
upstream license notices and source provenance, review LGPL distribution/relinking
requirements for each target, and ship the required notices/source material before
including the libraries in a release. The script copies available COPYING files
to the external prefix; it does not claim to complete release compliance.

Reference APIs: [libheif 1.23.4](https://github.com/strukturag/libheif/tree/v1.23.4/libheif/api/libheif).
JPEG metadata behavior is compared with [libultrahdr 2.0.2](https://github.com/google/libultrahdr/tree/v2.0.2/lib/src),
without linking libultrahdr into the product.
