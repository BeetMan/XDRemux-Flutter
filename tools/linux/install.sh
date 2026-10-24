#!/usr/bin/env bash
# User-level installer for the XDRemux Linux tarball.
#
# Installs the application into ${XDG_DATA_HOME:-$HOME/.local/share}/xdremux and
# a launcher at $HOME/.local/bin/xdremux, plus a desktop entry and icon. No root
# is required and nothing outside the user's home is modified.
#
# Usage: ./install.sh
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bin_dir="$HOME/.local/bin"
app_dir="$data_home/xdremux"
launcher="$bin_dir/xdremux"
desktop_dir="$data_home/applications"
icon_dir="$data_home/icons/hicolor/512x512/apps"

for f in "$here/bundle/xdremux" "$here/xdremux.desktop" "$here/xdremux.png"; do
  if [[ ! -e "$f" ]]; then
    echo "error: missing package file: $f" >&2
    echo "Run install.sh from the extracted XDRemux-Linux-*-x64 directory." >&2
    exit 1
  fi
done

install -d "$app_dir" "$bin_dir" "$desktop_dir" "$icon_dir"

# Replace any previous copy so re-installing/upgrading is a clean overwrite.
rm -rf "$app_dir"
cp -a "$here/bundle" "$app_dir"
# Be independent of the extraction/installer umask: files must stay readable and
# the main binary executable.
chmod -R a+rX "$app_dir"
chmod 755 "$app_dir/xdremux"

# The Rust core is dlopen()ed by Dart, so the executable's RUNPATH does not cover
# its transitive dependencies (libnuma). The launcher exports the bundle lib dir
# so the bundled libnuma.so.1 is found on hosts without libnuma1 installed.
cat > "$launcher" <<'EOF'
#!/bin/sh
# XDRemux launcher (installed by install.sh)
XDREMUX_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/xdremux"
export LD_LIBRARY_PATH="$XDREMUX_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$XDREMUX_HOME/xdremux" "$@"
EOF
chmod 755 "$launcher"

sed "s|^Exec=.*|Exec=$launcher %F|" "$here/xdremux.desktop" \
  > "$desktop_dir/xdremux.desktop"
cp -f "$here/xdremux.png" "$icon_dir/xdremux.png"
chmod a+r "$desktop_dir/xdremux.desktop" "$icon_dir/xdremux.png"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$data_home/icons/hicolor" >/dev/null 2>&1 || true
fi

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    echo "note: $bin_dir is not in PATH; add it to run 'xdremux' by name." >&2
    ;;
esac

echo "Installed XDRemux to $app_dir"
echo "Launcher: $launcher"
echo "Desktop entry: $desktop_dir/xdremux.desktop"
echo "Uninstall with:"
echo "  rm -rf \"$app_dir\" \"$launcher\" \"$desktop_dir/xdremux.desktop\" \"$icon_dir/xdremux.png\""
