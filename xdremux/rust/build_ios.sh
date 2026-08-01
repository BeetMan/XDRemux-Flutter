#!/bin/bash
# Build the Rust core + x265 static libraries for iOS (arm64 device).
# Outputs are copied into ios/Runner/Frameworks for the Xcode linker.
#
#   - target/aarch64-apple-ios/release/libxdremux_core.a   (Rust staticlib)
#   - vendor/x265/build_ios/libx265.a                       (x265 static)
#   - <cargo build out>/libx265_helper.a                    (C helper)
#
# Prereqs: rustup target add aarch64-apple-ios
set -euo pipefail
cd "$(dirname "$0")/.."   # -> xdremux/rust

DEST="../flutter/ios/Runner/Frameworks"
mkdir -p "$DEST"

echo "==> x265 (iOS arm64, no assembly)"
X265_SDK="${IPHONEOS_SDK:-/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
if [ ! -f vendor/x265/build_ios/libx265.a ]; then
  cmake -S vendor/x265/source -B vendor/x265/build_ios \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$X265_SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
    -DCMAKE_BUILD_TYPE=Release
fi
cmake --build vendor/x265/build_ios --target x265-static -j8

echo "==> Rust staticlib (aarch64-apple-ios)"
cargo build --target aarch64-apple-ios --release --lib

HELPER="$(find target/aarch64-apple-ios/release/build -name libx265_helper.a | head -1)"
cp target/aarch64-apple-ios/release/libxdremux_core.a "$DEST/"
cp vendor/x265/build_ios/libx265.a "$DEST/"
cp "$HELPER" "$DEST/"

# Also stage into a space-free path for the Xcode -L (the repo path has spaces,
# which breaks an unquoted linker -L flag).
STAGE="$HOME/xdremux_ios_libs"
mkdir -p "$STAGE"
cp "$DEST"/lib*.a "$STAGE/"
echo "==> staged to $STAGE"
echo "==> done. Libraries in $DEST:"
ls -la "$DEST"
