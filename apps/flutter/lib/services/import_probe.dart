import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';
import 'background_ffi.dart';
import 'motion_photo_service.dart';
import 'xdremux_service.dart';

/// Metadata the queue needs for one input photo, read off the UI isolate.
class ImportProbeResult {
  const ImportProbeResult({
    required this.isConvertedOutput,
    required this.classification,
    required this.huaweiReport,
    this.motionReport,
  });

  /// The input already is an XDRemux ISO gain-map output.
  final bool isConvertedOutput;

  /// [XdRemuxService.classify] fields (capture mode, HDR kind, family).
  final Map<String, dynamic> classification;

  /// [XdRemuxService.inspectHuawei] report; empty for non-HEIF inputs.
  final Map<String, dynamic> huaweiReport;

  /// Raw Motion Photo report, or null when inspection failed.
  final Map<String, dynamic>? motionReport;

  /// Motion Photo summary, or null for a still photo or a failed inspection.
  MotionPhotoSummary? get motionPhoto {
    final report = motionReport;
    if (report == null) return null;
    try {
      return MotionPhotoService.summaryFromReport(report);
    } catch (_) {
      return null;
    }
  }
}

/// Runs the per-photo import probes (verify, classify, Huawei inspect and
/// Motion Photo inspect) together on one background isolate.
///
/// Each probe reads and parses the whole file, so on the root isolate a batch
/// of 20–30 picked photos blocked the UI for seconds.
class ImportProbe {
  ImportProbe._();

  /// Probe [path]. [checkConverted] skips the converted-output check, e.g.
  /// for an original donor resolved from a converted file.
  static Future<ImportProbeResult> run(
    String path, {
    bool checkConverted = true,
  }) {
    return BackgroundFfi.run(
      () => probeSync(path, checkConverted: checkConverted),
      label: 'import-probe',
    );
  }

  /// Synchronous body of [run]; the same FFI calls, in the same order, that
  /// the queue intake used to make on the root isolate.
  static ImportProbeResult probeSync(
    String path, {
    bool checkConverted = true,
  }) {
    final converted = checkConverted && XdRemuxFFI.verifyOutput(path);
    final classification = XdRemuxService.classifySync(path);
    final lower = path.toLowerCase();
    final isHeic = lower.endsWith('.heic') || lower.endsWith('.heif');
    final huaweiReport = isHeic
        ? XdRemuxService.inspectHuaweiSync(path)
        : const <String, dynamic>{};
    Map<String, dynamic>? motionReport;
    try {
      motionReport = XdRemuxFFI.motionPhotoInspect(path);
    } catch (_) {
      // Best-effort, like the previous fire-and-forget inspection: a failure
      // leaves the item a static photo.
    }
    return ImportProbeResult(
      isConvertedOutput: converted,
      classification: classification,
      huaweiReport: huaweiReport,
      motionReport: motionReport,
    );
  }
}
