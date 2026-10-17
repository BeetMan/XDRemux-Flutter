# Check the platform kernel used by the pinned OHOS SDK, not just its version
# string: a stale kernel can still compile successfully but truncate native
# function pointers during Flutter startup. Never repair a shared SDK in place.
param(
    [Parameter(Mandatory = $true)][string]$SdkPath,
    [ValidateSet('debug', 'profile', 'release')][string]$BuildMode = 'profile'
)

$ErrorActionPreference = 'Stop'
$sdk = (Resolve-Path -LiteralPath $SdkPath).Path
if (!(Test-Path -LiteralPath (Join-Path $sdk 'bin/flutter.bat'))) {
    throw "Not a Flutter SDK: $sdk"
}
$revision = & git -C $sdk rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw "Cannot determine OHOS SDK revision: $sdk" }
if ($revision -ne '62357a93d653bf844f730bb1f4b7cc9e2139d14e') {
    Write-Warning "No pinned kernel checksum for SDK $revision; runtime compatibility is not verified."
    return
}

# SHA256 of the freshly downloaded artifacts for this exact framework revision.
# This is a local compatibility guard, not a general SDK authenticity check.
$product = $BuildMode -eq 'release'
$folder = if ($product) { 'flutter_patched_sdk_product' } else { 'flutter_patched_sdk' }
$expected = if ($product) {
    '0945FAF70F121E17288D4E30B9FFCF77D9F3B2A842CCBF628BA9087F796127B3'
} else {
    '6BB2231472FC399BD1BC75E6344D4380CFB94B1DB21705A7B1A36F1EA1C914B8'
}
$kernel = Join-Path $sdk "bin/cache/artifacts/engine/common/$folder/platform_strong.dill"
if (!(Test-Path -LiteralPath $kernel)) {
    throw "OHOS platform kernel missing. Run this SDK's 'flutter precache --ohos', then retry."
}
$actual = (Get-FileHash -LiteralPath $kernel -Algorithm SHA256).Hash
if ($actual -ne $expected) {
    throw "OHOS $BuildMode platform kernel checksum mismatch ($actual). Do not use this cache: it may crash at startup. Prepare a separate SDK with fresh 'flutter precache --ohos' artifacts and select it with -FlutterSdk or XDREMUX_OHOS_FLUTTER_SDK."
}
Write-Host "OHOS $BuildMode platform kernel verified: $actual"
