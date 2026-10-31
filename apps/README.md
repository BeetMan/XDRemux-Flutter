# Apps

Graphical or platform-specific application shells live here. All of them call the shared Rust core in `xdremux/rust`.

- `flutter/` — the released cross-platform app (Windows, macOS, Linux, Android, iOS, HarmonyOS). See `docs/app/flutter-app.md`.
- `apple/` — the native SwiftUI app for iOS / macOS (in development, not released), plus the macOS command-line tool `xdremux` in `apple/Packages/XDRemuxKit/Sources/xdremux-cli`. See `apple/README.md`.

The HarmonyOS ArkUI native app lives on the long-lived `feat/harmony-native` branch, not here.

App projects should depend on or mirror converter behavior deliberately instead of reimplementing conversion logic.
