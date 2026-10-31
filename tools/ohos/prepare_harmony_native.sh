#!/bin/bash
# macOS/Linux counterpart of prepare_harmony_native.ps1: stage the Rust OHOS
# core and the matching DevEco libc++_shared.so into apps/harmony/entry/libs.
# Does not build Rust; run xdremux/rust/build_ohos.sh first.
#
# Usage: tools/ohos/prepare_harmony_native.sh [--core-path P] [--sdk-root P]
# Env:   OHOS_SDK_ROOT (default: DevEco.app .../sdk/default/openharmony)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE_PATH="$REPO_ROOT/target/aarch64-unknown-linux-ohos/release/libxdremux_core.so"
SDK_ROOT="${OHOS_SDK_ROOT:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"

while [ $# -gt 0 ]; do
  case "$1" in
    --core-path) CORE_PATH="$2"; shift 2 ;;
    --sdk-root) SDK_ROOT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$CORE_PATH" in /*) ;; *) CORE_PATH="$REPO_ROOT/$CORE_PATH" ;; esac

ENTRY_LIB_DIR="$REPO_ROOT/apps/harmony/entry/libs/arm64-v8a"
SDK_CXX="$SDK_ROOT/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"

if [ ! -f "$CORE_PATH" ]; then
  echo "Rust OHOS core was not found: $CORE_PATH. Build it with xdremux/rust/build_ohos.sh first." >&2
  exit 1
fi
if [ ! -f "$SDK_CXX" ]; then
  echo "DevEco libc++_shared.so was not found: $SDK_CXX" >&2
  exit 1
fi

mkdir -p "$ENTRY_LIB_DIR"
cp -f "$CORE_PATH" "$ENTRY_LIB_DIR/libxdremux_core.so"
cp -f "$SDK_CXX" "$ENTRY_LIB_DIR/libc++_shared.so"

sha() { shasum -a 256 "$1" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'; }
size() { wc -c < "$1" | tr -d ' '; }
CORE_DST="$ENTRY_LIB_DIR/libxdremux_core.so"
CXX_DST="$ENTRY_LIB_DIR/libc++_shared.so"
printf '{"repoRoot":"%s","coreSource":"%s","coreDestination":"%s","coreBytes":%s,"coreSha256":"%s","libcxxSource":"%s","libcxxDestination":"%s","libcxxBytes":%s,"libcxxSha256":"%s"}\n' \
  "$REPO_ROOT" "$CORE_PATH" "$CORE_DST" "$(size "$CORE_DST")" "$(sha "$CORE_DST")" \
  "$SDK_CXX" "$CXX_DST" "$(size "$CXX_DST")" "$(sha "$CXX_DST")"
