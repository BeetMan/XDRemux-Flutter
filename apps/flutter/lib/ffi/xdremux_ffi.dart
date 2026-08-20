import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
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
/// - `oppoCompat`: 0=off, 1=auto, 2=on, 3=tail, 4=iso,
///   5=iso-no-local, 6=iso-graph
/// - `oppoCameraTail`: 0=off through 9=preserve-no-hdr; 255=automatic
/// - `strictTmap`: false=ImageIO-compatible 62/142-byte payload;
///   true=strict ISO 65/145-byte payload
/// - `applePhotographicStyles`: generate the native Rust Styles graph
/// - `applePortrait`: generate the native Rust Apple Portrait graph
final class ConvertConfig extends ffi.Struct {
  @ffi.Uint8()
  external int oppoCompat;

  @ffi.Uint8()
  external int oppoCameraTail;

  @ffi.Uint8()
  external int strictTmap;

  @ffi.Uint8()
  external int applePhotographicStyles;

  @ffi.Uint8()
  external int applePortrait;
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

/// Capture-mode result returned by `xdremux_classify`.
/// Must be released with [freeClassificationResult].
final class ClassificationResult extends ffi.Struct {
  external ffi.Pointer<Utf8> modeKey;

  external ffi.Pointer<Utf8> folderName;

  external ffi.Pointer<Utf8> status;

  external ffi.Pointer<Utf8> rawUserComment;

  @ffi.Bool()
  external bool hasTagFlags;

  @ffi.Uint64()
  external int tagFlags;

  @ffi.Uint64()
  external int unknownFlags;

  /// "lhdr" or "uhdr" (from the source container), or null if not ProXDR.
  external ffi.Pointer<Utf8> hdrKind;

  /// "x6" or "x7" family, or null when unknown.
  external ffi.Pointer<Utf8> family;
}

/// Result of thumbnail extraction. Must be freed with [freeThumbnail].
final class ThumbnailResult extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> data;

  @ffi.IntPtr()
  external int len;

  @ffi.Bool()
  external bool success;
}

/// Result of `xdremux_prepare_tiles`. Must be freed with [freePrepared].
final class PreparedTilesResult extends ffi.Struct {
  @ffi.Bool()
  external bool success;

  external ffi.Pointer<ffi.Void> opaque;

  external ffi.Pointer<ffi.Uint8> tileData;

  @ffi.IntPtr()
  external int tileDataLen;

  @ffi.Uint32()
  external int tileW;

  @ffi.Uint32()
  external int tileH;

