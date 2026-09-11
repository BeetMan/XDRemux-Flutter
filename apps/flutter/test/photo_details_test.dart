import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/photo_details_service.dart';

void main() {
  group('PhotoDetailsModel', () {
    test('fromJson deserializes all fields', () {
      final json = {
        'success': true,
        'errorMessage': null,
        'make': 'OPPO',
        'model': 'OPPO Find X10',
        'dateTime': '2026:02:18 13:45:00',
        'exposureTime': '1/176s',
        'fNumber': 'f/1.6',
        'iso': '50',
        'focalLength': '6.1mm',
        'focalLength35mm': '23mm',
        'exposureBias': '+0.0 EV',
        'width': 4352,
        'height': 5780,
        'hdrKind': 'uhdr',
        'edrScale': 4.90,
        'gainMapMax': 2.30,
      };

      final details = PhotoDetailsModel.fromJson(json);

      expect(details.success, isTrue);
      expect(details.model, 'OPPO Find X10');
      expect(details.fNumber, 'f/1.6');
      expect(details.exposureTime, '1/176s');
      expect(details.iso, '50');
      expect(details.focalLengthSummary, '6.1mm (等效 23mm)');
      expect(details.dimensionsSummary, '4352 × 5780 (25.2 MP)');
      expect(details.hdrKind, 'uhdr');
      expect(details.edrScale, 4.90);
      expect(details.gainMapMax, 2.30);
    });

    test('focalLengthSummary falls back to single focal length', () {
      const details = PhotoDetailsModel(
        success: true,
        focalLength: '24mm',
      );
      expect(details.focalLengthSummary, '24mm');
    });

    test('dimensionsSummary calculates megapixel accurately', () {
      const details = PhotoDetailsModel(
        success: true,
        width: 4000,
        height: 3000,
      );
      expect(details.dimensionsSummary, '4000 × 3000 (12.0 MP)');
    });
  });

  group('PhotoDetailsService', () {
    test('inspect missing file returns failure without crashing', () {
      final details = PhotoDetailsService.inspect('non_existent_file.jpg');
      expect(details.success, isFalse);
      expect(details.errorMessage, isNotNull);
    });
  });
}
