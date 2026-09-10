import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/portrait_service.dart';

void main() {
  group('PortraitSummary tests', () {
    test('PortraitSummary parses JSON and formats labels properly', () {
      final json = {
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
      };

      final summary = PortraitSummary.fromJson(json);

      expect(summary.hasPortrait, true);
      expect(summary.width, 1024);
      expect(summary.height, 768);
      expect(summary.resolutionLabel, '1024 × 768');
      expect(summary.apertureLabel, 'f/4.5');
      expect(summary.distanceLabel, '1080 cm');
      expect(summary.hasPortraitMatte, true);
      expect(summary.hasHairMatte, false);
      expect(summary.hasPetMatte, false);

      final roundTrip = summary.toJson();
      expect(roundTrip['hasPortrait'], true);
      expect(roundTrip['width'], 1024);
      expect(roundTrip['currentFNumber'], 4.5);
      expect(roundTrip['scaleMode'], 'passthrough');
    });

    test('PortraitSummary handles null optional fields gracefully', () {
      final json = {
        'hasPortrait': true,
        'width': 512,
        'height': 384,
        'scale': 0.005,
        'scaleMode': 'calibrated-p50',
        'currentFNumber': null,
        'focalLength': null,
        'objectDistance': null,
        'hasPortraitMatte': false,
        'hasHairMatte': false,
        'hasPetMatte': false,
      };

      final summary = PortraitSummary.fromJson(json);
      expect(summary.apertureLabel, 'f/--');
      expect(summary.distanceLabel, '-');
      expect(summary.focalLength, isNull);
    });

    test('PortraitMode displayName matches expected localization', () {
      expect(PortraitMode.applePortrait.displayName, isNotEmpty);
      expect(PortraitMode.standard.displayName, isNotEmpty);
    });

    test('PortraitService inspect on non-existent file returns null', () async {
      final result = await PortraitService.inspect('/does/not/exist.heic');
      expect(result, isNull);
    });

    test('PortraitService inspect on real sample files if present', () async {
      final candidates = [
        r'C:\Users\Beet\Desktop\Find X10\IMG20260910130252.heic',
        r'C:\Users\Beet\Desktop\Find X10\IMG20260910111932.jpg',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          final summary = await PortraitService.inspect(path);
          expect(summary, isNotNull);
          expect(summary!.hasPortrait, true);
          expect(summary.width, 1024);
          expect(summary.height, 768);
          expect(summary.currentFNumber, 4.5);
          expect(summary.scale, greaterThan(0.0));
        }
      }
    });
  });
}
