import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// One conversion request shared by all backend implementations.
class ConversionRequest {
  final String id;
  final ConversionBackend backend;
  final String inputPath;
  final String outputPath;
  final int oppoCompat;
  final int oppoCameraTail;
  final bool strictTmap;
  final int progressHandle;

  const ConversionRequest({
    required this.id,
    required this.backend,
    required this.inputPath,
    required this.outputPath,
    required this.oppoCompat,
    required this.oppoCameraTail,
    required this.strictTmap,
    this.progressHandle = 0,
  });
}

/// Backend-neutral progress snapshot.
class BackendProgress {
  final int stage;
  final int current;
  final int total;

  const BackendProgress({this.stage = 0, this.current = 0, this.total = 0});
}

/// Backend-neutral conversion result and error/cancellation state.
class BackendConversionResult {
  final ConversionBackend backend;
  final bool success;
  final bool cancelled;
  final bool? outputValid;
  final String? mode;
  final String? family;
  final double edrScale;
  final double gainMapMax;
  final String? errorMessage;

  const BackendConversionResult({
    required this.backend,
    required this.success,
    this.cancelled = false,
    this.outputValid,
    this.mode,
    this.family,
    this.edrScale = 0,
    this.gainMapMax = 0,
    this.errorMessage,
  });

  factory BackendConversionResult.failure(
    ConversionBackend backend,
    String message, {
    bool cancelled = false,
  }) {
    return BackendConversionResult(
      backend: backend,
      success: false,
      cancelled: cancelled,
      errorMessage: message,
    );
  }

