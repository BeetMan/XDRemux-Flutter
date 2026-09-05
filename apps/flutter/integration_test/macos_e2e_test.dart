import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/l10n/l10n.dart';
import 'package:xdremux/services/xdremux_service.dart';

/// macOS end-to-end smoke: real app launch, real ingestion through the native
/// drop MethodChannel, per-card Motion Photo policy, real conversion via the
/// Rust FFI, output validation, and a bilingual settings switch.
///
/// Inputs are OPPO ProXDR originals from ../test-media (copied to /tmp with
/// ASCII names). The app sandbox is disabled so arbitrary paths are readable.
///
/// The persisted UI language is not reset between runs (NSUserDefaults is
/// cached by cfprefsd), so assertions resolve text through [t] — the same
/// resolver the app uses — making the test robust to any starting locale.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const repoRoot = '/Users/beet/Documents/XDRemux Playground';
  const workDir = '/tmp/xdremux-macos-it';

  testWidgets('macOS e2e: drop, convert, verify, bilingual switch', (
    tester,
  ) async {
    // Stage inputs with ASCII names.
    final dir = Directory(workDir);
    await dir.create(recursive: true);
    final heicIn = '$workDir/photo1.heic';
    final motionIn = '$workDir/motion1.jpg';
    await File(
      '$repoRoot/test-media/sources/oppo-camera-heic/IMG20260807131731.heic',
    ).copy(heicIn);
    await File(
      '$repoRoot/test-media/sources/oppo-motion-photos/标准 1x.jpg',
    ).copy(motionIn);

    await tester.pumpWidget(const XdRemuxApp());
    await tester.pump();
    // Let _initAsync (loadConfig + capability probe) finish in real time.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    // A leftover checkpoint from a previous run may surface a resume dialog;
    // dismiss it so the queue starts empty for a deterministic test.
    final discard = find.text(t('放弃', 'Discard'));
    if (discard.evaluate().isNotEmpty) {
      await tester.tap(discard.first);
      await tester.pumpAndSettle();
    }

    // Home renders. (The desktop layout has no 'add files' Text — it is a
    // toolbar tooltip — so launch is asserted via the locale-independent
    // app title instead.)
    expect(find.text('XDRemux'), findsOneWidget);

    // Simulate the native window dropping files: the app registered a handler
    // on 'xdremux/drop'; deliver the platform message as if from macOS.
    final dropCall = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onFilesDropped', [heicIn, motionIn]),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'xdremux/drop',
      dropCall,
      (_) {},
    );
    // Ingestion is async: classify + skipExisting + motion inspect per file.
    // Poll (runAsync waits real time; pump renders) until the queue appears.
    var queued = false;
    for (var i = 0; i < 20 && !queued; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      queued = find.textContaining(t('个文件', 'files')).evaluate().isNotEmpty;
    }
    expect(queued, isTrue, reason: 'files were not ingested into the queue');
    expect(find.text('photo1.heic'), findsOneWidget);
    expect(find.text('motion1.jpg'), findsOneWidget);

    // Only motion1.jpg is a Motion Photo; the plain HEIC has no policy menu.
    final menus = find.byType(PopupMenuButton<MotionPhotoMode>);
    expect(menus, findsOneWidget);
    await tester.tap(menus.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('静帧+视频', 'Still + video')).last);
    await tester.pumpAndSettle();

    // Start the batch.
    await tester.tap(find.text(t('开始转换', 'Start conversion')));
    await tester.pump();

    // Poll the real output files until both exist (HEVC encode takes seconds).
    // Output naming keeps the original extension in the stem:
    // photo1.heic -> photo1_iso.heic, motion1.jpg -> motion1.jpg_iso.heic.
    final heicOut = File('$workDir/photo1_iso.heic');
    final motionOut = File('$workDir/motion1.jpg_iso.heic');
    var done = false;
    for (var i = 0; i < 90 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      done = heicOut.existsSync() && motionOut.existsSync();
    }
    expect(heicOut.existsSync(), isTrue, reason: 'photo1 output missing');
    expect(motionOut.existsSync(), isTrue, reason: 'motion1 output missing');

    // Outputs are valid ISO HDR HEIC.
    expect(await XdRemuxService.verifyOutput(heicOut.path), isTrue);
    expect(await XdRemuxService.verifyOutput(motionOut.path), isTrue);

    // Batch-complete status is set slightly after the last file lands; poll
    // for the status text rather than asserting immediately.
    var completed = false;
    for (var i = 0; i < 20 && !completed; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      completed = find
          .textContaining(t('全部完成', 'All done'))
          .evaluate()
          .isNotEmpty;
    }
    expect(completed, isTrue, reason: 'batch-complete status not shown');

    // Bilingual: switch to English through the settings sheet UI.
    await tester.tap(find.byTooltip(t('设置', 'Settings')));
    await tester.pumpAndSettle();
    expect(find.text(t('转换设置', 'Settings')), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<AppLanguage>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    // After selecting English the global language flips and the sheet follows.
    expect(uiLanguage, AppLanguage.english);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('General'), findsOneWidget);

    // Close the sheet; the home page follows the new language. After a
    // completed batch the primary action becomes the completed-output
    // actions, so assert on those (English) rather than 'Start conversion'.
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    expect(find.text('Clear completed'), findsOneWidget);
    expect(find.text('Open output directory'), findsOneWidget);
  });
}
