import '../l10n/l10n.dart';
import '../models/app_models.dart';

/// Shared admission policy for picker/share/drop and restored queues.
class HuaweiPhotoPolicy {
  static bool portraitReady(Map<String, dynamic>? report) =>
      report?['safeToTransform'] == true;

  static (QueueItemStatus, String?) admission({
    required bool huaweiHdr,
    required bool portraitReady,
    required bool stylesRequested,
    bool motionPhoto = false,
  }) {
    if (!huaweiHdr || portraitReady || stylesRequested || motionPhoto) {
      return (QueueItemStatus.pending, null);
    }
    return (
      QueueItemStatus.skippedPolicy,
      t(
        '华为 HDR 原生兼容 Apple Photos，无需转换',
        'Huawei HDR is natively compatible with Apple Photos; no conversion needed',
      ),
    );
  }
}
