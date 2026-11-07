#!/usr/bin/env bash
# Package the native SwiftUI app (apps/apple) for a GitHub release:
#
#   apps/apple/build/release/<version>/
#     ├── XDRemux-Apple-macOS-<version>.dmg            ad-hoc signed, Apple Silicon
#     ├── XDRemux-Apple-iOS-<version>-unsigned.ipa     Payload/XDRemux.app, no signature
#     ├── XDRemux.xcarchive/                           the iOS archive (not uploaded)
#     ├── BUILD_RECORD.txt                             commits, core / transfer records, hashes
#     └── SHA256SUMS.txt
#
# Like the HarmonyOS native app, this is run on a developer Mac and uploaded by
# hand under its own tag (apple-v<version>); it never touches the Flutter
# release workflow or the Latest release.
#
# Steps:
#   1. rebuild XDRemuxCore.xcframework and XDRemuxTransferCore.xcframework
#      (macos + ios + ios-sim, arm64) from the checked-out sources, so the
#      bundled cores match HEAD (both are gitignored and go stale otherwise);
#      the simulator slice is not shipped but keeps the dev workflow working
#   2. xcodegen, Release builds for macOS (ad-hoc signed) and iOS (unsigned archive)
#   3. sanity checks: version in the bundles, core record vs. HEAD, transfer
#      framework and Share Extension present, macOS seal valid
#   4. DMG (app + /Applications link + licence files), IPA, SHA256SUMS
#
# Env:
#   XDREMUX_SKIP_CORE=1       reuse the existing XDRemuxCore.xcframework
#   XDREMUX_SKIP_TRANSFER=1   reuse the existing XDRemuxTransferCore.xcframework
#   XDREMUX_RELEASE_OUT       output dir (default apps/apple/build/release/<version>)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/apps/apple"
cd "$APP_DIR"

VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)"
BUILD_NO="$(sed -nE 's/^[[:space:]]*CFBundleVersion:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad CFBundleShortVersionString in project.yml: '$VERSION'" >&2; exit 1; }
OUT="${XDREMUX_RELEASE_OUT:-$APP_DIR/build/release/$VERSION}"
DD="$APP_DIR/build/release/DerivedData"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
echo "==> XDRemux Apple native $VERSION ($BUILD_NO) from $HEAD_SHA"
if [ -n "$(git -C "$ROOT" status --porcelain -- apps/apple xdremux/rust crates tools/apple)" ]; then
  echo "warning: working tree has uncommitted changes under apps/apple, xdremux/rust, crates or tools/apple" >&2
fi

rm -rf "$OUT" "$DD"
mkdir -p "$OUT"

# ---------------------------------------------------------------- 1. cores
if [ "${XDREMUX_SKIP_CORE:-0}" != 1 ]; then
  echo "==> XDRemuxCore.xcframework (macos ios ios-sim, arm64)"
  XDREMUX_APPLE_SLICES="macos ios ios-sim" XDREMUX_APPLE_ARCHS=arm64 "$ROOT/xdremux/rust/build_apple.sh"
fi
if [ "${XDREMUX_SKIP_TRANSFER:-0}" != 1 ]; then
  echo "==> XDRemuxTransferCore.xcframework (ios ios-sim macos)"
  "$ROOT/tools/apple/build_transfer_xcframework.sh"
fi
CORE_REC="$APP_DIR/Frameworks/XDRemuxCore.xcframework/BUILD_RECORD.txt"
XFER_REC="$APP_DIR/Frameworks/XDRemuxTransferCore.xcframework/BUILD_RECORD.txt"
[ -f "$CORE_REC" ] || { echo "missing $CORE_REC" >&2; exit 1; }
[ -f "$XFER_REC" ] || { echo "missing $XFER_REC" >&2; exit 1; }
core_commit="$(sed -n 's/^rust_commit=//p' "$CORE_REC")"
xfer_commit="$(sed -n 's/^transfer_ffi_commit=//p' "$XFER_REC")"
# The records name the commit the cores were built from; refuse a core that
# predates a change to its sources (the gitignored xcframeworks go stale
# silently otherwise — see docs/plans/apple-native.md, 2026-11-06).
if ! git -C "$ROOT" diff --quiet "$core_commit" HEAD -- xdremux/rust; then
  echo "XDRemuxCore.xcframework was built from $core_commit but xdremux/rust changed since; rebuild it" >&2; exit 1
fi
if ! git -C "$ROOT" diff --quiet "$xfer_commit" HEAD -- crates/xdremux-transfer crates/xdremux-transfer-ffi ':!*Cargo.lock'; then
  echo "XDRemuxTransferCore.xcframework was built from $xfer_commit but the transfer crates changed since; rebuild it" >&2; exit 1
fi
for slice in macos-arm64 ios-arm64; do
  [ -f "$APP_DIR/Frameworks/XDRemuxCore.xcframework/$slice/libXDRemuxCore.a" ] || { echo "core is missing the $slice slice" >&2; exit 1; }
  [ -d "$APP_DIR/Frameworks/XDRemuxTransferCore.xcframework/$slice/XDRemuxTransferCore.framework" ] || { echo "transfer core is missing the $slice slice" >&2; exit 1; }
