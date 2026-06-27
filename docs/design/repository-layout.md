# Repository Layout

XDRemux is both a converter and a research/debugging workspace. The repository should make the production path obvious while preserving auditability for experiments.

## Current top-level model

```text
xdremux/                 converter entry points
apps/                    graphical or platform-specific app shells
docs/                    durable maintainer documentation
scripts/                 reusable local automation
tests/                   repository-level converter validation
fixtures/                small fixtures and external sample manifests
experiments/             dated research branches and ablation attempts
skills/                  agent skills and rule references
```

## Boundaries

`xdremux/` contains converter entry points. The Swift CLI and Python CLI live here because they are direct conversion tools.

`apps/` contains graphical shells. A macOS SwiftUI app should not live beside the Swift CLI because it has separate concerns: Xcode project state, assets, app lifecycle, drag/drop UI, preview UI, and app-specific tests.

`tests/` is for converter-level validation that should survive app layout changes. App-specific tests may remain under the app project.

`fixtures/` is for fixture policy, small synthetic fixtures, and manifests for external sample sets. Large real images and private dumps should not be committed to git.

`experiments/` is for historical and auditable work. Code there is not a supported entry point until it has been promoted through the main converter path.

## Next structural step

The next high-value refactor is a shared core boundary.

A future Swift layout can evolve toward:

```text
xdremux/core/swift/Sources/XDRemuxCore/
xdremux/swift-cli/
apps/macos/XDRemuxApp/
```

The CLI should handle argument parsing and command-line UX. The macOS app should handle UI, queueing, drag/drop, preview, and settings. The shared core should own HEIF/ISOBMFF parsing, gain-map reconstruction, ISO metadata writing, OPPO compatibility behavior, and output verification.

Do not extract this core by only moving files. It should be done with validation against representative LHDR, UHDR, OPPO-compatible, and clean ImageIO-native outputs.
