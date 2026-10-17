#!/bin/bash
# Build the macOS app and deploy the fixed copy to the repo root.
#
# Usage: deploy_macos.sh [--release]
#   (default is debug build)
#
# Steps:
#   1. flutter build macos (debug or release). The Runner target's
#      "Bundle Framework" copy phase takes care of the Rust dylib, so the
#      bundle is complete and correctly signed when the build returns.
#   2. Copy the whole app bundle to <repo>/xdremux.app (the "fixed version").
#
# Run `cargo build --release -p xdremux-core` first: the copy phase will fail
# the build rather than produce an app that cannot load the Rust core.
set -euo pipefail

cd "$(dirname "$0")"   # -> apps/flutter

MODE="debug"
if [ "${1:-}" = "--release" ]; then
  MODE="release"
fi

echo "==> flutter build macos --${MODE}"
flutter build macos --${MODE}

# Note: the product is XDRemux.app (capitalized). ${MODE^} needs bash 4;
# macOS ships bash 3.2, so map the product directory explicitly.
if [ "$MODE" = "release" ]; then
  PRODUCT_DIR="Release"
else
  PRODUCT_DIR="Debug"
fi
APP="build/macos/Build/Products/${PRODUCT_DIR}/XDRemux.app"

ROOT_APP="$(dirname "$(dirname "$(pwd)")")/xdremux.app"
echo "==> deploying to ${ROOT_APP}"
rm -rf "$ROOT_APP"
cp -R "$APP" "$ROOT_APP"

echo "==> done"
