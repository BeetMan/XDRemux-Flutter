# XDRemux Native HarmonyOS P3

This is the small HarmonyOS native app for the existing Rust bridge. The Gallery tab embeds a single-select `PhotoPickerComponent` as a full-page image grid, with HarmonyOS 7 API 26's CURRENT original-format preference and high-resolution HEIC capability; each selected photo is physically copied into the app sandbox before Rust reads it. The app also receives supported HEIC/JPEG shares into sandbox files, runs a bounded foreground conversion queue, exports completed results through one serial multi-file save session, and can inspect and split Motion Photos, create eligible Live Photo pairs, and export paired HEIC/MOV files. Settings and queue recovery stay in same-page panels so opening them does not destroy the queue session.

## Build

Run these commands from the repository root in PowerShell. Always pass the path of an already-built OHOS core explicitly; this helper stages that file and the matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory and does not rebuild or modify the Rust core.

```powershell
$core = 'C:\path\to\existing\libxdremux_core.so'
.\tools\ohos\prepare_harmony_native.ps1 -CorePath $core
Set-Location .\apps\harmony
devecocli build --product default --build-mode debug
```

When no local signing profile is selected, the unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The project is configured for arm64 devices, the independent bundle ID `io.github.beetman.xdremux.arkui`, and native app version code `40015` (`0.4.5`). Previous API26 gallery-tabs build logs and copied HAP artifacts are kept outside the repository under `C:\Users\Beet\Documents\XDRemux-Flutter-logs\harmony-native\gallery-tabs\`.

The historical code40011 signed test HAP uses the `.native` bundle ID. The current `.arkui` app has a separate identity and a matching local DevEco test-signing profile; it does not inherit `.native` app data. Release artifacts remain unsigned.

DevEco signing material is machine-specific and must remain untracked. Use local signing only for device-test packages; release artifacts remain unsigned. Do not reuse the Flutter application's identity or credentials.

## System image sharing

The `sendData` Share Kit target accepts supported file-backed HEIC/HEIF/JPEG image records. The ability reads shared records during `onCreate` or `onNewWant` and promptly copies each temporary URI into the app sandbox before queue import or Rust calls. Unsupported records are ignored with a visible count. The queue journal owns a copied file only after its durable checkpoint; restart reconciliation keeps a ready inbox copy protected until that handoff completes. If a temporary grant expires before copying, the failed task cannot retry the old URI: select that task and use **重新选择失效分享图片** to choose a replacement into the same queue item.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI. The run command performs the build using the configured signing profile:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

P3 device verification should select several real files, including one known-invalid input, and check that valid items continue when one item fails. Check start/resume, stop-after-current, retry, reconvert after changing the global mode, per-item progress, details, single export, and multi-file export. For batch export, verify shuffled picker URI order maps by the unique requested filename, one failed target does not block later targets, stop-after-current leaves later items canceled, and a journal failure reports physical writes separately from queue state. Select a converted item and request Motion Photo information on demand; check an ordinary photo, a supported Motion Photo, and an unreadable/invalid input, then switch items and confirm each result stays with its photo. The displayed ranges and optional video/audio details must remain readable. Compare source bytes with the materialized sandbox file before conversion. Confirm a failed reconversion still labels and exports its previous successful sandbox result. The settings checklist should change each supported option, save, reopen the panel, and restart the app to confirm persistence; then verify a running conversion keeps its start-time snapshot while a later item uses the newly saved settings. A signed-device P3 run is not part of the unsigned build evidence.

## Source main synchronization

This worktree merged `origin/main` at `747ad8ffd4e59ecc7ea2c65feb068bb989d1f692` in merge commit `e65c970` after checkpoint `82bbd04`. The source tree therefore contains the newer mainline Rust work, including the SDR photographic-style path, PS3 texture/grain and semantic-matte work, and EXIF orientation fixes.

The previously verified main-sync HAP used staged core `D2C6BBA679846718124FE77BDDDD0276367B9EFB810A789C97714F273B828A80`; that artifact and its old-feature limitation are historical. The current code40009 build reuses staged core `B994FB28E379C8C43B40BB952B7276EF75E38E5D40DC38DCC8E579C9F81CA63D` (4,321,800 bytes), including the native Photographic Styles 3 post-processing path.

The previous code40008 unsigned HAP was copied to `C:\\Users\\Beet\\Documents\\XDRemux-Flutter-logs\\harmony-native\\p3-styles3\\entry-default-unsigned-code40008-p3-styles3.hap` (5,448,800 bytes, SHA-256 `FE8F31DB6C151A73F794124061B49BC216F7BDA03EDB0F4E08FD43BA54994F67`). The earlier post-merge main-sync artifact remains at `C:\\Users\\Beet\\Documents\\XDRemux-Flutter-logs\\harmony-native\\main-sync\\entry-default-unsigned-main-sync.hap` for historical comparison.

The user has confirmed the code40007 basic workflow works; that confirmation does not cover every error branch, boundary, cache/lifecycle path, or device compatibility case.

## Queue behavior and lifecycle

The queue journal is `filesDir/queue.json`; writes go to a sibling `.tmp`, verify the complete UTF-8 byte count, flush and close, then atomically rename the temporary record. Progress ticks stay in memory, while item creation, input ownership, attempt state, result publication, export state, deletion intent, and record deletion are checkpointed. A write failure is latched, stops later scheduling and maintenance, and must be explicitly retried before the queue can continue.

On startup the app validates the schema, stable IDs, decimal-string `u64` values, mode/config snapshots, input/result ownership, and sandbox file status before restoring the queue. A running or cleanup-pending item never resumes native work automatically: it becomes a visible manual-retry or cleanup record. A pending item whose sandbox input is missing becomes a visible failed item that must be re-imported. A malformed or unsafe journal is retained for an explicit quarantine/recovery action, and no orphan cleanup runs while recovery is required. The journal is sized for the bounded picker selection rather than split across Preferences keys.

The UI offers OPPO and Apple output modes plus the Rust-backed OPPO compatibility, camera-tail, strict ISO, Apple Photographic Styles, Apple Photographic Styles 3, and Apple Portrait data options. Photographic Styles 3 automatically enables the 2023 styles graph and uses a stable per-input seed for its texture metadata; switching back to OPPO clears all Apple feature flags. The values are captured as the exact five `ConvertConfig` bytes plus a separate bridge-only PS3 option for each item. Apple output and any Apple feature use `oppoCompat=0` and `oppoCameraTail=0`; the default OPPO output uses `oppoCompat=2` and `oppoCameraTail=255`. Each item receives a stable ID and moves through pending, running, succeeded, or failed states. Conversion is serial; a failed item does not block later pending items, and stop requests take effect after the active native call settles. Retry of an import failure repeats URI materialization, details, and classification before conversion. Reconvert captures the current committed settings when that item actually starts and retains the last successful result if a Rust or PS3 post-process attempt fails.

The restored session is foreground-only. `onPageHide` detaches the UI and requests stop-after-current; `onPageShow` reattaches without automatically resuming. Queue records are not background work and are not automatically resumed after process restart. Removing an item persists deletion intent before cleaning its owned sandbox paths, then removes the record only after cleanup succeeds. Cleanup covers old outputs and temporary files from previous attempts, never the picker source URI or a successfully exported destination. A cleanup failure remains a retryable removal record. The explicit cache maintenance action validates the root and `inputs`/`outputs` directories, refuses symlinks or unsafe paths, and deletes only recognized unreferenced app artifacts; it is disabled during any import, conversion, export, settings save, recovery, or journal write.

Batch export snapshots only usable, unexported results and locks those queue items for the picker and serial FD copies. The selected target URIs are matched by their unique final filename, regardless of returned array order; every queue source and sandbox path is protected from becoming a target. API18 may pre-create empty targets, so a non-empty target is rejected and no document-provider URI is deleted on failure. A successful FD copy is recorded separately from the later queue journal checkpoint; a journal failure stops later copies while retaining the physical-export fact and sandbox result. Picker cancellation and foreground teardown leave later items explicitly canceled, and the batch is never resumed automatically after restart.

Motion Photo inspection is an explicit action for the currently selected, already imported photo. The panel reports an ordinary photo or unsupported structure, recognized Motion Photo ranges and available video/audio information, or a clear inspection error. Recognized Motion Photos can be split into still/video resources or paired with an Apple HEIC conversion from the same imported source. Inspection, split, and pair-generation caches are session-only.

## Persistent settings

`SettingsStore` uses the documented `@kit.ArkData` Preferences API with one JSON record (`schema=1`) under the native app's sandbox. The record stores the output mode, Rust OPPO compatibility value, camera-tail value, strict ISO flag, and all three Apple feature flags. A schema 1 record from before Photographic Styles 3 may omit that field; it migrates to `false`, while a present non-boolean value is rejected. Missing data uses the documented defaults: OPPO compatibility `2`, camera tail `255`, and all three flags `false`. Stored schema, enum ranges, and boolean types are checked before any value reaches N-API. Malformed data produces a visible warning and leaves the original record untouched.

Settings are edited as a draft. A successful `flush()` publishes the committed snapshot used by future queue items; failed saves restore the previous raw Preferences value, retain the draft for retry, and leave running items unchanged. Writes are serialized so an older asynchronous save cannot finish after a newer save. Restore defaults changes the draft and requires an explicit save. Each conversion retains its mode/config summary, so later settings changes cannot relabel an old result.

## ABI boundary

The Live Photo wrapper exposes the existing xdremux_make_live_photo and xdremux_live_photo_pair_valid functions asynchronously under the shared core mutex. The creation report is released with xdremux_free_string; pair validation returns u8.

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
node --experimental-strip-types apps/harmony/tests/motion_split_model_test.mjs
node --experimental-strip-types apps/harmony/tests/motion_split_edge_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_styles3_model_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_live_photo_pair_test.mjs
node --experimental-strip-types apps/harmony/tests/share_import_model_test.mjs
```

