import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/models/checkpoint_model.dart';
import 'package:xdremux/services/motion_photo_service.dart';

void main() {
  group('Checkpoint motion-photo round-trip', () {
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

    test('CheckpointItem without motion fields defaults to skip', () {
      final item = CheckpointItem(
        inputPath: '/a.heic',
        outputPath: '/b.heic',
      );
      final restored = CheckpointItem.fromJson(item.toJson());
      expect(restored.motionPhoto, isNull);
      expect(restored.motionPhotoMode, 'skip');
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

    test('JSONL round-trip keeps photographic style fields', () {
      final checkpoint = Checkpoint(
        header: CheckpointHeader(
          configHash: 'abc',
          totalJobs: 1,
          startedAt: DateTime.parse('2026-09-10T08:00:00Z'),
          appVersion: '0.4.0',
        ),
        items: [
          CheckpointItem(
            inputPath: '/tmp/IMG_0001.JPG',
            outputPath: '/out/IMG_0001.heic',
            status: CheckpointItemStatus.converted,
            photographicStyle: const {
              'styleNameZh': '清透',
              'styleNameEn': 'Crisp',
              'lutName': 'qing_tou.bin',
              'baseImageBytes': 8192000,
              'intensity': 100,
              'tone': 90,
              'version': '5.1f',
            },
            photographicStyleMode: 'extractBasePhoto',
          ),
        ],
      );

      final restored = Checkpoint.fromJsonl(checkpoint.toJsonl());
      expect(restored, isNotNull);
      expect(restored!.items.single.photographicStyle, isNotNull);
      expect(restored.items.single.photographicStyle!['styleNameZh'], '清透');
      expect(restored.items.single.photographicStyleMode, 'extractBasePhoto');
    });

    test('JSONL round-trip keeps portrait fields', () {
      final checkpoint = Checkpoint(
        header: CheckpointHeader(
          configHash: 'abc',
          totalJobs: 1,
          startedAt: DateTime.parse('2026-09-10T08:00:00Z'),
          appVersion: '0.4.0',
        ),
        items: [
          CheckpointItem(
            inputPath: '/tmp/IMG_130252.HEIC',
            outputPath: '/out/IMG_130252.heic',
            status: CheckpointItemStatus.converted,
            portrait: const {
              'hasPortrait': true,
              'width': 1024,
              'height': 768,
              'scale': 0.00748,
              'scaleMode': 'passthrough',
              'currentFNumber': 4.5,
              'focalLength': 7.1,
              'objectDistance': 1080,
              'hasPortraitMatte': true,
              'hasHairMatte': false,
              'hasPetMatte': false,
            },
            portraitMode: 'applePortrait',
          ),
        ],
      );

      final restored = Checkpoint.fromJsonl(checkpoint.toJsonl());
      expect(restored, isNotNull);
      expect(restored!.items.single.portrait, isNotNull);
      expect(restored.items.single.portrait!['currentFNumber'], 4.5);
      expect(restored.items.single.portrait!['scaleMode'], 'passthrough');
      expect(restored.items.single.portraitMode, 'applePortrait');
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
      expect(restored.items.single.motionPhotoMode, 'skip');
      expect(restored.items.single.photographicStyle, isNull);
      expect(restored.items.single.photographicStyleMode, 'keepStyle');
      expect(restored.items.single.portrait, isNull);
      expect(restored.items.single.portraitMode, 'applePortrait');
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
      expect(summary.hasAudio, isTrue);
      expect(summary.audioCodec, 'mp4a');
      expect(summary.audioChannels, 1);
      expect(summary.audioSampleRate, 16000);
      expect(summary.secondaryWidth, 1920);
      expect(summary.secondaryHeight, 1440);
      expect(summary.presentationTimestampUs, 1496141);
    });
  });
}


