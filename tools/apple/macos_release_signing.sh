#!/usr/bin/env bash
# Signing and notarization helpers for tools/apple/package_release.sh.
# Sourced by package_release.sh and tested by tools/apple/test_package_release.py.

resolve_macos_signing() {
  local mode="${XDREMUX_MACOS_SIGN:-auto}"
  local team="${XDREMUX_TEAM_ID-W94G5B6VGC}"
  local explicit="${XDREMUX_DEVELOPER_ID:-}"
  local notarize_req="${XDREMUX_NOTARIZE:-auto}"

  case "$mode" in
    auto|developer-id|ad-hoc) ;;
    *) echo "XDREMUX_MACOS_SIGN must be auto, developer-id or ad-hoc, got '$mode'" >&2; return 2 ;;
  esac
  case "$notarize_req" in
    auto|1|0) ;;
    *) echo "XDREMUX_NOTARIZE must be auto, 1 or 0, got '$notarize_req'" >&2; return 2 ;;
  esac

  MACOS_SIGN_MODE=""
  MACOS_SIGN_IDENTITY=""

  if [ "$mode" = "ad-hoc" ]; then
    if [ "$notarize_req" = "1" ]; then
      echo "XDREMUX_NOTARIZE=1 requires Developer ID signing (XDREMUX_MACOS_SIGN cannot be ad-hoc)" >&2
      return 2
    fi
    MACOS_SIGN_MODE="ad-hoc"
    MACOS_SIGN_IDENTITY="-"
    return 0
  fi

  if [ -n "$explicit" ]; then
    MACOS_SIGN_MODE="developer-id"
    MACOS_SIGN_IDENTITY="$explicit"
    return 0
  fi

  local identities filtered count
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$identities" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p')"
  if [ -n "$team" ]; then
    local team_filtered
    team_filtered="$(printf '%s\n' "$filtered" | grep -F "($team)" || true)"
    if [ -n "$team_filtered" ]; then
      filtered="$team_filtered"
    else
      filtered=""
    fi
  fi
  filtered="$(printf '%s\n' "$filtered" | awk 'NF && !seen[$0]++')"
  count="$(printf '%s\n' "$filtered" | awk 'NF {n++} END {print n+0}')"

  if [ "$count" -eq 1 ]; then
    MACOS_SIGN_MODE="developer-id"
    MACOS_SIGN_IDENTITY="$filtered"
    return 0
  elif [ "$count" -gt 1 ]; then
    echo "multiple Developer ID Application certificates found; set XDREMUX_DEVELOPER_ID explicitly:" >&2
    printf '%s\n' "$filtered" >&2
    return 1
  fi

  if [ "$mode" = "developer-id" ]; then
    echo "no Developer ID Application certificate found${team:+ for team $team}; install one or set XDREMUX_DEVELOPER_ID" >&2
    return 1
  fi

  echo "note: no Developer ID Application certificate found${team:+ for team $team}; falling back to ad-hoc signing" >&2
  MACOS_SIGN_MODE="ad-hoc"
  MACOS_SIGN_IDENTITY="-"
}

resolve_macos_notarization() {
  local notarize_req="${XDREMUX_NOTARIZE:-auto}"
  local profile="${XDREMUX_NOTARY_PROFILE:-}"
  local keychain="${XDREMUX_NOTARY_KEYCHAIN:-}"

  MACOS_DO_NOTARIZE=0
  MACOS_NOTARY_AUTH=()

  if [ "$MACOS_SIGN_MODE" != "developer-id" ] || [ "$notarize_req" = "0" ]; then
    if [ "$notarize_req" = "1" ] && [ "$MACOS_SIGN_MODE" != "developer-id" ]; then
      echo "XDREMUX_NOTARIZE=1 requires Developer ID signing" >&2
      return 2
    fi
    return 0
  fi

  if [ -n "$profile" ]; then
    MACOS_NOTARY_AUTH=(--keychain-profile "$profile")
    if [ -n "$keychain" ]; then
      MACOS_NOTARY_AUTH+=(--keychain "$keychain")
    fi
    MACOS_DO_NOTARIZE=1
    return 0
  fi

  if [ -n "${ASC_KEY_PATH:-}" ]; then
    [ -f "$ASC_KEY_PATH" ] || { echo "ASC_KEY_PATH does not exist: $ASC_KEY_PATH" >&2; return 1; }
    if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
      echo "ASC_KEY_ID and ASC_ISSUER_ID must be set alongside ASC_KEY_PATH" >&2
      return 2
    fi
    MACOS_NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    MACOS_DO_NOTARIZE=1
    return 0
  fi

  if [ "$notarize_req" = "1" ]; then
    echo "XDREMUX_NOTARIZE=1 requires XDREMUX_NOTARY_PROFILE or ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID" >&2
    return 2
  fi

  echo "warning: Developer ID signing active, but no notarization credentials set (XDREMUX_NOTARY_PROFILE or ASC_KEY_*); skipping notarization" >&2
}

