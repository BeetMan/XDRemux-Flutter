#!/bin/bash
# Run an Android arm64 binary under qemu with the 17U sysroot: qrun.sh <binary> [args...]
E="$(cd "$(dirname "$0")/../emu" && pwd)"
exec qemu-aarch64-static -L "$E/sysroot" -E LD_LIBRARY_PATH=/vendor/lib64:/system/lib64 "$@"