  @ffi.Uint32()
  external int tileCount;

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
      return _openMacOS();
    }
  }

  /// On macOS, try the Frameworks directory inside the app bundle first,
  /// then fall back to the working directory (for flutter run standalone).
  static ffi.DynamicLibrary _openMacOS() {
    const name = 'libxdremux_core.dylib';
    // macOS dyld searches @rpath and @executable_path automatically.
    // The app has @executable_path/../Frameworks in LD_RUNPATH_SEARCH_PATHS,
    // and we also place the dylib next to the main binary.
    // Try each approach, catching and collecting errors for diagnostics.
    final attempts = <(String, dynamic)>[
      // 1. Just the bare name — let dyld search rpath + executable_path
      (name, null),
      // 2. Next to the executable
      ('${Platform.resolvedExecutable}/../$name', null),
      // 3. App bundle Frameworks
      ('${Platform.resolvedExecutable}/../../Frameworks/$name', null),
      // 4. Also try ../../../Frameworks (if resolvedExecutable is inside App.framework)
      ('${Platform.resolvedExecutable}/../../../Frameworks/$name', null),
    ];
    Object? lastError;
    for (final (path, _) in attempts) {
      try {
        return ffi.DynamicLibrary.open(path);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Could not load $name. Last error: $lastError');
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
      '../../../target/release/$name',
      '../../../target/debug/$name',
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

  static final _diagnosePortrait = _lib.lookupFunction<
      ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>),
      ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>)>('xdremux_diagnose_portrait');

  static final _inspect = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<Utf8>),
      ConversionResult Function(ffi.Pointer<Utf8>)>('xdremux_inspect');

  static final _classify = _lib.lookupFunction<
      ClassificationResult Function(ffi.Pointer<Utf8>),
      ClassificationResult Function(ffi.Pointer<Utf8>)>('xdremux_classify');

  static final _convert = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>),
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>)>('xdremux_convert');

  static final _convertWithProgress = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>, ffi.Uint32),
      ConversionResult Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>, int)>('xdremux_convert_with_progress');

  static final _progressBegin = _lib.lookupFunction<
      ffi.Uint32 Function(),
      int Function()>('xdremux_progress_begin');

  static final _progressEnd = _lib.lookupFunction<
      ffi.Void Function(ffi.Uint32),
      void Function(int)>('xdremux_progress_end');

  static final _readProgressFor = _lib.lookupFunction<
      ffi.Void Function(ffi.Uint32, ffi.Pointer<ffi.Uint32>),
      void Function(int, ffi.Pointer<ffi.Uint32>)>('xdremux_read_progress_for');

  static final _verifyOutput = _lib.lookupFunction<
      ffi.Bool Function(ffi.Pointer<Utf8>),
      bool Function(ffi.Pointer<Utf8>)>('xdremux_verify_output');

  static final _verifyStylesOutput = _lib.lookupFunction<
      ffi.Bool Function(ffi.Pointer<Utf8>),
      bool Function(ffi.Pointer<Utf8>)>('xdremux_verify_styles_output');

  static final _verifyPortraitOutput = _lib.lookupFunction<
      ffi.Bool Function(ffi.Pointer<Utf8>),
      bool Function(ffi.Pointer<Utf8>)>('xdremux_verify_portrait_output');

  static final _freeResult = _lib.lookupFunction<
      ffi.Void Function(ConversionResult),
      void Function(ConversionResult)>('xdremux_free_result');

  static final _freeClassificationResult = _lib.lookupFunction<
      ffi.Void Function(ClassificationResult),
      void Function(ClassificationResult)>('xdremux_free_classification_result');

  static final _readProgress = _lib.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Uint32>),
      void Function(ffi.Pointer<ffi.Uint32>)>('xdremux_read_progress');

  static final _extractThumbnail = _lib.lookupFunction<
      ThumbnailResult Function(ffi.Pointer<Utf8>),
      ThumbnailResult Function(ffi.Pointer<Utf8>)>('xdremux_extract_thumbnail');

  static final _freeThumbnail = _lib.lookupFunction<
      ffi.Void Function(ThumbnailResult),
      void Function(ThumbnailResult)>('xdremux_free_thumbnail');

  static final _prepareTiles = _lib.lookupFunction<
      PreparedTilesResult Function(ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>, ffi.Uint32),
      PreparedTilesResult Function(ffi.Pointer<Utf8>, ffi.Pointer<ConvertConfig>, int)>('xdremux_prepare_tiles');

  static final _freePrepared = _lib.lookupFunction<
      ffi.Void Function(PreparedTilesResult),
      void Function(PreparedTilesResult)>('xdremux_free_prepared');

  static final _assembleTiles = _lib.lookupFunction<
      ConversionResult Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>, ffi.IntPtr, ffi.Pointer<Utf8>, ffi.Uint32),
      ConversionResult Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>, int, ffi.Pointer<Utf8>, int)>('xdremux_assemble_tiles');

  static final _progressReport = _lib.lookupFunction<
      ffi.Void Function(ffi.Uint32, ffi.Uint32, ffi.Uint32),
      void Function(int, int, int)>('xdremux_progress_report');

  /// Returns the Rust core version string (e.g. "0.1.1").
  static String version() {
    final ptr = _version();
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr);
    }
  }

  /// Read the portable Rust Apple Portrait depth diagnostic.
  static Map<String, dynamic> diagnosePortrait(String inputPath) {
    final input = inputPath.toNativeUtf8();
    ffi.Pointer<Utf8> ptr = ffi.nullptr;
    try {
      ptr = _diagnosePortrait(input);
      if (ptr == ffi.nullptr) {
        return <String, dynamic>{
          'schema': 'xdremux-portrait-depth-diagnostic-v1',
          'available': false,
          'safeToTransform': false,
          'classification': 'diagnostic-error',
        };
      }
      final decoded = jsonDecode(ptr.toDartString());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } finally {
      if (ptr != ffi.nullptr) _freeString(ptr);
      calloc.free(input);
    }
    return <String, dynamic>{
      'schema': 'xdremux-portrait-depth-diagnostic-v1',
      'available': false,
      'safeToTransform': false,
      'classification': 'invalid-diagnostic-report',
    };
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

  /// Classify an image from its EXIF UserComment capture-mode flags.
  static ClassificationResult classify(String inputPath) {
    final input = inputPath.toNativeUtf8();
    try {
      return _classify(input);
    } finally {
      calloc.free(input);
    }
  }

  /// Convert a single file. Returns a [ConversionResult] that the caller must free.
  ///
  /// [oppoCompat] — 0=off, 1=auto, 2=on, 3=tail, 4=iso,
  /// 5=iso-no-local, 6=iso-graph. [oppoCameraTail] uses 0..9, or 255 for auto.
  static ConversionResult convert(
    String inputPath,
    String outputPath, {
    int oppoCompat = 0,
    int oppoCameraTail = 255,
    bool strictTmap = false,
    bool applePhotographicStyles = false,
    bool applePortrait = false,
  }) {
    final input = inputPath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();
    final cfg = calloc<ConvertConfig>();
    cfg.ref.oppoCompat = oppoCompat.clamp(0, 6);
    cfg.ref.oppoCameraTail = oppoCameraTail.clamp(0, 255);
    cfg.ref.strictTmap = strictTmap ? 1 : 0;
    cfg.ref.applePhotographicStyles = applePhotographicStyles ? 1 : 0;
    cfg.ref.applePortrait = applePortrait ? 1 : 0;
    try {
      return _convert(input, output, cfg);
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(cfg);
    }
  }

  /// Convert like [convert], but report tile progress into the given
  /// [progressHandle] (from [progressBegin]) so the caller can poll this
  /// conversion's real progress via [readProgressFor] while sibling
  /// conversions run concurrently.
  static ConversionResult convertWithProgress(
    String inputPath,
    String outputPath, {
    required int progressHandle,
    int oppoCompat = 0,
    int oppoCameraTail = 255,
    bool strictTmap = false,
    bool applePhotographicStyles = false,
    bool applePortrait = false,
  }) {
    final input = inputPath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();
    final cfg = calloc<ConvertConfig>();
    cfg.ref.oppoCompat = oppoCompat.clamp(0, 6);
    cfg.ref.oppoCameraTail = oppoCameraTail.clamp(0, 255);
    cfg.ref.strictTmap = strictTmap ? 1 : 0;
    cfg.ref.applePhotographicStyles = applePhotographicStyles ? 1 : 0;
    cfg.ref.applePortrait = applePortrait ? 1 : 0;
    try {
      return _convertWithProgress(input, output, cfg, progressHandle);
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(cfg);
    }
  }

  /// Allocate a Rust progress handle on the calling thread. Poll it with
  /// [readProgressFor] while the conversion runs on a worker isolate, then
  /// release it with [progressEnd].
  static int progressBegin() => _progressBegin();

  /// Release a progress handle allocated by [progressBegin].
  static void progressEnd(int handle) => _progressEnd(handle);

  static bool verifyOutput(String path) {
    final ptr = path.toNativeUtf8();
    try {
      return _verifyOutput(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static bool verifyStylesOutput(String path) {
    final ptr = path.toNativeUtf8();
    try {
      return _verifyStylesOutput(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static bool verifyPortraitOutput(String path) {
    try {
      final ptr = path.toNativeUtf8();
      try {
        return _verifyPortraitOutput(ptr);
      } finally {
        calloc.free(ptr);
      }
    } catch (_) {
      // Older platform bundles may not have the new structural verifier yet.
      return verifyOutput(path);
    }
  }

  static void freeResult(ConversionResult result) {
    _freeResult(result);
  }

  static void freeClassificationResult(ClassificationResult result) {
    _freeClassificationResult(result);
  }

  /// Read the current conversion progress.
  ///
  /// Returns `(stage, current, total)`.
  /// Stage: 0=idle, 1=extract, 2=decode, 3=encode tiles, 4=assemble.
  static (int, int, int) readProgress() {
    final buf = calloc<ffi.Uint32>(3);
    try {
      _readProgress(buf);
      return (buf[0], buf[1], buf[2]);
    } finally {
      calloc.free(buf);
    }
  }

  /// Read progress for the conversion bound to [handle] (from
  /// [progressBegin]). Returns (0, 0, 0) once the handle is released.
  static (int, int, int) readProgressFor(int handle) {
    final buf = calloc<ffi.Uint32>(3);
    try {
      _readProgressFor(handle, buf);
      return (buf[0], buf[1], buf[2]);
    } finally {
      calloc.free(buf);
    }
  }

  /// Extract an embedded JPEG thumbnail from a HEIC file.
  ///
  /// Returns JPEG bytes or null if no thumbnail is found.
  static Uint8List? extractThumbnail(String inputPath) {
    final path = inputPath.toNativeUtf8();
    try {
      final result = _extractThumbnail(path);
      if (!result.success || result.data == ffi.nullptr || result.len == 0) {
        _freeThumbnail(result);
        return null;
      }
      final bytes = result.data.asTypedList(result.len);
      final copy = Uint8List.fromList(bytes);
      _freeThumbnail(result);
      return copy;
    } finally {
      calloc.free(path);
    }
  }

  // -------------------------------------------------------------------------
  // Hardware-encoding split: prepare → Dart/MediaCodec encodes tiles → assemble
  // -------------------------------------------------------------------------

  /// Parse a HEIC, reconstruct the gain map, and pack each 512×512 tile as
  /// YUV420 (I420) into one contiguous buffer (Y,U,V per tile). Returns the
  /// owned [PreparedTilesResult]; caller must [freePrepared] it when done.
  static PreparedTilesResult prepareTiles(
    String inputPath, {
    int oppoCompat = 0,
    int oppoCameraTail = 255,
    bool strictTmap = false,
    int progressHandle = 0,
  }) {
    final path = inputPath.toNativeUtf8();
    final cfg = calloc<ConvertConfig>();
    cfg.ref.oppoCompat = oppoCompat.clamp(0, 6);
    cfg.ref.oppoCameraTail = oppoCameraTail.clamp(0, 255);
    cfg.ref.strictTmap = strictTmap ? 1 : 0;
    try {
      return _prepareTiles(path, cfg, progressHandle);
    } finally {
      calloc.free(path);
      calloc.free(cfg);
    }
  }

  /// Free a [PreparedTilesResult] from [prepareTiles].
  static void freePrepared(PreparedTilesResult result) => _freePrepared(result);

  /// Report per-tile encode progress into a Rust progress handle (from
  /// [progressBegin]) so the UI can show real tile progress during the
  /// Dart-side MediaCodec loop.
  static void progressReport(int handle, int current, int total) {
    _progressReport(handle, current, total);
  }

  /// Assemble the final HEIC from externally-encoded per-tile HEVC byte
  /// streams. [opaque] comes from a [PreparedTilesResult]. Returns a
  /// [ConversionResult] that the caller must free.
  static ConversionResult assembleTiles(
    ffi.Pointer<ffi.Void> opaque,
    List<Uint8List> tileStreams,
    String outputPath, {
    int progressHandle = 0,
  }) {
    // Copy each stream into a native buffer; Rust copies it out synchronously.
    final ptrs = calloc<ffi.Pointer<ffi.Uint8>>(tileStreams.length);
    final lengths = calloc<ffi.IntPtr>(tileStreams.length);
    final natives = <ffi.Pointer<ffi.Uint8>>[];
    try {
      for (var i = 0; i < tileStreams.length; i++) {
        final stream = tileStreams[i];
        final native = calloc<ffi.Uint8>(stream.length);
        native.asTypedList(stream.length).setAll(0, stream);
        natives.add(native);
        ptrs[i] = native;
        lengths[i] = stream.length;
      }
      final out = outputPath.toNativeUtf8();
      try {
        return _assembleTiles(
          opaque,
          ptrs,
          lengths,
          tileStreams.length,
          out,
          progressHandle,
        );
      } finally {
        calloc.free(out);
      }
    } finally {
      for (final n in natives) {
        calloc.free(n);
      }
      calloc.free(ptrs);
      calloc.free(lengths);
    }
  }
}
