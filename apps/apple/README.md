# XDRemux for iOS / macOS (native SwiftUI)

Native Apple front-end on the shared Rust core. Plan, stages and acceptance:
[`docs/plans/apple-native.md`](../../docs/plans/apple-native.md). Status: **P1** — a working
basic version: import (files, drag-drop, Photos picker on iOS), detail-first inspection, single
or batch conversion with progress, verified publish, HDR preview, export (Photos / share /
save panel / Finder), persistent settings with restart restore, Motion Photo → Live Photo pairs, the
OPPO ↔ Apple round-trip workflow, plus a macOS command-line tool.

```text
apps/apple/
  project.yml                 xcodegen spec → XDRemux.xcodeproj (ignored)
  App/                        multiplatform SwiftUI target (iOS 17 / macOS 14)
    Model/                    LibraryModel (items, settings, pipeline), PhotoItem
    Views/                    ContentView (split view / stack), PhotoDetailView, SettingsView
    Platform/                 Photos picker (iOS), export (Photos / save panel / Finder)
  Packages/XDRemuxKit/
    Sources/XDRemuxKit/       Swift wrapper over the C ABI (background queue, RAII free, Codable reports, ImageIO)
    Sources/XDRemuxModel/     pure Swift model: ConversionConfig, ConversionJob, OutputPlanner, SettingsStore
    Sources/xdremux-cli/      `xdremux` command-line tool (macOS)
    Tests/                    `swift test` — no simulator, no private photos
  Frameworks/                 XDRemuxCore.xcframework (built, ignored)
```

## iOS simulator

```bash
cd xdremux/rust && XDREMUX_APPLE_SLICES="macos ios-sim" ./build_apple.sh
cd apps/apple && xcodegen generate
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/XDRemux.app
# stage samples inside the app container, then launch with the same flags as macOS
C=$(xcrun simctl get_app_container booted io.github.beetman.xdremux.swiftui data)
xcrun simctl launch booted io.github.beetman.xdremux.swiftui --import "$C/Documents/samples/a.heic" --convert-all
```

`build_apple.sh` builds arm64 + x86_64 for the macOS and simulator slices (`XDREMUX_APPLE_ARCHS=arm64` to
skip Intel); device iOS stays arm64. The simulator has no EDR headroom, so previews are shown SDR there; a device with an HDR panel gets the
HDR decode. Live Photo saving was verified on the simulator (Photos shows the LIVE badge). Settings → 照片 →
转换完成后自动存入照片 saves every finished photo to the library when a batch (or a single conversion) ends; photos
already saved are skipped.

## Share Extension (iOS)

`XDRemuxShare` adds XDRemux to the share sheet. It copies the shared photos (HEIC original representation
first, so Photos does not transcode to JPEG) into the app-group inbox
`group.io.github.beetman.xdremux.swiftui/Inbox`; the app imports and clears the inbox on launch and
whenever it returns to the foreground. No conversion runs inside the extension.

## Command line (macOS)

```bash
cd apps/apple/Packages/XDRemuxKit && swift build -c release --product xdremux
.build/release/xdremux convert ~/Pictures/oppo/*.heic -o ~/Pictures/converted          # OPPO 兼容 (default)
.build/release/xdremux convert photo.heic -m apple --styles3 --json                     # Apple 标准 + Photographic Styles 3 (post-process + styles verify)
.build/release/xdremux inspect ~/Pictures/oppo                                          # convertible? family / hdr kind
.build/release/xdremux plan ~/Pictures/oppo -m apple --styles3                          # core's plan: classification, policy, output name
.build/release/xdremux details photo.heic                                               # EXIF / HDR summary
.build/release/xdremux verify out/*.heic                                                # decode + structure check
.build/release/xdremux capabilities                                                     # encoder paths in this core
.build/release/xdremux edit-copy oppo.heic                                              # round trip step 2 → oppo.apple-edit.heic
.build/release/xdremux writeback returned.heic --donor oppo.heic -m oppo                # round trip step 4 → returned.oppo-final.heic
```

Ctrl-C cancels the running conversion in the core (`xdremux_progress_cancel`), discards the partial
file and exits 130. `convert` writes each output to a temporary path, verifies it, then publishes `<stem><suffix>.heic`
(`--suffix`, `--no-overwrite` appends ` (2)`, `--categorize` adds a mode folder). Exit status 1 if any
input failed; `--json` prints one object per input. The CLI and the app share `ConversionJob`, so
results are identical for the same options. x265's own log lines are silenced unless `-v`.

