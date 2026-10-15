import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/motion_photo_service.dart';
import 'package:xdremux/services/output_export_service.dart';

class FakeDestination implements OutputExportDestination {
  @override
  final String operatingSystem;
  final calls = <String>[];
  final albums = <String?>[];
  List<String>? shared;
  bool? originals;
  bool permission = true;
  bool failVideo = false;
  bool failImage = false;
  bool failLive = false;
  bool failShare = false;
  Directory? copies;
  FakeDestination(this.operatingSystem);
  @override
  Future<bool> galleryPermission() async {
    calls.add('permission');
    return permission;
  }

  @override
  Future<void> saveImage(String path, String? album) async {
    calls.add('image');
    albums.add(album);
    if (failImage) throw StateError('image write failed');
    if (copies != null) {
      await File(
        path,
      ).copy('${copies!.path}/${File(path).uri.pathSegments.last}');
    }
  }

  @override
  Future<void> saveVideo(String path, String? album) async {
    calls.add('video');
    albums.add(album);
    if (failVideo) throw StateError('video write failed');
    if (copies != null) {
      await File(
        path,
      ).copy('${copies!.path}/${File(path).uri.pathSegments.last}');
    }
  }

  @override
  Future<void> saveLivePhoto(String still, String movie) async {
    calls.add('live');
    if (failLive) throw PlatformException(code: 'live_photo_save_failed');
  }

