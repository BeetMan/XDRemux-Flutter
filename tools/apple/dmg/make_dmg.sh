#!/usr/bin/env bash
# Build the macOS installer DMG from a staging directory:
#
#   make_dmg.sh <volume-name> <output.dmg> <stage-dir> [volume-icon.icns]
#
# The window follows xdremux.app (black, glows, gradient wordmark drawn by
# gen_background.swift) and shows the app on the left, the /Applications link
# on the right with an arrow between them, the website link in the top-right
# corner and the remaining staged files (licence files, the Privacy &
# Security shortcut) in a row along the bottom. See settings.py for the
# positions.#
# dmgbuild writes the Finder layout (.DS_Store) itself, so no Finder session
# or AppleScript is needed and a developer Mac and CI produce the same image.
# It needs Python >= 3.11 and is installed once into a cached virtualenv from
# requirements.txt. When that is not possible the image is still built, only
# without the layout, unless XDREMUX_DMG_STRICT=1 makes that an error (use it
# in CI so a broken environment cannot ship an unstyled DMG unnoticed).
#
# Env:
#   XDREMUX_DMG_VENV     virtualenv location (default ~/.cache/xdremux/dmgbuild-venv)
#   XDREMUX_DMG_STRICT   1 = fail instead of falling back to a plain image
set -euo pipefail

VOL="${1:-}"
OUT="${2:-}"
STAGE="${3:-}"
ICON="${4:-}"
if [ -z "$VOL" ] || [ -z "$OUT" ] || [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
  echo "usage: $0 <volume-name> <output.dmg> <stage-dir> [volume-icon.icns]" >&2
  exit 2
fi
STAGE="$(cd "$STAGE" && pwd)"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ -n "$ICON" ] || ICON=""
HERE="$(cd "$(dirname "$0")" && pwd)"

plain_dmg() {
  echo "warning: building $OUT without the installer layout ($1)" >&2
  rm -f "$OUT"
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -quiet -format UDZO "$OUT"
}

# dmgbuild 2.x needs Python >= 3.11; macOS itself still ships 3.9.
find_python() {
  local c
  for c in ${XDREMUX_DMG_PYTHON:-} python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           python3.14 python3.13 python3.12 python3.11; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

if ! PY="$(find_python)"; then
  if [ "${XDREMUX_DMG_STRICT:-0}" = "1" ]; then
    echo "no Python >= 3.11 found for dmgbuild (set XDREMUX_DMG_PYTHON)" >&2
    exit 1
  fi
  plain_dmg "no Python >= 3.11"
  exit 0
fi

VENV="${XDREMUX_DMG_VENV:-$HOME/.cache/xdremux/dmgbuild-venv}"
if [ ! -x "$VENV/bin/dmgbuild" ] || ! "$VENV/bin/python" -c 'import dmgbuild' >/dev/null 2>&1; then
  echo "==> Installing dmgbuild into $VENV"
  rm -rf "$VENV"
  if ! "$PY" -m venv "$VENV" || ! "$VENV/bin/pip" install --quiet --disable-pip-version-check \
        -r "$HERE/requirements.txt"; then
    if [ "${XDREMUX_DMG_STRICT:-0}" = "1" ]; then
      echo "cannot install dmgbuild from $HERE/requirements.txt" >&2
      exit 1
    fi
    plain_dmg "cannot install dmgbuild"
    exit 0
  fi
fi

APP=""
for p in "$STAGE"/*.app; do
  [ -d "$p" ] && APP="$(basename "$p")"
done
if [ -z "$APP" ]; then
  echo "no .app bundle in $STAGE" >&2
  exit 1
fi

# Shortcut files show the generic document icon. Give them an icon of the
# build machine as a custom Finder icon (see set_file_icon.py): System
# Settings for the Privacy & Security .inetloc, Safari for the website link.
# That needs extended attributes, which exFAT/SMB staging folders drop, so
# work on copies in a temporary directory rather than in the staging folder.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DECORATED="$WORK/decorated"; mkdir -p "$DECORATED"
LINKS="$WORK/links"; mkdir -p "$LINKS"

decorate() {  # <file> <icon.icns>: copy into DECORATED with the icon
  local name; name="$(basename "$1")"
  cp "$1" "$DECORATED/$name" && "$PY" "$HERE/set_file_icon.py" "$DECORATED/$name" "$2" || {
    echo "warning: no custom icon for $name" >&2
    rm -f "$DECORATED/$name"
    return 1
  }
}

SETTINGS_ICON="/System/Applications/System Settings.app/Contents/Resources/Settings.icns"
if [ -f "$SETTINGS_ICON" ]; then
  for f in "$STAGE"/*.inetloc; do
    [ -e "$f" ] && decorate "$f" "$SETTINGS_ICON"
  done
fi

# Website link in the top-right corner of the window.
WEBSITE_NAME="官网 xdremux.app.webloc"
cat > "$LINKS/$WEBSITE_NAME" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>https://xdremux.app/</string>
</dict>
</plist>
PLIST
SAFARI_ICON=""
for p in /Applications/Safari.app/Contents/Resources/AppIconUpdated.icns \
         /Applications/Safari.app/Contents/Resources/App.icns; do
  [ -f "$p" ] && SAFARI_ICON="$p" && break
done
[ -z "$SAFARI_ICON" ] || decorate "$LINKS/$WEBSITE_NAME" "$SAFARI_ICON"

rm -f "$OUT"
echo "==> DMG layout: $APP -> Applications (+ extras), window from settings.py"
if ! "$VENV/bin/dmgbuild" -s "$HERE/settings.py" \
      -D "stage=$STAGE" -D "app=$APP" -D "icon=$ICON" -D "assets=$HERE" \
      -D "decorated=$DECORATED" -D "links=$LINKS" \
      --detach-retries 8 "$VOL" "$OUT"; then
  if [ "${XDREMUX_DMG_STRICT:-0}" = "1" ]; then
    echo "dmgbuild failed" >&2
    exit 1
  fi
  plain_dmg "dmgbuild failed"
fi
