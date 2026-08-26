#!/bin/bash
# Build the Rust core + x265 static libraries for OpenHarmony (aarch64).
#
# Outputs:
#   - target/aarch64-unknown-linux-ohos/release/libxdremux_core.so (cdylib,
#     for Flutter OHOS FFI via DynamicLibrary.open)
#   - vendor/x265/build_ohos/libx265.a (x265 static, built if missing)
#
# Prereqs:
#   - DevEco Studio installed with the OpenHarmony native SDK
#     (default: "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
#   - rustup target add aarch64-unknown-linux-ohos
#
# Env override: OHOS_NATIVE=/path/to/openharmony/native
# NOTE: the default DevEco path contains spaces ("Program Files", "DevEco
# Studio") and cc-rs splits CFLAGS on whitespace, so we default to the 8.3
# short path. If your short-path differs, set OHOS_NATIVE to a space-free path.
set -euo pipefail
cd "$(dirname "$0")"   # -> xdremux/rust

NATIVE="${OHOS_NATIVE:-C:/PROGRA~1/Huawei/DEVECO~1/sdk/default/OPENHA~1/native}"
TARGET=aarch64-unknown-linux-ohos
TARGET_UNDERSCORE=${TARGET//-/_}
TARGET_UPPER=${TARGET_UNDERSCORE^^}
LLVM_TARGET=aarch64-linux-ohos
SYSROOT="$NATIVE/sysroot"
CLANGXX="$NATIVE/llvm/bin/clang++.exe"

echo "==> x265 (OHOS arm64-v8a, no assembly)"
if [ ! -f vendor/x265/build_ohos/libx265.a ]; then
  cmake -S vendor/x265/source -B vendor/x265/build_ohos \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NATIVE/build-tools/cmake/bin/ninja.exe" \
    -DCMAKE_TOOLCHAIN_FILE="$NATIVE/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=arm64-v8a \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
    -DCMAKE_BUILD_TYPE=Release
fi
cmake --build vendor/x265/build_ohos --target x265-static -j

echo "==> Rust cdylib ($TARGET)"
# cc-rs picks up the target-scoped C/C++ compilers. C mode (clang.exe) is
# intentional: the C++ driver defines _GNU_SOURCE on Linux targets, which
# selects zstd's glibc qsort_r branch, and OHOS musl has no qsort_r. C mode
# keeps zstd on its portable fallback and matches how the Android NDK build
# compiles x265_helper.c.
export CC_${TARGET_UNDERSCORE}="$NATIVE/llvm/bin/clang.exe"
export CXX_${TARGET_UNDERSCORE}="$CLANGXX"
export AR_${TARGET_UNDERSCORE}="$NATIVE/llvm/bin/llvm-ar.exe"
export CFLAGS_${TARGET_UNDERSCORE}="-target $LLVM_TARGET --sysroot=$SYSROOT -D__MUSL__"
export CXXFLAGS_${TARGET_UNDERSCORE}="-target $LLVM_TARGET --sysroot=$SYSROOT -D__MUSL__"
# Cargo validates CARGO_TARGET_* names strictly: uppercase + underscores only.
export CARGO_TARGET_${TARGET_UPPER}_LINKER="$CLANGXX"
export CARGO_TARGET_${TARGET_UPPER}_RUSTFLAGS="-C link-args=--target=$LLVM_TARGET -C link-args=--sysroot=$SYSROOT"

cargo build --target "$TARGET" --release

echo "==> done: target/$TARGET/release/libxdremux_core.so"