The persistence and sandbox tests exercise the production queue codec/store and path policy through fake IO adapters, including malformed-record preservation, missing-file recovery, ownership isolation, symlink refusal, orphan cleanup, schema validation, exact Rust mappings, serial writes, and flush failure recovery. These tests do not prove Harmony picker, N-API, codec, Preferences framework integration, or device export behavior. Those require the signed-device checklist above.
## Motion Photo split (code40009)

The previous code40009 unsigned artifact is `C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/p3-motion-split/entry-default-unsigned-code40009-p3-motion-split.hap` (5,537,354 bytes, SHA256 `A80165677C2F709E29FEC1E6FAAA91EA1AEA4D7F6CCE33C3BE0955C7240A76CA`). It reuses the code40008 Rust core without rebuilding it. Build and test evidence, plus the pending device checklist, are in the same external directory.

After inspection identifies a Motion Photo, the details panel can split its still and video resources. Each attempt copies the materialized input to a unique scratch path and registers all candidate outputs before writing. Existing files or ownership conflicts stop the attempt without deletion. The split report must match exact candidate names, MIME-derived extensions, regular files, and expected byte lengths. Failures clean only that attempt and preserve previous successful split and conversion results; cleanup failures retain ownership for later task deletion.

Split results are cached by task and source input for this session. Restart requires reinspection and splitting again; previous files remain task-owned and are removed with the task. Each resource exports through a single save picker with source and sandbox URI-alias protection. Resource export does not mark the converted image as exported. The full video may contain multiple streams or vendor trailing data; a primary-video option appears only when Rust reports one. Live Photo pairing and gallery integration are outside this batch.

