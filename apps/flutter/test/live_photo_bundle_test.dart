import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/motion_photo_service.dart';
import 'package:xdremux/services/output_export_service.dart';

class _Destination implements OutputExportDestination {
  @override
  final String operatingSystem;
  final calls = <String>[];
  final saved = <String>[];
  List<String>? shared;
  bool? originals;
  _Destination(this.operatingSystem);
  @override
  Future<bool> galleryPermission() async => true;
  @override
  Future<void> saveImage(String path, String? album) async {
    calls.add('image');
    saved.add(path);
  }

  @override
  Future<void> saveVideo(String path, String? album) async {
    calls.add('video');
    saved.add(path);
  }

  @override
  Future<void> saveLivePhoto(String still, String movie) async {
    calls.add('live');
    saved.addAll([still, movie]);
  }

  @override
  Future<void> share(List<String> paths, {required bool originals}) async {
    calls.add('share');
    shared = List.of(paths);
    this.originals = originals;
  }
}

/// Host tests can only reach the Rust core when the tester and the library
/// share an architecture (the macOS darwin-x64 tester cannot open an arm64
/// core). Skip the real-file test rather than fail on such hosts.
final bool _coreLoadable = () {
  try {
    XdRemuxFFI.version();
    return true;
  } catch (_) {
    return false;
  }
}();

