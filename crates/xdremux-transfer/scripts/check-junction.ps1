param([Parameter(Mandatory=$true)][string]$Binary)
$ErrorActionPreference='Stop'
$testRoot=Join-Path $PSScriptRoot "../target/runs/junction-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$testRoot=(Resolve-Path -LiteralPath $testRoot).Path
$store=Join-Path $testRoot 'store'
$outside=Join-Path $testRoot 'outside'
New-Item -ItemType Directory -Path $outside | Out-Null
Set-Content -LiteralPath (Join-Path $outside 'sentinel') -Value 'untouched'
# First initialize a real store. No files is intentionally a nonzero harness exit.
& $Binary receive $store '127.0.0.1:0' 1 (Join-Path $testRoot 'initial.json') --accept-test-files > (Join-Path $testRoot 'initial.stdout') 2> (Join-Path $testRoot 'initial.stderr')
$managed=Join-Path $store '.incoming'
if(-not (Test-Path -LiteralPath $managed)){throw 'Store initialization failed'}
Remove-Item -LiteralPath $managed # empty directory owned by this check
New-Item -ItemType Junction -Path $managed -Target $outside | Out-Null
try {
    & $Binary receive $store '127.0.0.1:0' 1 (Join-Path $testRoot 'rejected.json') --accept-test-files > (Join-Path $testRoot 'rejected.stdout') 2> (Join-Path $testRoot 'rejected.stderr')
    if($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath (Join-Path $testRoot 'rejected.stderr') -Raw) -notmatch 'UnsafeStorage'){throw 'Managed junction was not rejected'}
    if((Get-Content -LiteralPath (Join-Path $outside 'sentinel') -Raw).Trim() -ne 'untouched'){throw 'Outside file changed'}
    Write-Output 'Managed Windows junction rejected; outside sentinel unchanged.'
} finally {
    # Remove only this exact junction; never recursively traverse its target.
    Remove-Item -LiteralPath $managed -Force
}
