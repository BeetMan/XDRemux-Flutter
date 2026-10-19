param(
    [ValidateSet('windows', 'android')][string]$Platform = 'windows',
    [string]$NdkDirectory = "$env:LOCALAPPDATA/Android/sdk/ndk/28.2.13676358"
)
$ErrorActionPreference = 'Stop'
$transferRepository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$transferManifest = Join-Path $transferRepository 'crates/xdremux-transfer-ffi/Cargo.toml'
$transferTarget = Join-Path $transferRepository 'crates/xdremux-transfer-ffi/target'
if ($Platform -eq 'android') {
    $transferBin = Join-Path $NdkDirectory 'toolchains/llvm/prebuilt/windows-x86_64/bin'
    $env:CC_aarch64_linux_android = Join-Path $transferBin 'aarch64-linux-android24-clang.cmd'
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $env:CC_aarch64_linux_android
    $env:AR_aarch64_linux_android = Join-Path $transferBin 'llvm-ar.exe'
    cargo +1.97.1 build --manifest-path $transferManifest --target-dir $transferTarget --locked --release --target aarch64-linux-android -j 2
} else {
    cargo +1.97.1 build --manifest-path $transferManifest --target-dir $transferTarget --locked --release -j 2
}
if ($LASTEXITCODE -ne 0) { throw 'Transfer library build failed' }
