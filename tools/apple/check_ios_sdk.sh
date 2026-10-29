#!/usr/bin/env bash
# Build SDK requirement, NOT the app's minimum supported iOS version.
# Keep the typed iOS 27.1 Duo APIs; never silently build a reduced feature set.
set -euo pipefail

for tool in xcodebuild xcrun; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'error: %s is required (select Xcode 27.1 or newer)\n' "$tool" >&2
    exit 1
  }
done

xcodebuild -version
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ ! "$sdk_version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
  printf 'error: unrecognised iPhoneOS SDK version: %s\n' "$sdk_version" >&2
  exit 1
fi
major="$((10#${BASH_REMATCH[1]}))"
minor="$((10#${BASH_REMATCH[2]}))"
if (( major < 27 || (major == 27 && minor < 1) )); then
  printf 'error: iPhone Duo requires iPhoneOS SDK >= 27.1; selected %s\n' "$sdk_version" >&2
  exit 1
fi
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
printf 'Checking Duo APIs with iPhoneOS SDK %s (%s)\n' "$sdk_version" "$sdk_path"
# Check actual declarations, not just the Xcode label/version. stdin avoids
# adding generated probe sources to the project or repository.
xcrun --sdk iphoneos swiftc -typecheck -sdk "$sdk_path" \
  -target arm64-apple-ios15.0 - <<'SWIFT'
import UIKit

@available(iOS 27.1, *)
func xdremuxDuoSDKProbe(_ traits: UITraitCollection) -> String {
  switch traits.verticalBarEdge {
  case .leading: return "leading"
  case .trailing: return "trailing"
  default: return "unspecified"
  }
}
SWIFT
printf 'Duo SDK preflight passed; deployment target remains iOS 15.0.\n'
