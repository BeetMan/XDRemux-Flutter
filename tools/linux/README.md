# Linux packaging (AppImage / tar.gz)

Publishable Linux artifacts are produced from an existing Flutter release bundle.
Nothing here publishes or uploads anything.

The main development version is 0.4.6 (not yet released). The 0.4.4 names below
describe the existing preview assets; use the checked-out pubspec version when
building new candidates. The Linux workflow runs on matching pull requests and
manual dispatch, with read-only build permissions. The release workflow also
calls it and gates publication on the Linux artifacts. Direct manual attachment
is a separate job, restricted to the Linux workflow and an existing matching
release; it cannot run when called by the Release workflow.

## Build the bundle first

```bash
cd apps/flutter
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter build linux --release
# -> apps/flutter/build/linux/x64/release/bundle
```

The bundle is dependency-converged by `apps/flutter/linux/CMakeLists.txt`: the
`tray_manager` and `jni` plugins are filtered out of the generated plugin list, so
the app does not require `libayatana-appindicator3` and does not ship
`libdartjni.so` (which needs `libjvm.so`).

## Package

```bash
tools/linux/package_linux.sh 0.4.4 --output build/linux-packages
```

Output (asset naming matches the GitHub release assets):

```
XDRemux-Linux-0.4.4-x64.AppImage
XDRemux-Linux-0.4.4-x64.tar.gz
XDRemux-Linux-0.4.4-x64.sha256
```

`--bundle DIR` packages a bundle from another location (for example a CI artifact
directory); it defaults to `apps/flutter/build/linux/x64/release/bundle`.

### Requirements

- `curl` or `wget` (first run downloads `appimagetool` into
  `${XDG_CACHE_HOME:-$HOME/.cache}/xdremux-linux-packaging`)
- `ar` and a `tar` that can read zstd-compressed `.deb` data archives (GNU tar
  with zstd, or `bsdtar`) — only needed when the host's `libnuma.so.1` targets a
  newer glibc than the release baseline
- no root, no FUSE requirement for building (appimagetool is retried with
  `APPIMAGE_EXTRACT_AND_RUN=1` / an extracted copy if FUSE is unavailable)

### libnuma and the glibc baseline

The Rust core NEEDs `libnuma.so.1`, which stock Ubuntu 22.04 desktop does not
ship. The core is `dlopen()`ed by Dart, so the executable's RUNPATH does not cover
this transitive dependency; the packaged `AppRun`, `run.sh` and installed
launcher export `LD_LIBRARY_PATH` to the bundle `lib/` directory, where the
packager places `libnuma.so.1`.

The release glibc baseline is **2.35** (Ubuntu 22.04). A host `libnuma` built
against a newer glibc (e.g. Arch's `libnuma.so.1` needs `GLIBC_2.38`) would break
on the target, so the packager resolves a compatible copy in this order:

1. `XDREMUX_LIBNUMA=/path/to/libnuma.so.1` (explicit override)
2. cached Ubuntu 22.04 build (`libnuma-ubuntu22.04.so.1` in the cache dir)
3. the host's `libnuma.so.1`, if it only needs glibc <= 2.35
4. download `libnuma1` from the Ubuntu 22.04 archive and cache the extracted
   library

Archive downloads use HTTPS and a pinned SHA256. The extracted Ubuntu library
also has a pinned SHA256, including when reusing an existing cache. Old,
unverified cached files are not trusted. `XDREMUX_LIBNUMA` remains an explicit
trusted override. Regression tests (Bash/sha256sum and GLib required):

```bash
python3 -m unittest discover -s tools/linux -p 'test_*.py' -v
```

libnuma is LGPL-2.1-or-later (numactl); the notice is included in the packaged
`README.txt`.

## Desktop integration files

- `xdremux.desktop` — shared by the tar.gz and the AppImage root
- `xdremux.png` — 512x512 icon (same asset as `apps/flutter/linux/runner/resources/app_icon.png`)
- `install.sh` — user-level installer shipped inside the tar.gz
  (`~/.local/bin` launcher + `~/.local/share/xdremux` + desktop entry + icon)

## Verify an artifact

```bash
cd build/linux-packages
sha256sum -c XDRemux-Linux-0.4.4-x64.sha256

# tar.gz
mkdir -p /tmp/xdremux-tar && tar -xzf XDRemux-Linux-0.4.4-x64.tar.gz -C /tmp/xdremux-tar
/tmp/xdremux-tar/XDRemux-Linux-0.4.4-x64/run.sh

# AppImage (extract instead of mounting if FUSE is unavailable)
./XDRemux-Linux-0.4.4-x64.AppImage --appimage-extract
./squashfs-root/AppRun
```
