import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

class PhotoFeatureInspection {
  final PhotographicStyleSummary? style;
  final PortraitSummary? portrait;
  final bool portraitInspectionAvailable;
  const PhotoFeatureInspection({this.style, this.portrait, this.portraitInspectionAvailable = false});

  void applyTo(QueueItem item) {
    item.photographicStyle = style;
    item.portraitInspectionAvailable = portraitInspectionAvailable;
    // Preserve a restored summary when the current library cannot inspect it.
    if (portraitInspectionAvailable) item.portrait = portrait;
  }
}

/// Serial background inspection limits simultaneous full-image reads. The
/// barrier is also used at batch start; no late result can change its policy.
class PhotoFeatureService {
  Future<void> _pending = Future<void>.value();
  final Future<PhotoFeatureInspection> Function(String) _inspect;

  PhotoFeatureService({
    Future<PhotoFeatureInspection> Function(String)? inspect,
  }) : _inspect = inspect ?? _inspectInBackground;

  Future<PhotoFeatureInspection> inspect(String path) {
    final result = _pending
        .then((_) => _inspect(path))
        .catchError((Object _) => const PhotoFeatureInspection());
    _pending = result.then((_) {});
    return result;
  }

  Future<void> waitUntilIdle() async {
    // Include work queued while a previous inspection was being awaited.
    while (true) {
      final pending = _pending;
      await pending;
      if (identical(pending, _pending)) return;
    }
  }

  static Future<PhotoFeatureInspection> _inspectInBackground(String path) =>
      Isolate.run(() {
        PhotographicStyleSummary? style;
        PortraitSummary? portrait;
        var portraitInspectionAvailable = false;
        // Independent best-effort APIs: a bad recipe must not hide depth.
        try {
          final report = XdRemuxFFI.photographicStyleInspect(path);
          if (report['hasPhotographicStyle'] == true) {
            style = PhotographicStyleSummary.fromJson(report);
          }
        } catch (_) {}
        try {
          final report = XdRemuxFFI.inspectPortrait(path);
          portraitInspectionAvailable = report['hasPortrait'] is bool &&
              report['inspectionUnavailable'] != true;
          if (report['hasPortrait'] == true) {
            portrait = PortraitSummary.fromJson(report);
          }
        } catch (_) {}
        return PhotoFeatureInspection(style: style, portrait: portrait,
          portraitInspectionAvailable: portraitInspectionAvailable);
      });

  /// The native API uses exclusive creation and validates the embedded JPEG.
  /// Bytes and embedded EXIF/orientation are preserved, not synthesized from
  /// the outer styled photo. An invalid base is an error, never a fallback.
  static Future<void> extractBase(String input, String output) async {
    final report = await Isolate.run(
      () => XdRemuxFFI.extractBasePhoto(input, output),
    );
    if (report['success'] != true) {
      throw StateError(
        report['errorMessage'] as String? ?? 'Base extraction failed',
      );
    }
  }

  static Future<bool> _isConvertibleBase(String path) => Isolate.run(() {
    final result = XdRemuxFFI.inspect(path);
    try {
      return result.success;
    } finally {
      XdRemuxFFI.freeResult(result);
    }
  });

  /// Extract before touching any existing output. Failed extraction cleans up
  /// immediately; successful callers own the lease until conversion finishes.
  static Future<TemporaryBasePhoto> prepareBasePhoto(
    String source, {
    Future<void> Function(String, String)? extract,
    bool requireUltraHdr = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp('xdremux-base-');
    final input = TemporaryBasePhoto._(directory);
    try {
      await (extract ?? extractBase)(source, input.path);
      if (requireUltraHdr && !await _isConvertibleBase(input.path)) {
        throw StateError(
          'Convert base requires an Ultra HDR JPEG with a valid gain map. Use Extract base for a raw JPEG export.',
        );
      }
      return input;
    } catch (_) {
      await input.dispose();
      rethrow;
    }
  }
}

class TemporaryBasePhoto {
  final Directory _directory;
  TemporaryBasePhoto._(this._directory);
  String get path => '${_directory.path}${Platform.pathSeparator}base.jpg';
  Future<void> dispose() => _directory.delete(recursive: true);
}
