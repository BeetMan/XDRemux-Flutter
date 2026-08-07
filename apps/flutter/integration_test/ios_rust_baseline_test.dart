import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/conversion_backend.dart';
import 'package:xdremux/services/xdremux_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS Rust baseline converts an input in the app container', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final input = File(
      '${documents.path}${Platform.pathSeparator}IMG20260807131731.heic',
    );
    final output = File(
      '${documents.path}${Platform.pathSeparator}ios-rust-smoke.oppo-baseline.heic',
    );

    expect(
      await input.exists(),
      isTrue,
      reason:
          'Copy IMG20260807131731.heic into the app Documents container before running this device smoke test.',
    );

    final capabilities = await XdRemuxService.getBackendCapabilities();
    expect(capabilities.swiftVisible, isTrue);
    expect(capabilities.swiftAvailable, isFalse);
    expect(capabilities.swiftPhotographicStyles, isFalse);
    expect(capabilities.swiftPortrait, isFalse);

    final result = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: 'ios-rust-baseline-smoke',
        backend: ConversionBackend.rust,
        outputMode: OutputMode.oppo,
        inputPath: input.path,
        outputPath: output.path,
        oppoCompat: OppoCompatMode.on.rustValue,
        oppoCameraTail: OppoCameraTailMode.preserve.rustValue,
        strictTmap: false,
      ),
    );

    expect(result.success, isTrue, reason: result.errorMessage);
    final outputValid = await XdRemuxService.verifyOutputForBackend(
      ConversionBackend.rust,
      output.path,
    );
    expect(outputValid, isTrue);
    expect(await output.exists(), isTrue);
    expect(await output.length(), greaterThan(0));
  });
}
