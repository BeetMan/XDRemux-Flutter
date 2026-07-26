import 'dart:io';

import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

/// File actions: save to gallery, share, open with system app.
class FileActionService {
  FileActionService._();

  /// Save an image/video file to the system gallery (MediaStore on Android).
  ///
  /// On Android this inserts the file into MediaStore (DCIM or Pictures).
  /// [album] overrides the MediaStore album (MediaStore album name, placed under Pictures/);
  /// defaults to 'XDRemux'.
  /// On desktop this is a no-op (files are already accessible).
  /// Returns true on success.
  static Future<bool> saveToGallery(String filePath, {String? album}) async {
    try {
      if (!File(filePath).existsSync()) return false;
      // gal handles Android MediaStore insertion and iOS PHPhotoLibrary.
      await Gal.putImage(filePath, album: album ?? 'XDRemux');
      return true;
    } catch (e) {
      print('saveToGallery error: $e');
      return false;
    }
  }

  /// Check if we have permission to save to gallery.
  static Future<bool> hasGalleryPermission() async {
    try {
      return await Gal.hasAccess(toAlbum: true);
    } catch (_) {
      return false;
    }
  }

  /// Request permission to save to gallery.
  static Future<bool> requestGalleryPermission() async {
    try {
      return await Gal.requestAccess(toAlbum: true);
    } catch (_) {
      return false;
    }
  }

  /// Share a file via the system share sheet (ACTION_SEND on Android).
  static Future<void> shareFile(String filePath) async {
    try {
      if (!File(filePath).existsSync()) return;
      final xFile = XFile(filePath);
      await Share.shareXFiles([xFile]);
    } catch (e) {
      print('shareFile error: $e');
    }
  }

  /// Open a file with the system default application.
  ///
  /// On Android this fires an ACTION_VIEW intent (opens in Gallery/file viewer).
  /// The MIME type is forced to image/* for HEIC/HEIF: open_filex's built-in
  /// table doesn't know the .heic extension and would fall back to
  /// application/octet-stream, for which no gallery app registers.
  static Future<bool> openFile(String filePath) async {
    try {
      if (!File(filePath).existsSync()) return false;
      final lower = filePath.toLowerCase();
      final isHeic = lower.endsWith('.heic') || lower.endsWith('.heif');
      final result = await OpenFilex.open(
        filePath,
        type: isHeic ? 'image/*' : null,
      );
      if (result.type != ResultType.done) {
        print('openFile failed: ${result.type} ${result.message}');
      }
      return result.type == ResultType.done;
    } catch (e) {
      print('openFile error: $e');
      return false;
    }
  }

  /// Copy output file to the source directory (same dir as input).
  ///
  /// Returns the new file path, or null on failure.
  static Future<String?> copyToSourceDir(String outputPath, String inputPath) async {
    try {
      final inputFile = File(inputPath);
      final outputFile = File(outputPath);
      if (!outputFile.existsSync()) return null;

      final sourceDir = inputFile.parent.path;
      final fileName = outputFile.uri.pathSegments.last;
      final destPath = '$sourceDir${Platform.pathSeparator}$fileName';

      // Avoid overwriting input
      if (destPath == inputPath) return null;

      await outputFile.copy(destPath);
      return destPath;
    } catch (e) {
      print('copyToSourceDir error: $e');
      return null;
    }
  }
}
