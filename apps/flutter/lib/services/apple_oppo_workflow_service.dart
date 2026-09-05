import 'dart:io';

import '../models/app_models.dart';
import '../l10n/l10n.dart';
import 'conversion_backend.dart';
import 'xdremux_service.dart';

/// The Apple/OPPO round-trip is intentionally separate from the ordinary
/// queue conversion path. The selected OPPO photo is both the conversion
/// input and the donor for the later writeback: its camera tail carries the
/// watermark and metadata in their most complete form, so no intermediate
/// OPPO-baseline file is produced.
class AppleOppoWorkflowService {
  AppleOppoWorkflowService._();

  /// Single-pass conversion from the selected OPPO photo to an Apple
  /// Photographic Styles editing copy (Apple 标准 + styleData).
  ///
  /// Converting the original photo directly is deliberate: an intermediate
  /// OPPO-compatible file already carries a gain map and tmap, and running
  /// the styles pipeline on it produced a duplicate gain map graph.
  static Future<String> createAppleStylesCopy({
    required String sourcePath,
    required String outputPath,
    ConversionBackend backend = ConversionBackend.rust,
    AppleWatermarkPolicy watermarkPolicy = AppleWatermarkPolicy.preserve,
    void Function(String message)? onStatus,
  }) async {
    onStatus?.call(
      t('正在生成 Apple 照片摄影风格编辑副本…', 'Generating Apple Photographic Styles edit copy…'),
    );
    final result = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: _requestID('styles'),
        backend: backend,
        outputMode: OutputMode.apple,
        inputPath: sourcePath,
        outputPath: outputPath,
        oppoCompat: OppoCompatMode.off.rustValue,
        oppoCameraTail: OppoCameraTailMode.off.rustValue,
        strictTmap: false,
        applePhotographicStyles: true,
        appleWatermarkPolicy: watermarkPolicy,
      ),
    );
    if (!result.success || result.outputValid == false) {
      throw AppleOppoWorkflowException(
        t(
          'Apple 照片摄影风格编辑副本生成失败：${result.errorMessage ?? '输出校验失败'}',
          'Failed to generate the Apple Photographic Styles edit copy: ${result.errorMessage ?? 'output verification failed'}',
        ),
      );
    }
    return outputPath;
  }

  static Future<Map<String, dynamic>> writebackReturnedPhoto({
    required String? donorPath,
    required String returnedPath,
    required String outputPath,
    required OutputMode outputMode,
    required bool restoreWatermark,
    void Function(String message)? onStatus,
  }) async {
    if (outputMode == OutputMode.oppo && donorPath == null) {
      throw AppleOppoWorkflowException(
        t(
          'OPPO 输出需要 OPPO 原始照片作为写回来源。',
          'OPPO output requires the original OPPO photo as the writeback source.',
        ),
      );
    }
    onStatus?.call(t('正在写回回传照片…', 'Writing back the returned photo…'));
    return XdRemuxService.writebackReturnedPhoto(
      originalPath: donorPath,
      returnedPath: returnedPath,
      outputPath: outputPath,
      outputMode: outputMode,
      restoreWatermark: restoreWatermark,
    );
  }

  /// Preserve an Apple Photos return file without attempting OPPO writeback.
  ///
  /// This iOS-only path performs a file-level pass-through. It does not
  /// generate Apple Photographic Styles metadata, invoke Swift, or claim that
  /// the returned file is an Apple Styles candidate. The native thumbnail
  /// bridge is used as a lightweight readability check before the result is
  /// exposed to the user.
  static Future<Map<String, dynamic>> preserveAppleReturnedPhoto({
    required String returnedPath,
    required String outputPath,
    void Function(String message)? onStatus,
  }) async {
    if (!Platform.isIOS) {
      throw AppleOppoWorkflowException(
        t(
          'Apple 直通输出目前只在 iOS 文件工作流中使用。',
          'Apple pass-through output is currently only used in the iOS file workflow.',
        ),
      );
    }
    final returned = File(returnedPath);
    if (!await returned.exists() || await returned.length() == 0) {
      throw AppleOppoWorkflowException(
        t(
          '回传文件不存在或为空。',
          'The returned file does not exist or is empty.',
        ),
      );
    }
    onStatus?.call(t('正在保留 Apple 回传文件…', 'Preserving the Apple returned file…'));
    await returned.copy(outputPath);
    final thumbnail = await XdRemuxService.generateThumbnail(outputPath);
    if (thumbnail == null || thumbnail.isEmpty) {
      try {
        await File(outputPath).delete();
      } catch (_) {}
      throw AppleOppoWorkflowException(
        t(
          'Apple 照片回传文件无法由 iOS ImageIO 读取。',
          'The Apple Photos returned file cannot be read by iOS ImageIO.',
        ),
      );
    }
    return <String, dynamic>{
      'outputPath': outputPath,
      'outputMode': OutputMode.apple.name,
      'outputValid': true,
      'passthrough': true,
    };
  }

  static String _requestID(String stage) =>
      'apple-oppo-$stage-${DateTime.now().microsecondsSinceEpoch}';
}

class AppleOppoWorkflowException implements Exception {
  final String message;

  const AppleOppoWorkflowException(this.message);

  @override
  String toString() => message;
}
