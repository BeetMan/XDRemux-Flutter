import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/conversion_backend.dart';

void main() {
  test('Rust is the default backend and survives config round-trip', () {
    final config = ConversionConfig();
    expect(config.backend, ConversionBackend.rust);

    final restored = ConversionConfig.fromJson(config.toJson());
    expect(restored.backend, ConversionBackend.rust);
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
