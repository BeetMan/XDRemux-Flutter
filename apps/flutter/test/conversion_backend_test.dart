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

  test('Swift visibility follows Apple platform gating', () {
    final capabilities = BackendCapabilities.forCurrentPlatform();
    expect(capabilities.swiftVisible, Platform.isMacOS || Platform.isIOS);
    expect(capabilities.isAvailable(ConversionBackend.rust), isTrue);
    expect(capabilities.isAvailable(ConversionBackend.swift), isFalse);
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
