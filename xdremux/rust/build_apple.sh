#!/bin/bash
# Build the Rust core + x265 as ONE static library per Apple slice and wrap the
# slices into an XCFramework for the native SwiftUI app (apps/apple).
#
#   apps/apple/Frameworks/XDRemuxCore.xcframework
#     ├── macos-arm64_x86_64/          libXDRemuxCore.a (fat) + Headers/
#     ├── ios-arm64/                   libXDRemuxCore.a + Headers/
#     └── ios-arm64_x86_64-simulator/  libXDRemuxCore.a (fat) + Headers/
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
#   XDREMUX_APPLE_ARCHS    architectures for macos / ios-sim: "arm64 x86_64" (default)
#                          or "arm64" (device iOS is always arm64 only)
#   XDREMUX_MAIN10         0 to skip the Main10 (10-bit) x265 build (default 1)
#   XDREMUX_APPLE_OUT      output dir (default: ../../apps/apple/Frameworks)
#   IPHONEOS_DEPLOYMENT_TARGET / MACOSX_DEPLOYMENT_TARGET (defaults 17.0 / 14.0)
#
# Prereqs: rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
#            x86_64-apple-darwin x86_64-apple-ios
set -euo pipefail
cd "$(dirname "$0")"   # -> xdremux/rust

SLICES="${XDREMUX_APPLE_SLICES:-macos ios ios-sim}"
ARCHS="${XDREMUX_APPLE_ARCHS:-arm64 x86_64}"
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

# arch_lib <arch> <rust_target> <x265_dir> <x265_10bit_dir> <cmake system args...>
# Builds x265 + the Rust staticlib for one architecture and prints the merged
# archive path. The x265 dirs are the arm64 names; x86_64 gets a "_x86_64"
# suffix so both can live in vendor/x265 side by side.
arch_lib() {
  local arch="$1" rust_target="$2" x265_dir="$3" x265_10bit_dir="$4"; shift 4
  if [ "$arch" = "x86_64" ]; then
    x265_dir="${x265_dir}_x86_64"; x265_10bit_dir="${x265_10bit_dir}_x86_64"
  fi
  echo "==> x265 ($rust_target)" >&2
  build_x265 "$x265_dir" "$@" -DCMAKE_OSX_ARCHITECTURES="$arch" >&2
  local main10_dir=""
  if [ "${XDREMUX_MAIN10:-1}" != "0" ]; then
    echo "==> x265 Main10 ($rust_target)" >&2
    build_x265 "$x265_10bit_dir" "$@" -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF >&2
    main10_dir="$(cd "$x265_10bit_dir" && pwd)"
  fi
  echo "==> Rust staticlib ($rust_target)" >&2
  XDREMUX_X265_DIR="$(cd "$x265_dir" && pwd)" XDREMUX_X265_MAIN10_DIR="$main10_dir" \
    cargo build --target "$rust_target" --release --lib >&2
  local out="$STAGE/arch-$rust_target.a"
  libtool -static -o "$out" \
    "$TARGET_DIR/$rust_target/release/libxdremux_core.a" \
    "$x265_dir/libx265.a" >&2
  echo "$out"
}

# slice <name-with-ARCH> <archs> <x265_dir> <x265_10bit_dir> <rust_arm64> <rust_x86_64> <cmake args...>
slice() {
  local name="$1" archs="$2" x265_dir="$3" x265_10bit_dir="$4" rt_arm="$5" rt_x86="$6"; shift 6
  local libs=() built=()
  for a in $archs; do
    case "$a" in
      arm64) libs+=("$(arch_lib arm64 "$rt_arm" "$x265_dir" "$x265_10bit_dir" "$@")"); built+=(arm64) ;;
      x86_64) [ -n "$rt_x86" ] || continue
              libs+=("$(arch_lib x86_64 "$rt_x86" "$x265_dir" "$x265_10bit_dir" "$@")"); built+=(x86_64) ;;
      *) echo "unknown arch: $a" >&2; exit 2 ;;
    esac
  done
  # Slice directory name follows xcodebuild's own convention (arm64_x86_64).
  local archtag; archtag="$(IFS=_; echo "${built[*]}")"
  local dest="$STAGE/${name/ARCH/$archtag}"; mkdir -p "$dest"
  lipo -create "${libs[@]}" -output "$dest/libXDRemuxCore.a"
  cp -R include "$dest/Headers"
  rm -f "${libs[@]}"
}

for s in $SLICES; do
  case "$s" in
    macos)
      slice macos-ARCH "$ARCHS" \
        vendor/x265/build_desktop vendor/x265/build_desktop_10bit \
        aarch64-apple-darwin x86_64-apple-darwin \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" ;;
    ios)
      slice ios-ARCH arm64 \
        vendor/x265/build_ios vendor/x265/build_ios_10bit \
        aarch64-apple-ios "" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" ;;
    ios-sim)
      slice ios-ARCH-simulator "$ARCHS" \
        vendor/x265/build_ios_sim vendor/x265/build_ios_sim_10bit \
        aarch64-apple-ios-sim x86_64-apple-ios \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
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
  echo "archs=$ARCHS"
  for d in "$STAGE"/*/; do
    echo "$(basename "$d")=$(shasum -a 256 "$d/libXDRemuxCore.a" | cut -d' ' -f1)"
  done
} | tee "$OUT/XDRemuxCore.xcframework/BUILD_RECORD.txt"
echo "done: $OUT/XDRemuxCore.xcframework"
