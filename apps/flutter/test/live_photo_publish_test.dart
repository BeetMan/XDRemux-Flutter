import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/services/motion_photo_service.dart';
import 'package:xdremux/services/output_export_service.dart';

/// Host tests reach the Rust core only when the tester and the library share
/// an architecture; skip rather than fail elsewhere.
final bool _coreLoadable = () {
  try {
    XdRemuxFFI.version();
    return true;
  } catch (_) {
    return false;
  }
}();

List<String> _names(Directory dir) {
  final names = dir
      .listSync()
      .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toList();
  names.sort();
  return names;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a pair that fails verification is rolled back and the still restored',
    () async {
      final temp = await Directory.systemTemp.createTemp('xdremux-publish-');
      addTearDown(() => temp.delete(recursive: true));
      final staging = await Directory('${temp.path}/staging').create();
      final out = await Directory('${temp.path}/out').create();
      // Bytes without content identifiers can never pass the pair check.
      final still = '${staging.path}/IMG_1.heic';
      final movie = '${staging.path}/IMG_1.mov';
      await File(still).writeAsString('not a paired still');
      await File(movie).writeAsString('not a paired movie');
      // The flat path publishes over the converted still.
      final outputPath = '${out.path}/IMG_1_iso.heic';
      await File(outputPath).writeAsString('converted still');

      final report = XdRemuxFFI.publishLivePhotoPair(
        still,
        movie,
        outputPath,
        livePhotoMoviePath(outputPath),
      );

      expect(report['success'], isFalse);
      final message = report['errorMessage'] as String;
      expect(message, contains('failed verification'));
      expect(
        message,
        endsWith(
          'rolled back: removed IMG_1_iso.heic, IMG_1_iso.mov; '
          'restored the previous IMG_1_iso.heic',
        ),
      );
      expect(await File(outputPath).readAsString(), 'converted still');
      expect(_names(out), ['IMG_1_iso.heic'], reason: 'nothing else left');
      expect(await File(still).readAsString(), 'not a paired still');
      expect(await File(movie).readAsString(), 'not a paired movie');
    },
    skip: _coreLoadable ? false : 'Rust core not loadable by this flutter_tester',
  );

  test(
    'the publisher refuses to write over its own input',
    () async {
      final temp = await Directory.systemTemp.createTemp('xdremux-publish-');
      addTearDown(() => temp.delete(recursive: true));
      final still = '${temp.path}/IMG_1.heic';
      final movie = '${temp.path}/IMG_1.mov';
      await File(still).writeAsString('still');
      await File(movie).writeAsString('movie');
      final report = XdRemuxFFI.publishLivePhotoPair(
        still,
        movie,
        still,
        '${temp.path}/other.mov',
      );
      expect(report['success'], isFalse);
      expect(report['errorMessage'], contains('must not overwrite its input'));
      expect(_names(temp), ['IMG_1.heic', 'IMG_1.mov']);
    },
    skip: _coreLoadable ? false : 'Rust core not loadable by this flutter_tester',
  );

  const sample =
      '/Volumes/MacData/XDRemux/test-media/sources/oppo-motion-photos/标准 1x.jpg';
  test(
    'real OPPO conversion publishes a verified flat pair and retries in place',
    () async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => Directory.systemTemp.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final temp = await Directory.systemTemp.createTemp('xdremux-flat-e2e-');
      addTearDown(() => temp.delete(recursive: true));
      final before = sha256.convert(await File(sample).readAsBytes());
      final flat = '${temp.path}/标准 1x_iso.heic';
      final movie = livePhotoMoviePath(flat);
      final identifiers = <String>{};
      for (var attempt = 0; attempt < 2; attempt++) {
        final converted = XdRemuxFFI.convert(sample, flat);
        final ok = converted.success;
        final error = converted.errorMessage.toDartStringOrNull();
        XdRemuxFFI.freeResult(converted);
        expect(ok, isTrue, reason: error);
        final still = await MotionPhotoService.composeLivePhoto(sample, flat);
        expect(still, flat);
        expect(XdRemuxFFI.livePhotoPairValid(flat, movie), isTrue);
        expect(
          _names(temp),
          ['标准 1x_iso.heic', '标准 1x_iso.mov'],
          reason: 'no staging or replaced files left behind',
        );
        // Each attempt composes a fresh pairing; the retry replaced both.
        final report = XdRemuxFFI.publishLivePhotoPair(
          flat,
          movie,
          '${temp.path}/copy.heic',
          '${temp.path}/copy.mov',
        );
        expect(report['success'], isTrue, reason: '${report['errorMessage']}');
        identifiers.add(report['contentIdentifier'] as String);
        await File('${temp.path}/copy.heic').delete();
        await File('${temp.path}/copy.mov').delete();
      }
      expect(identifiers, hasLength(2));
      expect(sha256.convert(await File(sample).readAsBytes()), before);
    },
    skip: !File(sample).existsSync()
        ? 'Local OPPO motion sample unavailable'
        : !_coreLoadable
        ? 'Rust core not loadable by this flutter_tester'
        : false,
  );
}
