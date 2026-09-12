# XDRemux Native HarmonyOS P0

This is the small HarmonyOS native smoke app for the P0 Rust bridge. It loads the existing arm64 `libxdremux_core.so`, reports `xdremux_version`, and classifies one image after the system document picker copy has materialized the URI into the app sandbox.

## Build

Run these commands from the repository root in PowerShell. The preparation step copies the existing Rust output and the matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory; it does not rebuild or modify the Rust core.

```powershell
.\tools\ohos\prepare_harmony_native.ps1
Set-Location .\apps\harmony
devecocli build
```

The unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The project is configured for arm64 devices and the independent bundle ID `io.github.beetman.xdremux.native`.

DevEco currently has no signing profile configured for this bundle, so the build intentionally emits an unsigned HAP. Installing it on a physical device requires a separately configured local signing profile for this application; do not reuse the Flutter application's identity or credentials.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

The current unsigned artifact cannot be installed on a physical device. Build success therefore proves packaging and compilation only; picker and native runtime behavior still need a signed-device run with a real image.

The signed-device checklist is:

- load the version once and refresh it to exercise repeated xdremux_version calls;
- classify a real image, then classify the retained sandbox path again;
- exercise a nonexistent sandbox path and confirm the Promise rejects with a useful error;
- compare the selected source bytes with the materialized file before classification.

## ABI boundary

The N-API bridge declarations mirror `xdremux/rust/src/lib.rs`: `xdremux_version` returns an owned string freed with `xdremux_free_string`; `xdremux_classify` returns `ClassificationResult` by value and its six owned strings are released with `xdremux_free_classification_result`. The arm64 static assertions in `entry/src/main/cpp/napi_bridge.cpp` guard the expected 72-byte layout. `u64` flags are exposed to ArkTS as `bigint` values.
