import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/l10n/l10n.dart';
import 'package:xdremux/services/conversion_backend.dart';
import 'package:xdremux/services/xdremux_service.dart';

/// iOS on-device smoke (iPhone, real Rust FFI):
///
/// 1. Service-level conversion of a plain OPPO HEIC and a Motion Photo still.
/// 2. Live Photo pair composition (HEIC still + MOV) from the original Motion
///    Photo and validation that the content identifiers match — the exact
///    condition Apple Photos requires to show the Live Photo badge.
/// 3. Bilingual settings switch (English) through the real settings UI.
///
/// Inputs are bundled as app assets (integration_test/assets/) and staged
/// into the app Documents container by the test itself, so no external file
/// staging is required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS service: OPPO conversion + Live Photo pair', (tester) async {
    final documents = await getApplicationDocumentsDirectory();
    final photoIn = '${documents.path}/photo1.heic';
    final motionIn = '${documents.path}/motion1.jpg';
    // Stage the bundled fixtures into the container (Rust FFI reads paths).
    for (final (asset, dest) in [
      ('integration_test/assets/photo1.heic', photoIn),
      ('integration_test/assets/motion1.jpg', motionIn),
    ]) {
      final bytes = await rootBundle.load(asset);
      // ByteData.buffer may have a non-zero offset; slice with offset+length
      // or the staged file is shifted and no longer starts with FFD8.
      await File(dest).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }
    expect(File(photoIn).existsSync(), isTrue);
    expect(File(motionIn).existsSync(), isTrue);

    // 1. Plain OPPO ProXDR conversion.
    final photoOut = '${documents.path}/photo1_iso.heic';
    final r1 = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: 'ios-it-photo',
        backend: ConversionBackend.rust,
        outputMode: OutputMode.oppo,
        inputPath: photoIn,
        outputPath: photoOut,
        oppoCompat: OppoCompatMode.on.rustValue,
        oppoCameraTail: OppoCameraTailMode.preserve.rustValue,
        strictTmap: false,
      ),
    );
    expect(r1.success, isTrue, reason: r1.errorMessage);
    expect(await XdRemuxService.verifyOutput(photoOut), isTrue);

    // 2. Motion Photo still conversion (Ultra HDR JPEG input).
    final motionOut = '${documents.path}/motion1_iso.heic';
    final r2 = await XdRemuxService.convertWithBackend(
      ConversionRequest(
        id: 'ios-it-motion',
        backend: ConversionBackend.rust,
        outputMode: OutputMode.oppo,
        inputPath: motionIn,
        outputPath: motionOut,
        oppoCompat: OppoCompatMode.on.rustValue,
        oppoCameraTail: OppoCameraTailMode.preserve.rustValue,
        strictTmap: false,
      ),
    );
    expect(r2.success, isTrue, reason: r2.errorMessage);
    expect(await XdRemuxService.verifyOutput(motionOut), isTrue);

    // 3. Compose the Apple Live Photo pair (still + paired MOV).
    final report = XdRemuxFFI.makeLivePhoto(
      motionIn,
      motionOut,
      documents.path,
    );
    expect(
      report['success'],
      isTrue,
      reason: report['errorMessage']?.toString(),
    );
    final pairedStill = report['stillPath'] as String;
    final pairedMov = report['videoPath'] as String;
    expect(File(pairedStill).existsSync(), isTrue);
    expect(File(pairedMov).existsSync(), isTrue);

    // 4. Content identifiers must match on both sides — the condition Apple
    // Photos uses to recognize a Live Photo.
    expect(XdRemuxFFI.livePhotoPairValid(pairedStill, pairedMov), isTrue);
  });

  testWidgets('iOS bilingual: settings switch', (tester) async {
    await tester.pumpWidget(const XdRemuxApp());
    await tester.pump();
    // Let _initAsync finish in real time.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    // Dismiss a leftover resume dialog so the queue starts empty.
    final discard = find.text(t('放弃', 'Discard'));
    if (discard.evaluate().isNotEmpty) {
      await tester.tap(discard.first);
      await tester.pumpAndSettle();
    }
    expect(find.text('XDRemux'), findsOneWidget);

    await tester.tap(find.byTooltip(t('设置', 'Settings')));
    await tester.pumpAndSettle();
    expect(find.text(t('转换设置', 'Settings')), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<AppLanguage>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(uiLanguage, AppLanguage.english);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('General'), findsOneWidget);
  });
}
