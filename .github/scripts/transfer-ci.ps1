#requires -Version 7.0
param(
    [string]$RustToolchain = '1.97.1',
    [string]$Python = 'python',
    [string]$ReportRoot,
    [switch]$NoPub
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This gate requires Windows; it exercises the actual DLL.' }
$transferRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $ReportRoot) {
    $ReportRoot = Join-Path $transferRepo "crates/xdremux-transfer-ffi/target/ci/$([guid]::NewGuid().ToString('N'))"
}
$ReportRoot = [IO.Path]::GetFullPath($ReportRoot)
if (Test-Path -LiteralPath $ReportRoot) { throw 'ReportRoot must be a new directory.' }
[IO.Directory]::CreateDirectory($ReportRoot) | Out-Null
$transferSteps = [Collections.Generic.List[object]]::new()
$transferSummary = @{ passed = $false; scope = 'Windows transfer crates, ABI, Dart worker and transfer Flutter tests'; stages = $transferSteps }
$transferOldDll = $env:XDREMUX_TRANSFER_TEST_DLL
$transferOldStorageReport = $env:XDREMUX_TRANSFER_STORAGE_REPORT
function Invoke-TransferStage([string]$Name, [string]$Program, [string[]]$Arguments) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $Program @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $ReportRoot "$Name.log")
    $stageExit = $LASTEXITCODE
    $transferSteps.Add(@{ name = $Name; passed = ($stageExit -eq 0); exitCode = $stageExit; seconds = $watch.Elapsed.TotalSeconds })
    if ($stageExit -ne 0) { throw "Transfer stage $Name failed (exit $stageExit)." }
}
Push-Location $transferRepo
try {
    $transferSummary.commit = (& git rev-parse HEAD).Trim()
    foreach ($crate in @('xdremux-transfer', 'xdremux-transfer-ffi')) {
        $manifest = "crates/$crate/Cargo.toml"
        Invoke-TransferStage "$crate-test" cargo @("+$RustToolchain", 'test', '--manifest-path', $manifest, '--locked', '-j', '2')
        Invoke-TransferStage "$crate-format" cargo @("+$RustToolchain", 'fmt', '--manifest-path', $manifest, '--', '--check')
        Invoke-TransferStage "$crate-clippy" cargo @("+$RustToolchain", 'clippy', '--manifest-path', $manifest, '--all-targets', '--no-deps', '--locked', '--', '-D', 'warnings')
    }
    Invoke-TransferStage 'dll-build' cargo @("+$RustToolchain", 'build', '--manifest-path', 'crates/xdremux-transfer-ffi/Cargo.toml', '--release', '--locked', '-j', '2')
    $transferDll = Join-Path $transferRepo 'crates/xdremux-transfer-ffi/target/release/xdremux_transfer.dll'
    if (-not (Test-Path -LiteralPath $transferDll -PathType Leaf)) { throw 'Built DLL missing.' }
    $env:XDREMUX_TRANSFER_TEST_DLL = $transferDll
    $env:XDREMUX_TRANSFER_STORAGE_REPORT = Join-Path $ReportRoot 'storage.json'
    $transferSummary.librarySha256 = (Get-FileHash -LiteralPath $transferDll -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-TransferStage 'abi-smoke' $Python @('crates/xdremux-transfer-ffi/scripts/smoke.py', $transferDll, '--report', (Join-Path $ReportRoot 'abi.json'))
    $transferCrashRoot = Join-Path $ReportRoot 'private-crash'
    try {
        Invoke-TransferStage 'crash-smoke' $Python @('crates/xdremux-transfer-ffi/scripts/crash_smoke.py', '--library', $transferDll, '--root', $transferCrashRoot)
    } finally {
        $transferCrashResult = Join-Path $transferCrashRoot 'result.json'
        if (Test-Path -LiteralPath $transferCrashResult -PathType Leaf) {
            Copy-Item -LiteralPath $transferCrashResult -Destination (Join-Path $ReportRoot 'crash.json')
        }
    }
    Push-Location apps/flutter
    try {
        if (-not $NoPub) { Invoke-TransferStage 'flutter-pub' flutter @('pub', 'get', '--enforce-lockfile') }
        Invoke-TransferStage 'flutter-analyze' flutter @('analyze', '--no-pub')
        $transferTests = @(Get-ChildItem test -Filter 'transfer_*_test.dart' | Sort-Object Name | ForEach-Object { "test/$($_.Name)" })
        if ($transferTests.Count -eq 0) { throw 'No transfer tests found.' }
        Invoke-TransferStage 'flutter-tests' flutter (@('test', '--no-pub', '--reporter=expanded') + $transferTests)
        if (-not (Test-Path -LiteralPath $env:XDREMUX_TRANSFER_STORAGE_REPORT -PathType Leaf)) {
            throw 'Real storage integration evidence missing; native test may have been skipped.'
        }
        Invoke-TransferStage 'worker-smoke' dart @('run', 'tool/transfer_worker_smoke.dart', $transferDll, (Join-Path $ReportRoot 'worker.json'))
        $transferSummary.testFiles = $transferTests
    } finally { Pop-Location }
    $transferSummary.passed = $true
} finally {
    $env:XDREMUX_TRANSFER_TEST_DLL = $transferOldDll
    $env:XDREMUX_TRANSFER_STORAGE_REPORT = $transferOldStorageReport
    $transferSummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ReportRoot 'summary.json') -Encoding utf8NoBOM
    Pop-Location
}
