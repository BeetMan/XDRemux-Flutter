import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

class PhotoDetailsService {
  /// Inspect EXIF shooting parameters and HDR GainMap properties of a photo.
  static PhotoDetailsModel inspect(String path) {
    try {
      final report = XdRemuxFFI.inspectPhotoDetails(path);
      return PhotoDetailsModel.fromJson(report);
    } catch (e) {
      return PhotoDetailsModel(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }
}
