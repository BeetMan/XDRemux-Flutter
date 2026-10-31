#!/usr/bin/env bash
# Build the optional local-transfer library for macOS, iOS, Linux, Android or
# OpenHarmony. Windows (and Android from Windows) use build-transfer.ps1.
#
# Usage: tools/native/build-transfer.sh macos|ios|linux|android|ohos
#
# Outputs (the platform projects pick these up when present; ordinary image
# builds never invoke Cargo for transfer):
#   macos   crates/xdremux-transfer-ffi/target/release/libxdremux_transfer.dylib
#   linux   crates/xdremux-transfer-ffi/target/release/libxdremux_transfer.so
#   ios     crates/xdremux-transfer-ffi/target/xdremux_transfer.xcframework
#   android crates/xdremux-transfer-ffi/target/aarch64-linux-android/release/libxdremux_transfer.so
#   ohos    crates/xdremux-transfer-ffi/target/aarch64-unknown-linux-ohos/release/libxdremux_transfer.so,
#           also copied to apps/flutter/ohos/entry/libs/arm64-v8a/
#
# Environment: XDREMUX_TRANSFER_TOOLCHAIN (default 1.97.1),
#   ANDROID_NDK_HOME (android), OHOS_NATIVE (ohos; defaults to DevEco Studio's SDK).
set -euo pipefail

PLATFORM="${1:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CRATE="$ROOT/crates/xdremux-transfer-ffi"
MANIFEST="$CRATE/Cargo.toml"
TARGET_DIR="$CRATE/target"
TOOLCHAIN="${XDREMUX_TRANSFER_TOOLCHAIN:-1.97.1}"
NAME=xdremux_transfer

build() {
  cargo "+$TOOLCHAIN" build --manifest-path "$MANIFEST" --target-dir "$TARGET_DIR" \
    --locked --release "$@"
}

# Wrap one iOS dylib slice as a dynamic framework. Info.plist keys are the
# minimum App Store validation needs for an embedded framework.
ios_framework() {
  local triple="$1" platform="$2" out="$3"
  local fw="$out/$NAME.framework"
  rm -rf "$fw"
  mkdir -p "$fw"
  cp "$TARGET_DIR/$triple/release/lib$NAME.dylib" "$fw/$NAME"
  install_name_tool -id "@rpath/$NAME.framework/$NAME" "$fw/$NAME"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.beetman.xdremux.transfer</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST
}

case "$PLATFORM" in
  macos)
    build
    install_name_tool -id "@rpath/lib$NAME.dylib" "$TARGET_DIR/release/lib$NAME.dylib"
    echo "$TARGET_DIR/release/lib$NAME.dylib"
    ;;
  linux)
    build
    echo "$TARGET_DIR/release/lib$NAME.so"
    ;;
  ios)
    export IPHONEOS_DEPLOYMENT_TARGET=15.0
    build --target aarch64-apple-ios
    build --target aarch64-apple-ios-sim
    STAGE="$TARGET_DIR/ios-frameworks"
    ios_framework aarch64-apple-ios iPhoneOS "$STAGE/device"
    ios_framework aarch64-apple-ios-sim iPhoneSimulator "$STAGE/simulator"
    rm -rf "$TARGET_DIR/$NAME.xcframework"
    xcodebuild -create-xcframework \
      -framework "$STAGE/device/$NAME.framework" \
      -framework "$STAGE/simulator/$NAME.framework" \
      -output "$TARGET_DIR/$NAME.xcframework" >/dev/null
    echo "$TARGET_DIR/$NAME.xcframework"
    ;;
  android)
    NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    case "$(uname -s)" in
      Darwin) HOST=darwin-x86_64 ;;
      *) HOST=linux-x86_64 ;;
    esac
    BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
    export CC_aarch64_linux_android="$BIN/aarch64-linux-android24-clang"
    export AR_aarch64_linux_android="$BIN/llvm-ar"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
    build --target aarch64-linux-android
    echo "$TARGET_DIR/aarch64-linux-android/release/lib$NAME.so"
    ;;
  ohos)
    if [[ "$OSTYPE" == darwin* ]]; then
      DEFAULT_NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
    else
      DEFAULT_NATIVE=C:/PROGRA~1/Huawei/DEVECO~1/sdk/default/OPENHA~1/native
    fi
    NATIVE="${OHOS_NATIVE:-$DEFAULT_NATIVE}"
    SYSROOT="$NATIVE/sysroot"
    LLVM_TARGET=aarch64-linux-ohos
    export CC_aarch64_unknown_linux_ohos="$NATIVE/llvm/bin/clang"
    export AR_aarch64_unknown_linux_ohos="$NATIVE/llvm/bin/llvm-ar"
    export CFLAGS_aarch64_unknown_linux_ohos="-target $LLVM_TARGET --sysroot=$SYSROOT -D__MUSL__"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$NATIVE/llvm/bin/clang"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="-C link-args=--target=$LLVM_TARGET -C link-args=--sysroot=$SYSROOT"
    build --target aarch64-unknown-linux-ohos
    OUT="$TARGET_DIR/aarch64-unknown-linux-ohos/release/lib$NAME.so"
    LIBS="$ROOT/apps/flutter/ohos/entry/libs/arm64-v8a"
    mkdir -p "$LIBS"
    cp "$OUT" "$LIBS/"
    echo "$OUT"
    ;;
  *)
    echo "usage: $0 macos|ios|linux|android|ohos" >&2
    exit 2
    ;;
esac
