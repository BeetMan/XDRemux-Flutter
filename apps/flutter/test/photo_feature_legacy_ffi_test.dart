import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/photo_feature_service.dart';

// Explicitly run against the unchanged v0.4.0 library (no new inspection API).
void main() {
  test('legacy core inspection does not block inherited portrait preflight', () async {
    final report = XdRemuxFFI.inspectPortrait('unused-by-missing-symbol.heic');
    expect(report['inspectionUnavailable'], true);
    expect(report.containsKey('hasPortrait'), false);
    final service = PhotoFeatureService();
    final inspection = await service.inspect('unused-by-missing-symbol.heic');
    final item = QueueItem(id: 'legacy', inputPath: 'original.heic', outputPath: 'out.heic');
    inspection.applyTo(item);
    expect(item.portraitInspectionAvailable, false);
    final config = ConversionConfig(applePortrait: true);
    expect(item.effectiveApplePortrait(config), true);
    expect(item.photoPolicyRejection(config), isNull);
    item.portraitMode = PortraitMode.applePortrait;
    expect(item.photoPolicyRejection(config), isNotNull);
  }, skip: !const bool.fromEnvironment('XDREMUX_TEST_LEGACY_CORE'));
}
