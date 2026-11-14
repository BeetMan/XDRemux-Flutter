#!/bin/bash
# Run the "Apple native" CI job (.github/workflows/apple-ci.yml) on this Mac.
#
# macOS runners are scarce, so CI only runs that job for pull requests that
# touch the Apple app or its tooling, and once on main after a Rust-core
# merge. For a Rust PR that changes the FFI surface (or anything else the
# Swift side depends on), run this before merging and paste the summary it
# prints into the PR description.
#
#   tools/apple/verify_local.sh            # everything
#   tools/apple/verify_local.sh --no-ios   # skip the iOS simulator build
#
# Env:
#   XDREMUX_VERIFY_SKIP_FRAMEWORKS=1  reuse apps/apple/Frameworks/*.xcframework
#                                     instead of rebuilding them (only valid
#                                     when no Rust source changed since)
#
# Prereqs: Xcode, rustup with the Apple targets build_apple.sh lists, Rust
# 1.97.1 for the transfer crate, cbindgen, xcodegen, and a vendored x265
# checkout in xdremux/rust/vendor/x265 (see apps/apple/README.md).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

IOS=1
for arg in "$@"; do
  case "$arg" in
    --no-ios) IOS=0 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xdremux-verify.XXXXXX")"
SUMMARY=()
FAILED=0

# step <name> <command...>: run, log to a file, record pass/fail and duration.
# Later steps are skipped after the first failure (they depend on earlier ones).
step() {
  local name="$1"; shift
  if [ "$FAILED" -ne 0 ]; then
    SUMMARY+=("- skipped: $name")
    return
  fi
  local log="$LOG_DIR/$(printf '%02d' "${#SUMMARY[@]}").log"
  local start=$SECONDS
  printf '==> %s\n' "$name"
  # Subshell: the step functions cd, and that must not leak into later steps.
  if ( "$@" ) >"$log" 2>&1; then
    SUMMARY+=("- ok ($((SECONDS - start))s): $name")
  else
    SUMMARY+=("- FAILED ($((SECONDS - start))s): $name")
    FAILED=1
    tail -40 "$log"
    echo "full log: $log" >&2
  fi
}

check_slices() {
  local fw=apps/apple/Frameworks/XDRemuxCore.xcframework lib
  for lib in "$fw"/macos-*/libXDRemuxCore.a "$fw"/ios-*-simulator/libXDRemuxCore.a; do
    lipo -info "$lib" | grep -q x86_64 && lipo -info "$lib" | grep -q arm64 || return 1
  done
}

cli_smoke() {
  cd apps/apple/Packages/XDRemuxKit || return 1
  swift build -c release --product xdremux || return 1
  .build/release/xdremux --version || return 1
  .build/release/xdremux capabilities || return 1
  head -c 4096 /dev/urandom > "$LOG_DIR/garbage.heic"
  # A garbage file must be rejected.
  ! .build/release/xdremux inspect "$LOG_DIR/garbage.heic"
}

build_app() {  # build_app <destination>
  cd apps/apple || return 1
  xcodegen generate || return 1
  xcodebuild -project XDRemux.xcodeproj -scheme XDRemux \
    -destination "$1" -configuration Debug CODE_SIGNING_ALLOWED=NO build
}

step "C header is current (check_header.sh)" tools/apple/check_header.sh
if [ "${XDREMUX_VERIFY_SKIP_FRAMEWORKS:-0}" = 1 ]; then
  SUMMARY+=("- skipped (XDREMUX_VERIFY_SKIP_FRAMEWORKS=1): xcframework rebuild")
else
  step "XDRemuxCore.xcframework (macOS + simulator, arm64 + x86_64)" \
    env XDREMUX_APPLE_SLICES="macos ios-sim" xdremux/rust/build_apple.sh
  step "XDRemuxTransferCore.xcframework (macOS + simulator)" \
    env XDREMUX_TRANSFER_SLICES="macos ios-sim" tools/apple/build_transfer_xcframework.sh
fi
step "xcframework slice architectures" check_slices
step "swift test (XDRemuxKit)" sh -c 'cd apps/apple/Packages/XDRemuxKit && swift test'
step "xdremux CLI release build and smoke" cli_smoke
step "macOS app build" build_app 'platform=macOS,arch=arm64'
if [ "$IOS" -eq 1 ]; then
  step "iOS app + Share Extension build (simulator)" build_app 'generic/platform=iOS Simulator'
else
  SUMMARY+=("- skipped (--no-ios): iOS app + Share Extension build (simulator)")
fi

echo
echo "### Local Apple verification (tools/apple/verify_local.sh)"
echo
echo "Commit \`$(git rev-parse --short HEAD)\`$(git diff --quiet HEAD -- 2>/dev/null || echo ' + uncommitted changes'), $(xcodebuild -version | tr '\n' ' ')on $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
echo
printf '%s\n' "${SUMMARY[@]}"
echo
echo "logs: $LOG_DIR"
exit "$FAILED"
