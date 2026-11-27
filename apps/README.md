# Apps

Graphical or platform-specific application shells live here. All of them call the shared Rust core in `xdremux/rust`.

- `flutter/` — the released cross-platform app (Windows, macOS, Linux, Android, iOS, HarmonyOS). See `docs/app/flutter-app.md`.
- `apple/` — the native SwiftUI app for iOS / macOS (pre-release 0.1.1 on GitHub and TestFlight), plus the macOS command-line tool `xdremux` in `apple/Packages/XDRemuxKit/Sources/xdremux-cli`. See `apple/README.md`.
- `harmony/` — the native ArkUI app for HarmonyOS, released under its own `harmony-v*` tags (0.5.4) and built from the same core. See `harmony/README.md`, `harmony/BUILDING.md` and `docs/plans/harmony-native.md`.

App projects should depend on or mirror converter behavior deliberately instead of reimplementing conversion logic.