sign_macos_bundle_developer_id() {
  local app="$1"
  local identity="$2"
  local entitlements="$3"
  local fw="$app/Contents/Frameworks/XDRemuxTransferCore.framework"

  if [ -d "$fw" ]; then
    codesign --force --timestamp --sign "$identity" "$fw"
  fi
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
}

verify_macos_developer_id_signature() {
  local app="$1"
  local fw="$app/Contents/Frameworks/XDRemuxTransferCore.framework"
  local app_info fw_info

  app_info="$(codesign -dvv "$app" 2>&1)"
  printf '%s\n' "$app_info" | /usr/bin/grep -q 'Authority=Developer ID Application' || {
    echo "macOS app is not signed with Developer ID Application" >&2
    return 1
  }
  printf '%s\n' "$app_info" | /usr/bin/grep -Eq 'flags=.*\(runtime\)' || {
    echo "macOS app does not have Hardened Runtime enabled" >&2
    return 1
  }
  printf '%s\n' "$app_info" | /usr/bin/grep -q 'Timestamp=' || {
    echo "macOS app signature is missing a secure timestamp" >&2
    return 1
  }
  if printf '%s\n' "$app_info" | /usr/bin/grep -q 'Timestamp=none'; then
    echo "macOS app signature has Timestamp=none" >&2
    return 1
  fi

  if [ -d "$fw" ]; then
    fw_info="$(codesign -dvv "$fw" 2>&1)"
    printf '%s\n' "$fw_info" | /usr/bin/grep -q 'Authority=Developer ID Application' || {
      echo "XDRemuxTransferCore.framework is not signed with Developer ID Application" >&2
      return 1
    }
    printf '%s\n' "$fw_info" | /usr/bin/grep -q 'Timestamp=' || {
      echo "XDRemuxTransferCore.framework signature is missing a secure timestamp" >&2
      return 1
    }
    if printf '%s\n' "$fw_info" | /usr/bin/grep -q 'Timestamp=none'; then
      echo "XDRemuxTransferCore.framework signature has Timestamp=none" >&2
      return 1
    fi
  fi
}

notarize_and_staple_target() {
  local target="$1"
  local submit_file="$target"
  local tmp_base="" cleanup_zip="" submit_log="" sub_id=""
  local timeout="${XDREMUX_NOTARY_TIMEOUT:-}"
  local submit_args=("${MACOS_NOTARY_AUTH[@]}" --wait)

  if [ -n "$timeout" ]; then
    submit_args+=(--timeout "$timeout")
  fi

  if [ -d "$target" ]; then
    tmp_base="$(mktemp "${TMPDIR:-/tmp}/xdremux-notarize.XXXXXX")"
    cleanup_zip="$tmp_base.zip"
    rm -f "$tmp_base" "$cleanup_zip"
    ditto -c -k --keepParent "$target" "$cleanup_zip"
    submit_file="$cleanup_zip"
  fi

  submit_log="$(mktemp "${TMPDIR:-/tmp}/xdremux-notary-log.XXXXXX")"
  set +e
  xcrun notarytool submit "$submit_file" "${submit_args[@]}" 2>&1 | tee "$submit_log"
  local rc=${PIPESTATUS[0]}
  set -e

  if [ -n "$cleanup_zip" ]; then
    rm -f "$cleanup_zip"
  fi

  if [ $rc -ne 0 ]; then
    sub_id="$(sed -nE 's/^[[:space:]]*id:[[:space:]]*([0-9a-fA-F-]+).*/\1/p' "$submit_log" | head -n1)"
    rm -f "$submit_log"
    if [ -n "$sub_id" ]; then
      echo "notarization did not complete (submission id: $sub_id); inspect or wait later with:" >&2
      echo "  xcrun notarytool info $sub_id ${MACOS_NOTARY_AUTH[*]}" >&2
      echo "  xcrun notarytool log $sub_id ${MACOS_NOTARY_AUTH[*]}" >&2
    fi
    return "$rc"
  fi
  rm -f "$submit_log"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}
