# XDRemux Native HarmonyOS P2

This is the small HarmonyOS native app for the P2 Rust bridge. It loads the existing arm64 `libxdremux_core.so`, reads photo details/classification after copying each picker URI into the app sandbox, and runs a bounded foreground multi-file conversion queue.

## Build

Run these commands from the repository root in PowerShell. The preparation step copies the existing Rust output and matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory; it does not rebuild or modify the Rust core.

```powershell
.\tools\ohos\prepare_harmony_native.ps1
Set-Location .\apps\harmony
devecocli build
```

The unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The project is configured for arm64 devices, the independent bundle ID `io.github.beetman.xdremux.native`, and native app version code `40002` (`0.4.0`). P2 build logs and copied HAP artifacts are kept outside the repository under `C:\Users\Beet\Documents\XDRemux-Flutter-logs\harmony-native\p2\`.

DevEco has no checked-in signing profile for this independent bundle, so the build intentionally emits an unsigned HAP. Installing it on a physical device requires a separately configured local signing profile for this application; do not reuse the Flutter application's identity or credentials.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI. The run command performs the build using the configured signing profile:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

P2 queue verification should select several real files, including one known-invalid input, and check that valid items continue when one item fails. Check start/resume, stop-after-current, retry, reconvert after changing the global mode, per-item progress, details, and export. Compare source bytes with the materialized sandbox file before conversion. Confirm a failed reconversion still labels and exports its previous successful sandbox result. A signed-device P2 run is not part of the unsigned build evidence.

## Queue behavior and lifecycle

The UI offers `OPPO 兼容` (`oppoCompat=2`, `oppoCameraTail=255`) and `Apple 标准` (`oppoCompat=0`, `oppoCameraTail=0`) modes. The remaining three configuration bytes are captured as zero. Each item receives a stable in-memory ID and moves through pending, running, succeeded, or failed states. Conversion is serial; a failed item does not block later pending items, and stop requests take effect after the active native call settles. Retry of an import failure repeats URI materialization, details, and classification before conversion. Reconvert captures the current global mode when that item actually starts and retains the last successful result if the new attempt fails.

The queue and its sandbox ownership records live only for the current app page session. `onPageHide` detaches the UI and requests stop-after-current; `onPageShow` reattaches without automatically resuming. There is no persistence, background scheduling, album permission flow, or batch conversion API in this P2 batch. Removing an item explicitly cleans every path allocated for that item, including old outputs and temporary files from previous attempts; a cleanup failure remains a retryable removal record.

## ABI boundary

The N-API bridge declarations mirror `xdremux/rust/src/lib.rs`: `xdremux_version` returns an owned string freed with `xdremux_free_string`; `xdremux_classify` returns `ClassificationResult` by value with six owned string pointers released with `xdremux_free_classification_result`; `xdremux_inspect_photo_details` returns an owned JSON string; and `xdremux_convert_with_progress` returns `ConversionResult` by value with three owned string pointers (`mode`, `family`, and `error_message`) released by `xdremux_free_result`. The arm64 static assertions in `entry/src/main/cpp/napi_bridge.cpp` guard the expected 72-byte classification and 48-byte conversion layouts. `u64` flags are exposed to ArkTS as `bigint` values.

## Deterministic queue tests

The controller tests exercise serialization, same-tick and double-start guards, failure continuation, stop-after-current, defensive mode snapshots, retry/reconversion, missing-input rematerialization, detach/resume, cleanup failure boundaries, and remove/export locks. Run them from the repository root with Node 24 or newer:

```powershell
node --experimental-strip-types apps/harmony/tests/p2_queue_controller_test.mjs
```

These tests use fake preparation/conversion/cleanup operations and do not prove Harmony picker, N-API, codec, or device export behavior. Those require the signed-device checklist above.
