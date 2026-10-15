# Windows developer build. No system install, source media, signing, or release writes.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [string]$Generator = 'Visual Studio 17 2022',
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$codecRoot = [IO.Path]::GetFullPath($BuildRoot)
if (Test-Path -LiteralPath $codecRoot) { throw 'BuildRoot must be a NEW directory; nothing is overwritten.' }
New-Item -ItemType Directory -Path $codecRoot | Out-Null
$codecPrefix = Join-Path $codecRoot 'prefix'
function Invoke-CodecCommand([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
foreach ($codecDependency in @(
    @{ Name = 'libde265'; Tag = 'v1.1.3'; Commit = 'ba62bf4cfb3242f3bf0a45617ff09e35236e4d82' },
    @{ Name = 'libheif'; Tag = 'v1.23.4'; Commit = '4e14f5942c1732ace9611b9522cc991501445463' }
)) {
    $codecSource = Join-Path $codecRoot $codecDependency.Name
    Invoke-CodecCommand 'git' @('clone', '--depth', '1', '--branch', $codecDependency.Tag,
        "https://github.com/strukturag/$($codecDependency.Name).git", $codecSource)
    $codecCommit = (& git -C $codecSource rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $codecCommit -ne $codecDependency.Commit) { throw 'Dependency commit does not match pinned source.' }
    $codecBuild = Join-Path $codecRoot "$($codecDependency.Name)-build"
    $codecArguments = @('-S', $codecSource, '-B', $codecBuild, '-G', $Generator, '-A', $Architecture,
        '-DBUILD_SHARED_LIBS=ON', "-DCMAKE_INSTALL_PREFIX=$codecPrefix", '-DCMAKE_CXX_FLAGS=/utf-8')
    if ($codecDependency.Name -eq 'libde265') {
        $codecArguments += @('-DENABLE_SDL=OFF', '-DENABLE_DECODER=OFF', '-DENABLE_ENCODER=OFF')
    } else {
        $codecArguments += @("-DCMAKE_PREFIX_PATH=$codecPrefix", '-DENABLE_PLUGIN_LOADING=OFF',
            '-DWITH_LIBDE265=ON', '-DWITH_LIBDE265_PLUGIN=OFF', '-DWITH_X265=OFF', '-DWITH_X264=OFF',
            '-DWITH_OpenH264_DECODER=OFF', '-DWITH_AOM_DECODER=OFF', '-DWITH_AOM_ENCODER=OFF',
            '-DWITH_LIBSHARPYUV=OFF', '-DWITH_EXAMPLES=OFF', '-DWITH_GDK_PIXBUF=OFF',
            '-DBUILD_TESTING=OFF', '-DBUILD_DOCUMENTATION=OFF')
    }
    Invoke-CodecCommand 'cmake' $codecArguments
    Invoke-CodecCommand 'cmake' @('--build', $codecBuild, '--config', 'Release', '--parallel', '4')
    Invoke-CodecCommand 'cmake' @('--install', $codecBuild, '--config', 'Release')
    $codecLicenseDir = Join-Path $codecPrefix "licenses/$($codecDependency.Name)"
    New-Item -ItemType Directory -Path $codecLicenseDir -Force | Out-Null
    Get-ChildItem -LiteralPath $codecSource -File -Filter 'COPYING*' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $codecLicenseDir
    }
}
Write-Output "Native prefix ready: $codecPrefix"
Write-Output 'Enable libheif-decoder and set XDREMUX_LIBHEIF_PREFIX for this target; see README.md.'
