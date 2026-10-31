# XDRemux Converter Core

- `rust/` is the conversion engine (`xdremux-core`): container surgery, HEVC/x265 encoding, ISO 21496-1 gain maps, Photographic Styles, portrait, Motion Photo / Live Photo. It exposes a C ABI (`rust/src/lib.rs`, header `rust/include/xdremux_core.h`) used by every front end.
- Build scripts: `rust/build_ios.sh`, `rust/build_ios_sim.sh`, `rust/build_apple.sh` (XCFramework for `apps/apple`) and `rust/build_ohos.sh`. Desktop and Android builds go through cargo; see `docs/operations/building.md`.

The earlier `swift-cli/` and `python/` entry points no longer exist. The macOS command-line tool is now `apps/apple/Packages/XDRemuxKit/Sources/xdremux-cli`, and the module map is in `docs/architecture/overview.md`.

Graphical app shells are intentionally kept outside this directory under `apps/`.
