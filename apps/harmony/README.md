# XDRemux Native HarmonyOS P1

This is the small HarmonyOS native app for the P1 Rust bridge. It loads the existing arm64 `libxdremux_core.so`, reports `xdremux_version`, and runs a single-file read, classify, convert, and export workflow after the system document picker copy has materialized the URI into the app sandbox.

## Build

Run these commands from the repository root in PowerShell. The preparation step copies the existing Rust output and the matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory; it does not rebuild or modify the Rust core.

```powershell
.\tools\ohos\prepare_harmony_native.ps1
Set-Location .\apps\harmony
devecocli build
```

The unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The project is configured for arm64 devices, the independent bundle ID `io.github.beetman.xdremux.native`, and native app version code `40001` (`0.4.0`).

DevEco currently has no signing profile configured for this bundle, so the build intentionally emits an unsigned HAP. Installing it on a physical device requires a separately configured local signing profile for this application; do not reuse the Flutter application's identity or credentials.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

The current unsigned artifact cannot be installed on a physical device. Build success therefore proves packaging and compilation only; picker and native runtime behavior still need a signed-device run with a real image.

The signed-device checklist is:

- load the version once during app startup;
- classify a real image, then classify the retained sandbox path again;
- exercise a nonexistent sandbox path and confirm classify resolves its structured `unreadable-image` status;
- compare the selected source bytes with the materialized file before classification.

## ABI boundary

The N-API bridge declarations mirror `xdremux/rust/src/lib.rs`: `xdremux_version` returns an owned string freed with `xdremux_free_string`; `xdremux_classify` returns `ClassificationResult` by value and its six owned strings are released with `xdremux_free_classification_result`; `xdremux_inspect_photo_details` returns an owned JSON string; and `xdremux_convert_with_progress` returns `ConversionResult` by value with its three owned string pointers released by `xdremux_free_result`. The arm64 static assertions in `entry/src/main/cpp/napi_bridge.cpp` guard the expected 72-byte classification and 48-byte conversion layouts. `u64` flags are exposed to ArkTS as `bigint` values.

## P1 single-file workflow

The Chinese UI offers `OPPO 兼容` (`oppoCompat=2`, `oppoCameraTail=255`) and `Apple 标准` (`oppoCompat=0`, `oppoCameraTail=0`) modes. The remaining three configuration bytes are captured as zero for this bounded P1. Photo details are read from the Rust JSON report before classification.

Conversion runs asynchronously and serially. A per-job progress handle is polled for stage/current/total and released only after the conversion Promise settles. The output is written to a unique `.heic.tmp` sandbox path, checked, and renamed to a unique `.heic` path only after a successful `ConversionResult`; the selected input is never used as the output path. The result stays in the sandbox and remains available for export retries after an export failure or success.

Export uses `DocumentViewPicker.save`, opens the returned URI without `TRUNC`, rejects a non-empty target and the retained source URI, copies through the target file descriptor, checks the byte count, and closes the descriptor before reporting success. Any picker, copy, stat, or close failure leaves the sandbox result available for retry.

Build logs and unsigned P1 HAP copies are kept outside the repository under `C:\Users\Beet\Documents\XDRemux-Flutter-logs\harmony-native\p1\`. A signed-device run remains required to verify picker fidelity, real-image details, conversion output bytes, progress updates, and system export behavior.
