#!/bin/bash
# macOS/Linux counterpart of prepare_harmony_native.ps1: stage the Rust OHOS
# core and the matching DevEco libc++_shared.so into apps/harmony/entry/libs.
# Does not build Rust; run xdremux/rust/build_ohos.sh first.
#
# Also stages the LocalSend transfer adapter built by
# tools/native/build-transfer.sh ohos.
#
# Usage: tools/ohos/prepare_harmony_native.sh [--core-path P] [--transfer-path P] [--sdk-root P]
# Env:   OHOS_SDK_ROOT, else DEVECO_SDK_HOME/default/openharmony (tools/env.sh sets it)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE_PATH="$REPO_ROOT/target/aarch64-unknown-linux-ohos/release/libxdremux_core.so"
TRANSFER_PATH="$REPO_ROOT/crates/xdremux-transfer-ffi/target/aarch64-unknown-linux-ohos/release/libxdremux_transfer.so"
SDK_ROOT="${OHOS_SDK_ROOT:-${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}/default/openharmony}"

while [ $# -gt 0 ]; do
  case "$1" in
    --core-path) CORE_PATH="$2"; shift 2 ;;
    --transfer-path) TRANSFER_PATH="$2"; shift 2 ;;
    --sdk-root) SDK_ROOT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$CORE_PATH" in /*) ;; *) CORE_PATH="$REPO_ROOT/$CORE_PATH" ;; esac
case "$TRANSFER_PATH" in /*) ;; *) TRANSFER_PATH="$REPO_ROOT/$TRANSFER_PATH" ;; esac

ENTRY_LIB_DIR="$REPO_ROOT/apps/harmony/entry/libs/arm64-v8a"
SDK_CXX="$SDK_ROOT/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"

if [ ! -f "$CORE_PATH" ]; then
  echo "Rust OHOS core was not found: $CORE_PATH. Build it with xdremux/rust/build_ohos.sh first." >&2
  exit 1
fi
if [ ! -f "$TRANSFER_PATH" ]; then
  echo "Transfer library was not found: $TRANSFER_PATH. Build it with tools/native/build-transfer.sh ohos first." >&2
  exit 1
fi
if [ ! -f "$SDK_CXX" ]; then
  echo "DevEco libc++_shared.so was not found: $SDK_CXX" >&2
  exit 1
fi

mkdir -p "$ENTRY_LIB_DIR"
cp -f "$CORE_PATH" "$ENTRY_LIB_DIR/libxdremux_core.so"
cp -f "$SDK_CXX" "$ENTRY_LIB_DIR/libc++_shared.so"
cp -f "$TRANSFER_PATH" "$ENTRY_LIB_DIR/libxdremux_transfer.so"

sha() { shasum -a 256 "$1" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'; }
size() { wc -c < "$1" | tr -d ' '; }
CORE_DST="$ENTRY_LIB_DIR/libxdremux_core.so"
CXX_DST="$ENTRY_LIB_DIR/libc++_shared.so"
TRANSFER_DST="$ENTRY_LIB_DIR/libxdremux_transfer.so"
printf '{"repoRoot":"%s","coreSource":"%s","coreDestination":"%s","coreBytes":%s,"coreSha256":"%s","libcxxSource":"%s","libcxxDestination":"%s","libcxxBytes":%s,"libcxxSha256":"%s","transferSource":"%s","transferBytes":%s,"transferSha256":"%s"}\n' \
  "$REPO_ROOT" "$CORE_PATH" "$CORE_DST" "$(size "$CORE_DST")" "$(sha "$CORE_DST")" \
  "$SDK_CXX" "$CXX_DST" "$(size "$CXX_DST")" "$(sha "$CXX_DST")" \
  "$TRANSFER_PATH" "$(size "$TRANSFER_DST")" "$(sha "$TRANSFER_DST")"