  BackendConversionResult copyWith({
    bool? success,
    bool? cancelled,
    bool? outputValid,
    String? errorMessage,
  }) {
    return BackendConversionResult(
      backend: backend,
      success: success ?? this.success,
      cancelled: cancelled ?? this.cancelled,
      outputValid: outputValid ?? this.outputValid,
      mode: mode,
      family: family,
      edrScale: edrScale,
      gainMapMax: gainMapMax,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toMap() => {
    'success': success,
    'cancelled': cancelled,
    'outputValid': outputValid,
    'mode': mode,
    'family': family,
    'edrScale': edrScale,
    'gainMapMax': gainMapMax,
    'errorMessage': errorMessage,
    'backend': backend.name,
  };
}

/// Internal adapter contract. New backends must provide the same request,
/// progress, cancellation, error, and output-validation surface.
abstract class ConversionBackendAdapter {
  ConversionBackend get backend;

  Future<BackendConversionResult> convert(ConversionRequest request);

  BackendProgress readProgress(ConversionRequest request);

  Future<bool> verifyOutput(String path);

  /// Cancellation is best-effort until the native backend exposes a true
  /// interruption primitive. The coordinator still prevents a cancelled
  /// request from being reported as converted.
  void cancel(String requestId);
}

/// Adapter for the existing Rust FFI path. Its conversion arguments and
/// progress handles are intentionally unchanged from the v0.2.x path.
class RustConversionBackend implements ConversionBackendAdapter {
  final Set<String> _cancelledRequests = <String>{};

  @override
  ConversionBackend get backend => ConversionBackend.rust;

  @override
  Future<BackendConversionResult> convert(ConversionRequest request) async {
    if (_cancelledRequests.remove(request.id)) {
      return BackendConversionResult.failure(backend, '转换已取消', cancelled: true);
    }

    final result = await Isolate.run(() {
      final ffiResult = request.progressHandle != 0
          ? XdRemuxFFI.convertWithProgress(
              request.inputPath,
              request.outputPath,
              progressHandle: request.progressHandle,
              oppoCompat: request.oppoCompat,
              oppoCameraTail: request.oppoCameraTail,
              strictTmap: request.strictTmap,
            )
          : XdRemuxFFI.convert(
              request.inputPath,
              request.outputPath,
              oppoCompat: request.oppoCompat,
              oppoCameraTail: request.oppoCameraTail,
              strictTmap: request.strictTmap,
            );
      try {
        return BackendConversionResult(
          backend: ConversionBackend.rust,
          success: ffiResult.success,
          mode: ffiResult.mode.toDartStringOrNull(),
          family: ffiResult.family.toDartStringOrNull(),
          edrScale: ffiResult.edrScale,
          gainMapMax: ffiResult.gainMapMax,
          errorMessage: ffiResult.errorMessage.toDartStringOrNull(),
        );
      } finally {
        XdRemuxFFI.freeResult(ffiResult);
      }
    });

    if (_cancelledRequests.remove(request.id)) {
      return result.copyWith(
        success: false,
        cancelled: true,
        errorMessage: '转换已取消',
      );
    }
    return result;
  }

  @override
  BackendProgress readProgress(ConversionRequest request) {
    if (request.progressHandle == 0) return const BackendProgress();
    final (stage, current, total) = XdRemuxFFI.readProgressFor(
      request.progressHandle,
    );
    return BackendProgress(stage: stage, current: current, total: total);
  }

  @override
  Future<bool> verifyOutput(String path) async {
    return XdRemuxFFI.verifyOutput(path);
  }

  @override
  void cancel(String requestId) {
    _cancelledRequests.add(requestId);
  }
}

/// Adapter for the embedded Swift Library contract.
///
/// The native channel intentionally has no CLI fallback. Until the Swift Core
/// is linked, calls return a clear unavailable error and the UI keeps this
/// backend disabled through capability detection.
class SwiftConversionBackend implements ConversionBackendAdapter {
  static const MethodChannel _channel = MethodChannel('xdremux/swift-backend');

  @override
  ConversionBackend get backend => ConversionBackend.swift;

  @override
  Future<BackendConversionResult> convert(ConversionRequest request) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('convert', {
        'requestId': request.id,
        'inputPath': request.inputPath,
        'outputPath': request.outputPath,
        'oppoCompat': request.oppoCompat,
        'oppoCameraTail': request.oppoCameraTail,
        'strictTmap': request.strictTmap,
      });
      final result = _parseResult(raw);
      if (!result.success) return result;

      // Swift output validation is deliberately a Swift-side operation. It
      // will later include Apple metadata/manifest checks rather than using
      // the Rust validator as a proxy.
      final valid = await verifyOutput(request.outputPath);
      if (!valid) {
        return result.copyWith(
          success: false,
          outputValid: false,
          errorMessage: 'Swift 后端输出验证失败',
        );
      }
      return result.copyWith(outputValid: true);
    } on MissingPluginException {
      return BackendConversionResult.failure(
        backend,
        'Swift 后端未连接：当前构建未嵌入 Swift Core。',
      );
    } on PlatformException catch (error) {
      return BackendConversionResult.failure(
        backend,
        error.message ?? 'Swift 后端调用失败（${error.code}）',
      );
    } catch (error) {
      return BackendConversionResult.failure(backend, 'Swift 后端调用失败：$error');
    }
  }

  BackendConversionResult _parseResult(Object? raw) {
    if (raw is! Map) {
      return BackendConversionResult.failure(backend, 'Swift 后端返回了无效结果');
    }
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    return BackendConversionResult(
      backend: backend,
      success: map['success'] == true,
      mode: map['mode'] as String?,
      family: map['family'] as String?,
      edrScale: (map['edrScale'] as num?)?.toDouble() ?? 0,
      gainMapMax: (map['gainMapMax'] as num?)?.toDouble() ?? 0,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  @override
  BackendProgress readProgress(ConversionRequest request) {
    // P0.0 reserves the common surface. P0.1 will stream native progress
    // events through this same request id.
    return const BackendProgress();
  }

  @override
  Future<bool> verifyOutput(String path) async {
    try {
      return await _channel.invokeMethod<bool>('verifyOutput', {
            'path': path,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  void cancel(String requestId) {
    unawaited(
      _channel
          .invokeMethod<void>('cancel', {'requestId': requestId})
          .catchError((_) {}),
    );
  }
}
