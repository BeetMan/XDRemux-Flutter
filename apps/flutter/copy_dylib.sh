#!/bin/bash
# Post-build hook: copy Rust dylib into the built app's Frameworks.
# Called automatically by flutter build via the Podfile post_install.
set -euo pipefail

DYLIB="$(dirname "$0")/Frameworks/libxdremux_core.dylib"

# Find the most recently built app
APP=$(find "$(dirname "$0")/build/macos/Build/Products" -name "xdremux.app" -type d 2>/dev/null | head -1)

if [ -n "$APP" ] && [ -f "$DYLIB" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -f "$DYLIB" "$APP/Contents/Frameworks/"
    chmod +x "$APP/Contents/Frameworks/libxdremux_core.dylib"
    echo "Copied libxdremux_core.dylib to $APP/Contents/Frameworks/"
fi
