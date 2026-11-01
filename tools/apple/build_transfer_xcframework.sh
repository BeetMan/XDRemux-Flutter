#!/usr/bin/env bash
# Build the optional local-transfer library (crates/xdremux-transfer-ffi,
# LocalSend v2 core) as ONE dynamic XCFramework for the native SwiftUI app:
#
#   apps/apple/Frameworks/XDRemuxTransferCore.xcframework
#     ├── ios-arm64/            XDRemuxTransferCore.framework (flat)
#     ├── ios-arm64-simulator/  XDRemuxTransferCore.framework (flat)
#     └── macos-arm64/          XDRemuxTransferCore.framework (versioned)
#
# Each framework wraps the cdylib plus Headers/xdremux_transfer.h and a module
# map, so Swift imports it as `XDRemuxTransferCore`. It stays a dynamic
# library on purpose: the image core is a Rust staticlib already linked into
# the app, and two Rust staticlibs in one binary collide on the allocator /
# unwinding shims. Separate images do not.
#
# Like tools/native/build-transfer.sh, strip and set the install name at link
# time; rustc's post-link strip produces a LINKEDIT that iOS dyld rejects.
#
# Env: XDREMUX_TRANSFER_TOOLCHAIN (default 1.97.1), XDREMUX_APPLE_TRANSFER_OUT
#      (default apps/apple/Frameworks), XDREMUX_TRANSFER_SLICES
#      (subset of "ios ios-sim macos", default all).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CRATE="$ROOT/crates/xdremux-transfer-ffi"
MANIFEST="$CRATE/Cargo.toml"
TARGET_DIR="$CRATE/target"
TOOLCHAIN="${XDREMUX_TRANSFER_TOOLCHAIN:-1.97.1}"
OUT="${XDREMUX_APPLE_TRANSFER_OUT:-$ROOT/apps/apple/Frameworks}"
SLICES="${XDREMUX_TRANSFER_SLICES:-ios ios-sim macos}"
FW=XDRemuxTransferCore
LIB=libxdremux_transfer.dylib
STAGE="$TARGET_DIR/apple-xcframework"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

rm -rf "$STAGE"; mkdir -p "$STAGE"

build_slice() { # <triple> <install_name>
  CARGO_PROFILE_RELEASE_STRIP=false \
  RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-x,-S,-install_name,$2" \
    cargo "+$TOOLCHAIN" build --manifest-path "$MANIFEST" --target-dir "$TARGET_DIR" \
      --locked --release --target "$1" 1>&2
  echo "$TARGET_DIR/$1/release/$LIB"
}

dyld_check() {
  local report
  report="$(xcrun dyld_info -platform "$1" 2>&1)" || true
  if printf '%s' "$report" | grep -qi 'mis-aligned\|malformed'; then
    echo "error: dyld rejects $1: $report" >&2; exit 1
  fi
}

write_plist() { # <path> <platform> <min_key> <min_version>
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FW</string>
  <key>CFBundleIdentifier</key><string>io.github.beetman.xdremux.swiftui.transfercore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FW</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$2</string></array>
  <key>$3</key><string>$4</string>
</dict>
PLIST
  printf '</plist>\n' >> "$1"
}

write_modules() { # <headers_dir> <modules_dir>
  mkdir -p "$1" "$2"
  cp "$CRATE/include/xdremux_transfer.h" "$1/"
  cat > "$2/module.modulemap" <<MAP
framework module $FW {
  umbrella header "xdremux_transfer.h"
  export *
}
MAP
}

flat_framework() { # <dylib> <out_dir> <platform>
  local fw="$2/$FW.framework"
  rm -rf "$fw"; mkdir -p "$fw"
  cp "$1" "$fw/$FW"
  write_plist "$fw/Info.plist" "$3" MinimumOSVersion "$IPHONEOS_DEPLOYMENT_TARGET"
  write_modules "$fw/Headers" "$fw/Modules"
}

versioned_framework() { # <dylib> <out_dir>
  local fw="$2/$FW.framework" v
  rm -rf "$fw"; v="$fw/Versions/A"; mkdir -p "$v/Resources"
  cp "$1" "$v/$FW"
  write_plist "$v/Resources/Info.plist" MacOSX LSMinimumSystemVersion "$MACOSX_DEPLOYMENT_TARGET"
  write_modules "$v/Headers" "$v/Modules"
  ln -s A "$fw/Versions/Current"
  for item in "$FW" Headers Modules Resources; do ln -s "Versions/Current/$item" "$fw/$item"; done
}

ARGS=()
for s in $SLICES; do
  case "$s" in
    ios)
      dylib="$(build_slice aarch64-apple-ios "@rpath/$FW.framework/$FW")"
      flat_framework "$dylib" "$STAGE/ios" iPhoneOS
      dyld_check "$STAGE/ios/$FW.framework/$FW"
      ARGS+=(-framework "$STAGE/ios/$FW.framework") ;;
    ios-sim)
      dylib="$(build_slice aarch64-apple-ios-sim "@rpath/$FW.framework/$FW")"
      flat_framework "$dylib" "$STAGE/ios-sim" iPhoneSimulator
      dyld_check "$STAGE/ios-sim/$FW.framework/$FW"
      ARGS+=(-framework "$STAGE/ios-sim/$FW.framework") ;;
    macos)
      dylib="$(build_slice aarch64-apple-darwin "@rpath/$FW.framework/Versions/A/$FW")"
      versioned_framework "$dylib" "$STAGE/macos"
      dyld_check "$STAGE/macos/$FW.framework/Versions/A/$FW"
      ARGS+=(-framework "$STAGE/macos/$FW.framework") ;;
    *) echo "unknown slice: $s" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
rm -rf "$OUT/$FW.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/$FW.xcframework" >/dev/null
{
  echo "transfer_ffi_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "toolchain=$TOOLCHAIN"
  echo "slices=$SLICES"
} > "$OUT/$FW.xcframework/BUILD_RECORD.txt"
echo "done: $OUT/$FW.xcframework"
