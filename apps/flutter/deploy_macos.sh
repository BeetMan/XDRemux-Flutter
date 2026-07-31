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

cd "$(dirname "$0")/.."   # -> apps/flutter

MODE="debug"
if [ "${1:-}" = "--release" ]; then
  MODE="release"
fi

echo "==> flutter build macos --${MODE}"
flutter build macos --${MODE}

# Ensure the Rust dylib is inside the freshly built bundle.
APP="build/macos/Build/Products/${MODE^}/xdremux.app"
DYLIB_SRC="Frameworks/libxdremux_core.dylib"
if [ -f "$DYLIB_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -f "$DYLIB_SRC" "$APP/Contents/Frameworks/"
  chmod +x "$APP/Contents/Frameworks/libxdremux_core.dylib"
fi

ROOT_APP="$(dirname "$(dirname "$(pwd)")")/xdremux.app"
echo "==> deploying to ${ROOT_APP}"
rm -rf "$ROOT_APP"
cp -R "$APP" "$ROOT_APP"

echo "==> done"
