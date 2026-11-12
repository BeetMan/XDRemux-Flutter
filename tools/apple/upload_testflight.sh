#!/usr/bin/env bash
# Build the native SwiftUI app (apps/apple) for TestFlight: a distribution-signed
# iOS archive, exported for App Store Connect and, on request, uploaded.
#
#   apps/apple/build/testflight/<version>-<build>/
#     ├── XDRemux.xcarchive/     signed archive (keep it: it holds the dSYMs)
#     ├── export/XDRemux.ipa     App Store Connect package (not with XDREMUX_UPLOAD=1)
#     └── ExportOptions.plist
#
# The GitHub release artefacts (ad-hoc DMG, unsigned IPA) still come from
# tools/apple/package_release.sh; this script only covers TestFlight.
#
# One-time setup (Apple Developer Program team):
#   - App IDs io.github.beetman.xdremux.swiftui and ….swiftui.share, both with
#     the App Groups capability bound to group.io.github.beetman.xdremux.swiftui
#   - an app record for io.github.beetman.xdremux.swiftui in App Store Connect
#   - the team's Apple ID signed in under Xcode ▸ Settings ▸ Accounts, or an
#     App Store Connect API key passed through the ASC_* variables below
#
# Env:
#   XDREMUX_TEAM_ID           developer team (default W94G5B6VGC)
#   XDREMUX_BUILD_NO          build number for this upload; default is
#                             CURRENT_PROJECT_VERSION from project.yml. App Store
#                             Connect rejects a build number it has already seen
#                             for the same version.
#   XDREMUX_UPLOAD=1          upload to App Store Connect instead of only
#                             exporting the IPA
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
#                             App Store Connect API key (.p8) for signing and
#                             upload without an Xcode account session
#   XDREMUX_SKIP_CORE=1       reuse the existing XDRemuxCore.xcframework
#   XDREMUX_SKIP_TRANSFER=1   reuse the existing XDRemuxTransferCore.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/apps/apple"
cd "$APP_DIR"

TEAM="${XDREMUX_TEAM_ID:-W94G5B6VGC}"
BUNDLE_ID=io.github.beetman.xdremux.swiftui
APP_GROUP=group.io.github.beetman.xdremux.swiftui
VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)"
BUILD_NO="${XDREMUX_BUILD_NO:-$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n1)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad CFBundleShortVersionString in project.yml: '$VERSION'" >&2; exit 1; }
[[ "$BUILD_NO" =~ ^[0-9]+$ ]] || { echo "bad build number: '$BUILD_NO'" >&2; exit 1; }
OUT="$APP_DIR/build/testflight/$VERSION-$BUILD_NO"
DD="$APP_DIR/build/testflight/DerivedData"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
echo "==> XDRemux Apple native $VERSION ($BUILD_NO) for TestFlight, team $TEAM, from $HEAD_SHA"
if [ -n "$(git -C "$ROOT" status --porcelain -- apps/apple xdremux/rust crates tools/apple)" ]; then
  echo "warning: working tree has uncommitted changes under apps/apple, xdremux/rust, crates or tools/apple" >&2
fi

AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  [ -f "$ASC_KEY_PATH" ] || { echo "ASC_KEY_PATH does not exist: $ASC_KEY_PATH" >&2; exit 1; }
  : "${ASC_KEY_ID:?set ASC_KEY_ID with ASC_KEY_PATH}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID with ASC_KEY_PATH}"
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
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
# Same staleness guard as package_release.sh: the gitignored xcframeworks must
# have been built from the sources at HEAD.
if ! git -C "$ROOT" diff --quiet "$core_commit" HEAD -- xdremux/rust; then
  echo "XDRemuxCore.xcframework was built from $core_commit but xdremux/rust changed since; rebuild it" >&2; exit 1
fi
if ! git -C "$ROOT" diff --quiet "$xfer_commit" HEAD -- crates/xdremux-transfer crates/xdremux-transfer-ffi ':!*Cargo.lock'; then
  echo "XDRemuxTransferCore.xcframework was built from $xfer_commit but the transfer crates changed since; rebuild it" >&2; exit 1
fi

# ---------------------------------------------------------------- 2. archive
echo "==> xcodegen"
xcodegen generate >/dev/null

