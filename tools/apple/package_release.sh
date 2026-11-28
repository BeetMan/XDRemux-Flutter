#!/usr/bin/env bash
# Package the native SwiftUI app (apps/apple) for a GitHub release:
#
#   apps/apple/build/release/<version>/
#     ├── XDRemux-Apple-macOS-<version>.dmg            Developer ID + notarized when configured, else ad-hoc
#     ├── XDRemux-Apple-iOS-<version>-unsigned.ipa     Payload/XDRemux.app, no signature
#     ├── XDRemux.xcarchive/                           the iOS archive (not uploaded)
#     ├── BUILD_RECORD.txt                             commits, core / transfer records, signing, hashes
#     └── SHA256SUMS.txt
#
# Like the HarmonyOS native app, this is run on a developer Mac and uploaded by
# hand under its own tag (apple-v<version>); it never touches the Flutter
# release workflow or the Latest release.
#
# Steps:
#   1. rebuild XDRemuxCore.xcframework and XDRemuxTransferCore.xcframework
#      (macos + ios + ios-sim, arm64) from the checked-out sources, the core
#      with both HEVC encoders (XDREMUX_APPLE_HEVC=vt+x265: GitHub packages
#      let the user choose; needs the vendored x265 checkout), so the
#      bundled cores match HEAD (both are gitignored and go stale otherwise);
#      the simulator slice is not shipped but keeps the dev workflow working
#   2. xcodegen, Release builds for macOS (Developer ID or ad-hoc) and iOS (unsigned archive)
#   3. sanity checks: version in the bundles, core record vs. HEAD, transfer
#      framework and Share Extension present, macOS seal (and runtime/timestamp) valid
#   4. package DMG (+ privacy shortcut if unnotarized) with the installer
#      window from tools/apple/dmg, sign DMG and run single-pass
#      notarization/stapling when enabled, IPA, SHA256SUMS
#
# Env:
#   XDREMUX_SKIP_CORE=1       reuse the existing XDRemuxCore.xcframework. NOT
#                             CHECKED YET: the reused core must have been built
#                             with XDREMUX_APPLE_HEVC=vt+x265 (build_apple.sh
#                             now defaults to vt). A VideoToolbox-only core is
#                             caught below by the "does not contain x265"
#                             check; BUILD_RECORD.txt's hevc_backend= line is
#                             not compared yet.
#   XDREMUX_SKIP_TRANSFER=1   reuse the existing XDRemuxTransferCore.xcframework
#   XDREMUX_RELEASE_OUT       output dir (default apps/apple/build/release/<version>)
#   XDREMUX_TEAM_ID           developer team (default W94G5B6VGC; "" disables team filter)
#   XDREMUX_MACOS_SIGN        auto (default) | developer-id | ad-hoc
#   XDREMUX_DEVELOPER_ID      explicit "Developer ID Application: ..." identity or SHA-1
#   XDREMUX_NOTARIZE          auto (default) | 1 | 0
#   XDREMUX_STAPLE_APP=1      also notarize and staple XDRemux.app before building the DMG
#   XDREMUX_NOTARY_TIMEOUT    optional --timeout passed to notarytool submit --wait (e.g. 20m)
#   XDREMUX_NOTARY_PROFILE    notarytool keychain profile name (with optional XDREMUX_NOTARY_KEYCHAIN)
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
#                             App Store Connect API key (.p8) for notarytool if no profile is set
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/apps/apple"
cd "$APP_DIR"

# shellcheck source=tools/apple/macos_release_signing.sh
source "$ROOT/tools/apple/macos_release_signing.sh"

VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)"
BUILD_NO="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)"
[[ "$BUILD_NO" =~ ^[0-9]+$ ]] || { echo "bad CURRENT_PROJECT_VERSION in project.yml: '$BUILD_NO'" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad CFBundleShortVersionString in project.yml: '$VERSION'" >&2; exit 1; }
OUT="${XDREMUX_RELEASE_OUT:-$APP_DIR/build/release/$VERSION}"
DD="$APP_DIR/build/release/DerivedData"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"

resolve_macos_signing
resolve_macos_notarization
echo "==> XDRemux Apple native $VERSION ($BUILD_NO) from $HEAD_SHA (macOS sign: $MACOS_SIGN_MODE, notarize: $MACOS_DO_NOTARIZE)"
if [ -n "$(git -C "$ROOT" status --porcelain -- apps/apple xdremux/rust crates tools/apple)" ]; then
  echo "warning: working tree has uncommitted changes under apps/apple, xdremux/rust, crates or tools/apple" >&2
fi

rm -rf "$OUT" "$DD"
mkdir -p "$OUT"

# ---------------------------------------------------------------- 1. cores
if [ "${XDREMUX_SKIP_CORE:-0}" != 1 ]; then
  echo "==> XDRemuxCore.xcframework (macos ios ios-sim, arm64, VideoToolbox + x265)"
  XDREMUX_APPLE_SLICES="macos ios ios-sim" XDREMUX_APPLE_ARCHS=arm64 XDREMUX_APPLE_HEVC=vt+x265 \
    "$ROOT/xdremux/rust/build_apple.sh"
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

echo "==> macOS Release ($MACOS_SIGN_MODE signed)"
MAC_BUILD_LOG="$OUT/macos-build.log"
set +e
if [ "$MACOS_SIGN_MODE" = "developer-id" ]; then
  xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$MACOS_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="${XDREMUX_TEAM_ID-W94G5B6VGC}" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build >"$MAC_BUILD_LOG" 2>&1
else
  xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    build >"$MAC_BUILD_LOG" 2>&1
fi
rc=$?
set -e
/usr/bin/grep -E 'error:|warning: .*(deprecated|unused)|\*\* BUILD' "$MAC_BUILD_LOG" || true
[ $rc -eq 0 ] || { echo "macOS build failed; full log: $MAC_BUILD_LOG" >&2; exit 1; }
MAC_APP="$DD/Build/Products/Release/XDRemux.app"
[ -d "$MAC_APP" ] || { echo "macOS build produced no app" >&2; exit 1; }
if [ "$MACOS_SIGN_MODE" = "developer-id" ]; then
  sign_macos_bundle_developer_id "$MAC_APP" "$MACOS_SIGN_IDENTITY" "$APP_DIR/App/XDRemux-macOS.entitlements"
fi

echo "==> iOS Release archive (unsigned)"
ARCHIVE="$OUT/XDRemux.xcarchive"
IOS_BUILD_LOG="$OUT/ios-archive.log"
set +e
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  archive >"$IOS_BUILD_LOG" 2>&1
rc=$?
set -e
/usr/bin/grep -E 'error:|\*\* ARCHIVE' "$IOS_BUILD_LOG" || true
[ $rc -eq 0 ] || { echo "iOS archive failed; full log: $IOS_BUILD_LOG" >&2; exit 1; }
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
if [ "$MACOS_SIGN_MODE" = "developer-id" ]; then
  verify_macos_developer_id_signature "$MAC_APP"
fi
echo "bundles OK: version $VERSION ($BUILD_NO), core linked, transfer framework embedded, Share Extension present"

# ---------------------------------------------------------------- 4. artefacts
if [ "$MACOS_DO_NOTARIZE" -eq 1 ] && [ "${XDREMUX_STAPLE_APP:-0}" = "1" ]; then
  echo "==> Notarizing macOS app"
  notarize_and_staple_target "$MAC_APP"
  spctl --assess --type execute -vv "$MAC_APP"
fi

echo "==> DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$MAC_APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT/LICENSING.md" "$STAGE/LICENSING.md"
if [ "$MACOS_DO_NOTARIZE" -eq 0 ]; then
  "$ROOT/tools/apple/write_privacy_shortcut.sh" "$STAGE" >/dev/null
fi
DMG="$OUT/XDRemux-Apple-macOS-$VERSION.dmg"
# Installer window (app -> Applications on a drawn background), see tools/apple/dmg.
# Without Python >= 3.11 for dmgbuild this still produces a plain image and warns.
"$ROOT/tools/apple/dmg/make_dmg.sh" XDRemux "$DMG" "$STAGE" "$MAC_APP/Contents/Resources/AppIcon.icns"
rm -rf "$STAGE"
if [ "$MACOS_SIGN_MODE" = "developer-id" ]; then
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
  codesign -v --strict "$DMG"
  if [ "$MACOS_DO_NOTARIZE" -eq 1 ]; then
    echo "==> Notarizing DMG"
    notarize_and_staple_target "$DMG"
  fi
fi

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
  echo "macos_sign_mode=$MACOS_SIGN_MODE"
  echo "macos_sign_identity=$MACOS_SIGN_IDENTITY"
  echo "macos_notarized=$MACOS_DO_NOTARIZE"
  echo "--- XDRemuxCore.xcframework"; cat "$CORE_REC"
  echo "--- XDRemuxTransferCore.xcframework"; cat "$XFER_REC"
} > "$OUT/BUILD_RECORD.txt"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$IPA")" > SHA256SUMS.txt && cat SHA256SUMS.txt)
du -h "$DMG" "$IPA"
echo "done: $OUT"
