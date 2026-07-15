import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';

extension ToDartStringOrNull on ffi.Pointer<Utf8> {
  String? toDartStringOrNull() {
    if (this == ffi.nullptr) return null;
    return toDartString();
  }
}

/// Configuration passed to `xdremux_convert`.
///
/// Fields match the Rust `ConvertConfig`:
/// - `oppoCompat`: 0=off, 1=auto, 2=on, 3=tail (alias for on)
final class ConvertConfig extends ffi.Struct {
  @ffi.Uint8()
  external int oppoCompat;
}

/// Opaque C struct returned by Rust. Must be freed with [freeResult].
final class ConversionResult extends ffi.Struct {
  @ffi.Bool()
  external bool success;

  external ffi.Pointer<Utf8> mode;

  external ffi.Pointer<Utf8> family;

  @ffi.Double()
  external double edrScale;

  @ffi.Double()
  external double gainMapMax;

  external ffi.Pointer<Utf8> errorMessage;
}

/// Low-level FFI bindings to the Rust core dynamic library.
class XdRemuxFFI {
  static ffi.DynamicLibrary get _lib {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libxdremux_core.so');
    } else if (Platform.isIOS) {
      return ffi.DynamicLibrary.process();
    } else if (Platform.isWindows) {
      return _openWindows();
    } else {
      return ffi.DynamicLibrary.open('libxdremux_core.dylib');
    }
  }

  /// On Windows the DLL ships next to the executable (installed by CMake).
  /// For `flutter test` the working directory differs, so fall back to a few
  /// candidate locations rooted at the package / known build dirs.
  static ffi.DynamicLibrary _openWindows() {
    const name = 'xdremux_core.dll';
    try {
      return ffi.DynamicLibrary.open(name);
    } catch (_) {
      // fall through to resolved candidates
    }
    final candidates = <String>[
      // Built app layout
      'build/windows/x64/runner/Debug/$name',
      'build/windows/x64/runner/Release/$name',
      // Rust cargo output, relative to apps/flutter
      '../../../xdremux/rust/target/release/$name',
      '../../../xdremux/rust/target/debug/$name',
    ];
    for (final c in candidates) {
      try {
        return ffi.DynamicLibrary.open(c);
      } catch (_) {
        // try next
      }
    }
    throw StateError('Could not locate $name in cwd or known build dirs.');
  }

  static final _version = _lib.lookupFunction<
      ffi.Pointer<Utf8> Function(),
      ffi.Pointer<Utf8> Function()>('xdremux_version');

  static final _freeString = _lib.lookupFunction<
      ffi.Void Function(ffi.Pointer<Utf8>),
      void Function(ffi.Pointer<Utf8>)>('xdremux_free_string');

  static final _inspect = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<Utf8>),
      ConversionResult Function(ffi.Pointer<Utf8>)>('xdremux_inspect');

  static final _convert = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>),
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>)>('xdremux_convert');

  static final _verifyOutput = _lib.lookupFunction<
      ffi.Bool Function(ffi.Pointer<Utf8>),
      bool Function(ffi.Pointer<Utf8>)>('xdremux_verify_output');

  static final _freeResult = _lib.lookupFunction<
      ffi.Void Function(ConversionResult),
      void Function(ConversionResult)>('xdremux_free_result');

  /// Returns the Rust core version string (e.g. "0.1.0").
  static String version() {
    final ptr = _version();
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr);
    }
  }

  /// Inspect a ProXDR HEIC file. Returns the parsed mode/family/edr metadata.
  static ConversionResult inspect(String inputPath) {
    final input = inputPath.toNativeUtf8();
    try {
      return _inspect(input);
    } finally {
      calloc.free(input);
    }
  }

  /// Convert a single file. Returns a [ConversionResult] that the caller must free.
  ///
  /// [oppoCompat] — 0=off, 1=auto, 2=on, 3=tail (alias for on).
  static ConversionResult convert(String inputPath, String outputPath, {int oppoCompat = 0}) {
    final input = inputPath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();
    final cfg = calloc<ConvertConfig>();
    cfg.ref.oppoCompat = oppoCompat.clamp(0, 3);
    try {
      return _convert(input, output, cfg);
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(cfg);
    }
  }

  static bool verifyOutput(String path) {
    final ptr = path.toNativeUtf8();
    try {
      return _verifyOutput(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static void freeResult(ConversionResult result) {
    _freeResult(result);
  }
}