Twelve Node test files and the unchanged C++ PS3 helper regression passed for code40009. This is host-side validation, not device N-API, picker lifecycle, playback, or Apple Photos validation. code40008 and code40009 device checks remain pending; unsigned delivery is unchanged.

## Live Photo paired files (code40010)

The Harmony bundle ID is `io.github.beetman.xdremux.native`, distinct from the Flutter app's `io.github.beetman.xdremux` so both can be installed side by side. The versionCode is 40010 and it reuses the existing staged Rust0.4.2 core. The unsigned DevEco artifact is `C:/Users/Beet/Documents/XDRemux-Flutter-logs/harmony-native/p3-live-photo/entry-default-unsigned-code40010-p3-live-photo.hap` (5,636,835 bytes, SHA256 `8ADAE2D6540500726C09E891897AE4032CEE2DF12504A2CAD21B962653A1B42B`). DevEco skipped signing because the project has no signing profile; sign locally in DevEco only for device testing.

Pair generation requires a currently identified Motion Photo and an Apple HEIC result whose persisted sourceInputPath exactly matches the current source. Older queue records may omit this field and remain exportable, but must be converted again before pairing. This prevents a newly imported Motion Photo from being combined with a stale successful result retained during preparation.

Each attempt allocates a unique source scratch file and flat HEIC/MOV candidates. All paths are checked for collisions, registered to the queue item, and durably saved before copying or calling Rust. The N-API calls run asynchronously under the existing core mutex. Rust's owned JSON string is released with xdremux_free_string; pair validation is invoked only after both output paths are confirmed non-empty regular files. Exact report paths, a UUID-shaped content identifier, output files, and Rust pair validation must pass before publishing the pair. Failure cleanup is limited to that attempt and keeps previous pairs and conversion output.

The session cache key contains task ID, current input path, and Apple result path; restart does not resume pair generation. Pair files remain queue-owned until task deletion. Paired export requests same-stem HEIC and MOV names from one save picker, maps returned URIs by decoded filename regardless of response order, and checks the complete target set against all source and sandbox aliases before opening a file. Copies are serial, each file reports its result, and partial success is visible. Pair export never changes the converted result's exportedUri.

Rust verifies that the two embedded identifiers match. This feature does not import the pair into the system gallery or claim Apple Photos playback compatibility. Host tests cover exact source binding and legacy records, ownership/persistence ordering, candidate collisions, malformed reports, native pair-validation failure, per-attempt cleanup, unordered picker URI mapping, alias rejection, and 1-of-2 serial export. All 13 Node tests and the C++ PS3 helper regression passed. The unsigned HAP manifest reports bundle `io.github.beetman.xdremux.native`, version `0.4.2` / code `40010`, API 18; its packaged Rust core hash matches code40009. Device picker/copy, gallery import, and Apple Photos playback remain unverified; see the external p3-live-photo device checklist.
