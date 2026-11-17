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
    'an invalid pair is refused before anything at the destination moves',
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
        replace: true,
      );

      expect(report['success'], isFalse);
      expect(report['targetExists'], isFalse);
      expect(report['errorMessage'] as String, contains('nothing was written'));
      expect(await File(outputPath).readAsString(), 'converted still');
      expect(_names(out), ['IMG_1_iso.heic'], reason: 'nothing staged or moved');
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
        replace: true,
      );
      expect(report['success'], isFalse);
      expect(report['errorMessage'], contains('must not overwrite its input'));
      expect(_names(temp), ['IMG_1.heic', 'IMG_1.mov']);
    },
    skip: _coreLoadable ? false : 'Rust core not loadable by this flutter_tester',
  );

  test(
    'a MOV only belongs to the old still when the two pair',
    () async {
      final temp = await Directory.systemTemp.createTemp('xdremux-paired-');
      addTearDown(() => temp.delete(recursive: true));
      final still = '${temp.path}/IMG_1_iso.heic';
      expect(await MotionPhotoService.pairedMovieOf(still), isNull);
      await File(still).writeAsString('converted still');
      expect(await MotionPhotoService.pairedMovieOf(still), isNull);
      // A MOV that does not pair with the still is not the item's to delete.
      await File(livePhotoMoviePath(still)).writeAsString('some movie');
      expect(await MotionPhotoService.pairedMovieOf(still), isNull);
    },
    skip: _coreLoadable ? false : 'Rust core not loadable by this flutter_tester',
  );

  test(
    'composing works when the temporary directory does not exist yet',
    () async {
      final temp = await Directory.systemTemp.createTemp('xdremux-compose-');
      addTearDown(() => temp.delete(recursive: true));
      // macOS hands out ~/Library/Caches/<bundle id>, which may be missing.
      final missing = '${temp.path}/Caches/com.example.xdremux';
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => missing);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final output = '${temp.path}/out/IMG_1_iso.heic';
      // The source is not a Motion Photo, so the core refuses it; what
      // matters is that composing gets as far as the core.
      await expectLater(
        MotionPhotoService.composeLivePhoto('${temp.path}/IMG_1.jpg', output),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot read source'),
          ),
        ),
      );
      expect(Directory(missing).existsSync(), isTrue);
      expect(Directory(missing).listSync(), isEmpty, reason: 'staging removed');
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
        // Converting this item again may delete exactly this MOV with the still.
        expect(await MotionPhotoService.pairedMovieOf(flat), movie);
        expect(
          _names(temp),
          ['标准 1x_iso.heic', '标准 1x_iso.mov'],
          reason: 'no staging or replaced files left behind',
        );
        // Each attempt composes a fresh pairing; the retry replaced both.
        final copyStill = '${temp.path}/copy.heic';
        final copyMovie = '${temp.path}/copy.mov';
        final report = XdRemuxFFI.publishLivePhotoPair(
          flat,
          movie,
          copyStill,
          copyMovie,
          replace: false,
        );
        expect(report['success'], isTrue, reason: '${report['errorMessage']}');
        identifiers.add(report['contentIdentifier'] as String);
        // Without replace, a taken name is refused and left as it is.
        final copied = await File(copyMovie).readAsBytes();
        final again = XdRemuxFFI.publishLivePhotoPair(
          flat,
          movie,
          '${temp.path}/other.heic',
          copyMovie,
          replace: false,
        );
        expect(again['success'], isFalse);
        expect(again['targetExists'], isTrue, reason: '${again['errorMessage']}');
        expect(await File(copyMovie).readAsBytes(), copied);
        expect(File('${temp.path}/other.heic').existsSync(), isFalse);
        await File(copyStill).delete();
        await File(copyMovie).delete();
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
