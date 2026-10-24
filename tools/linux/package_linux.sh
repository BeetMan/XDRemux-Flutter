#!/usr/bin/env bash
# Build publishable XDRemux Linux artifacts from an existing Flutter release
# bundle: a self-contained AppImage, a portable tar.gz with a user-level
# installer, and a combined sha256 checksum file.
#
# Usage:
#   tools/linux/package_linux.sh <version> [--output DIR] [--bundle DIR]
#
#   <version>        Release version, e.g. 0.4.4 (asset names use it verbatim).
#   --output DIR     Output directory (default: <repo>/build/linux-packages).
#   --bundle DIR     Flutter release bundle to package
#                    (default: <repo>/apps/flutter/build/linux/x64/release/bundle).
#
# Produces in DIR:
#   XDRemux-Linux-<version>-x64.AppImage
#   XDRemux-Linux-<version>-x64.tar.gz
#   XDRemux-Linux-<version>-x64.sha256   (checksums of the two files above)
#
# The bundle must be built first:
#   cd apps/flutter && flutter build linux --release
#
# Network is used only on first run: to download appimagetool, and (when the
# host's libnuma.so.1 targets a newer glibc than the release baseline) the
# Ubuntu 22.04 libnuma1 package. Both are cached in
# ${XDG_CACHE_HOME:-$HOME/.cache}/xdremux-linux-packaging. Set XDREMUX_LIBNUMA
# to a libnuma.so.1 path to override. No root is required and nothing is
# published/uploaded.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

APP_NAME="XDRemux"
BINARY_NAME="xdremux"
ARCH="x86_64"        # AppImage/appimagetool architecture name
ARTIFACT_ARCH="x64"  # artifact file-name architecture suffix
# glibc baseline of the release artifacts (Ubuntu 22.04): the Rust core is built
# against this, and bundled third-party libraries must not require anything newer.
MAX_GLIBC="2.35"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
# Ubuntu 22.04 (jammy) libnuma1, built against glibc 2.35. Bundled because the
# Rust core NEEDs libnuma.so.1, which stock Ubuntu 22.04 desktop does not ship.
LIBNUMA_DEB_URL="http://archive.ubuntu.com/ubuntu/pool/main/n/numactl/libnuma1_2.0.14-3ubuntu2_amd64.deb"

