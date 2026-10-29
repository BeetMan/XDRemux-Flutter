#!/bin/bash
# Build the Rust core + x265 static libraries for the iOS **simulator**
# (arm64, Apple Silicon host) so the Flutter app can run in a simulator such as
# the iPhone Duo.
#
#   - target/aarch64-apple-ios-sim/release/libxdremux_core.a (Rust staticlib)
#   - vendor/x265/build_ios_sim/libx265.a                    (x265 static)
#   - <cargo build out>/libx265_helper.a                     (C helper)
#
# The archives are staged into the same two places build_ios.sh writes, so the
# Podfile (which link-force-loads $HOME/xdremux_ios_libs) picks them up. Run
# build_ios.sh afterwards to restore the device archives — device builds fail
# with "building for 'iOS', but linking in object file ... built for
# 'iOS-simulator'" if the simulator archives are still staged.
#
# Prereqs: rustup target add aarch64-apple-ios-sim
set -euo pipefail
cd "$(dirname "$0")"   # -> xdremux/rust

DEST="../../apps/flutter/ios/Runner/Frameworks"
mkdir -p "$DEST"

echo "==> x265 (iOS simulator arm64, no assembly)"
X265_SDK="${IPHONESIMULATOR_SDK:-$(xcrun --sdk iphonesimulator --show-sdk-path)}"
if [ ! -f vendor/x265/build_ios_sim/libx265.a ]; then
  cmake -S vendor/x265/source -B vendor/x265/build_ios_sim \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$X265_SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
    -DCMAKE_BUILD_TYPE=Release
fi
cmake --build vendor/x265/build_ios_sim --target x265-static -j8

# Optional Main10 encoder (set XDREMUX_MAIN10=0 to skip); see build_ios.sh.
if [ "${XDREMUX_MAIN10:-1}" != "0" ]; then
  echo "==> x265 10-bit (iOS simulator arm64, no assembly)"
  if [ ! -f vendor/x265/build_ios_sim_10bit/libx265.a ]; then
    cmake -S vendor/x265/source -B vendor/x265/build_ios_sim_10bit \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT="$X265_SDK" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
      -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
      -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF \
      -DCMAKE_BUILD_TYPE=Release
  fi
  cmake --build vendor/x265/build_ios_sim_10bit --target x265-static -j8
fi

# Workspace root may redirect the target dir (repo root Cargo.toml workspace),
# so resolve it via cargo metadata instead of assuming ./target.
TARGET_DIR="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"

echo "==> Rust staticlib (aarch64-apple-ios-sim)"
cargo build --target aarch64-apple-ios-sim --release --lib

HELPER="$(find "$TARGET_DIR/aarch64-apple-ios-sim/release/build" -name libx265_helper.a | head -1)"
cp "$TARGET_DIR/aarch64-apple-ios-sim/release/libxdremux_core.a" "$DEST/"
cp vendor/x265/build_ios_sim/libx265.a "$DEST/"
cp "$HELPER" "$DEST/"

# Also stage into a space-free path for the Xcode -L (the repo path has spaces,
# which breaks an unquoted linker -L flag).
STAGE="$HOME/xdremux_ios_libs"
mkdir -p "$STAGE"
cp "$DEST"/lib*.a "$STAGE/"
echo "==> staged to $STAGE"
echo "==> done. Run: flutter run -d <simulator-udid>"
