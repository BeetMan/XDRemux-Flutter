[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$CorePath,
    [string]$SdkRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

if ([string]::IsNullOrWhiteSpace($CorePath)) {
    $CorePath = Join-Path $RepoRoot 'target\aarch64-unknown-linux-ohos\release\libxdremux_core.so'
} elseif (-not [IO.Path]::IsPathRooted($CorePath)) {
    $CorePath = Join-Path $RepoRoot $CorePath
}
$CorePath = (Resolve-Path $CorePath).Path

if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $SdkRoot = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony'
}
$SdkRoot = (Resolve-Path $SdkRoot).Path

$entryLibDir = Join-Path $RepoRoot 'apps\harmony\entry\libs\arm64-v8a'
$stagedCore = Join-Path $entryLibDir 'libxdremux_core.so'
$stagedCxx = Join-Path $entryLibDir 'libc++_shared.so'
$sdkCxx = Join-Path $SdkRoot 'native\llvm\lib\aarch64-linux-ohos\libc++_shared.so'

if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
    throw "Rust OHOS core was not found: $CorePath. Build it with xdremux/rust/build_ohos.sh first."
}
if (-not (Test-Path -LiteralPath $sdkCxx -PathType Leaf)) {
    throw "DevEco libc++_shared.so was not found: $sdkCxx"
}

New-Item -ItemType Directory -Force -Path $entryLibDir | Out-Null
Copy-Item -LiteralPath $CorePath -Destination $stagedCore -Force
Copy-Item -LiteralPath $sdkCxx -Destination $stagedCxx -Force

$coreHash = (Get-FileHash -LiteralPath $stagedCore -Algorithm SHA256).Hash
$cxxHash = (Get-FileHash -LiteralPath $stagedCxx -Algorithm SHA256).Hash
$coreInfo = Get-Item -LiteralPath $stagedCore
$cxxInfo = Get-Item -LiteralPath $stagedCxx

[ordered]@{
    repoRoot = $RepoRoot
    coreSource = $CorePath
    coreDestination = $stagedCore
    coreBytes = $coreInfo.Length
    coreSha256 = $coreHash
    libcxxSource = $sdkCxx
    libcxxDestination = $stagedCxx
    libcxxBytes = $cxxInfo.Length
    libcxxSha256 = $cxxHash
} | ConvertTo-Json -Compress
