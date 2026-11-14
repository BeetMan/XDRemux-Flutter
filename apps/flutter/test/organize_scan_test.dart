import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/organize_page.dart';
import 'package:xdremux/services/background_ffi.dart';
import 'package:xdremux/services/organize_scan.dart';

/// A stand-in photo. The classifier falls back to scanning raw bytes for an
/// OPPO `Oplus_<flags>` tag, so [tag] is enough to give it a capture mode.
File _photo(Directory dir, String name, {String? tag}) {
  final file = File('${dir.path}/$name')..createSync(recursive: true);
  file.writeAsBytesSync([
    ...List<int>.generate(2048, (i) => i % 251),
    if (tag != null) ...tag.codeUnits,
  ]);
  return file;
}

/// Photos in the order the organize page lists them.
List<File> _listedPhotos(Directory dir) => [
  for (final entity in dir.listSync(recursive: true, followLinks: false))
    if (entity is File &&
        RegExp(
          r'\.(heic|heif|jpe?g)$',
          caseSensitive: false,
        ).hasMatch(entity.path))
      entity,
];

/// Lets the scan's real file I/O and background isolates progress, pumping
/// frames in between, until [done] or a generous timeout.
Future<void> _runScan(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

/// File names shown on each mode group card, keyed by the card title.
Map<String, List<String>> _renderedGroups() {
  final groups = <String, List<String>>{};
  for (final card in find.byType(Card).evaluate()) {
    final texts = find
        .descendant(of: find.byWidget(card.widget), matching: find.byType(Text))
        .evaluate()
        .map((element) => (element.widget as Text).data!)
        .toList();
    // Title, photo count, then one row per photo.
    groups[texts.first] = texts.sublist(2);
  }
  return groups;
}

void main() {
  tearDown(BackgroundFfi.resetForTesting);

  group('OrganizeScanProbe', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('organize_scan'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('background probe matches the root-isolate probe', () async {
      final cases = <String, String?>{
        'night.jpg': 'Oplus_2048',
        'portrait.heic': 'oplus_16',
        'plain.jpeg': null,
      };
      for (final MapEntry(key: name, value: tag) in cases.entries) {
        final photo = _photo(temp, name, tag: tag);
        // Same basename, but not a Live Photo video of this still.
        final mov = File('${temp.path}/${name.split('.').first}.mov')
          ..writeAsBytesSync(List<int>.filled(1024, 7));

        final background = await OrganizeScanProbe.run(
          photo.path,
          companionMovPath: mov.path,
        );
        final root = OrganizeScanProbe.probeSync(
          photo.path,
          companionMovPath: mov.path,
        );

        expect(BackgroundFfi.rootIsolateOnly, isFalse);
        expect(background.classification, isNotNull);
        expect(background.classification, root.classification);
        expect(background.livePhotoMovPath, isNull);
        expect(background.livePhotoMovPath, root.livePhotoMovPath);
      }

      final night = await OrganizeScanProbe.run('${temp.path}/night.jpg');
      expect(night.classification!['modeKey'], 'night');
      final plain = await OrganizeScanProbe.run('${temp.path}/plain.jpeg');
      expect(plain.classification!['modeKey'], isNull);
      expect(plain.classification!['status'], 'missing-user-comment');
    });
  });

  group('OrganizePage scan', () {
    late Directory temp;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('organize_page_scan');
      OrganizePage.inputDirectoryPickerForTesting = () async => temp.path;
    });
    tearDown(() {
      OrganizePage.inputDirectoryPickerForTesting = null;
      temp.deleteSync(recursive: true);
    });

    testWidgets('adds photos in listing order with root-isolate results', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (var i = 0; i < 6; i++) {
        _photo(temp, 'IMG_N$i.jpg', tag: 'oplus_2048');
      }
      for (var i = 0; i < 3; i++) {
        _photo(temp, 'IMG_P$i.heic', tag: 'Oplus_16');
      }
      _photo(temp, 'IMG_U0.jpeg');
      _photo(temp, 'IMG_U1.HEIF');
      _photo(temp, 'nested/IMG_M0.jpg', tag: 'oplus_0');
      File('${temp.path}/IMG_N0.mov').writeAsBytesSync([1, 2, 3]);
      File('${temp.path}/notes.txt').writeAsStringSync('not a photo');

      // What the old loop computed: classification on the root isolate, in
      // listing order.
      final listed = _listedPhotos(temp);
      expect(listed, hasLength(12));
      final expected = <String, List<String>>{};
      for (final file in listed) {
        final classification = OrganizeScanProbe.probeSync(
          file.path,
        ).classification!;
        expected
            .putIfAbsent(
              classification['folderName'] as String? ?? '（未分类）',
              () => [],
            )
            .add(file.uri.pathSegments.last);
      }
      expect(expected.keys, containsAll(['夜景', '人像', '普通拍照', '（未分类）']));

      await tester.pumpWidget(const MaterialApp(home: OrganizePage()));
      await tester.tap(find.text('选择照片目录'));
      final summary = find.text('共 12 张照片，10 张可分类，0 组实况照片');
      await _runScan(tester, () => summary.evaluate().isNotEmpty);

      expect(summary, findsOneWidget);
      expect(_renderedGroups(), expected);
      expect(BackgroundFfi.rootIsolateOnly, isFalse);
    });

    testWidgets('closing the page mid-scan stops the scan cleanly', (
      tester,
    ) async {
      for (var i = 0; i < 40; i++) {
        _photo(temp, 'IMG_$i.jpg', tag: 'oplus_2048');
      }
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const OrganizePage()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('选择照片目录'));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(OrganizePage), findsNothing);

      // Let the probes still in flight finish: nothing may touch the
      // disposed page.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  });
}
