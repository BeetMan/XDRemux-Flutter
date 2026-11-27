#!/usr/bin/env bash
# Write a macOS .inetloc shortcut opening System Settings -> Privacy & Security
# inside a DMG staging directory so users of unnotarized builds can jump to
# the "Open Anyway" section directly from the DMG window.
# (.webloc only accepts http/https URLs in LaunchServices and fails with -10400
# on x-apple.systempreferences: URLs.)
set -euo pipefail

DEST_DIR="${1:-}"
if [ -z "$DEST_DIR" ] || [ ! -d "$DEST_DIR" ]; then
  echo "usage: $0 <dmg-stage-dir>" >&2
  exit 2
fi

SHORTCUT_NAME="${XDREMUX_PRIVACY_SHORTCUT_NAME:-打开隐私与安全性 (Privacy & Security).inetloc}"
OUT="$DEST_DIR/$SHORTCUT_NAME"

cat > "$OUT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension</string>
</dict>
</plist>
PLIST
chmod 644 "$OUT"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$OUT" >/dev/null
fi
echo "$OUT"
