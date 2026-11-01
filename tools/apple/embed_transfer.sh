#!/bin/sh
# Xcode build phase (macOS and iOS Runner): embed the optional local-transfer
# library built by tools/native/build-transfer.sh. Without a built library the
# app still builds; the transfer entry is then hidden at runtime.
#
# Overrides: XDREMUX_MACOS_TRANSFER_DYLIB, XDREMUX_IOS_TRANSFER_XCFRAMEWORK.
# An explicit override that does not exist fails the build.
set -eu

TARGET_ROOT="$SRCROOT/../../../crates/xdremux-transfer-ffi/target"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

sign() {
  if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none "$1"
  fi
}

resolve() {
  # $1 override value, $2 default path
  if [ -n "$1" ]; then
    if [ ! -e "$1" ]; then
      echo "error: explicit transfer library does not exist: $1" >&2
      exit 1
    fi
    echo "$1"
  elif [ -e "$2" ]; then
    echo "$2"
  fi
}

case "$PLATFORM_NAME" in
  macosx)
    SRC="$(resolve "${XDREMUX_MACOS_TRANSFER_DYLIB:-}" "$TARGET_ROOT/release/libxdremux_transfer.dylib")"
    [ -n "$SRC" ] || { echo "note: local transfer library not built; skipping"; exit 0; }
    mkdir -p "$DEST"
    cp -f "$SRC" "$DEST/libxdremux_transfer.dylib"
    chmod 755 "$DEST/libxdremux_transfer.dylib"
    sign "$DEST/libxdremux_transfer.dylib"
    ;;
  iphoneos|iphonesimulator)
    XCF="$(resolve "${XDREMUX_IOS_TRANSFER_XCFRAMEWORK:-}" "$TARGET_ROOT/xdremux_transfer.xcframework")"
    [ -n "$XCF" ] || { echo "note: local transfer framework not built; skipping"; exit 0; }
    if [ "$PLATFORM_NAME" = iphoneos ]; then SLICE=ios-arm64; else SLICE=ios-arm64-simulator; fi
    FW="$XCF/$SLICE/xdremux_transfer.framework"
    [ -d "$FW" ] || { echo "error: $FW is missing from the xcframework" >&2; exit 1; }
    mkdir -p "$DEST"
    rm -rf "$DEST/xdremux_transfer.framework"
    cp -R "$FW" "$DEST/"
    sign "$DEST/xdremux_transfer.framework"
    ;;
  *)
    echo "note: no local transfer library for $PLATFORM_NAME"
    ;;
esac
