#!/bin/bash
# Build the Rust core + x265 as ONE static library per Apple slice and wrap the
# slices into an XCFramework for the native SwiftUI app (apps/apple).
#
#   apps/apple/Frameworks/XDRemuxCore.xcframework
#     ├── macos-arm64/                 libXDRemuxCore.a + Headers/
#     ├── ios-arm64/                   libXDRemuxCore.a + Headers/
#     └── ios-arm64-simulator/         libXDRemuxCore.a + Headers/
#
# Each libXDRemuxCore.a = libxdremux_core.a (Rust staticlib, already bundling
# x265_helper and the optional Main10 archive) + libx265.a (8-bit encoder),
# merged with libtool so the SPM binaryTarget links a single archive. Consumers
# still link libc++ (XDRemuxKit declares it).
#
# This script never writes into apps/flutter/*; it is independent of
# build_ios.sh / build_ios_sim.sh, which stage archives for the Flutter app.
#
# Env:
#   XDREMUX_APPLE_SLICES   space-separated subset of: macos ios ios-sim (default: all)
#   XDREMUX_MAIN10         0 to skip the Main10 (10-bit) x265 build (default 1)
#   XDREMUX_APPLE_OUT      output dir (default: ../../apps/apple/Frameworks)
#   IPHONEOS_DEPLOYMENT_TARGET / MACOSX_DEPLOYMENT_TARGET (defaults 17.0 / 14.0)
#
# Prereqs: rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail
cd "$(dirname "$0")"   # -> xdremux/rust

SLICES="${XDREMUX_APPLE_SLICES:-macos ios ios-sim}"
OUT="${XDREMUX_APPLE_OUT:-../../apps/apple/Frameworks}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
JOBS="$(sysctl -n hw.ncpu)"

TARGET_DIR="$(cargo metadata --format-version 1 --no-deps \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
STAGE="$TARGET_DIR/apple-xcframework"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# build_x265 <build_dir> <cmake system args...>
build_x265() {
  local dir="$1"; shift
  if [ ! -f "$dir/libx265.a" ]; then
    cmake -S vendor/x265/source -B "$dir" "$@" \
      -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
      -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$dir" --target x265-static -j"$JOBS"
  fi
}

# slice <name> <rust_target> <x265_dir> <x265_10bit_dir> <cmake system args...>
slice() {
  local name="$1" rust_target="$2" x265_dir="$3" x265_10bit_dir="$4"; shift 4
  echo "==> x265 ($name)"
  build_x265 "$x265_dir" "$@"
  if [ "${XDREMUX_MAIN10:-1}" != "0" ]; then
    echo "==> x265 Main10 ($name)"
    build_x265 "$x265_10bit_dir" "$@" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
  fi
  echo "==> Rust staticlib ($rust_target)"
  cargo build --target "$rust_target" --release --lib
  local dest="$STAGE/$name"; mkdir -p "$dest"
  libtool -static -o "$dest/libXDRemuxCore.a" \
    "$TARGET_DIR/$rust_target/release/libxdremux_core.a" \
    "$x265_dir/libx265.a"
  cp -R include "$dest/Headers"
}

for s in $SLICES; do
  case "$s" in
    macos)
      slice macos-arm64 aarch64-apple-darwin \
        vendor/x265/build_desktop vendor/x265/build_desktop_10bit \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" ;;
    ios)
      slice ios-arm64 aarch64-apple-ios \
        vendor/x265/build_ios vendor/x265/build_ios_10bit \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" ;;
    ios-sim)
      slice ios-arm64-simulator aarch64-apple-ios-sim \
        vendor/x265/build_ios_sim vendor/x265/build_ios_sim_10bit \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" ;;
    *) echo "unknown slice: $s" >&2; exit 2 ;;
  esac
done

echo "==> XCFramework"
mkdir -p "$OUT"; rm -rf "$OUT/XDRemuxCore.xcframework"
args=()
for d in "$STAGE"/*/; do
  args+=(-library "$d/libXDRemuxCore.a" -headers "$d/Headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT/XDRemuxCore.xcframework" >/dev/null

echo "==> Build record"
{
  echo "rust_commit=$(git rev-parse HEAD)"
  echo "rustc=$(rustc --version)"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "core_version=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
  echo "slices=$SLICES"
  for d in "$STAGE"/*/; do
    echo "$(basename "$d")=$(shasum -a 256 "$d/libXDRemuxCore.a" | cut -d' ' -f1)"
  done
} | tee "$OUT/XDRemuxCore.xcframework/BUILD_RECORD.txt"
echo "done: $OUT/XDRemuxCore.xcframework"
