import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/services/huawei_photo_policy.dart';

void main() {
  test('native static HDR skips, portrait/styles/motion all remain eligible', () {
    for (final portrait in [false, true]) {
      for (final styles in [false, true]) {
        for (final motion in [false, true]) {
          final (status, reason) = HuaweiPhotoPolicy.admission(
            huaweiHdr: true,
            portraitReady: portrait,
            stylesRequested: styles,
            motionPhoto: motion,
          );
          final skip = !portrait && !styles && !motion;
          expect(status, skip ? QueueItemStatus.skippedPolicy : QueueItemStatus.pending);
          expect(reason != null, skip);
        }
      }
    }
  });

  test('changing style settings cannot skip an already detected motion photo', () {
    for (final styles in [true, false, true, false]) {
      expect(HuaweiPhotoPolicy.admission(
        huaweiHdr: true, portraitReady: false,
        stylesRequested: styles, motionPhoto: true,
      ).$1, QueueItemStatus.pending);
    }
  });

  test('only supported Huawei portrait reports bypass OPPO import rejection', () {
    expect(HuaweiPhotoPolicy.portraitReady({'safeToTransform': true}), isTrue);
    expect(HuaweiPhotoPolicy.portraitReady({'safeToTransform': false}), isFalse);
    expect(HuaweiPhotoPolicy.portraitReady(null), isFalse);
  });
}
