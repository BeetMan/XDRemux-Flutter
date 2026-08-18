import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';
import 'conversion_backend.dart';

/// Higher-level service that wraps raw FFI calls and manages settings.
class XdRemuxService {
  XdRemuxService._();

  static const MethodChannel _backendChannel = MethodChannel(
    'xdremux/swift-backend',
  );
  static final Map<ConversionBackend, ConversionBackendAdapter> _backends = {
    ConversionBackend.rust: RustConversionBackend(),
    ConversionBackend.swift: SwiftConversionBackend(),
  };
  static final Set<String> _cancelledRequests = <String>{};

  // -----------------------------------------------------------------------
  // Backend capabilities and common conversion contract
  // -----------------------------------------------------------------------

  static Future<BackendCapabilities> getBackendCapabilities() async {
    final defaults = BackendCapabilities.forCurrentPlatform();
    if (!defaults.swiftVisible) return defaults;

    try {
      final raw = await _backendChannel.invokeMethod<Object?>(
        'getCapabilities',
      );
      if (raw is! Map) return defaults;
      final map = raw.map((key, value) => MapEntry(key.toString(), value));
      return defaults.copyWith(
        swiftAvailable: map['swiftAvailable'] == true,
        swiftStandardHdr: map['swiftStandardHdr'] == true,
        swiftAppleFeatures: map['swiftAppleFeatures'] == true,
        swiftPhotographicStyles: map['swiftPhotographicStyles'] == true,
        swiftPortrait: map['swiftPortrait'] == true,
        swiftPortraitResearch: map['swiftPortraitResearch'] == true,
        swiftUnavailableReason:
            map['swiftUnavailableReason'] as String? ??
            defaults.swiftUnavailableReason,
        swiftAppleFeaturesUnavailableReason:
            map['swiftAppleFeaturesUnavailableReason'] as String? ??
            defaults.swiftAppleFeaturesUnavailableReason,
      );
    } on MissingPluginException {
      return defaults;
    } on PlatformException {
      return defaults;
    } catch (_) {
      return defaults;
    }
  }

