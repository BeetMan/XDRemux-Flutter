#!/bin/bash
# Build a minimal Android arm64 sysroot for qemu-aarch64-static under emu/sysroot
set -e
E="$(dirname "$0")/../emu"
cd "$E/tmp"
rm -rf rt && mkdir rt
fsck.erofs --extract=rt --no-preserve apex_payload.img >/dev/null
S="$E/sysroot"
mkdir -p "$S/system/bin" "$S/system/lib64" "$S/vendor/lib64" "$S/apex/com.android.runtime"
cp -r rt/* "$S/apex/com.android.runtime/"
cp "$S/apex/com.android.runtime/bin/linker64" "$S/system/bin/linker64"
cp "$S/apex/com.android.runtime/lib64/bionic/"*.so "$S/system/lib64/"
R="$E/../rom"
cp "$R/system/system/lib64/liblog.so" "$S/system/lib64/"
for f in libc++.so libbase.so libcutils.so libutils.so; do [ -f "$R/system/system/lib64/$f" ] && cp "$R/system/system/lib64/$f" "$S/system/lib64/"; done
cp "$R/vendor/lib64/"libQnn*.so "$S/vendor/lib64/"
ls "$S/system/lib64" "$S/system/bin"
cd "$E" && rm -rf tmp