echo "==> iOS Release archive (automatic signing, team $TEAM)"
ARCHIVE="$OUT/XDRemux.xcarchive"
LOG="$OUT/archive.log"
# project.yml pins ad-hoc signing for local and CI builds; the overrides here
# switch this one archive to the team's automatic signing. Pipe through a log
# so a signing failure (missing account, App ID or App Group) stays readable.
set +e
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  CURRENT_PROJECT_VERSION="$BUILD_NO" \
  archive >"$LOG" 2>&1
rc=$?
set -e
/usr/bin/grep -E 'error:|\*\* ARCHIVE' "$LOG" || true
[ $rc -eq 0 ] || { echo "archive failed; full log: $LOG" >&2; exit 1; }
IOS_APP="$ARCHIVE/Products/Applications/XDRemux.app"
[ -d "$IOS_APP" ] || { echo "iOS archive produced no app" >&2; exit 1; }

# ---------------------------------------------------------------- 3. checks
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
APPEX="$IOS_APP/PlugIns/XDRemuxShare.appex"
test -d "$APPEX" || { echo "iOS bundle lacks the Share Extension" >&2; exit 1; }
for b in "$IOS_APP" "$APPEX"; do
  v="$(plist "$b" CFBundleShortVersionString)"; n="$(plist "$b" CFBundleVersion)"
  [ "$v" = "$VERSION" ] && [ "$n" = "$BUILD_NO" ] || { echo "$b reports $v ($n), expected $VERSION ($BUILD_NO)" >&2; exit 1; }
  test -f "$b/PrivacyInfo.xcprivacy" || { echo "$b lacks PrivacyInfo.xcprivacy" >&2; exit 1; }
  ents="$(codesign -d --entitlements - --xml "$b" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  /usr/bin/grep -q "$APP_GROUP" <<<"$ents" || { echo "$b is not signed with the app group $APP_GROUP" >&2; exit 1; }
  /usr/bin/grep -q "<string>$TEAM\." <<<"$ents" || { echo "$b is not signed for team $TEAM" >&2; exit 1; }
  # macOS sandbox keys are not in an iOS profile and fail upload validation.
  ! /usr/bin/grep -q 'com.apple.security.app-sandbox' <<<"$ents" || { echo "$b carries macOS sandbox entitlements" >&2; exit 1; }
done
[ "$(plist "$IOS_APP" CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "wrong bundle id" >&2; exit 1; }
[ "$(plist "$APPEX" CFBundleIdentifier)" = "$BUNDLE_ID.share" ] || { echo "wrong Share Extension bundle id" >&2; exit 1; }
[ "$(plist "$IOS_APP" ITSAppUsesNonExemptEncryption)" = false ] || { echo "ITSAppUsesNonExemptEncryption is not false" >&2; exit 1; }
test -f "$IOS_APP/Frameworks/XDRemuxTransferCore.framework/XDRemuxTransferCore" || { echo "iOS bundle lacks the transfer framework" >&2; exit 1; }
strs="$(strings -a "$IOS_APP/XDRemux")"
/usr/bin/grep -q "Failed to locate LHDR metadata block" <<<"$strs" || { echo "binary does not contain the Rust core" >&2; exit 1; }
codesign -v --deep --strict "$IOS_APP"
echo "archive OK: $VERSION ($BUILD_NO), team $TEAM, app group signed, privacy manifests present"

# ---------------------------------------------------------------- 4. export / upload
DEST=export
[ "${XDREMUX_UPLOAD:-0}" = 1 ] && DEST=upload
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DEST</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
echo "==> exportArchive ($DEST)"
LOG="$OUT/export.log"
set +e
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} >"$LOG" 2>&1
rc=$?
set -e
/usr/bin/grep -E 'error:|\*\* EXPORT|Upload succeeded|Uploaded' "$LOG" || true
[ $rc -eq 0 ] || { echo "export failed; full log: $LOG" >&2; exit 1; }
if [ "$DEST" = upload ]; then
  echo "uploaded $VERSION ($BUILD_NO); App Store Connect takes a few minutes to process the build"
else
  ls -lh "$OUT/export/"*.ipa
  echo "exported only; rerun with XDREMUX_UPLOAD=1 to send it to App Store Connect"
fi
echo "done: $OUT"
