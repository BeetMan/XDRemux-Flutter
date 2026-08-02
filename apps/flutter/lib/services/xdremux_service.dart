import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Higher-level service that wraps raw FFI calls and manages settings.
class XdRemuxService {
  XdRemuxService._();

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
    return Isolate.run(() {
      final result = progressHandle != 0
          ? XdRemuxFFI.convertWithProgress(
              inputPath,
              outputPath,
              progressHandle: progressHandle,
              oppoCompat: oppoCompat,
              oppoCameraTail: oppoCameraTail,
              strictTmap: strictTmap,
            )
          : XdRemuxFFI.convert(
              inputPath,
              outputPath,
              oppoCompat: oppoCompat,
              oppoCameraTail: oppoCameraTail,
              strictTmap: strictTmap,
            );
      final map = {
        'success': result.success,
        'mode': result.mode.toDartStringOrNull(),
        'family': result.family.toDartStringOrNull(),
        'edrScale': result.edrScale,
        'gainMapMax': result.gainMapMax,
        'errorMessage': result.errorMessage.toDartStringOrNull(),
      };
      XdRemuxFFI.freeResult(result);
      return map;
    });
  }

  // -----------------------------------------------------------------------
  // Verify output
  // -----------------------------------------------------------------------

  static Future<bool> verifyOutput(String path) async {
    return XdRemuxFFI.verifyOutput(path);
  }

  // -----------------------------------------------------------------------
  // Thumbnails
  // -----------------------------------------------------------------------

  /// Generate a thumbnail PNG/JPEG data from a HEIC/JPG input file.
  ///
  /// macOS/iOS: native ImageIO decode (full-resolution HEIC, HDR tone-mapped)
  /// so the photo wall is crisp. Other platforms: Rust FFI extracts the
  /// embedded EXIF JPEG thumbnail.
  static Future<Uint8List?> generateThumbnail(
    String inputPath, {
    int maxPixelSize = 320,
  }) async {
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        const channel = MethodChannel('xdremux/thumbnail');
        return await channel.invokeMethod<Uint8List>('render', {
          'path': inputPath,
          'maxPixelSize': maxPixelSize,
        });
      } catch (e) {
        print('generateThumbnail native error: $e');
      }
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

  /// Cached thumbnail for a file. Generates on first call and caches the result.
  static Future<Uint8List?> getThumbnail(
    String inputPath, {
    int maxPixelSize = 320,
  }) async {
    final key = '$inputPath@$maxPixelSize';
    if (_thumbnailCache.containsKey(key)) return _thumbnailCache[key];
    final result = await generateThumbnail(inputPath, maxPixelSize: maxPixelSize);
    _thumbnailCache[key] = result;
    return result;
  }

  /// Invalidate all cached thumbnails (e.g. after clearing queue).
  static void clearThumbnailCache() {
    _thumbnailCache.clear();
  }

  // -----------------------------------------------------------------------
  // Settings persistence
  // -----------------------------------------------------------------------

  static const _keyFamily = 'family';
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
      family: Family.values.firstWhere(
        (e) => e.name == prefs.getString(_keyFamily),
        orElse: () => Family.auto,
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
    await prefs.setString(_keyFamily, config.family.name);
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
        _keyCategorizeOutputByMode, config.categorizeOutputByMode);
    await prefs.setBool(_keyHardwareEncode, config.hardwareEncode);
  }
}
