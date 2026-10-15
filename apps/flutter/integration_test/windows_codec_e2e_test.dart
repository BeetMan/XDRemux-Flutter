import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/services/codec_diagnostics.dart';
import 'package:xdremux/services/xdremux_service.dart';

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => '$root/profile';
  @override
  Future<String?> getTemporaryPath() async => '$root/cache';
}

/// Real Windows runner and real core. Only preferences/profile and native
/// thumbnail failure are mocked. No system picker or Photos acceptance claim.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixtureRoot = String.fromEnvironment('CODEC_TEST_ROOT');
  const appleRoot = String.fromEnvironment('APPLE_JPEG_TEST_ROOT');
  testWidgets('Windows app: drop, previews, settings, batch, failure isolation', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    expect(
      fixtureRoot,
      isNotEmpty,
      reason: 'Pass --dart-define=CODEC_TEST_ROOT=<controls-02>',
    );
    expect(
      appleRoot,
      isNotEmpty,
      reason:
          'Pass --dart-define=APPLE_JPEG_TEST_ROOT=<libultrahdr/tests/data>',
    );
    final root = Directory.systemTemp.createTempSync('xdremux-windows-app-');
    Directory('${root.path}/profile').createSync();
    Directory('${root.path}/cache').createSync();
    final output = Directory('${root.path}/output')..createSync();
    PathProviderPlatform.instance = _TestPaths(root.path);
    SharedPreferences.setMockInitialValues({
      'language': 'chinese',
      'backend': 'rust',
      'outputMode': 'apple',
      'outputDirectory': output.path,
      'applePhotographicStyles': true,
      'skipExisting': false,
      'maxConcurrentJobs': 1,
      'categorizeOutputByMode': false,
      'hardwareEncode': false,
    });
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
    // Exercise the fallback irrespective of installed Windows HEIF extensions.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xdremux/thumbnail'),
      (_) async => null,
    );
    final names = [
      'synthetic-422-10bit.heic',
      'synthetic-444-10bit.heic',
      'synthetic-444-rotated.heic',
      'apple_gainmap_old.jpg',
      'apple_gainmap_new.jpg',
    ];
    final inputs = <String>[];
    final hashes = <String, String>{};
    for (final name in names) {
      final source = File(
        '${name.endsWith('.jpg') ? appleRoot : fixtureRoot}/$name',
      );
      expect(source.existsSync(), isTrue);
      final copy = source.copySync('${root.path}/$name');
      inputs.add(copy.path);
      hashes[copy.path] = sha256.convert(copy.readAsBytesSync()).toString();
    }
    final bad = File('${root.path}/malformed.jpg')
      ..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
    inputs.add(bad.path);
    hashes[bad.path] = sha256.convert(bad.readAsBytesSync()).toString();
    await tester.pumpWidget(const XdRemuxApp());
    await tester.pump();
    Future<void> until(bool Function() ready, String reason) async {
      for (var i = 0; i < 120; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
        if (ready()) return;
      }
      fail(reason);
    }

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'xdremux/drop',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onFilesDropped', inputs),
      ),
      (_) {},
    );
    await until(
      () => find.text(names.first).evaluate().isNotEmpty,
      'drop intake did not populate queue',
    );
    // Duplicate drop is deduplicated by the real home-page ingestion path.
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'xdremux/drop',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onFilesDropped', [inputs.first]),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.text(names.first), findsOneWidget);
    final previews = await tester.runAsync(() async {
      final result = <int>[];
      for (final path in inputs.take(5)) {
        final bytes = await XdRemuxService.getThumbnail(
          path,
          maxPixelSize: 128,
        );
        expect(bytes, isNotNull);
        expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        result.add(bytes.length);
      }
      return result;
    });
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final stylesToggle = find.widgetWithText(
      SwitchListTile,
      'Apple 照片摄影风格（Rust）',
    );
    await tester.ensureVisible(stylesToggle);
    expect(tester.widget<SwitchListTile>(stylesToggle).value, true);
    await tester.tap(stylesToggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(stylesToggle).value, false);
    await tester.tap(stylesToggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(stylesToggle).value, true);
    await tester.ensureVisible(find.text('Codec 能力与诊断'));
    await tester.tap(find.text('Codec 能力与诊断'));
    await tester.pumpAndSettle();
    expect(find.text('导出 JSON'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // Dismiss settings with navigator, retaining the actual config controls.
    Navigator.of(tester.element(find.text('转换设置'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始转换').first);
    await tester.pump();
    await until(
      () => find.textContaining('完成：成功 5').evaluate().isNotEmpty,
      'batch did not finish with 5 successes and one isolated failure',
    );
    final outputs = output
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.heic'))
        .toList();
    expect(outputs, hasLength(5));
    for (final file in outputs) {
      expect(XdRemuxFFI.verifyOutput(file.path), isTrue);
      expect(XdRemuxFFI.verifyStylesOutput(file.path), isTrue);
    }
    for (final entry in hashes.entries) {
      expect(
        sha256.convert(File(entry.key).readAsBytesSync()).toString(),
        entry.value,
      );
    }
    final facts = await tester.runAsync(CodecDiagnostics.capabilities);
    expect(facts!['libheif']['hevcDecoderAvailable'], true);
    final report = CodecDiagnostics.report(facts);
    expect(report, isNot(contains(root.path)));
    await File('${root.path}/report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'queued': 6,
        'converted': outputs.length,
        'failed': 1,
        'previewBytes': previews,
        'settingsToggleRoundTrip': true,
        'sourceHashesUnchanged': true,
        'diagnostic': jsonDecode(report),
      }),
    );
    // Keep uniquely-created test artifacts for inspection; never touch user profile.
    // ignore: avoid_print
    print('Windows app regression report: ${root.path}/report.json');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
