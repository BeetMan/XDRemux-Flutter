/// file_picker v12-compatible facade over this fork's v10 platform interface.
///
/// XDRemux's shared Dart code targets the v12 API (`FilePicker.pickFiles`
// statics, `PlatformFile.uri`, `readAsBytes()`); the OHOS fork predates it.
/// The facade delegates to the fork's platform instance, so the native side
/// is untouched.
library file_picker;

import 'dart:typed_data';

import 'src/file_picker.dart' as v10 show FilePicker, FileType, FilePickerStatus;
import 'src/platform_file.dart';
import 'src/file_picker.dart' show FileType, FilePickerStatus;

export './src/platform_file.dart';
export './src/file_picker_result.dart';
export './src/file_picker_macos.dart';
export './src/linux/file_picker_linux.dart';
export './src/file_picker_io.dart';
// Conditional export needed for web to successfully compile,
// as `dart:ffi` is not available on the web.
export './src/windows/file_picker_windows_stub.dart'
    if (dart.library.ffi) './src/windows/file_picker_windows.dart';

// FileType / FilePickerStatus live in the fork's own src (v10 predates the
// platform-interface package split).
export './src/file_picker.dart' show FileType, FilePickerStatus;

/// v12 static facade.
abstract class FilePicker {
  FilePicker._();

  static Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final result = await v10.FilePicker.platform.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      allowCompression: allowCompression,
      compressionQuality: compressionQuality,
      allowMultiple: allowMultiple,
      withData: withData,
      withReadStream: withReadStream,
      lockParentWindow: lockParentWindow,
      readSequential: readSequential,
    );
    return result?.files ?? const <PlatformFile>[];
  }

  static Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
  }) async {
    final files = await pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      allowMultiple: false,
    );
    return files.isEmpty ? null : files.first;
  }

  static Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    bool lockParentWindow = false,
  }) =>
      v10.FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        lockParentWindow: lockParentWindow,
      );

  /// v12 saveFile takes bytes; the v10 API takes a destination path and
  /// returns it, so write the bytes ourselves.
  static Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool lockParentWindow = false,
  }) async {
    final path = await v10.FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
      lockParentWindow: lockParentWindow,
    );
    return path == null ? null : Uri.file(path);
  }
}
