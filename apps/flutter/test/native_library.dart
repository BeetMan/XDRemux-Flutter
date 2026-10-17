import 'dart:io';

/// Locates the compiled Rust core for host (desktop) tests.
///
/// `flutter test` runs with the current directory set to `apps/flutter`, and
/// dlopen/dlfcn only searches the current directory plus the loader defaults.
/// CI copies a freshly built library next to the Flutter project, while a local
/// macOS/Windows build leaves it in the Cargo target directory, which is *not*
/// on the default search path. Probe both layouts so the FFI smoke tests really
/// load the packaged core on every host instead of failing (or silently
/// skipping) on Apple platforms.
String nativeCoreLibraryPath() {
  final name = Platform.isWindows
      ? 'xdremux_core.dll'
      : Platform.isMacOS
          ? 'libxdremux_core.dylib'
          : 'libxdremux_core.so';

  final candidates = <String>[
    // CI / release layout: copied next to the Flutter project.
    name,
    'lib/$name',
    // Local Cargo layouts, from `apps/flutter` and from the repository root.
    '../target/release/$name',
    '../target/debug/$name',
    '../../target/release/$name',
    '../../target/debug/$name',
    'build/rust/release/$name',
    // A built macOS app bundle, useful after `flutter build macos`.
    'build/macos/Build/Products/Release/Runner.app/Contents/Frameworks/$name',
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return File(candidate).absolute.path;
    }
  }

  final searched = candidates
      .map((candidate) => '  ${File(candidate).absolute.path}')
      .join('\n');
  throw StateError(
    'Native core library "$name" not found.\n'
    'Build it first: cargo build -p xdremux-core --release\n'
    'Then either copy it into ${Directory.current.path} or keep the Cargo '
    'target directory in place.\nSearched:\n$searched',
  );
}
