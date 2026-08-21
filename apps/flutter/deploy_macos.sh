#!/bin/bash
# Build the macOS app and deploy the fixed copy to the repo root.
#
# Usage: deploy_macos.sh [--release]
#   (default is debug build)
#
# Steps:
#   1. flutter build macos (debug or release)
#   2. Post-build dylib copy (via copy_dylib.sh) puts the Rust lib into the
#      app's Frameworks.
#   3. Copy the whole app bundle to <repo>/xdremux.app (the "fixed version").
set -euo pipefail

cd "$(dirname "$0")"   # -> apps/flutter

MODE="debug"
if [ "${1:-}" = "--release" ]; then
  MODE="release"
fi

echo "==> flutter build macos --${MODE}"
flutter build macos --${MODE}

# Ensure the Rust dylib is inside the freshly built bundle.
# Note: the product is XDRemux.app (capitalized). ${MODE^} needs bash 4;
# macOS ships bash 3.2, so map the product directory explicitly.
if [ "$MODE" = "release" ]; then
  PRODUCT_DIR="Release"
else
  PRODUCT_DIR="Debug"
fi
APP="build/macos/Build/Products/${PRODUCT_DIR}/XDRemux.app"
# dylib 源：优先仓库根副本（由 cargo build --release 更新），
# 退回 macos/Frameworks 中的历史/手工 staged 副本。
DYLIB_SRC="libxdremux_core.dylib"
BUILT_DYLIB="../../target/release/libxdremux_core.dylib"
# Never package a stale root copy when cargo has produced a newer host dylib.
if [ -f "$BUILT_DYLIB" ] && { [ ! -f "$DYLIB_SRC" ] || [ "$BUILT_DYLIB" -nt "$DYLIB_SRC" ]; }; then
  cp -f "$BUILT_DYLIB" "$DYLIB_SRC"
fi
[ -f "$DYLIB_SRC" ] || DYLIB_SRC="macos/Frameworks/libxdremux_core.dylib"
if [ -f "$DYLIB_SRC" ] && [ -d "$APP" ]; then
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/MacOS"
  cp -f "$DYLIB_SRC" "$APP/Contents/Frameworks/"
  cp -f "$DYLIB_SRC" "$APP/Contents/MacOS/"
  chmod +x "$APP/Contents/Frameworks/libxdremux_core.dylib"
  chmod +x "$APP/Contents/MacOS/libxdremux_core.dylib"
else
  echo "warning: dylib or app missing (dylib=$DYLIB_SRC, app=$APP)" >&2
fi

ROOT_APP="$(dirname "$(dirname "$(pwd)")")/xdremux.app"
echo "==> deploying to ${ROOT_APP}"
rm -rf "$ROOT_APP"
cp -R "$APP" "$ROOT_APP"

echo "==> done"
