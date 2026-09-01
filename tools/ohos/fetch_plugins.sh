#!/bin/bash
# Fetch the OHOS-adapted Flutter plugins into apps/flutter/third_party/ohos/.
#
# Why vendored instead of git deps: AtomGit's git server does not allow
# fetching arbitrary SHAs, and pub's git cache mis-resolves branch refs for
# these forks (version mismatch loops). Path deps are deterministic.
#
# Sources: CPF-Flutter forks (AtomGit), pinned to the branches below.
# Re-run to refresh; the vendored tree is gitignored.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # repo root
DEST="$ROOT/apps/flutter/third_party/ohos"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

clone() { # repo branch dir
  git clone --depth 1 --branch "$2" "https://atomgit.com/CPF-Flutter/$1.git" "$WORK/$3" >/dev/null 2>&1
}

clone flutter_packages br_path_provider-v2.1.5_ohos pkg-path_provider &
clone flutter_packages br_shared_preferences-v2.5.3_ohos pkg-shared_preferences &
clone flutter_packages br_url_launcher-v6.3.2_ohos pkg-url_launcher &
# file_picker is NOT fetched: the vendored copy is committed (with the
# v12-compat facade in lib/file_picker.dart) because the upstream fork
# (br_v8.0.7_ohos) predates file_picker v12's static API that the app uses.
clone fluttertpc_flutter_local_notifications br_v19.5.0_ohos flutter_local_notifications &
clone fluttertpc_open_filex br_v4.7.0_ohos open_filex &
clone flutter_permission_handler br_v12.0.1_ohos permission_handler &
clone fluttertpc_gallery_saver master gallery_saver &
clone fluttertpc_share_extend master share_extend &
clone fluttertpc_receive_sharing_intent br_v1.8.1_ohos receive_sharing_intent &
clone fluttertpc_flutter_foreground_task master flutter_foreground_task &
wait

rm -rf "$DEST"
mkdir -p "$DEST/permission_handler"
cp -r "$WORK/pkg-path_provider/packages/path_provider/path_provider" "$DEST/path_provider"
cp -r "$WORK/pkg-path_provider/packages/path_provider/path_provider_ohos" "$DEST/path_provider_ohos"
cp -r "$WORK/pkg-shared_preferences/packages/shared_preferences/shared_preferences" "$DEST/shared_preferences"
cp -r "$WORK/pkg-shared_preferences/packages/shared_preferences/shared_preferences_ohos" "$DEST/shared_preferences_ohos"
cp -r "$WORK/pkg-url_launcher/packages/url_launcher/url_launcher" "$DEST/url_launcher"
cp -r "$WORK/pkg-url_launcher/packages/url_launcher/url_launcher_ohos" "$DEST/url_launcher_ohos"
cp -r "$WORK/flutter_local_notifications/flutter_local_notifications" "$DEST/flutter_local_notifications"
cp -r "$WORK/open_filex" "$DEST/open_filex"
cp -r "$WORK/permission_handler/permission_handler" "$DEST/permission_handler/permission_handler"
cp -r "$WORK/permission_handler/permission_handler_ohos" "$DEST/permission_handler/permission_handler_ohos"
cp -r "$WORK/receive_sharing_intent" "$DEST/receive_sharing_intent"
cp -r "$WORK/gallery_saver" "$DEST/gallery_saver"
# The vendored fork pins http ^0.13.3; the app uses http ^1.6.0. The fork
# only uses http for remote-URL downloads, which we never do - relax it.
sed -i 's|http: \^0.13.3|http: ">=0.13.3 <2.0.0"|' "$DEST/gallery_saver/pubspec.yaml"
cp -r "$WORK/share_extend" "$DEST/share_extend"
cp -r "$WORK/flutter_foreground_task" "$DEST/flutter_foreground_task"

echo "vendored OHOS plugins -> $DEST"
