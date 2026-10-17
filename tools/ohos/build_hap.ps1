# Build the OHOS hap with the OHOS-specific pubspec variant.
#
# The OHOS fork's plugin set is vendored under third_party/ohos (see
# fetch_plugins.sh) and referenced by pubspec.ohos.yaml via path deps.
# This script swaps that variant in for the duration of the build, then
# always restores the mainline pubspec.yaml + pubspec.lock.
#
# Usage (PowerShell): tools/ohos/build_hap.ps1 -Profile -FlutterSdk C:\path\to\flutter-ohos
param(
    [switch]$Profile,
    [switch]$Release,
    [string]$FlutterSdk = $(if ($env:XDREMUX_OHOS_FLUTTER_SDK) {
        $env:XDREMUX_OHOS_FLUTTER_SDK
    } else { 'C:\flutter-ohos' })
)

$ErrorActionPreference = 'Stop'
if ($Profile -and $Release) { throw 'Choose either -Profile or -Release, not both.' }
$FlutterSdk = (Resolve-Path -LiteralPath $FlutterSdk).Path
$flutterBin = Join-Path $FlutterSdk 'bin\flutter.bat'
$buildMode = if ($Profile) { 'profile' } elseif ($Release) { 'release' } else { 'debug' }
& (Join-Path $PSScriptRoot 'check_sdk.ps1') -SdkPath $FlutterSdk -BuildMode $buildMode
$app = Join-Path $PSScriptRoot '..\..\apps\flutter'
Set-Location $app

$env:PATH = (Join-Path $FlutterSdk 'bin') + ';C:\tools\ohos-shim;' +
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;' +
  'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:PATH
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'

Copy-Item pubspec.yaml pubspec.yaml.mainline.bak -Force
if (Test-Path pubspec.lock) { Copy-Item pubspec.lock pubspec.lock.mainline.bak -Force }
$registrantPath = Join-Path $app 'macos\Flutter\GeneratedPluginRegistrant.swift'
$registrantBytes = if (Test-Path $registrantPath) {
    [System.IO.File]::ReadAllBytes($registrantPath)
} else { $null }
try {
    Copy-Item pubspec.ohos.yaml pubspec.yaml -Force
    # Keep the app version in sync with the mainline pubspec so OHOS builds
    # never lag behind a version bump.
    $mainlineVersion = (Select-String -Path pubspec.yaml.mainline.bak -Pattern '^version:').Line
    (Get-Content pubspec.yaml) -replace '^version:.*', $mainlineVersion | Set-Content pubspec.yaml
    & $flutterBin pub get
    if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
    # Profile mode = AOT compiled but flagged debug:true, so sideload tools
    # signing with a Development profile accept it. Plain debug mode is JIT
    # (~4x larger, slower); release mode packages can only be signed with a
    # distribution certificate and cannot be sideloaded with debug profiles.
    if ($Profile) { & $flutterBin build hap --profile }
    elseif ($Release) { & $flutterBin build hap --release }
    else { & $flutterBin build hap --debug }
    if ($LASTEXITCODE -ne 0) { throw 'build hap failed' }
} finally {
    Move-Item pubspec.yaml.mainline.bak pubspec.yaml -Force
    if (Test-Path pubspec.lock.mainline.bak) {
        Move-Item pubspec.lock.mainline.bak pubspec.lock -Force
    }
    # Preserve the caller's generated registrant, including local edits. Do
    # not reset it to HEAD: building OHOS must not discard unrelated work.
    if ($null -ne $registrantBytes) {
        [System.IO.File]::WriteAllBytes($registrantPath, $registrantBytes)
    }
}
