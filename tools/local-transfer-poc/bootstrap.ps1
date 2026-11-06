param()
$ErrorActionPreference = 'Stop'
$destination = Join-Path $PSScriptRoot '.upstream'
$expected = 'af0416be50770a97760f7070684bc667b759a15c'
if (-not (Test-Path -LiteralPath $destination)) {
    git clone --depth 1 --branch v1.18.2 --no-recurse-submodules https://github.com/localsend/localsend.git $destination
    if ($LASTEXITCODE -ne 0) { throw 'LocalSend source checkout failed' }
}
$actual = git -C $destination rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual.Trim() -ne $expected) { throw 'Unexpected upstream commit' }
$dirty = git -C $destination status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Upstream tracked source has modifications' }
Write-Output "Verified LocalSend v1.18.2 ($expected); no submodules initialized."
