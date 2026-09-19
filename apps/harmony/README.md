# XDRemux Native HarmonyOS P3

This is the small HarmonyOS native app for the existing Rust bridge. It loads the existing arm64 `libxdremux_core.so`, reads photo details/classification after copying each picker URI into the app sandbox, runs a bounded foreground conversion queue, exports completed results through one serial multi-file save session, and can inspect the selected sandbox photo for Motion Photo information on demand. Settings and queue recovery stay in same-page panels so opening them does not destroy the queue session.

## Build

Run these commands from the repository root in PowerShell. Always pass the path of an already-built OHOS core explicitly; this helper stages that file and the matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory and does not rebuild or modify the Rust core.

```powershell
$core = 'C:\path\to\existing\libxdremux_core.so'
.\tools\ohos\prepare_harmony_native.ps1 -CorePath $core
Set-Location .\apps\harmony
devecocli build --product default --build-mode debug
```

The unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The project is configured for arm64 devices, the independent bundle ID `io.github.beetman.xdremux.native`, and native app version code `40007` (`0.4.0`). Motion Photo build logs and copied HAP artifacts are kept outside the repository under `C:\Users\Beet\Documents\XDRemux-Flutter-logs\harmony-native\p3-motion-inspect\`.

DevEco has no checked-in signing profile for this independent bundle, so the build intentionally emits an unsigned HAP. Installing it on a physical device requires a separately configured local signing profile for this application; do not reuse the Flutter application's identity or credentials.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI. The run command performs the build using the configured signing profile:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

P3 device verification should select several real files, including one known-invalid input, and check that valid items continue when one item fails. Check start/resume, stop-after-current, retry, reconvert after changing the global mode, per-item progress, details, single export, and multi-file export. For batch export, verify shuffled picker URI order maps by the unique requested filename, one failed target does not block later targets, stop-after-current leaves later items canceled, and a journal failure reports physical writes separately from queue state. Select a converted item and request Motion Photo information on demand; check an ordinary photo, a supported Motion Photo, and an unreadable/invalid input, then switch items and confirm each result stays with its photo. The displayed ranges and optional video/audio details must remain readable. Compare source bytes with the materialized sandbox file before conversion. Confirm a failed reconversion still labels and exports its previous successful sandbox result. The settings checklist should change each supported option, save, reopen the panel, and restart the app to confirm persistence; then verify a running conversion keeps its start-time snapshot while a later item uses the newly saved settings. A signed-device P3 run is not part of the unsigned build evidence.

## Source main synchronization

This worktree merged `origin/main` at `747ad8ffd4e59ecc7ea2c65feb068bb989d1f692` in merge commit `e65c970` after checkpoint `82bbd04`. The source tree therefore contains the newer mainline Rust work, including the SDR photographic-style path, PS3 texture/grain and semantic-matte work, and EXIF orientation fixes.

The Harmony HAP still uses the previously verified staged core (`D2C6BBA679846718124FE77BDDDD0276367B9EFB810A789C97714F273B828A80`, packaged hash `659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7`). The core was intentionally not rebuilt or replaced during this source synchronization, so the new mainline Rust features are not included in the Harmony HAP. Updating those native features requires a separate explicit `build_ohos.sh` core build and a new HAP.

The post-merge unsigned build was copied to `C:\\Users\\Beet\\Documents\\XDRemux-Flutter-logs\\harmony-native\\main-sync\\entry-default-unsigned-main-sync.hap` (5,272,818 bytes, SHA-256 `6665482C7D6BCE6BFC10B788C0DBDFA4F7C2756CDCC1CBB86D84C9E7893907B9`). The build and nine-test evidence are in the same directory; the packaged core hash remains `659C9B4DCBFF511615C5A151A227C0C336F06876061AD9F8777D8B915FD8BBF7`.

The user has confirmed the code40007 basic workflow works; that confirmation does not cover every error branch, boundary, cache/lifecycle path, or device compatibility case.

## Queue behavior and lifecycle

The queue journal is `filesDir/queue.json`; writes go to a sibling `.tmp`, verify the complete UTF-8 byte count, flush and close, then atomically rename the temporary record. Progress ticks stay in memory, while item creation, input ownership, attempt state, result publication, export state, deletion intent, and record deletion are checkpointed. A write failure is latched, stops later scheduling and maintenance, and must be explicitly retried before the queue can continue.

On startup the app validates the schema, stable IDs, decimal-string `u64` values, mode/config snapshots, input/result ownership, and sandbox file status before restoring the queue. A running or cleanup-pending item never resumes native work automatically: it becomes a visible manual-retry or cleanup record. A pending item whose sandbox input is missing becomes a visible failed item that must be re-imported. A malformed or unsafe journal is retained for an explicit quarantine/recovery action, and no orphan cleanup runs while recovery is required. The journal is sized for the bounded picker selection rather than split across Preferences keys.

The UI offers OPPO and Apple output modes plus the Rust-backed OPPO compatibility, camera-tail, strict ISO, Apple Photographic Styles, and Apple Portrait data options. The values are captured as the exact five `ConvertConfig` bytes for each item. Apple output and either Apple feature use `oppoCompat=0` and `oppoCameraTail=0`; the default OPPO output uses `oppoCompat=2` and `oppoCameraTail=255`. Each item receives a stable ID and moves through pending, running, succeeded, or failed states. Conversion is serial; a failed item does not block later pending items, and stop requests take effect after the active native call settles. Retry of an import failure repeats URI materialization, details, and classification before conversion. Reconvert captures the current committed settings when that item actually starts and retains the last successful result if the new attempt fails.

The restored session is foreground-only. `onPageHide` detaches the UI and requests stop-after-current; `onPageShow` reattaches without automatically resuming. Queue records are not background work and are not automatically resumed after process restart. Removing an item persists deletion intent before cleaning its owned sandbox paths, then removes the record only after cleanup succeeds. Cleanup covers old outputs and temporary files from previous attempts, never the picker source URI or a successfully exported destination. A cleanup failure remains a retryable removal record. The explicit cache maintenance action validates the root and `inputs`/`outputs` directories, refuses symlinks or unsafe paths, and deletes only recognized unreferenced app artifacts; it is disabled during any import, conversion, export, settings save, recovery, or journal write.

Batch export snapshots only usable, unexported results and locks those queue items for the picker and serial FD copies. The selected target URIs are matched by their unique final filename, regardless of returned array order; every queue source and sandbox path is protected from becoming a target. API18 may pre-create empty targets, so a non-empty target is rejected and no document-provider URI is deleted on failure. A successful FD copy is recorded separately from the later queue journal checkpoint; a journal failure stops later copies while retaining the physical-export fact and sandbox result. Picker cancellation and foreground teardown leave later items explicitly canceled, and the batch is never resumed automatically after restart.

Motion Photo inspection is an explicit action for the currently selected, already imported photo. The panel reports an ordinary photo or unsupported structure, recognized Motion Photo ranges and available video/audio information, or a clear inspection error. It does not split the embedded video or create a Live Photo pair. Results are kept for the current app run and must be requested again after restart.

## Persistent settings

`SettingsStore` uses the documented `@kit.ArkData` Preferences API with one JSON record (`schema=1`) under the native app's sandbox. The record stores the output mode, Rust OPPO compatibility value, camera-tail value, strict ISO flag, and both Apple feature flags. Missing data uses the documented defaults: OPPO compatibility `2`, camera tail `255`, and all three flags `false`. Stored schema, enum ranges, and boolean types are checked before any value reaches N-API. Malformed data produces a visible warning and leaves the original record untouched.

Settings are edited as a draft. A successful `flush()` publishes the committed snapshot used by future queue items; failed saves restore the previous raw Preferences value, retain the draft for retry, and leave running items unchanged. Writes are serialized so an older asynchronous save cannot finish after a newer save. Restore defaults changes the draft and requires an explicit save. Each conversion retains its mode/config summary, so later settings changes cannot relabel an old result.

## ABI boundary

The N-API bridge declarations mirror `xdremux/rust/src/lib.rs`: `xdremux_version` returns an owned string freed with `xdremux_free_string`; `xdremux_classify` returns `ClassificationResult` by value with six owned string pointers released with `xdremux_free_classification_result`; `xdremux_inspect_photo_details` returns an owned JSON string; and `xdremux_convert_with_progress` returns `ConversionResult` by value with three owned string pointers (`mode`, `family`, and `error_message`) released by `xdremux_free_result`. The arm64 static assertions in `entry/src/main/cpp/napi_bridge.cpp` guard the expected 72-byte classification and 48-byte conversion layouts. `u64` flags are exposed to ArkTS as `bigint` values.

## Deterministic queue tests

The controller tests exercise serialization, same-tick and double-start guards, failure continuation, stop-after-current, defensive mode snapshots, retry/reconversion, missing-input rematerialization, detach/resume, cleanup failure boundaries, and remove/export locks. The persistence regression tests also cover immutable snapshots, first-write failure latching and explicit retry, native-result retention when a result checkpoint fails, deletion intent ordering, progress-only updates, and restore waiting for an in-flight write. Run them from the repository root with Node 24 or newer:

```powershell
node --experimental-strip-types apps/harmony/tests/p2_queue_controller_test.mjs
node --experimental-strip-types apps/harmony/tests/p2_queue_controller_persistence_test.mjs
node --experimental-strip-types apps/harmony/tests/queue_persistence_test.mjs
node --experimental-strip-types apps/harmony/tests/queue_sandbox_test.mjs
node --experimental-strip-types apps/harmony/tests/settings_model_test.mjs
node --experimental-strip-types apps/harmony/tests/batch_export_edge_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_batch_export_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_motion_photo_model_test.mjs
node --experimental-strip-types apps/harmony/tests/motion_inspect_edge_test.mjs
```

The persistence and sandbox tests exercise the production queue codec/store and path policy through fake IO adapters, including malformed-record preservation, missing-file recovery, ownership isolation, symlink refusal, orphan cleanup, schema validation, exact Rust mappings, serial writes, and flush failure recovery. These tests do not prove Harmony picker, N-API, codec, Preferences framework integration, or device export behavior. Those require the signed-device checklist above.
