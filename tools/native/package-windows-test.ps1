param(
    [string]$Name = 'XDRemux-Windows-x64-0.4.3-libheif-test-20261005-02'
)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ($Name -notmatch '^XDRemux-Windows-x64-[A-Za-z0-9.-]+$') { throw 'Invalid package name' }
$taskRelease = Join-Path $taskRoot 'apps/flutter/build/windows/x64/runner/Release'
$taskBundle = Join-Path $taskRoot "dist/$Name"
$taskZip = "$taskBundle.zip"
if ((Test-Path -LiteralPath $taskBundle) -or (Test-Path -LiteralPath $taskZip)) { throw 'Choose a new package name; existing artifacts are preserved' }
foreach ($file in @('xdremux.exe', 'xdremux_core.dll', 'heif.dll', 'libde265.dll', 'vcruntime140.dll', 'data/app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $taskRelease $file))) { throw "Missing release file: $file" }
}
$null = New-Item -ItemType Directory -Path $taskBundle
Copy-Item -LiteralPath (Join-Path $taskRelease 'xdremux.exe') -Destination $taskBundle
Get-ChildItem -LiteralPath $taskRelease -File -Filter '*.dll' | Where-Object Name -ne 'jni.dll' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $taskBundle
}
Copy-Item -LiteralPath (Join-Path $taskRelease 'data') -Destination $taskBundle -Recurse
Copy-Item -LiteralPath (Join-Path $taskRoot 'LICENSE') -Destination $taskBundle
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-test-README.md') -Destination (Join-Path $taskBundle 'TEST-BUILD-README.md')
Copy-Item -LiteralPath (Join-Path $taskRoot 'docs/testing/windows-codec-test-02.md') -Destination (Join-Path $taskBundle 'TEST-CHECKLIST.md')
$taskSourceInfo = Join-Path $taskBundle 'source-info'
$null = New-Item -ItemType Directory -Path $taskSourceInfo
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build-libheif.ps1') -Destination $taskSourceInfo
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $taskSourceInfo
$taskSourcePaths = @(
    'xdremux/rust/src/lib.rs', 'xdremux/rust/src/preview.rs', 'xdremux/rust/src/codec_capabilities.rs',
    'xdremux/rust/src/apple_note_payload.rs', 'xdremux/rust/src/styles_scaffold.rs',
    'xdremux/rust/src/libheif_helper.cpp', 'apps/flutter/lib/main.dart',
    'apps/flutter/lib/ffi/xdremux_ffi.dart', 'apps/flutter/lib/services/xdremux_service.dart',
    'apps/flutter/lib/services/codec_diagnostics.dart', 'apps/flutter/lib/widgets/codec_diagnostics_tile.dart',
    'apps/flutter/pubspec.yaml', 'apps/flutter/pubspec.lock', 'apps/flutter/windows/CMakeLists.txt'
)
$taskSourceHashes = @($taskSourcePaths | ForEach-Object {
    [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $taskRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$taskFiles = @(Get-ChildItem -LiteralPath $taskBundle -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = [IO.Path]::GetRelativePath($taskBundle, $_.FullName).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$taskManifest = [ordered]@{
    package = $Name; appVersion = '0.4.3+37'; coreVersion = '0.4.3'
    branch = (& git -C $taskRoot branch --show-current)
    baseCommit = (& git -C $taskRoot rev-parse HEAD)
    sourceWorktreeDirty = $true; officialRelease = $false
    rustFeature = 'libheif-decoder'; libheif = '1.23.4'; libde265 = '1.1.3'
    builtUtc = [DateTime]::UtcNow.ToString('o')
    sourceFiles = $taskSourceHashes; files = $taskFiles
    note = 'Selected source hashes plus all packaged files; manifest excludes itself. No photos/reports/private signing configuration bundled.'
}
$taskManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskBundle 'BUILD-MANIFEST.json') -Encoding utf8
Compress-Archive -LiteralPath $taskBundle -DestinationPath $taskZip -CompressionLevel Optimal
[ordered]@{ path = $taskZip; bytes = (Get-Item -LiteralPath $taskZip).Length; sha256 = (Get-FileHash -LiteralPath $taskZip -Algorithm SHA256).Hash.ToLowerInvariant(); manifestFiles = $taskFiles.Count } | ConvertTo-Json
