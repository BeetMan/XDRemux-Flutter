import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Resolve the ffmpeg executable path, checking the app's own directory first
/// (bundled distribution) before falling back to PATH.
String _resolveFfmpeg() {
  try {
    // On Windows, check next to our own executable first.
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final bundled = File('${exeDir.path}\\ffmpeg.exe');
      if (bundled.existsSync()) return bundled.path;
    } else if (Platform.isMacOS) {
      // macOS app bundle: check Frameworks and executable directory.
      final exeDir = File(Platform.resolvedExecutable).parent;
      final bundled = File('${exeDir.path}/ffmpeg');
      if (bundled.existsSync()) return bundled.path;
      final frameworksDir = File('${exeDir.path}/../Frameworks/ffmpeg');
      if (frameworksDir.existsSync()) return frameworksDir.path;
      // Homebrew paths (app launched from Finder has minimal PATH).
      const homebrew = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'];
      for (final p in homebrew) {
        if (File(p).existsSync()) return p;
      }
    }
  } catch (e) {
    print('_resolveFfmpeg error: $e');
  }
  // Fall back to whatever is on PATH (or bare name on other platforms).
  return 'ffmpeg';
}

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
  // Convert (runs in background isolate to keep UI responsive)
  // -----------------------------------------------------------------------

  static Future<Map<String, dynamic>> convert(
    String inputPath,
    String outputPath, {
    int oppoCompat = 0,
  }) {
    return Isolate.run(() {
      final result = XdRemuxFFI.convert(inputPath, outputPath, oppoCompat: oppoCompat);
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
  // Thumbnails (via ffmpeg subprocess — cross-platform)
  // -----------------------------------------------------------------------

  /// Generate a thumbnail PNG data from a HEIC/JPG input file.
  ///
  /// Uses ffmpeg to decode and resize to at most [maxPixelSize] on the
  /// longest edge, outputting PNG bytes.
  static Future<Uint8List?> generateThumbnail(
    String inputPath, {
    int maxPixelSize = 320,
  }) async {
    try {
      final ffmpeg = _resolveFfmpeg();
      print('generateThumbnail: ffmpeg=$ffmpeg');
      // Output PNG (not rawvideo) so Image.memory() can decode it.
      // Use -s (simple scale) to avoid complex filtergraph errors on HEIC.
      final result = await Process.run(ffmpeg, [
        '-y',
        '-ss', '0',
        '-i', inputPath,
        '-vframes', '1',
        '-s', '${maxPixelSize}x${maxPixelSize}',
        '-f', 'image2pipe',
        '-c:v', 'png',
        'pipe:1',
      ], runInShell: false, stdoutEncoding: null);
      if (result.exitCode == 0 && result.stdout is List<int> && result.stdout.isNotEmpty) {
        return Uint8List.fromList(result.stdout as List<int>);
      }
      // ffmpeg binary output should be List<int>; if it's String (e.g. error
      // message), print a snippet for debugging.
      final stdoutSnippet = result.stdout is String
          ? (result.stdout as String).substring(0, (result.stdout as String).length.clamp(0, 200))
          : 'type=${result.stdout.runtimeType} len=${result.stdout.length}';
      print('generateThumbnail: exit=${result.exitCode}, stdoutSnippet=$stdoutSnippet, stderr=${result.stderr.toString().substring(0, result.stderr.toString().length.clamp(0, 200))}');
    } catch (e, st) {
      print('generateThumbnail ERROR: $e');
      print(st);
    }
    return null;
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
  static const _keySkipExisting = 'skipExisting';
  static const _keyMaxConcurrentJobs = 'maxConcurrentJobs';
  static const _keyFileNameSuffix = 'fileNameSuffix';

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
        orElse: () => OppoCompatMode.off,
      ),
      skipExisting: prefs.getBool(_keySkipExisting) ?? true,
      maxConcurrentJobs: prefs.getInt(_keyMaxConcurrentJobs) ?? 4,
      fileNameSuffix: prefs.getString(_keyFileNameSuffix) ?? '_iso',
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
    await prefs.setBool(_keySkipExisting, config.skipExisting);
    await prefs.setInt(_keyMaxConcurrentJobs, config.maxConcurrentJobs);
    await prefs.setString(_keyFileNameSuffix, config.fileNameSuffix);
  }
}
