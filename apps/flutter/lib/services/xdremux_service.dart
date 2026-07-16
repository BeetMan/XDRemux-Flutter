import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Resolve the ffmpeg executable path, checking the app's own directory first
/// (bundled distribution) before falling back to PATH.
String _resolveFfmpeg() {
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
      final result = await Process.run(ffmpeg, [
        '-y',
        '-i',
        inputPath,
        '-vf',
        'scale=min($maxPixelSize\\,iw):min($maxPixelSize\\,ih):force_original_aspect_ratio=decrease',
        '-f',
        'image2pipe',
        '-c:v',
        'png',
        'pipe:1',
      ], runInShell: false);
      if (result.exitCode == 0 && result.stdout is List<int>) {
        return Uint8List.fromList(result.stdout as List<int>);
      }
    } catch (_) {
      // ffmpeg not available — return null (UI shows placeholder)
    }
    return null;
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
