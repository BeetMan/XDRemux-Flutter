import 'package:flutter/foundation.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Thin async wrapper over the Rust Photographic Style FFI.
///
/// Detection is best-effort: malformed inputs or non-style files resolve
/// to null (treated as ordinary photos) so a broken file never blocks the
/// main conversion flow.
class PhotographicStyleService {
  PhotographicStyleService._();

  /// Inspect [path] and return a summary when it carries an OPPO Photographic Style with an embedded base image.
  static Future<PhotographicStyleSummary?> inspect(String path) async {
    try {
      final report = XdRemuxFFI.photographicStyleInspect(path);
      if (report['hasPhotographicStyle'] != true) return null;
      return PhotographicStyleSummary(
        styleNameZh: report['styleNameZh'] as String? ?? '摄影风格',
        styleNameEn: report['styleNameEn'] as String? ?? 'Style',
        lutName: report['lutName'] as String? ?? '',
        baseImageBytes: (report['baseImageBytes'] as num?)?.toInt() ?? 0,
        intensity: (report['intensity'] as num?)?.toInt() ?? 100,
        tone: (report['tone'] as num?)?.toInt() ?? 0,
        version: report['version'] as String? ?? '1.0',
      );
    } catch (e) {
      debugPrint('[XDRemux][style] inspect failed for $path: $e');
      return null;
    }
  }

  /// Extract the un-styled base photo from [inputPath] directly to [outputPath].
  static Future<String> extractBasePhoto(
    String inputPath,
    String outputPath,
  ) async {
    final report = XdRemuxFFI.extractBasePhoto(inputPath, outputPath);
    if (report['success'] != true) {
      throw report['errorMessage'] ?? 'extract base photo failed';
    }
    return report['outputPath'] as String? ?? outputPath;
  }
}
