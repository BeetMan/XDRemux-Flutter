import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/background_ffi.dart';
import 'package:xdremux/services/import_probe.dart';

/// Set only on the root isolate: a spawned isolate starts with fresh statics,
/// like a native library that only the root isolate managed to open.
class _RootOnly {
  static String? value;
}

void main() {
  tearDown(() {
    BackgroundFfi.resetForTesting();
    _RootOnly.value = null;
  });

  group('BackgroundFfi', () {
    test('runs the call on a background isolate', () async {
      final name = await BackgroundFfi.run(
        () => Isolate.current.debugName,
        label: 'probe',
      );
      expect(name, 'xdremux-probe');
      expect(BackgroundFfi.rootIsolateOnly, isFalse);
    });

    test('falls back to the root isolate when only a spawned one fails',
        () async {
      _RootOnly.value = 'root';
      final value = await BackgroundFfi.run(
        () => _RootOnly.value!,
        label: 'fallback',
      );
      expect(value, 'root');
      expect(BackgroundFfi.rootIsolateOnly, isTrue);

      // Later calls stay on the root isolate instead of failing again.
      final name = await BackgroundFfi.run(
        () => Isolate.current.debugName,
        label: 'after-fallback',
      );
      expect(name, Isolate.current.debugName);
    });

    test('rethrows a call that fails everywhere and keeps using isolates',
        () async {
      await expectLater(
        BackgroundFfi.run<int>(() => throw StateError('boom'), label: 'fail'),
        throwsStateError,
      );
      expect(BackgroundFfi.rootIsolateOnly, isFalse);
    });
  });

  group('ImportProbe', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('import_probe'));
    tearDown(() => temp.deleteSync(recursive: true));

    for (final name in ['not-a-photo.heic', 'not-a-photo.jpg']) {
      test('background probe matches the root-isolate probe for $name',
          () async {
        final file = File('${temp.path}/$name')
          ..writeAsBytesSync(List<int>.generate(4096, (i) => i % 251));

        final background = await ImportProbe.run(file.path);
        final root = ImportProbe.probeSync(file.path);

        expect(BackgroundFfi.rootIsolateOnly, isFalse);
        expect(background.isConvertedOutput, isFalse);
        expect(background.isConvertedOutput, root.isConvertedOutput);
        expect(background.classification, root.classification);
        expect(background.huaweiReport, root.huaweiReport);
        expect(background.motionReport, root.motionReport);
        expect(background.motionPhoto, isNull);
        if (name.endsWith('.jpg')) expect(background.huaweiReport, isEmpty);
      });
    }
  });
}
