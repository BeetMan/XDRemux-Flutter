import '../ffi/xdremux_ffi.dart';
import 'background_ffi.dart';
import 'xdremux_service.dart';

/// What the organize page needs for one scanned photo, read off the UI
/// isolate.
class OrganizeScanResult {
  const OrganizeScanResult({
    required this.classification,
    required this.livePhotoMovPath,
  });

  /// [XdRemuxService.classify] fields, or null when classification threw (the
  /// page marks such a photo `unreadable-image`, as it always has).
  final Map<String, dynamic>? classification;

  /// The same-basename MOV, when its content identifiers match the photo's
  /// (a validated Apple Live Photo pair); otherwise null.
  final String? livePhotoMovPath;
}

/// Classifies one photo for the organize page, and validates its
/// same-basename MOV as a Live Photo pair, on a background isolate.
///
/// Both FFI calls read the whole file: ~12 ms to classify a 10 MB OPPO HEIC
/// on an M-series Mac, several times that on a phone. On the root isolate a
/// folder of hundreds or thousands of photos froze the UI for many seconds.
class OrganizeScanProbe {
  OrganizeScanProbe._();

  /// Probe [path], with [companionMovPath] as its candidate Live Photo video.
  ///
  /// Never throws, so a probe started ahead of the photo being added cannot
  /// surface as an unhandled async error: a failed classification comes back
  /// as a null [OrganizeScanResult.classification], and the pair is still
  /// checked, as the scan used to do.
  static Future<OrganizeScanResult> run(
    String path, {
    String? companionMovPath,
  }) async {
    try {
      return await _probeInBackground(path, companionMovPath);
    } catch (_) {
      // Classification threw on the background isolate and again on the
      // root isolate (BackgroundFfi retries there).
      var paired = false;
      if (companionMovPath != null) {
        try {
          paired = await _pairInBackground(path, companionMovPath);
        } catch (_) {}
      }
      return OrganizeScanResult(
        classification: null,
        livePhotoMovPath: paired ? companionMovPath : null,
      );
    }
  }

  /// Synchronous body of [run]: the same FFI calls, in the same order, that
  /// the scan used to make on the root isolate. Throws when classification
  /// does.
  static OrganizeScanResult probeSync(String path, {String? companionMovPath}) {
    final classification = XdRemuxService.classifySync(path);
    final paired =
        companionMovPath != null &&
        XdRemuxFFI.livePhotoPairValid(path, companionMovPath);
    return OrganizeScanResult(
      classification: classification,
      livePhotoMovPath: paired ? companionMovPath : null,
    );
  }

  // The isolate closures are built in these non-async helpers so that they
  // capture only the two path strings.
  static Future<OrganizeScanResult> _probeInBackground(
    String path,
    String? companionMovPath,
  ) => BackgroundFfi.run(
    () => probeSync(path, companionMovPath: companionMovPath),
    label: 'organize-scan',
  );

  static Future<bool> _pairInBackground(String path, String movPath) =>
      BackgroundFfi.run(
        () => XdRemuxFFI.livePhotoPairValid(path, movPath),
        label: 'organize-pair',
      );
}
