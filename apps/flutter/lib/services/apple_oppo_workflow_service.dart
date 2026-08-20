import 'dart:io';
import 'dart:typed_data';

import '../models/app_models.dart';
import 'conversion_backend.dart';
import 'xdremux_service.dart';

/// The five-stage Apple/OPPO round-trip is intentionally separate from the
/// ordinary queue conversion path. The ordinary path remains one input to one
/// output; this service owns the baseline and returned-photo relationship.
class AppleOppoWorkflowService {
  AppleOppoWorkflowService._();

  static Future<String> ensureBaseline({
    required String sourcePath,
    required String baselinePath,
    bool sourceIsBaseline = false,
    void Function(String message)? onStatus,
  }) async {
    if (sourceIsBaseline && await _isValidOutput(sourcePath)) {
      onStatus?.call('已选择有效 OPPO baseline');
      return sourcePath;
    }
    if (baselinePath != sourcePath && await _isReusableBaseline(baselinePath)) {
      onStatus?.call('复用已有 OPPO baseline');
      return baselinePath;
    }

    onStatus?.call('正在生成 OPPO baseline…');
    final result = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: _requestID('baseline'),
        backend: ConversionBackend.rust,
        outputMode: OutputMode.oppo,
        inputPath: sourcePath,
        outputPath: baselinePath,
        // The baseline is the donor for later writeback, so retain the full
        // OPPO-compatible route and camera tail.
        oppoCompat: OppoCompatMode.on.rustValue,
        oppoCameraTail: OppoCameraTailMode.preserve.rustValue,
        strictTmap: false,
      ),
    );
    if (!result.success || result.outputValid == false) {
      throw AppleOppoWorkflowException(
        'OPPO baseline 生成失败：${result.errorMessage ?? '输出校验失败'}',
      );
    }
    return baselinePath;
  }

  static Future<String> createAppleStylesCopy({
    required String baselinePath,
    required String outputPath,
    ConversionBackend backend = ConversionBackend.rust,
    AppleWatermarkPolicy watermarkPolicy = AppleWatermarkPolicy.preserve,
    void Function(String message)? onStatus,
  }) async {
    onStatus?.call('正在生成 Apple 照片摄影风格编辑副本…');
    final result = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: _requestID('styles'),
        backend: backend,
        outputMode: OutputMode.apple,
        inputPath: baselinePath,
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
        'Apple 照片摄影风格编辑副本生成失败：${result.errorMessage ?? '输出校验失败'}',
      );
    }
    return outputPath;
  }

  static Future<Map<String, dynamic>> writebackReturnedPhoto({
    required String? baselinePath,
    required String returnedPath,
    required String outputPath,
    required OutputMode outputMode,
    required bool restoreWatermark,
    void Function(String message)? onStatus,
  }) async {
    if (outputMode == OutputMode.oppo && baselinePath == null) {
      throw const AppleOppoWorkflowException('OPPO 输出需要 baseline donor。');
    }
    onStatus?.call('正在写回回传照片…');
    return XdRemuxService.writebackReturnedPhoto(
      originalPath: baselinePath,
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
      throw const AppleOppoWorkflowException('Apple 直通输出目前只在 iOS 文件工作流中使用。');
    }
    final returned = File(returnedPath);
    if (!await returned.exists() || await returned.length() == 0) {
      throw const AppleOppoWorkflowException('回传文件不存在或为空。');
    }
    onStatus?.call('正在保留 Apple 回传文件…');
    await returned.copy(outputPath);
    final thumbnail = await XdRemuxService.generateThumbnail(outputPath);
    if (thumbnail == null || thumbnail.isEmpty) {
      try {
        await File(outputPath).delete();
      } catch (_) {}
      throw const AppleOppoWorkflowException('Apple 照片回传文件无法由 iOS ImageIO 读取。');
    }
    return <String, dynamic>{
      'outputPath': outputPath,
      'outputMode': OutputMode.apple.name,
      'outputValid': true,
      'passthrough': true,
    };
  }

  static Future<bool> _isReusableBaseline(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      if (!await _isValidOutput(path)) return false;
      final bytes = await file.readAsBytes();
      return _containsAnyMarker(bytes, const [
        'watermark.',
        'local.',
        'master.mode.preset.info',
        'hdr.transform.data',
      ]);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isValidOutput(String path) {
    return XdRemuxService.verifyOutputForBackend(ConversionBackend.rust, path);
  }

  static bool _containsAnyMarker(Uint8List bytes, List<String> markers) {
    return markers.any((marker) {
      final needle = Uint8List.fromList(marker.codeUnits);
      if (needle.length > bytes.length) return false;
      for (var start = 0; start <= bytes.length - needle.length; start++) {
        var matches = true;
        for (var index = 0; index < needle.length; index++) {
          if (bytes[start + index] != needle[index]) {
            matches = false;
            break;
          }
        }
        if (matches) return true;
      }
      return false;
    });
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
