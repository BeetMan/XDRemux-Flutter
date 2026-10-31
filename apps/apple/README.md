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
HDR decode. Live Photo saving was verified on the simulator (Photos shows the LIVE badge).

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
go through `String(localized:)`. Test with `-AppleLanguages "(en)"`.

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
(`io.github.beetman.xdremux`) so both install side by side. Release artefacts and signing are
not set up yet (plan §5).