The app also accepts `XDRemux --import <files…> [--convert-all] [--round-trip]` at launch for scripting;
the files must be readable from inside the app sandbox (e.g. its container's `Documents`). Finder
"Open With", Dock drops and iOS "Open in XDRemux" import through the same path.

## Localization

Source language is Simplified Chinese; `App/Localizable.xcstrings` carries the English translations
(terminology matches the Flutter app: Apple Standard / OPPO Compatible). Strings outside SwiftUI views
go through `L(_:)` (see Language below), never `String(localized:)` directly, so the in-app language
setting applies to them too. Test with `-AppleLanguages "(en)"` or the Settings picker.

## Build

```bash
# 1. Rust core + x265 → XCFramework (macOS arm64, iOS arm64, iOS simulator arm64)
xdremux/rust/build_apple.sh            # XDREMUX_APPLE_SLICES="macos" for a quick macOS-only build

# 2. Packages
cd apps/apple/Packages/XDRemuxKit && swift test

# 3. App
cd apps/apple && xcodegen generate
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -destination 'platform=macOS,arch=arm64' build
xcodebuild -project XDRemux.xcodeproj -scheme XDRemux -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Prerequisites: Xcode 16+, `rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim`,
`brew install xcodegen`, `cargo install cbindgen` (only to regenerate the header). builds on Apple Silicon; the macOS and simulator slices are arm64 + x86_64 (Intel Macs run the same app)
(no x86_64 Rust / x265 builds). The iOS simulator build needs an iOS runtime installed in Xcode.

`XDREMUX_SAMPLE_DIR=/path/to/proxdr-heics swift test` additionally converts one real sample
through the Swift wrapper and verifies the output; it is skipped otherwise.

## C ABI

`xdremux/rust/include/xdremux_core.h` is generated by cbindgen from `src/lib.rs`
(`cbindgen.toml` next to it) and committed; `tools/apple/check_header.sh` fails when it is stale.
Swift imports it as `XDRemuxCoreC` through `include/module.modulemap`, packaged into the XCFramework.
Ownership and error rules are in `docs/architecture/ffi-contract.md`; `XDRemuxKit` enforces them
(`RustString`, `Classification(consuming:)`, `ConversionReport(consuming:)`).

The core staticlib does not carry link flags: anything linking `XDRemuxCore` must also link `libc++`
(`XDRemuxKit`'s `linkerSettings` and the app's `OTHER_LDFLAGS` do).

## Identity

Bundle ID `io.github.beetman.xdremux.swiftui`, distinct from the Flutter app
(`io.github.beetman.xdremux`) so both install side by side. Signing and notarization are not set
up (plan §5): releases are ad-hoc signed (macOS) and unsigned (iOS).

## Release

Like the HarmonyOS native app, releases are built on a developer Mac and uploaded by hand under
their own tag (`apple-v<version>`, never `v*`, so the Flutter release workflow and the Latest
release are untouched):

```bash
tools/apple/package_release.sh      # XDREMUX_SKIP_CORE=1 / XDREMUX_SKIP_TRANSFER=1 to reuse the built cores
```

It rebuilds both xcframeworks from the checked-out sources (and refuses a core whose
`BUILD_RECORD.txt` predates a change to `xdremux/rust` or the transfer crates), builds the macOS
Release app (ad-hoc) and an unsigned iOS archive, checks version / bundle id / embedded core /
transfer framework / Share Extension, then writes `apps/apple/build/release/<version>/`:
`XDRemux-Apple-macOS-<version>.dmg`, `XDRemux-Apple-iOS-<version>-unsigned.ipa`, `BUILD_RECORD.txt`
and `SHA256SUMS.txt`. The version comes from `CFBundleShortVersionString` in `project.yml`; bump it
(and `CFBundleVersion`, in both targets) before packaging. Release notes live in
`tools/installer/RELEASE_NOTES_apple-v<version>.md`; publish with
`gh release create apple-v<version> --prerelease --latest=false -F <notes> <dmg> <ipa> SHA256SUMS.txt`.

## Language

Settings → 语言 / Language switches the UI between the device language, Simplified Chinese and English without a
restart. `Text` keys follow the `locale` environment set at the root of `ContentView`; strings built in model code go
through `L(_:)` (`App/Platform/L10n.swift`). To pull new keys into `App/Localizable.xcstrings`, run
`xcodebuild -exportLocalizations -project XDRemux.xcodeproj -localizationPath out -exportLanguage en -sdk iphonesimulator ARCHS=arm64`
and translate the untranslated units; a plain `xcodebuild build` does not update the catalog.

## Local network transfer

`⋯ → 局域网传输` sends photos to, and receives them from, another XDRemux or LocalSend device (LocalSend v2 over mTLS).
The core is `crates/xdremux-transfer-ffi`, packaged as a dynamic framework by
`tools/apple/build_transfer_xcframework.sh` (Rust 1.97.1; `XDREMUX_TRANSFER_SLICES="macos ios-sim"` for a dev box without
device signing). The Swift side is the `XDRemuxTransfer` package target; `swift test --filter XDRemuxTransferTests` runs a
loopback round trip, and `XDREMUX_TRANSFER_PEER=ip:port XDREMUX_TRANSFER_FILE=/path swift test --filter ExternalPeer`
sends one file (or several, `:`-separated) to a device that is receiving; `XDREMUX_TRANSFER_RECEIVE=ip:port swift test
--filter ExternalReceiver` is the other direction, a Mac that accepts every offer and copies the files into
`XDREMUX_TRANSFER_OUT`. Multicast discovery needs Apple's multicast
entitlement on a real iPhone; without it the page scans the /24 subnet on the LocalSend ports (automatically after a few
quiet seconds, or from the "扫描网段" button) and still takes a typed `IP:port`. The device name other peers see is
editable on the receive section; received photos can be saved to Photos (a still with a same-named `.mov`, or a `.pvt.zip` bundle as the Flutter app
sends it, becomes one Live Photo) or queued, singly or all at once. Besides the conversion list, the send section takes
files picked with "选择照片" (the system photo picker, photos and videos; a Live Photo is sent as its still + `.mov` under
the original name) or "选择文件".
