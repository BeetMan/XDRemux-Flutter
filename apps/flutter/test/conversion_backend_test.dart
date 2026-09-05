import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/l10n/l10n.dart';
import 'package:xdremux/services/conversion_backend.dart';

void main() {
  test('language selection survives config round-trip', () {
    final config = ConversionConfig(language: AppLanguage.english);
    final restored = ConversionConfig.fromJson(config.toJson());
    expect(restored.language, AppLanguage.english);
  });

  test('Rust is the default backend and survives config round-trip', () {
    final config = ConversionConfig();
    expect(config.backend, ConversionBackend.rust);
    expect(config.outputMode, OutputMode.oppo);

    final restored = ConversionConfig.fromJson(config.toJson());
    expect(restored.backend, ConversionBackend.rust);
    expect(restored.outputMode, OutputMode.oppo);
  });

  test('OPPO and Apple output modes survive config round-trip', () {
    final config = ConversionConfig(
      outputMode: OutputMode.apple,
      oppoCompatibility: OppoCompatMode.off,
      oppoCameraTail: OppoCameraTailMode.off,
    );
    final restored = ConversionConfig.fromJson(config.toJson());
    expect(restored.outputMode, OutputMode.apple);
    expect(restored.oppoCompatibility, OppoCompatMode.off);
    expect(restored.oppoCameraTail, OppoCameraTailMode.off);
  });

  test('Apple feature flags survive config round-trip', () {
    final config = ConversionConfig(
      backend: ConversionBackend.swift,
      applePhotographicStyles: true,
      applePortrait: true,
    );
    final restored = ConversionConfig.fromJson(config.toJson());
    expect(restored.backend, ConversionBackend.swift);
    expect(restored.applePhotographicStyles, isTrue);
    expect(restored.applePortrait, isTrue);
  });

  test('Rust Apple feature requests are available independently of Swift', () {
    const request = ConversionRequest(
      id: 'rust-apple-features-test',
      backend: ConversionBackend.rust,
      outputMode: OutputMode.apple,
      inputPath: 'input.heic',
      outputPath: 'output.heic',
      oppoCompat: 0,
      oppoCameraTail: 0,
      strictTmap: false,
      applePhotographicStyles: true,
      applePortrait: true,
    );
    expect(request.applePhotographicStyles, isTrue);
    expect(request.applePortrait, isTrue);
  });

  test(
    'workflow watermark policy defaults to preserve and exposes isolate',
    () {
      const request = ConversionRequest(
        id: 'workflow-test',
        backend: ConversionBackend.swift,
        inputPath: 'input.heic',
        outputPath: 'output.heic',
        oppoCompat: 0,
        oppoCameraTail: 0,
        strictTmap: false,
      );
      expect(request.appleWatermarkPolicy, AppleWatermarkPolicy.preserve);
      const isolated = ConversionRequest(
        id: 'workflow-isolate-test',
        backend: ConversionBackend.swift,
        inputPath: 'input.heic',
        outputPath: 'output.heic',
        oppoCompat: 0,
        oppoCameraTail: 0,
        strictTmap: false,
        appleWatermarkPolicy: AppleWatermarkPolicy.isolate,
      );
      expect(isolated.appleWatermarkPolicy, AppleWatermarkPolicy.isolate);
    },
  );

  test('Swift visibility follows Apple platform gating', () {
    final capabilities = BackendCapabilities.forCurrentPlatform();
    expect(capabilities.swiftVisible, Platform.isMacOS || Platform.isIOS);
    expect(capabilities.isAvailable(ConversionBackend.rust), isTrue);
    expect(capabilities.isAvailable(ConversionBackend.swift), isFalse);
    expect(capabilities.swiftPhotographicStyles, isFalse);
    expect(capabilities.swiftPortrait, isFalse);
  });

  test('backend result exposes cancellation and validation state', () {
    final result = BackendConversionResult.failure(
      ConversionBackend.swift,
      'not linked',
      cancelled: true,
    );
    expect(result.toMap(), containsPair('cancelled', true));
    expect(result.toMap(), containsPair('backend', 'swift'));
    expect(result.outputValid, isNull);
  });
}
