# Native HarmonyOS build and verification

The host CI workflow at `.github/workflows/harmony-native-ci.yml` runs the deterministic ArkTS model/queue tests, the HAP verifier's unit tests, and the C++ PS3 pipeline helper. It does not compile ArkTS or package a HAP. Full app packaging requires the locally installed DevEco SDK and `devecocli`.

## Build an unsigned HAP

Run from the repository root in PowerShell. Use the Rust core already produced by `xdremux/rust/build_ohos.sh`; `prepare_harmony_native.ps1` stages that library and the matching DevEco C++ runtime but does not build Rust.

```powershell
$corePath = 'C:\path\to\existing\libxdremux_core.so'
.\tools\ohos\prepare_harmony_native.ps1 -CorePath $corePath

Push-Location .\apps\harmony
devecocli build --product default --build-mode debug 2>&1 |
    Tee-Object -FilePath 'C:\path\to\external\logs\build.log'
$buildExitCode = $LASTEXITCODE
Pop-Location
if ($buildExitCode -ne 0) { throw 'DevEco HAP build failed' }
```

DevEco writes the HAP to `apps/harmony/entry/build/default/outputs/default/entry-default-unsigned.hap` when no signing profile is configured. Copy each reviewed build to the external `harmony-native` log/artifact directory; never add HAP files, staged libraries, signing profiles, or signing credentials to Git.

## Verify the built package

The verifier reads the packaged `module.json` and `pack.info`, checks the native bundle identity is distinct from the Flutter bundle, version and compatible API, checks the arm64 bridge/core/runtime libraries, rejects recognized signature entries, and reports hashes for the HAP and packaged Rust core.

```powershell
python .\apps\harmony\tools\verify_harmony_hap.py `
  'C:\path\to\external\logs\entry-default-unsigned-codeNNNNN.hap' `
  --version-name 0.4.2 `
  --version-code 40000 `
  --compatible-api 18 `
  --expected-core-sha256 <packaged-core-sha256> `
  --report 'C:\path\to\external\logs\hap-verification.json'
```

Record the Rust input library hash separately with `Get-FileHash` or the preparation script's JSON output. The HAP's core is toolchain-stripped, so its hash is expected to differ from the staged input. Pair the manifest report with the DevEco build log showing whether signing was skipped. Local device-test signing belongs in DevEco and must use the native bundle identity; release artifacts remain unsigned.

## Host regressions

The workflow command list can also be run locally from the repository root:

```powershell
Get-ChildItem .\apps\harmony\tests -Filter '*.mjs' | ForEach-Object {
  node --experimental-strip-types $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "Test failed: $($_.Name)" }
}
python -m unittest apps.harmony.tests.hap_verifier_test
```

These host regressions do not prove Harmony Share Kit, file-picker permissions, ArkUI lifecycle, N-API loading, or photo/gallery behavior. Use the signed-device checklist in the external `harmony-native` artifact folder for those checks.