  /// Read-only probe for OPPO rear Portrait depth variants (macOS + iOS;
  /// iOS uses the embedded zstd decoder). This does not enable Apple
  /// Portrait conversion and is intentionally unavailable on Windows and
  /// Android.
  static Future<Map<String, dynamic>> diagnosePortrait(String inputPath) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-depth-diagnostic-v1',
        'available': false,
        'safeToTransform': false,
        'classification': 'unsupported-platform',
      };
    }
    try {
      final raw = await _backendChannel.invokeMethod<Object?>(
        'diagnosePortrait',
        <String, Object?>{'inputPath': inputPath},
      );
      if (raw is! Map) {
        return <String, dynamic>{
          'schema': 'xdremux-portrait-depth-diagnostic-v1',
          'available': false,
          'safeToTransform': false,
          'classification': 'invalid-native-report',
        };
      }
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } on MissingPluginException {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-depth-diagnostic-v1',
        'available': false,
        'safeToTransform': false,
        'classification': 'native-bridge-unavailable',
      };
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-depth-diagnostic-v1',
        'available': false,
        'safeToTransform': false,
        'classification': 'native-diagnostic-error',
        'error': error.message ?? error.code,
      };
    }
  }

  /// Runs the macOS-only, explicitly experimental Portrait research module.
  /// It generates Apple Portrait candidates and never performs OPPO writeback
  /// or output-mode conversion.
  static Future<Map<String, dynamic>> researchPortrait({
    required List<String> inputPaths,
    required String outputDirectory,
    List<String> variants = const <String>[
      'p20',
      'p50',
      'p80',
      'uniform:0.005',
    ],
  }) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-calibration-research-v1',
        'researchOnly': true,
        'safeToTransform': false,
        'error': 'Apple 人像模式研究仅支持 macOS/iOS。',
      };
    }
    try {
      final raw = await _backendChannel
          .invokeMethod<Object?>('researchPortrait', <String, Object?>{
            'inputPaths': inputPaths,
            'outputDirectory': outputDirectory,
            'variants': variants,
          });
      if (raw is! Map) {
        return <String, dynamic>{
          'schema': 'xdremux-portrait-calibration-research-v1',
          'researchOnly': true,
          'safeToTransform': false,
          'error': 'Apple 人像模式研究报告无效',
        };
      }
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } on MissingPluginException {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-calibration-research-v1',
        'researchOnly': true,
        'safeToTransform': false,
        'error': 'macOS Apple 人像模式研究桥接不可用。',
      };
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'schema': 'xdremux-portrait-calibration-research-v1',
        'researchOnly': true,
        'safeToTransform': false,
        'error': error.message ?? error.code,
      };
    }
  }

  static Future<BackendConversionResult> convertWithBackend(
    ConversionRequest request,
  ) async {
    final capabilities = await getBackendCapabilities();
    if (request.applePhotographicStyles || request.applePortrait) {
      if (request.applePortrait && request.backend != ConversionBackend.swift) {
        return BackendConversionResult.failure(
          request.backend,
          'Apple 人像模式目前只能由 Swift 后端执行。',
        );
      }
      if (request.applePhotographicStyles &&
          request.backend == ConversionBackend.swift &&
          !capabilities.swiftPhotographicStyles) {
        return BackendConversionResult.failure(
          request.backend,
          capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
              ? 'Apple 相册摄影风格当前未通过能力验证。'
              : capabilities.swiftAppleFeaturesUnavailableReason,
        );
      }
      if (request.applePortrait && !capabilities.swiftPortrait) {
        return BackendConversionResult.failure(
          request.backend,
          capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
              ? 'Apple 人像模式当前未通过能力验证。'
              : capabilities.swiftAppleFeaturesUnavailableReason,
        );
      }
    }
    if (!capabilities.isAvailable(request.backend)) {
      return BackendConversionResult.failure(
        request.backend,
        capabilities.statusFor(request.backend),
      );
    }
    return _backends[request.backend]!.convert(request);
  }

  static BackendProgress readProgress(ConversionRequest request) {
    return _backends[request.backend]!.readProgress(request);
  }

  static Future<bool> verifyOutputForBackend(
    ConversionBackend backend,
    String path, {
    bool applePhotographicStyles = false,
    bool applePortrait = false,
  }) {
    return _backends[backend]!.verifyOutput(
      path,
      applePhotographicStyles: applePhotographicStyles,
      applePortrait: applePortrait,
    );
  }

  /// Request cancellation for a backend request. Rust cannot interrupt an
  /// in-flight FFI call yet, so the coordinator guarantees only that its
  /// eventual result is not reported as converted. Swift receives the same
  /// request id over MethodChannel for native cancellation when available.
  static void cancel(String requestId) {
    _cancelledRequests.add(requestId);
    for (final backend in _backends.values) {
      backend.cancel(requestId);
    }
  }

  static bool takeCancellation(String requestId) {
    return _cancelledRequests.remove(requestId);
  }

  // -----------------------------------------------------------------------
  // Version
  // -----------------------------------------------------------------------

  static Future<String> getVersion() async => XdRemuxFFI.version();

  // -----------------------------------------------------------------------
  // Inspect
  // -----------------------------------------------------------------------

  static Future<Map<String, dynamic>> inspect(String inputPath) async {
    final result = XdRemuxFFI.inspect(inputPath);
    try {
      return {
        'success': result.success,
        'mode': result.mode.toDartStringOrNull(),
        'family': result.family.toDartStringOrNull(),
        'edrScale': result.edrScale,
        'gainMapMax': result.gainMapMax,
        'errorMessage': result.errorMessage.toDartStringOrNull(),
      };
    } finally {
      XdRemuxFFI.freeResult(result);
    }
  }

  // -----------------------------------------------------------------------
  // Capture-mode classification
  // -----------------------------------------------------------------------

  static Future<Map<String, dynamic>> classify(String inputPath) async {
    // Keep this FFI call on the root isolate. Android release builds can fail
    // when the dynamically loaded Rust library is opened from a spawned
    // isolate, which makes the file picker appear to add nothing.
    final result = XdRemuxFFI.classify(inputPath);
    try {
      return {
        'modeKey': result.modeKey.toDartStringOrNull(),
        'folderName': result.folderName.toDartStringOrNull(),
        'status': result.status.toDartStringOrNull(),
        'rawUserComment': result.rawUserComment.toDartStringOrNull(),
        'tagFlags': result.hasTagFlags ? result.tagFlags : null,
        'unknownFlags': result.unknownFlags,
        'hdrKind': result.hdrKind.toDartStringOrNull(),
        'family': result.family.toDartStringOrNull(),
      };
    } finally {
      XdRemuxFFI.freeClassificationResult(result);
    }
  }

  // -----------------------------------------------------------------------
  // Convert (runs in background isolate to keep UI responsive)
  // -----------------------------------------------------------------------

  static Future<Map<String, dynamic>> convert(
    String inputPath,
    String outputPath, {
    int oppoCompat = 0,
    int oppoCameraTail = 255,
    bool strictTmap = false,
    int progressHandle = 0,
  }) {
    return convertWithBackend(
      ConversionRequest(
        id: 'rust-${DateTime.now().microsecondsSinceEpoch}',
        backend: ConversionBackend.rust,
        inputPath: inputPath,
        outputPath: outputPath,
        oppoCompat: oppoCompat,
        oppoCameraTail: oppoCameraTail,
        strictTmap: strictTmap,
        progressHandle: progressHandle,
      ),
    ).then((result) => result.toMap());
  }

  // -----------------------------------------------------------------------
  // Verify output
  // -----------------------------------------------------------------------

  static Future<bool> verifyOutput(String path) async {
    return verifyOutputForBackend(ConversionBackend.rust, path);
  }

  /// Reconcile a returned Apple Photos file with its original OPPO donor.
  /// The native bridge runs on macOS (SwiftBackend package) and iOS
  /// (Runner-local ImageIO implementation). Both use ImageIO readback as the
  /// output validation and never start a helper process.
  static Future<Map<String, dynamic>> writebackReturnedPhoto({
    String? originalPath,
    required String returnedPath,
    required String outputPath,
    required OutputMode outputMode,
    bool restoreWatermark = true,
  }) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      throw UnsupportedError(
        'returned-photo writeback is only available on Apple platforms',
      );
    }
    final raw = await _backendChannel
        .invokeMethod<Object?>('writebackReturnedPhoto', <String, dynamic>{
          if (originalPath != null) 'originalPath': originalPath,
          'returnedPath': returnedPath,
          'outputPath': outputPath,
          'outputMode': outputMode.name,
          'restoreWatermark': restoreWatermark,
        });
    if (raw is! Map) {
      throw StateError('returned-photo writeback returned an invalid result');
    }
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  // -----------------------------------------------------------------------
  // Thumbnails
  // -----------------------------------------------------------------------

  /// Generate a thumbnail PNG/JPEG data from a HEIC/JPG input file.
  ///
  /// macOS/iOS/Android/Windows: native decode (ImageIO / Android ImageDecoder /
  /// Windows WIC) of the full-resolution HEIC primary image, tone-mapped to
  /// SDR, so the photo wall is crisp and full-colour. On Android/macOS the
  /// Rust FFI fallback would scan for embedded JPEGs, which picks up the
  /// grayscale gain map (black-and-white preview) or a corrupt fragment, so
  /// the system decoder is preferred. On Windows, WIC decodes the primary
  /// image for files that carry no EXIF thumbnail (older OPPO X6-series),
  /// where the FFI fallback returned a broken JPEG fragment.
  /// Other platforms (Linux): Rust FFI extracts the embedded EXIF JPEG
  /// thumbnail.
  static Future<Uint8List?> generateThumbnail(
    String inputPath, {
    int maxPixelSize = 320,
  }) async {
    if (Platform.isMacOS ||
        Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isWindows) {
      try {
        const channel = MethodChannel('xdremux/thumbnail');
        final bytes = await channel.invokeMethod<Uint8List>('render', {
          'path': inputPath,
          'maxPixelSize': maxPixelSize,
        });
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (e) {
        print('generateThumbnail native error: $e');
      }
      // Native render returned empty (e.g. no HEIF extension on Windows) or
      // threw — fall through to the FFI embedded-thumbnail path.
    }
    try {
      return XdRemuxFFI.extractThumbnail(inputPath);
    } catch (e) {
      print('generateThumbnail FFI error: $e');
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Thumbnail cache (in-memory, keyed by inputPath + maxPixelSize)
  // -----------------------------------------------------------------------

  static final Map<String, Uint8List?> _thumbnailCache = {};

  /// In-flight thumbnail generations, so concurrent requests for the same file
  /// (e.g. after dragging in many photos at once) share one decode instead of
  /// spawning N identical WIC decodes that contend on the platform channel.
  static final Map<String, Future<Uint8List?>> _thumbnailInFlight = {};

  /// Throttle concurrent native decodes. Dragging in 20 HEICs fires 20
  /// `getThumbnail` calls at once; running them all concurrently makes the
  /// photo wall janky while every thumbnail decodes on the same channel.
  static int _thumbnailActive = 0;
  static final List<Future<void> Function()> _thumbnailQueue = [];
  // Native decode is off the platform thread (background thread in the C++
  // handler), so a modest cap is enough to keep HEVC decoding from saturating
  // the CPU; it no longer needs to protect the UI thread.
  static const int _thumbnailMaxConcurrent = 8;

  static Future<Uint8List?> _scheduleThumbnail(
    Future<Uint8List?> Function() job,
  ) {
    if (_thumbnailActive < _thumbnailMaxConcurrent) {
      _thumbnailActive++;
      return _runThumbnailJob(job);
    }
    final completer = Completer<Uint8List?>();
    _thumbnailQueue.add(() async {
      final r = await _runThumbnailJob(job);
      completer.complete(r);
    });
    return completer.future;
  }

  static Future<Uint8List?> _runThumbnailJob(
    Future<Uint8List?> Function() job,
  ) async {
    try {
      return await job();
    } finally {
      _thumbnailActive--;
      // Pop the next queued job, if any.
      if (_thumbnailQueue.isNotEmpty) {
        final next = _thumbnailQueue.removeAt(0);
        _thumbnailActive++;
        next();
      }
    }
  }

  /// Cached thumbnail for a file. Generates on first call and caches the result.
  static Future<Uint8List?> getThumbnail(
    String inputPath, {
    int maxPixelSize = 320,
  }) async {
    final key = '$inputPath@$maxPixelSize';
    if (_thumbnailCache.containsKey(key)) return _thumbnailCache[key];
    final inflight = _thumbnailInFlight[key];
    if (inflight != null) return inflight;

    final future =
        _scheduleThumbnail(
          () => generateThumbnail(inputPath, maxPixelSize: maxPixelSize),
        ).then((r) {
          _thumbnailCache[key] = r;
          _thumbnailInFlight.remove(key);
          return r;
        });
    _thumbnailInFlight[key] = future;
    return future;
  }

  /// Invalidate all cached thumbnails (e.g. after clearing queue).
  static void clearThumbnailCache() {
    _thumbnailCache.clear();
    _thumbnailInFlight.clear();
    _thumbnailQueue.clear();
  }

  // -----------------------------------------------------------------------
  // Settings persistence
  // -----------------------------------------------------------------------

  static const _keyLanguage = 'language';
  static const _keyFamily = 'family';
  static const _keyBackend = 'backend';
  static const _keyOutputMode = 'outputMode';
  static const _keyOutputDirectory = 'outputDirectory';
  static const _keyOppoCompat = 'oppoCompatibility';
  static const _keyOppoCameraTail = 'oppoCameraTail';
  static const _keyStrictTmap = 'strictTmap';
  static const _keySkipExisting = 'skipExisting';
  static const _keyMaxConcurrentJobs = 'maxConcurrentJobs';
  static const _keyFileNameSuffix = 'fileNameSuffix';
  static const _keyCategorizeOutputByMode = 'categorizeOutputByMode';
  static const _keyHardwareEncode = 'hardwareEncode';

  static Future<ConversionConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return ConversionConfig(
      language: AppLanguage.values.firstWhere(
        (e) => e.name == prefs.getString(_keyLanguage),
        orElse: () => AppLanguage.chinese,
      ),
      family: Family.values.firstWhere(
        (e) => e.name == prefs.getString(_keyFamily),
        orElse: () => Family.auto,
      ),
      backend: ConversionBackend.values.firstWhere(
        (e) => e.name == prefs.getString(_keyBackend),
        orElse: () => ConversionBackend.rust,
      ),
      outputMode: OutputMode.values.firstWhere(
        (e) => e.name == prefs.getString(_keyOutputMode),
        orElse: () => OutputMode.oppo,
      ),
      outputDirectory: prefs.getString(_keyOutputDirectory),
      oppoCompatibility: OppoCompatMode.values.firstWhere(
        (e) => e.name == prefs.getString(_keyOppoCompat),
        orElse: () => OppoCompatMode.on,
      ),
      oppoCameraTail: OppoCameraTailMode.values.firstWhere(
        (e) => e.name == prefs.getString(_keyOppoCameraTail),
        orElse: () => OppoCameraTailMode.automatic,
      ),
      strictTmap: prefs.getBool(_keyStrictTmap) ?? false,
      skipExisting: prefs.getBool(_keySkipExisting) ?? true,
      maxConcurrentJobs: prefs.getInt(_keyMaxConcurrentJobs) ?? 4,
      fileNameSuffix: prefs.getString(_keyFileNameSuffix) ?? '_iso',
      categorizeOutputByMode:
          prefs.getBool(_keyCategorizeOutputByMode) ?? false,
      hardwareEncode: prefs.getBool(_keyHardwareEncode) ?? false,
    );
  }

  static Future<void> saveConfig(ConversionConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLanguage, config.language.name);
    await prefs.setString(_keyFamily, config.family.name);
    await prefs.setString(_keyBackend, config.backend.name);
    await prefs.setString(_keyOutputMode, config.outputMode.name);
    if (config.outputDirectory != null) {
      await prefs.setString(_keyOutputDirectory, config.outputDirectory!);
    } else {
      await prefs.remove(_keyOutputDirectory);
    }
    await prefs.setString(_keyOppoCompat, config.oppoCompatibility.name);
    await prefs.setString(_keyOppoCameraTail, config.oppoCameraTail.name);
    await prefs.setBool(_keyStrictTmap, config.strictTmap);
    await prefs.setBool(_keySkipExisting, config.skipExisting);
    await prefs.setInt(_keyMaxConcurrentJobs, config.maxConcurrentJobs);
    await prefs.setString(_keyFileNameSuffix, config.fileNameSuffix);
    await prefs.setBool(
      _keyCategorizeOutputByMode,
      config.categorizeOutputByMode,
    );
    await prefs.setBool(_keyHardwareEncode, config.hardwareEncode);
  }
}
