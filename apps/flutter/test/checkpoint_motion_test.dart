import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/checkpoint_model.dart';

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
    });
  });
}