  @override
  Future<void> share(List<String> paths, {required bool originals}) async {
    calls.add('share');
    if (failShare) throw StateError('share unavailable');
    shared = List.of(paths);
    this.originals = originals;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late QueueItem pair;
  late FakeDestination destination;
  late OutputExportService service;
  var validations = 0;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('xdremux-export-test-');
    final still = '${temp.path}/out.heic';
    pair = QueueItem(
      id: 'pair',
      inputPath: '${temp.path}/source.heic',
      outputPath: still,
      status: QueueItemStatus.converted,
      motionPhoto: const MotionPhotoSummary(
        kind: 'oppoLivePhoto',
        stillBytes: 1,
        videoBytes: 1,
        streamCount: 1,
      ),
    );
    await File(
      still,
    ).writeAsBytes(utf8.encode('fake still: routing test, not a valid HEIF'));
    await File(
      livePhotoMoviePath(still),
    ).writeAsBytes(utf8.encode('fake movie: routing test'));
    validations = 0;
    destination = FakeDestination('android');
    service = OutputExportService(
      destination: destination,
      validatePair: (s, m) async {
        validations++;
        return true;
      },
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('Android saves both resources with the selected album', () async {
    final result = await service.save(pair, album: 'Portrait');
    expect(result.success, true);
    expect(result.savedResources, 2);
    expect(result.kind, GalleryExportKind.independentPair);
    expect(destination.calls, ['permission', 'image', 'video']);
    expect(destination.albums, ['Portrait', 'Portrait']);
    expect(validations, 1);
    expect(result.message, contains('两个独立文件'));
  });
  test(
    'missing MOV refuses all writes and shares, never still-only fallback',
    () async {
      await File(livePhotoMoviePath(pair.outputPath)).delete();
      final result = await service.save(pair);
      expect(result.success, false);
      expect(result.savedResources, 0);
      expect(destination.calls, isEmpty);
      await expectLater(service.share(pair), throwsStateError);
      expect(destination.calls, isEmpty);
    },
  );
  test('empty MOV is rejected before permission or media writes', () async {
    await File(livePhotoMoviePath(pair.outputPath)).writeAsBytes([]);
    expect((await service.save(pair)).success, false);
    expect(destination.calls, isEmpty);
  });
  test('mismatched pair IDs refuse export', () async {
    service = OutputExportService(
      destination: destination,
      validatePair: (s, m) async => false,
    );
    expect((await service.save(pair)).savedResources, 0);
    await expectLater(service.share(pair), throwsStateError);
    expect(destination.calls, isEmpty);
  });
  test(
    'Android movie failure is partial failure, not complete success',
    () async {
      destination.failVideo = true;
      final result = await service.save(pair);
      expect(result.success, false);
      expect(result.partial, true);
      expect(result.savedResources, 1);
      expect(result.expectedResources, 2);
      expect(result.message, contains('部分'));
      expect(await File(pair.outputPath).exists(), true);
      expect(await File(livePhotoMoviePath(pair.outputPath)).exists(), true);
    },
  );
  test('image failure does not proceed to the video', () async {
    destination.failImage = true;
    final result = await service.save(pair);
    expect(result.partial, false);
    expect(result.success, false);
    expect(destination.calls, ['permission', 'image']);
  });
  test('permission denial has no writes and no success', () async {
    destination.permission = false;
    expect((await service.save(pair)).success, false);
    expect(destination.calls, ['permission']);
  });
  test(
    'iOS uses one PhotoKit transaction, not separate image/video writes',
    () async {
      destination = FakeDestination('ios');
      service = OutputExportService(
        destination: destination,
        validatePair: (s, m) async => true,
      );
      final result = await service.save(
        pair,
        album: 'Not promised on add-only access',
      );
      expect(result.success, true);
      expect(result.kind, GalleryExportKind.livePhoto);
      expect(destination.calls, ['live']);
    },
  );
  test('iOS permission/import failure never falls back to a still', () async {
    destination = FakeDestination('ios')..failLive = true;
    service = OutputExportService(
      destination: destination,
      validatePair: (s, m) async => true,
    );
    final result = await service.save(pair);
    expect(result.success, false);
    expect(result.savedResources, 0);
    expect(destination.calls, ['live']);
  });
  test(
    'pair sharing sends both original paths and propagates failure',
    () async {
      await service.share(pair);
      expect(destination.shared, [
        pair.outputPath,
        livePhotoMoviePath(pair.outputPath),
      ]);
      expect(destination.originals, true);
      destination.failShare = true;
      await expectLater(service.share(pair), throwsStateError);
    },
  );
  test(
    'ordinary still and split mode never attach a stale sibling MOV',
    () async {
      for (final mode in [
        MotionPhotoMode.still,
        MotionPhotoMode.stillAndVideo,
      ]) {
        pair.motionPhotoMode = mode;
        destination.calls.clear();
        expect((await service.save(pair)).expectedResources, 1);
        expect(destination.calls, ['permission', 'image']);
        await service.share(pair);
        expect(destination.shared, [pair.outputPath]);
        expect(destination.originals, false);
      }
      expect(validations, 0);
    },
  );
  test(
    'skipped native motion photo shares its input, not a nonexistent conversion',
    () async {
      pair.status = QueueItemStatus.skippedPolicy;
      await File(pair.outputPath).copy(pair.inputPath);
      await service.share(pair);
      expect(destination.shared, [pair.inputPath]);
      expect(validations, 0);
    },
  );
  test('batch counts items only after the complete bundle saves', () async {
    destination.failVideo = true;
    final photo = QueueItem(
      id: 'photo',
      inputPath: 'unused',
      outputPath: pair.outputPath,
      status: QueueItemStatus.converted,
    );
    final result = await service.saveBatch([
      pair,
      photo,
    ], albumFor: (_) => 'Batch');
    expect(result.saved, 1);
    expect(result.failed, 1);
    expect(result.partial, 1);
    expect(result.message, contains('1 项仅保存部分文件'));
  });
  test(
    'non-mobile gallery save fails explicitly but both files can be shared',
    () async {
      destination = FakeDestination('windows');
      service = OutputExportService(
        destination: destination,
        validatePair: (s, m) async => true,
      );
      expect((await service.save(pair)).success, false);
      expect(destination.calls, isEmpty);
      await service.share(pair);
      expect(destination.shared!.length, 2);
    },
  );
  test(
    'native Dart adapter sends both paths and observes PhotoKit result',
    () async {
      const channel = MethodChannel('xdremux/live-photo');
      final calls = <MethodCall>[];
      var accepted = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return accepted;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const adapter = NativeOutputExportDestination();
      await adapter.saveLivePhoto(
        pair.outputPath,
        livePhotoMoviePath(pair.outputPath),
      );
      expect(calls.single.method, 'saveLivePhoto');
      expect(calls.single.arguments, {
        'stillPath': pair.outputPath,
        'videoPath': livePhotoMoviePath(pair.outputPath),
      });
      accepted = false;
      await expectLater(
        adapter.saveLivePhoto(
          pair.outputPath,
          livePhotoMoviePath(pair.outputPath),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'native gallery adapter selects putImage and putVideo, not two images',
    () async {
      const channel = MethodChannel('gal');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const adapter = NativeOutputExportDestination();
      await adapter.saveImage(pair.outputPath, 'Pair');
      await adapter.saveVideo(livePhotoMoviePath(pair.outputPath), 'Pair');
      // gal requests access internally before each media write as well.
      expect(
        calls.where((c) => c.method.startsWith('put')).map((c) => c.method),
        ['putImage', 'putVideo'],
      );
      expect(
        (calls.last.arguments as Map)['path'],
        livePhotoMoviePath(pair.outputPath),
      );
    },
  );
  const oppoSample = r'C:\Users\Beet\Desktop\Find X10\IMG20260910130211.jpg';
  test(
    'real OPPO dual-stream conversion exports a valid complete pair',
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
      final before = sha256
          .convert(await File(oppoSample).readAsBytes())
          .toString();
      final converted = XdRemuxFFI.convert(oppoSample, pair.outputPath);
      final convertedOk = converted.success;
      final conversionError = converted.errorMessage.toDartStringOrNull();
      XdRemuxFFI.freeResult(converted);
      expect(convertedOk, true, reason: conversionError);
      await MotionPhotoService.composeLivePhoto(oppoSample, pair.outputPath);
      final movie = livePhotoMoviePath(pair.outputPath);
      final originalHashes = [
        for (final path in [pair.outputPath, movie])
          sha256.convert(await File(path).readAsBytes()).toString(),
      ];
      destination.copies = await Directory('${temp.path}/oppo-export').create();
      service = OutputExportService(destination: destination);
      expect((await service.save(pair)).success, true);
      final exportedStill = '${destination.copies!.path}/out.heic';
      final exportedMovie = '${destination.copies!.path}/out.mov';
      expect(XdRemuxFFI.livePhotoPairValid(exportedStill, exportedMovie), true);
      expect([
        for (final path in [exportedStill, exportedMovie])
          sha256.convert(await File(path).readAsBytes()).toString(),
      ], originalHashes);
      expect(
        sha256.convert(await File(oppoSample).readAsBytes()).toString(),
        before,
      );
    },
    skip: !File(oppoSample).existsSync()
        ? 'Private OPPO fixture unavailable'
        : false,
  );

  const sample =
      r'C:\tmp\huawei\portrait-motion-20260907\IMG_20260907_021031.heic';
  test(
    'real FFI pair survives complete file export byte-for-byte',
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
      final before = sha256
          .convert(await File(sample).readAsBytes())
          .toString();
      await File(sample).copy(pair.outputPath);
      await MotionPhotoService.composeLivePhoto(sample, pair.outputPath);
      final movie = livePhotoMoviePath(pair.outputPath);
      expect(XdRemuxFFI.livePhotoPairValid(pair.outputPath, movie), true);
      final hashes = [
        for (final p in [pair.outputPath, movie])
          sha256.convert(await File(p).readAsBytes()).toString(),
      ];
      destination.copies = await Directory('${temp.path}/export').create();
      // The default validator calls the actual Rust core, not a fake validator.
      service = OutputExportService(destination: destination);
      expect((await service.save(pair)).success, true);
      final savedStill = '${destination.copies!.path}/out.heic';
      final savedMovie = '${destination.copies!.path}/out.mov';
      expect(XdRemuxFFI.livePhotoPairValid(savedStill, savedMovie), true);
      expect([
        for (final p in [savedStill, savedMovie])
          sha256.convert(await File(p).readAsBytes()).toString(),
      ], hashes);
      expect(
        sha256.convert(await File(sample).readAsBytes()).toString(),
        before,
      );
      await service.share(pair);
      expect(destination.shared, [pair.outputPath, movie]);
    },
    skip: !File(sample).existsSync()
        ? 'Private real-media fixture unavailable'
        : false,
  );
}