version=""
output_dir="$repo_root/build/linux-packages"
bundle_dir=""

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR > 1 { if ($0 ~ /^set -euo/) exit; sub(/^# ?/, ""); print }' \
    "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      [[ $# -ge 2 ]] || die "--output needs a directory argument"
      output_dir="$2"; shift 2 ;;
    --bundle)
      [[ $# -ge 2 ]] || die "--bundle needs a directory argument"
      bundle_dir="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$version" ]] || die "unexpected extra argument: $1"
      version="$1"; shift ;;
  esac
done

[[ -n "$version" ]] || { usage; die "missing <version> (e.g. 0.4.4)"; }
[[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || die "invalid version string: $version"

bundle_dir="${bundle_dir:-$repo_root/apps/flutter/build/linux/x64/release/bundle}"
[[ -x "$bundle_dir/$BINARY_NAME" ]] || die \
  "release bundle not found: $bundle_dir/$BINARY_NAME (build with: cd apps/flutter && flutter build linux --release)"

mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"

asset_base="$APP_NAME-Linux-$version-$ARTIFACT_ARCH"
out_appimage="$output_dir/$asset_base.AppImage"
out_tar="$output_dir/$asset_base.tar.gz"
out_sha="$output_dir/$asset_base.sha256"

desktop_file="$script_dir/xdremux.desktop"
icon_file="$script_dir/xdremux.png"
installer_file="$script_dir/install.sh"
for f in "$desktop_file" "$icon_file" "$installer_file"; do
  [[ -f "$f" ]] || die "missing packaging input: $f"
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xdremux-linux-pkg.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/xdremux-linux-packaging"

download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    die "neither curl nor wget is available to download $url"
  fi
}

download_with_proxy_fallback() {
  local url="$1" dest="$2"
  if download_file "$url" "$dest"; then
    return 0
  fi
  rm -f "$dest"
  log "direct download failed; retrying through http://127.0.0.1:7890"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 20 -x http://127.0.0.1:7890 \
      -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 \
      wget -q -O "$dest" "$url"
  else
    return 1
  fi
}

# --- libnuma -----------------------------------------------------------------
# The Rust core NEEDs libnuma.so.1. It is not installed by default on Ubuntu
# 22.04 desktop, and the core is dlopen()ed by Dart, so the executable's RUNPATH
# does not cover this transitive dependency. The package therefore ships a
# libnuma.so.1 in the bundle lib dir and AppRun / run.sh / the installed launcher
# export LD_LIBRARY_PATH so it is found on hosts without libnuma1.
#
# The host's libnuma (e.g. Arch) may be built against a much newer glibc than the
# release baseline (GLIBC_2.38+ symbols), which would break on Ubuntu 22.04. The
# packager therefore prefers a glibc-compatible copy: explicit override, cached
# Ubuntu 22.04 build, compatible host copy, then downloads the Ubuntu 22.04
# libnuma1 package and caches the extracted library.

glibc_max_version() {
  local lib="$1"
  command -v objdump >/dev/null 2>&1 || return 0
  objdump -T "$lib" 2>/dev/null \
    | grep -o 'GLIBC_[0-9][0-9.]*' \
    | sed 's/^GLIBC_//' | sort -V | tail -n 1
}

# True when $1 <= $2 (dotted numeric versions).
version_le() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$2" ]]
}

libnuma_is_compatible() {
  local lib="$1" max
  max="$(glibc_max_version "$lib")"
  if [[ -z "$max" ]]; then
    log "warning: could not determine the glibc requirement of $lib"
    return 0
  fi
  if version_le "$max" "$MAX_GLIBC"; then
    return 0
  fi
  log "$lib requires GLIBC_$max (release baseline is GLIBC_$MAX_GLIBC)"
  return 1
}

find_host_libnuma() {
  local candidate
  while IFS= read -r candidate; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(ldconfig -p 2>/dev/null | awk '/libnuma\.so\.1 /{print $NF}')
  for candidate in \
    /usr/lib/libnuma.so.1 \
    /usr/lib64/libnuma.so.1 \
    /usr/lib/x86_64-linux-gnu/libnuma.so.1 \
    /lib/x86_64-linux-gnu/libnuma.so.1; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

extract_deb_libnuma() {
  local deb="$1" out="$2" tmp data_archive real
  command -v ar >/dev/null 2>&1 || return 1
  tmp="$(mktemp -d "$work_dir/libnuma.XXXXXX")"
  ( cd "$tmp" && ar x "$deb" ) || { rm -rf "$tmp"; return 1; }
  data_archive="$(find "$tmp" -maxdepth 1 -name 'data.tar.*' -print -quit)"
  [[ -n "$data_archive" ]] || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/data"
  if ! tar -xf "$data_archive" -C "$tmp/data" 2>/dev/null; then
    if command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "$data_archive" -C "$tmp/data" || { rm -rf "$tmp"; return 1; }
    elif command -v zstd >/dev/null 2>&1; then
      zstd -dc "$data_archive" | tar -xf - -C "$tmp/data" \
        || { rm -rf "$tmp"; return 1; }
    else
      rm -rf "$tmp"; return 1
    fi
  fi
  real="$(find "$tmp/data" -type f -name 'libnuma.so.1*' -print -quit)"
  [[ -n "$real" ]] || { rm -rf "$tmp"; return 1; }
  cp -f "$real" "$out"
  rm -rf "$tmp"
}

resolve_libnuma() {
  local override="${XDREMUX_LIBNUMA:-}"
  if [[ -n "$override" ]]; then
    [[ -f "$override" ]] || die "XDREMUX_LIBNUMA does not exist: $override"
    if ! libnuma_is_compatible "$override"; then
      log "warning: XDREMUX_LIBNUMA may not run on glibc $MAX_GLIBC targets"
    fi
    printf '%s\n' "$override"
    return 0
  fi

  local cached="$cache_dir/libnuma-ubuntu22.04.so.1"
  if [[ -f "$cached" ]] && libnuma_is_compatible "$cached"; then
    printf '%s\n' "$cached"
    return 0
  fi

  local host
  host="$(find_host_libnuma || true)"
  if [[ -n "$host" ]] && libnuma_is_compatible "$host"; then
    printf '%s\n' "$host"
    return 0
  fi

  local deb="$cache_dir/libnuma1_2.0.14-3ubuntu2_amd64.deb"
  mkdir -p "$cache_dir"
  if [[ ! -f "$deb" ]]; then
    log "fetching Ubuntu 22.04 libnuma1 (glibc $MAX_GLIBC baseline)"
    download_with_proxy_fallback "$LIBNUMA_DEB_URL" "$deb" \
      || { rm -f "$deb"; die "could not download $LIBNUMA_DEB_URL"; }
  fi
  extract_deb_libnuma "$deb" "$cached" \
    || die "could not extract libnuma.so.1 from $deb (need ar and tar with zstd support)"
  libnuma_is_compatible "$cached" \
    || die "extracted libnuma.so.1 is not compatible with glibc $MAX_GLIBC"
  printf '%s\n' "$cached"
}

libnuma="$(resolve_libnuma)" || die "could not resolve a usable libnuma.so.1"
libnuma_glibc="$(glibc_max_version "$libnuma")"
if [[ -n "$libnuma_glibc" ]]; then
  log "bundling libnuma from $libnuma (requires GLIBC_$libnuma_glibc)"
else
  log "bundling libnuma from $libnuma"
fi

# Copy the Flutter bundle into a staging dir and add the bundled libnuma.
# Repository files may be 0600; published artifacts must be readable.
stage_bundle() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  cp -a "$src/." "$dest/"
  cp -f "$libnuma" "$dest/lib/libnuma.so.1"
  chmod -R a+rX "$dest"
  chmod 755 "$dest/xdremux"
}

# --- tar.gz package ----------------------------------------------------------
log "staging tar.gz package"
pkg_root="$work_dir/$asset_base"
stage_bundle "$bundle_dir" "$pkg_root/bundle"
cp -f "$desktop_file" "$pkg_root/xdremux.desktop"
cp -f "$icon_file" "$pkg_root/xdremux.png"
cp -f "$installer_file" "$pkg_root/install.sh"
chmod a+r "$pkg_root/xdremux.desktop" "$pkg_root/xdremux.png"
chmod 755 "$pkg_root/install.sh"

cat > "$pkg_root/run.sh" <<'EOF'
#!/bin/sh
# Run XDRemux directly from this extracted directory (no installation needed).
# Exports the bundle lib dir so the bundled libnuma is found on hosts without
# the libnuma1 package (e.g. stock Ubuntu 22.04).
here="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$here/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/bundle/xdremux" "$@"
EOF
chmod 755 "$pkg_root/run.sh"

cat > "$pkg_root/README.txt" <<EOF
XDRemux $version for Linux ($ARTIFACT_ARCH)
============================================

This archive contains the Flutter/Rust desktop build of XDRemux together with a
user-level installer. No root privileges are required.

Quick start (no installation)
-----------------------------
  ./run.sh                 # launch XDRemux
  ./run.sh photo.heic      # launch and import files

Install for the current user
----------------------------
  ./install.sh
This installs into \${XDG_DATA_HOME:-\$HOME/.local/share}/xdremux, creates a
launcher at \$HOME/.local/bin/xdremux, a desktop entry and a hicolor icon.
Uninstall instructions are printed by the installer (and repeated at the end of
install.sh).

Requirements
------------
  * glibc >= 2.35 (Ubuntu 22.04+, Debian 12+, Fedora 36+)
  * GTK 3 runtime (libgtk-3-0 / gtk3)
  * libstdc++6 (usually installed on desktop systems)
  * libnuma.so.1 is bundled in bundle/lib/ (built against the glibc 2.35
    baseline) and loaded through LD_LIBRARY_PATH by run.sh / install.sh, so the
    libnuma1 package is NOT required.
  * Optional: xdg-utils (xdg-open) for "open output folder"; xdg-desktop-portal
    (with a GTK backend) for the system file picker dialog.

Notes
-----
  * Do not run bundle/xdremux directly unless libnuma1 is installed on the host:
    use run.sh or the installed launcher, which set LD_LIBRARY_PATH.
  * AppImage users get the same layout and environment through AppRun.

Third-party notices
-------------------
  * libnuma (bundled): LGPL-2.1-or-later, from numactl 2.0.14 (Ubuntu 22.04).
  * x265 (statically linked into the Rust core): GPL-2.0-or-later.
  * Flutter engine (libflutter_linux_gtk.so, libapp.so): BSD-3-Clause.
See the project repository for full third-party licensing information.
EOF

# Normalise modes for the archive (the build user's umask may be 077).
chmod -R a+rX "$pkg_root"
chmod 755 "$pkg_root/install.sh" "$pkg_root/run.sh"

tar -czf "$out_tar" -C "$work_dir" "$asset_base"
log "wrote $out_tar"

# --- AppImage ----------------------------------------------------------------
log "staging AppDir"
appdir="$work_dir/AppDir"
stage_bundle "$bundle_dir" "$appdir/usr/bin"
cp -f "$icon_file" "$appdir/xdremux.png"
chmod a+r "$appdir/xdremux.png"
# Root-level desktop file used for AppImage desktop integration.
sed 's|^Exec=.*|Exec=xdremux %F|' "$desktop_file" > "$appdir/xdremux.desktop"
chmod a+r "$appdir/xdremux.desktop"

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
# AppImage entry point: set the bundled lib dir (libnuma) and start XDRemux.
here="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$here/usr/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/usr/bin/xdremux" "$@"
EOF
chmod 755 "$appdir/AppRun"
# Normalise modes for the AppImage filesystem (umask may be 077).
chmod -R a+rX "$appdir"
chmod 755 "$appdir/AppRun"

# --- appimagetool ------------------------------------------------------------
appimagetool="$cache_dir/appimagetool-x86_64.AppImage"

if [[ ! -x "$appimagetool" ]]; then
  mkdir -p "$cache_dir"
  log "downloading appimagetool to $appimagetool"
  tmp_tool="$appimagetool.part"
  rm -f "$tmp_tool"
  download_with_proxy_fallback "$APPIMAGETOOL_URL" "$tmp_tool" \
    || { rm -f "$tmp_tool"; die "could not download appimagetool"; }
  mv -f "$tmp_tool" "$appimagetool"
  chmod +x "$appimagetool"
fi

log "packaging AppImage with $appimagetool"
export ARCH="$ARCH"
appimagetool_log="$work_dir/appimagetool.log"
if ! "$appimagetool" --no-appstream "$appdir" "$out_appimage" 2>"$appimagetool_log"; then
  log "direct appimagetool run failed (FUSE?); retrying with APPIMAGE_EXTRACT_AND_RUN=1"
  rm -f "$out_appimage"
  if ! APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool" --no-appstream \
      "$appdir" "$out_appimage" 2>>"$appimagetool_log"; then
    log "retrying with appimagetool extracted via --appimage-extract"
    rm -f "$out_appimage"
    extract_dir="$work_dir/appimagetool-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    ( cd "$extract_dir" && "$appimagetool" --appimage-extract >/dev/null 2>&1 ) || true
    extracted="$extract_dir/squashfs-root/AppRun"
    if [[ ! -x "$extracted" ]] || ! "$extracted" --no-appstream \
        "$appdir" "$out_appimage" 2>>"$appimagetool_log"; then
      cat "$appimagetool_log" >&2
      die "appimagetool could not create the AppImage"
    fi
  fi
fi
[[ -s "$out_appimage" ]] || die "appimagetool did not produce $out_appimage"
log "wrote $out_appimage"

# --- checksums ---------------------------------------------------------------
log "writing checksums"
(
  cd "$output_dir"
  sha256sum "$(basename "$out_appimage")" "$(basename "$out_tar")" \
    > "$(basename "$out_sha")"
  sha256sum -c "$(basename "$out_sha")"
)

# --- summary -----------------------------------------------------------------
# Publishable assets must be world-readable regardless of the build user's umask.
chmod 755 "$out_appimage"
chmod 644 "$out_tar" "$out_sha"
bundle_kib="$(du -sk "$bundle_dir" | awk '{print $1}')"
printf '\nArtifacts in %s (source bundle %s KiB):\n' "$output_dir" "$bundle_kib"
ls -lh "$out_appimage" "$out_tar" "$out_sha"
