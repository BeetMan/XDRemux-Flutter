#!/bin/bash
# macOS counterpart of build_hap.ps1: build the OHOS hap with the OHOS-specific
# pubspec variant, then always restore the mainline files the build rewrites.
#
# Usage: tools/ohos/build_hap.sh [--profile|--release] [--flutter-sdk DIR]
#   SDK default: $XDREMUX_OHOS_FLUTTER_SDK, else ~/.sdks/flutter-ohos-3.41.9-1.0.2
#   DevEco default: $DEVECO_HOME, else /Applications/DevEco-Studio.app/Contents
#
# Prereqs: xdremux/rust/build_ohos.sh output copied to
# apps/flutter/ohos/entry/libs/arm64-v8a/ (with libc++_shared.so), plugins
# vendored by tools/ohos/fetch_plugins.sh, and Rosetta (the OHOS fork only
# ships an x86_64 gen_snapshot for macOS hosts).
set -euo pipefail

MODE=debug
SDK="${XDREMUX_OHOS_FLUTTER_SDK:-$HOME/.sdks/flutter-ohos-3.41.9-1.0.2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) MODE=profile ;;
    --release) MODE=release ;;
    --flutter-sdk) SDK="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/apps/flutter"

# Same guard as check_sdk.ps1: a stale platform kernel compiles and signs but
# crashes at startup, so verify the pinned revision's kernel checksum.
[ -x "$SDK/bin/flutter" ] || { echo "Not a Flutter SDK: $SDK" >&2; exit 1; }
revision=$(git -C "$SDK" rev-parse HEAD)
if [ "$revision" = 62357a93d653bf844f730bb1f4b7cc9e2139d14e ]; then
  if [ "$MODE" = release ]; then
    folder=flutter_patched_sdk_product
    expected=0945faf70f121e17288d4e30b9ffcf77d9f3b2a842ccbf628ba9087f796127b3
  else
    folder=flutter_patched_sdk
    expected=6bb2231472fc399bd1bc75e6344d4380cfb94b1db21705a7b1a36f1ea1c914b8
  fi
  kernel="$SDK/bin/cache/artifacts/engine/common/$folder/platform_strong.dill"
  [ -f "$kernel" ] || { echo "OHOS platform kernel missing. Run this SDK's 'flutter precache --ohos', then retry." >&2; exit 1; }
  actual=$(shasum -a 256 "$kernel" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "OHOS $MODE platform kernel checksum mismatch ($actual). Do not use this cache: prepare a separate SDK with fresh 'flutter precache --ohos' artifacts." >&2
    exit 1
  fi
  echo "OHOS $MODE platform kernel verified: $actual"
else
  echo "warning: no pinned kernel checksum for SDK $revision; runtime compatibility is not verified." >&2
fi
if [ "$MODE" != debug ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Rosetta is required for the x86_64 OHOS gen_snapshot: softwareupdate --install-rosetta --agree-to-license" >&2
  exit 1
fi

export PATH="$SDK/bin:$DEVECO/tools/hvigor/bin:$DEVECO/tools/ohpm/bin:$DEVECO/tools/node/bin:$DEVECO/jbr/Contents/Home/bin:$PATH"
export DEVECO_SDK_HOME="$DEVECO/sdk" DEVECO_HOME="$DEVECO" JAVA_HOME="$DEVECO/jbr/Contents/Home"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
# pnpm (run by hvigor) aborts without a TTY unless CI is set.
export CI=true
# The SDK's flutter-hvigor-plugin requires @ohos/hvigor-ohos-plugin relative to
# the SDK checkout, which has no node_modules; resolve it from DevEco instead.
MODS="$(mktemp -d)"
mkdir -p "$MODS/@ohos"
ln -s "$DEVECO/tools/hvigor/hvigor" "$MODS/@ohos/hvigor"
ln -s "$DEVECO/tools/hvigor/hvigor-ohos-plugin" "$MODS/@ohos/hvigor-ohos-plugin"
export NODE_PATH="$MODS${NODE_PATH:+:$NODE_PATH}"

cd "$APP"
BAK="$(mktemp -d)"
# The OHOS build rewrites these; the ohos/package*.json files get the local
# SDK path written into them.
FILES=(pubspec.yaml pubspec.lock macos/Flutter/GeneratedPluginRegistrant.swift ohos/package.json ohos/package-lock.json)
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BAK/$(dirname "$f")"; cp -p "$f" "$BAK/$f"; fi
done
restore() {
  for f in "${FILES[@]}"; do
    if [ -f "$BAK/$f" ]; then cp -p "$BAK/$f" "$f"; fi
  done
  rm -rf "$BAK" "$MODS"
}
trap restore EXIT

cp pubspec.ohos.yaml pubspec.yaml
# Keep the app version in sync with the mainline pubspec.
version_line=$(grep '^version:' "$BAK/pubspec.yaml")
sed -i.bak "s/^version:.*/$version_line/" pubspec.yaml && rm -f pubspec.yaml.bak
flutter pub get
# Profile mode = AOT compiled but flagged debug:true, so sideload tools signing
# with a Development profile accept it (see build_hap.ps1).
log="$(mktemp)"
stamp="$(mktemp)"   # untouched during the build, so a fresh hap is newer
set +e
flutter build hap --"$MODE" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
hap="$APP/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
# Without a local signing config the tool exits non-zero after packaging; the
# unsigned hap is what releases ship (docs/operations/releasing.md §3.5).
if [ "$status" -ne 0 ] && [ "$hap" -nt "$stamp" ] && grep -q 'Signing Configs' "$log"; then
  echo "signing not configured; using the unsigned hap"
  status=0
fi
rm -f "$log" "$stamp"
[ "$status" -eq 0 ] || exit "$status"
echo "unsigned hap: $hap"
