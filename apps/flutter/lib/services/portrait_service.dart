import 'package:flutter/foundation.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Thin async wrapper over the Rust Portrait Depth FFI.
///
/// Detection is best-effort: malformed inputs or non-portrait files resolve
/// to null (treated as ordinary photos) so a non-portrait file never blocks
/// the main queue or batch conversion flow.
class PortraitService {
  PortraitService._();

  /// Inspect [path] and return a [PortraitSummary] when it carries OPPO portrait depth (rear.depth).
  static Future<PortraitSummary?> inspect(String path) async {
    try {
      final report = XdRemuxFFI.inspectPortrait(path);
      if (report['hasPortrait'] != true) return null;
      return PortraitSummary.fromJson(report);
    } catch (e) {
      debugPrint('[XDRemux][portrait] inspect failed for $path: $e');
      return null;
    }
  }
}
