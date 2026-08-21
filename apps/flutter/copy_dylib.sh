#!/bin/bash
# Post-build hook: copy Rust dylib into the built app's Frameworks and MacOS.
# Called automatically by flutter build via the Podfile post_install.
set -euo pipefail

# Prefer the repository-root dylib (updated by cargo build --release);
# fall back to the macOS staging directory.
DYLIB="$(dirname "$0")/libxdremux_core.dylib"
BUILT_DYLIB="$(dirname "$0")/../../target/release/libxdremux_core.dylib"
# Prefer a newer host build so a Flutter rebuild cannot silently package an
# older FFI implementation.
if [ -f "$BUILT_DYLIB" ] && { [ ! -f "$DYLIB" ] || [ "$BUILT_DYLIB" -nt "$DYLIB" ]; }; then
    cp -f "$BUILT_DYLIB" "$DYLIB"
fi
[ -f "$DYLIB" ] || DYLIB="$(dirname "$0")/macos/Frameworks/libxdremux_core.dylib"

# Find the most recently built app (product name is XDRemux.app, capitalized;
# -name is case-sensitive so use -iname to tolerate either spelling).
APP=$(
    find "$(dirname "$0")/build/macos/Build/Products" \
        -iname "xdremux.app" -type d -print0 2>/dev/null \
        | xargs -0 stat -f '%m %N' 2>/dev/null \
        | sort -rn \
        | sed -n '1s/^[^ ]* //p'
)

if [ -z "$APP" ]; then
    echo "warning: no built XDRemux.app found; dylib not copied" >&2
fi

if [ -n "$APP" ] && [ -f "$DYLIB" ]; then
    mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/MacOS"
    cp -f "$DYLIB" "$APP/Contents/Frameworks/"
    cp -f "$DYLIB" "$APP/Contents/MacOS/"
    chmod +x "$APP/Contents/Frameworks/libxdremux_core.dylib"
    chmod +x "$APP/Contents/MacOS/libxdremux_core.dylib"
    echo "Copied libxdremux_core.dylib to $APP/Contents/Frameworks/ and MacOS/"
fi
