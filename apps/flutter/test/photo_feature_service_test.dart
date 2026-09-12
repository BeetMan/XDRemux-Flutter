import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/photo_feature_service.dart';

void main() {
  test(
    'inspection barrier includes queued work and survives failures',
    () async {
      final first = Completer<PhotoFeatureInspection>();
      final second = Completer<PhotoFeatureInspection>();
      final started = <String>[];
      final service = PhotoFeatureService(
        inspect: (path) {
          started.add(path);
          return path == 'first' ? first.future : second.future;
        },
      );
      final result1 = service.inspect('first');
      var idle = false;
      final barrier = service.waitUntilIdle().then((_) => idle = true);
      final result2 = service.inspect('second');
      await Future<void>.delayed(Duration.zero);
      expect(started, ['first']);
      expect(idle, false);
      first.completeError(StateError('malformed'));
      expect((await result1).portrait, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['first', 'second']);
      expect(idle, false);
      second.complete(const PhotoFeatureInspection());
      await result2;
      await barrier;
      expect(idle, true);
    },
  );

  test(
    'extraction failure removes its temporary directory without fallback',
    () async {
      String? temporary;
      await expectLater(
        PhotoFeatureService.prepareBasePhoto(
          '/original.jpg',
          extract: (source, destination) async {
            expect(source, '/original.jpg');
            temporary = destination;
            await File(destination).writeAsString('partial');
            throw StateError('invalid base');
          },
        ),
        throwsStateError,
      );
      expect(File(temporary!).parent.existsSync(), false);
    },
  );

  test('base leases are unique and cleaned after conversion failure', () async {
    Future<void> extract(String source, String destination) =>
        File(destination).writeAsString('base');
    final first = await PhotoFeatureService.prepareBasePhoto(
      'original',
      extract: extract,
    );
    final second = await PhotoFeatureService.prepareBasePhoto(
      'original',
      extract: extract,
    );
    expect(first.path, isNot(second.path));
    try {
      await expectLater(
        Future<void>.error(StateError('conversion failure')),
        throwsStateError,
      );
    } finally {
      await first.dispose();
      await second.dispose();
    }
    expect(File(first.path).parent.existsSync(), false);
    expect(File(second.path).parent.existsSync(), false);
  });
}
