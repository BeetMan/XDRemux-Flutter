import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/models/checkpoint_model.dart';
import 'package:xdremux/services/motion_photo_service.dart';
import 'package:xdremux/services/checkpoint_service.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Live composition refuses to overwrite its original source', () async {
    await expectLater(
      MotionPhotoService.composeLivePhoto('/source.heic', '/source.heic'),
      throwsStateError,
    );
  });

  test('Huawei Live FFI preserves source and produces a valid pair on retry', () async {
    const path = r'C:\tmp\huawei\portrait-motion-20260907\IMG_20260907_021031.heic';
    if (!File(path).existsSync()) return;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => Directory.systemTemp.path);
    final temp = await Directory.systemTemp.createTemp('xdremux-live-test-');
    try {
      // Intentionally put source and output in the same directory, matching
      // desktop's default workflow and exercising the old overwrite bug.
      final input = '${temp.path}${Platform.pathSeparator}source.heic';
      final output = '${temp.path}${Platform.pathSeparator}source_iso.heic';
      final movie = '${temp.path}${Platform.pathSeparator}source_iso.mov';
      final original = await File(path).readAsBytes();
      await File(input).writeAsBytes(original);
      await File(input).copy(output);
      for (var attempt = 0; attempt < 2; attempt++) {
        await MotionPhotoService.composeLivePhoto(input, output);
        expect(XdRemuxFFI.livePhotoPairValid(output, movie), isTrue);
        expect(await File(input).readAsBytes(), original);
        expect(File('${temp.path}${Platform.pathSeparator}source_iso 2.mov').existsSync(), isFalse);
      }
      final direct = XdRemuxFFI.makeLivePhoto(input, output, temp.path);
      expect(direct['success'], isFalse);
      expect(await File(input).readAsBytes(), original);
    } finally {
      await temp.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  group('Checkpoint motion-photo round-trip', () {
    test('fresh checkpoint preserves all terminal states and Huawei skip reason', () {
      final queue = [for (final status in QueueItemStatus.values)
        QueueItem(
          id: status.name, inputPath: '/${status.name}.heic',
          outputPath: '/out/${status.name}.heic', status: status,
          huaweiHdr: true, policyReason: 'Native HDR needs no conversion',
          motionPhotoMode: MotionPhotoMode.stillAndVideo,
        ),
      ];
      final items = CheckpointService.createItemsFromQueue(queue);
      for (var i = 0; i < queue.length; i++) {
        final item = CheckpointItem.fromJson(items[i].toJson());
        final state = queue[i].status;
        expect(item.status.name, switch (state) {
          QueueItemStatus.running || QueueItemStatus.cancelled => 'pending',
          _ => state.name,
        });
        expect(item.policyReason, 'Native HDR needs no conversion');
        expect(item.huaweiHdr, isTrue);
        expect(item.motionPhotoMode, 'stillAndVideo');
      }
    });

    test('CheckpointItem persists motion photo fields', () {
      final item = CheckpointItem(
        inputPath: '/tmp/IMG_0001.HEIC',
        outputPath: '/out/IMG_0001.heic',
        status: CheckpointItemStatus.converted,
        inputSize: 123,
        inputMtimeMs: 456,
        captureModeKey: 'portrait',
        captureModeFolderName: '人像',
        classificationStatus: null,
        hdrKind: 'x7',
        family: 'x7',
        motionPhoto: const {
          'kind': 'oppoLivePhotoDualStream',
          'stillBytes': 1024,
          'videoBytes': 2048,
          'streamCount': 2,
        },
        motionPhotoMode: 'livePhotoPair',
      );

      final json = item.toJson();
      final restored = CheckpointItem.fromJson(json);

      expect(restored.captureModeKey, 'portrait');
      expect(restored.captureModeFolderName, '人像');
      expect(restored.hdrKind, 'x7');
      expect(restored.motionPhoto, isNotNull);
      expect(restored.motionPhoto!['kind'], 'oppoLivePhotoDualStream');
      expect(restored.motionPhoto!['streamCount'], 2);
      expect(restored.motionPhotoMode, 'livePhotoPair');
      expect(restored.status, CheckpointItemStatus.converted);
    });

    test('CheckpointItem without motion fields defaults to livePhotoPair', () {
      final item = CheckpointItem(
        inputPath: '/a.heic',
        outputPath: '/b.heic',
      );
      final restored = CheckpointItem.fromJson(item.toJson());
      expect(restored.motionPhoto, isNull);
      expect(restored.motionPhotoMode, 'livePhotoPair');
    });

    test('skippedPolicy wire status round-trips', () {
      final item = CheckpointItem(
        inputPath: '/a.heic',
        outputPath: '/b.heic',
        status: CheckpointItemStatus.skippedPolicy,
      );
      final restored = CheckpointItem.fromJson(item.toJson());
      expect(restored.status, CheckpointItemStatus.skippedPolicy);
    });

    test('JSONL round-trip keeps new fields', () {
      final checkpoint = Checkpoint(
        header: CheckpointHeader(
          configHash: 'abc',
          totalJobs: 1,
          startedAt: DateTime.parse('2026-09-02T08:00:00Z'),
          appVersion: '0.4.0',
        ),
        items: [
          CheckpointItem(
            inputPath: '/tmp/IMG_0001.HEIC',
            outputPath: '/out/IMG_0001.heic',
            status: CheckpointItemStatus.skippedPolicy,
            motionPhoto: const {'kind': 'androidMotionPhotoV1'},
            motionPhotoMode: 'livePhotoPair',
          ),
        ],
      );

      final restored = Checkpoint.fromJsonl(checkpoint.toJsonl());
      expect(restored, isNotNull);
      expect(restored!.items.single.status, CheckpointItemStatus.skippedPolicy);
      expect(restored.items.single.motionPhotoMode, 'livePhotoPair');
      expect(
        restored.items.single.motionPhoto?['kind'],
        'androidMotionPhotoV1',
      );
    });

    test('old checkpoint JSONL without new fields still restores', () {
      final legacy = jsonEncode({
        'type': 'item',
        'inputPath': '/old.heic',
        'outputPath': '/old-out.heic',
        'status': 'converted',
        'inputSize': 1,
        'inputMtimeMs': 2,
      });
      final restored = Checkpoint.fromJsonl(
        '{"type":"header","configHash":"h","totalJobs":1,'
        '"startedAt":"2026-09-02T08:00:00Z","appVersion":"0.3.1"}\n'
        '$legacy\n',
      );
      expect(restored, isNotNull);
      expect(restored!.items.single.status, CheckpointItemStatus.converted);
      expect(restored.items.single.motionPhotoMode, 'livePhotoPair');
    });

    test('MotionPhotoSummary round-trips all rich stream and audio fields', () {
      const original = MotionPhotoSummary(
        kind: 'oppoLivePhoto',
        stillBytes: 10259134,
        videoBytes: 16434648,
        streamCount: 2,
        videoWidth: 3840,
        videoHeight: 2880,
        durationMs: 2895,
        fps: 30.04,
        frameCount: 87,
        videoCodec: 'hvc1',
        hasAudio: true,
        audioCodec: 'mp4a',
        audioChannels: 1,
        audioSampleRate: 16000,
        audioDurationMs: 2905,
        presentationTimestampUs: 1496141,
        presentationSource: 'androidXMP',
        primaryBytes: 13622680,
        secondaryBytes: 2811968,
        secondaryWidth: 1920,
        secondaryHeight: 1440,
        secondaryFps: 30.09,
      );

      final json = original.toJson();
      final restored = MotionPhotoSummary.fromJson(json);

      expect(restored.kind, 'oppoLivePhoto');
      expect(restored.isDualStream, isTrue);
      expect(restored.videoWidth, 3840);
      expect(restored.videoHeight, 2880);
      expect(restored.resolutionLabel, '3840×2880 (4K)');
      expect(restored.durationLabel, '2.90s');
      expect(restored.fpsLabel, '30.0 fps');
      expect(restored.audioLabel, contains('MP4A'));
      expect(restored.audioLabel, contains('16kHz'));
      expect(restored.dualStreamSummary, contains('双码流'));
      expect(restored.hasAudio, isTrue);
      expect(restored.audioChannels, 1);
      expect(restored.presentationTimestampUs, 1496141);
      expect(restored.secondaryWidth, 1920);
      expect(restored.secondaryHeight, 1440);
    });

    test('MotionPhotoService inspects real OPPO Find X10 live photo if present', () async {
      const sample = r'C:\Users\Beet\Desktop\Find X10\IMG20260910130211.jpg';
      if (!File(sample).existsSync()) return;

      final summary = await MotionPhotoService.inspect(sample);
      expect(summary, isNotNull);
      expect(summary!.kind, 'oppoLivePhoto');
      expect(summary.isDualStream, isTrue);
      expect(summary.videoWidth, 3840);
      expect(summary.videoHeight, 2880);
      expect(summary.resolutionLabel, contains('3840×2880'));
    });

    test('MotionPhotoService inspects real Huawei Mate 70 motion photo if present', () async {
      const sample = r'C:\tmp\huawei\portrait-motion-20260907\IMG_20260907_021031.heic';
      if (!File(sample).existsSync()) return;

      final summary = await MotionPhotoService.inspect(sample);
      expect(summary, isNotNull);
      expect(summary!.kind, 'huaweiOpenHarmonyMotionPhoto');
      expect(summary.videoBytes, greaterThan(0));
      expect(summary.stillBytes, greaterThan(0));
    });

    test('CheckpointItem persists huawei fields', () {
      final item = CheckpointItem(
        inputPath: '/tmp/IMG_0001.heic',
        outputPath: '/out/IMG_0001_iso.heic',
        status: CheckpointItemStatus.pending,
        huaweiHdr: true,
        huaweiHasXtstyle: true,
        huaweiPortrait: const {'classification': 'huawei-portrait', 'safeToTransform': true},
        motionPhoto: const {
          'kind': 'huaweiOpenHarmonyMotionPhoto',
          'stillBytes': 2854016,
          'videoBytes': 4562931,
          'streamCount': 1,
        },
        motionPhotoMode: 'livePhotoPair',
      );

      final json = item.toJson();
      final restored = CheckpointItem.fromJson(json);

      expect(restored.huaweiHdr, isTrue);
      expect(restored.huaweiHasXtstyle, isTrue);
      expect(restored.huaweiPortrait?['safeToTransform'], isTrue);
      expect(restored.motionPhoto?['kind'], 'huaweiOpenHarmonyMotionPhoto');
      expect(restored.motionPhotoMode, 'livePhotoPair');
    });
  });
}