const _plist =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0"><dict><key>PFVideoComplementMetadataVersionKey</key>'
    '<string>1</string></dict></plist>\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundle paths', () {
    test('POSIX bundle paths round-trip', () {
      const flat = '/out/IMG_1_iso.heic';
      const bundled = '/out/IMG_1_iso.pvt/IMG_1_iso.heic';
      expect(livePhotoBundledPath(flat), bundled);
      expect(livePhotoBundleDir(bundled), '/out/IMG_1_iso.pvt');
      expect(livePhotoFlatPath(bundled), flat);
      expect(livePhotoMoviePath(bundled), '/out/IMG_1_iso.pvt/IMG_1_iso.mov');
      expect(livePhotoBundleDir(flat), isNull);
      expect(livePhotoFlatPath(flat), flat);
    });

    test('Windows separators are kept when bundling', () {
      expect(
        livePhotoBundledPath(r'C:\out\实况 1x_iso.heic'),
        r'C:\out\实况 1x_iso.pvt\实况 1x_iso.heic',
      );
    });
  });

  test('bundling setting defaults off and persists', () {
    final config = ConversionConfig();
    expect(config.livePhotoBundle, isFalse);
    config.livePhotoBundle = true;
    expect(ConversionConfig.fromJson(config.toJson()).livePhotoBundle, isTrue);
    expect(config.copy().livePhotoBundle, isTrue);
    final legacy = config.toJson()..remove('livePhotoBundle');
    expect(ConversionConfig.fromJson(legacy).livePhotoBundle, isFalse);
  });

  group('export of a .pvt item', () {
    late Directory temp;
    late QueueItem item;
    late String bundle;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('xdremux-pvt-test-');
      bundle = '${temp.path}/out.pvt';
      await Directory(bundle).create();
      await File('$bundle/out.heic').writeAsString('fake still');
      await File('$bundle/out.mov').writeAsString('fake movie');
      await File('$bundle/metadata.plist').writeAsString(_plist);
      item = QueueItem(
        id: 'pvt',
        inputPath: '${temp.path}/source.jpg',
        outputPath: '$bundle/out.heic',
        status: QueueItemStatus.converted,
        motionPhoto: const MotionPhotoSummary(
          kind: 'oppoLivePhoto',
          stillBytes: 1,
          videoBytes: 1,
          streamCount: 2,
        ),
      );
    });
    tearDown(() => temp.delete(recursive: true));

    OutputExportService service(
      _Destination destination, {
      List<String>? archived,
    }) => OutputExportService(
      destination: destination,
      validatePair: (_, _) async => true,
      archiveBundle: (dir) async {
        archived?.add(dir);
        return '${temp.path}/out.pvt.zip';
      },
    );

    test('share sends one zip of the bundle', () async {
      final destination = _Destination('android');
      final archived = <String>[];
      await service(destination, archived: archived).share(item);
      expect(archived, [bundle]);
      expect(destination.shared, ['${temp.path}/out.pvt.zip']);
      expect(destination.originals, isTrue);
    });

    test('Android saves the inner HEIF + MOV', () async {
      final destination = _Destination('android');
      final result = await service(destination).save(item);
      expect(result.success, isTrue);
      expect(destination.saved, ['$bundle/out.heic', '$bundle/out.mov']);
    });

    test('iOS saves the inner pair as one Live Photo', () async {
      final destination = _Destination('ios');
      final result = await service(destination).save(item);
      expect(result.kind, GalleryExportKind.livePhoto);
      expect(destination.calls, ['live']);
      expect(destination.saved, ['$bundle/out.heic', '$bundle/out.mov']);
    });

    test('a bundle without metadata.plist is refused', () async {
      await File('$bundle/metadata.plist').delete();
      final destination = _Destination('android');
      final result = await service(destination).save(item);
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('metadata.plist'));
      expect(destination.calls, isEmpty);
      await expectLater(service(destination).share(item), throwsStateError);
      expect(destination.shared, isNull);
    });

    test(
      'zip keeps the <name>.pvt/ prefix, skips hidden files, stores bytes',
      () async {
        await File('$bundle/.DS_Store').writeAsString('finder');
        final zip = await zipLivePhotoBundle(bundle);
        expect(zip, endsWith('out.pvt.zip'));
        final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
        final names =
            archive.files.where((f) => f.isFile).map((f) => f.name).toList()
              ..sort();
        expect(names, [
          'out.pvt/metadata.plist',
          'out.pvt/out.heic',
          'out.pvt/out.mov',
        ]);
        final heic = archive.files.firstWhere(
          (f) => f.name == 'out.pvt/out.heic',
        );
        expect(utf8.decode(heic.content), 'fake still');
        await File(zip).parent.delete(recursive: true);
      },
    );
  });

  const sample =
      '/Volumes/MacData/XDRemux/test-media/sources/oppo-motion-photos/标准 1x.jpg';
  test(
    'real OPPO conversion composes a valid .pvt and retries in place',
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
      final temp = await Directory.systemTemp.createTemp('xdremux-pvt-e2e-');
      addTearDown(() => temp.delete(recursive: true));
      final before = sha256.convert(await File(sample).readAsBytes());
      final flat = '${temp.path}/标准 1x_iso.heic';
      for (var attempt = 0; attempt < 2; attempt++) {
        final converted = XdRemuxFFI.convert(sample, flat);
        final ok = converted.success;
        final error = converted.errorMessage.toDartStringOrNull();
        XdRemuxFFI.freeResult(converted);
        expect(ok, isTrue, reason: error);
        final still = await MotionPhotoService.composeLivePhoto(
          sample,
          flat,
          bundle: true,
        );
        expect(still, livePhotoBundledPath(flat));
        expect(
          XdRemuxFFI.livePhotoBundleValid(livePhotoBundleDir(still)!),
          isTrue,
        );
        expect(File(flat).existsSync(), isFalse, reason: 'loose still removed');
        expect(File(livePhotoMoviePath(flat)).existsSync(), isFalse);
        final entries = temp.listSync().map(
          (e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last,
        );
        expect(entries, ['标准 1x_iso.pvt'], reason: 'no staging leftovers');
      }
      final item = QueueItem(
        id: 'real',
        inputPath: sample,
        outputPath: livePhotoBundledPath(flat),
        status: QueueItemStatus.converted,
        motionPhoto: const MotionPhotoSummary(
          kind: 'oppoLivePhoto',
          stillBytes: 1,
          videoBytes: 1,
          streamCount: 2,
        ),
      );
      // Default validator: the actual Rust pair check.
      final files = await OutputExportService(
        destination: _Destination('android'),
      ).filesFor(item);
      expect(files, [item.outputPath, livePhotoMoviePath(item.outputPath)]);
      expect(sha256.convert(await File(sample).readAsBytes()), before);
    },
    skip: !File(sample).existsSync()
        ? 'Local OPPO motion sample unavailable'
        : !_coreLoadable
        ? 'Rust core not loadable by this flutter_tester'
        : false,
  );
}