done

# ---------------------------------------------------------------- 2. builds
echo "==> xcodegen"
xcodegen generate >/dev/null

echo "==> macOS Release (ad-hoc signed)"
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build | /usr/bin/grep -E 'error:|warning: .*(deprecated|unused)|\*\* BUILD' || true
MAC_APP="$DD/Build/Products/Release/XDRemux.app"
[ -d "$MAC_APP" ] || { echo "macOS build produced no app" >&2; exit 1; }

echo "==> iOS Release archive (unsigned)"
ARCHIVE="$OUT/XDRemux.xcarchive"
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  archive | /usr/bin/grep -E 'error:|\*\* ARCHIVE' || true
IOS_APP="$ARCHIVE/Products/Applications/XDRemux.app"
[ -d "$IOS_APP" ] || { echo "iOS archive produced no app" >&2; exit 1; }

# ---------------------------------------------------------------- 3. checks
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
mac_plist="$MAC_APP/Contents"
for app in "$mac_plist" "$IOS_APP"; do
  v="$(plist "$app" CFBundleShortVersionString)"; b="$(plist "$app" CFBundleVersion)"
  [ "$v" = "$VERSION" ] && [ "$b" = "$BUILD_NO" ] || { echo "$app reports $v ($b), expected $VERSION ($BUILD_NO)" >&2; exit 1; }
  [ "$(plist "$app" CFBundleIdentifier)" = io.github.beetman.xdremux.swiftui ] || { echo "$app has the wrong bundle id" >&2; exit 1; }
done
# The Rust core is statically linked and the archive strips symbols, so look
# for strings the core and x265 carry rather than for exported symbols.
for bin in "$MAC_APP/Contents/MacOS/XDRemux" "$IOS_APP/XDRemux"; do
  strs="$(strings -a "$bin")"
  /usr/bin/grep -q "Failed to locate LHDR metadata block" <<<"$strs" || { echo "$bin does not contain the Rust core" >&2; exit 1; }
  /usr/bin/grep -q "x265" <<<"$strs" || { echo "$bin does not contain x265" >&2; exit 1; }
done
nm -U "$MAC_APP/Contents/MacOS/XDRemux" | /usr/bin/grep -q " T _xdremux_version$" || { echo "macOS binary lacks _xdremux_version" >&2; exit 1; }
test -f "$MAC_APP/Contents/Frameworks/XDRemuxTransferCore.framework/XDRemuxTransferCore" || { echo "macOS bundle lacks the transfer framework" >&2; exit 1; }
test -f "$IOS_APP/Frameworks/XDRemuxTransferCore.framework/XDRemuxTransferCore" || { echo "iOS bundle lacks the transfer framework" >&2; exit 1; }
test -d "$IOS_APP/PlugIns/XDRemuxShare.appex" || { echo "iOS bundle lacks the Share Extension" >&2; exit 1; }
test -z "$(find "$MAC_APP" -name '*.appex')" || { echo "macOS bundle must not embed the iOS Share Extension" >&2; exit 1; }
lipo -info "$MAC_APP/Contents/MacOS/XDRemux" | /usr/bin/grep -q arm64
codesign -v --deep --strict "$MAC_APP"
codesign -d --entitlements - "$MAC_APP" 2>/dev/null | /usr/bin/grep -q 'com.apple.security.app-sandbox' || { echo "macOS app lost its sandbox entitlement" >&2; exit 1; }
echo "bundles OK: version $VERSION ($BUILD_NO), core linked, transfer framework embedded, Share Extension present"

# ---------------------------------------------------------------- 4. artefacts
echo "==> DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$MAC_APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT/LICENSING.md" "$STAGE/LICENSING.md"
DMG="$OUT/XDRemux-Apple-macOS-$VERSION.dmg"
hdiutil create -volname XDRemux -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> IPA"
IPA_STAGE="$OUT/ipa-stage"
rm -rf "$IPA_STAGE"; mkdir -p "$IPA_STAGE/Payload"
cp -R "$IOS_APP" "$IPA_STAGE/Payload/"
IPA="$OUT/XDRemux-Apple-iOS-$VERSION-unsigned.ipa"
(cd "$IPA_STAGE" && zip -qry "$IPA" Payload)
rm -rf "$IPA_STAGE"

{
  echo "version=$VERSION"
  echo "build=$BUILD_NO"
  echo "commit=$HEAD_SHA"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "--- XDRemuxCore.xcframework"; cat "$CORE_REC"
  echo "--- XDRemuxTransferCore.xcframework"; cat "$XFER_REC"
} > "$OUT/BUILD_RECORD.txt"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$IPA")" > SHA256SUMS.txt && cat SHA256SUMS.txt)
du -h "$DMG" "$IPA"
echo "done: $OUT"
