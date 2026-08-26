import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

/// File actions: save to gallery, share, open with system app.
class FileActionService {
  FileActionService._();

  /// True on the CPF-Flutter OpenHarmony fork (dart:io reports "ohos").
  static bool get _isOhos => Platform.operatingSystem == 'ohos';

  static const _nativeShareChannel = MethodChannel('xdremux/native-share');

  // OHOS-only channels registered by the vendored gallery_saver/share_extend
  // forks (invoked by name so stock platforms never import those packages).
  static const _ohosGalleryChannel = MethodChannel('gallery_saver');
  static const _ohosShareChannel =
      MethodChannel('com.zt.shareextend/share_extend');

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
      if (_isOhos) {
        // OHOS: PhotoAccessHelper via the gallery_saver fork's channel
        // (handles .heic).
        final ok = await _ohosGalleryChannel.invokeMethod<bool>('saveImage', {
          'path': filePath,
          'albumName': album ?? 'XDRemux',
          'toDcim': false,
        });
        return ok ?? false;
      }
      // gal handles Android MediaStore insertion and iOS PHPhotoLibrary.
      await Gal.putImage(filePath, album: album ?? 'XDRemux');
      return true;
    } catch (e) {
      debugPrint('saveToGallery error: $e');
      return false;
    }
  }

  /// Check if we have permission to save to gallery.
  static Future<bool> hasGalleryPermission() async {
    // OHOS gallery_saver drives the system save flow; no app permission.
    if (_isOhos) return true;
    try {
      return await Gal.hasAccess(toAlbum: true);
    } catch (_) {
      return false;
    }
  }

  /// Request permission to save to gallery.
  static Future<bool> requestGalleryPermission() async {
    if (_isOhos) return true;
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
      if (Platform.isIOS) {
        await _nativeShareChannel.invokeMethod<void>('shareFile', {
          'path': filePath,
        });
        return;
      }
      final lower = filePath.toLowerCase();
      final isHeic = lower.endsWith('.heic') || lower.endsWith('.heif');
      final xFile = XFile(
        filePath,
        mimeType: isHeic
            ? (lower.endsWith('.heif') ? 'image/heif' : 'image/heic')
            : null,
      );
      if (_isOhos) {
        // share_plus has no OHOS implementation; the share_extend fork
        // registers this channel (system share sheet with file paths).
        await _ohosShareChannel.invokeMethod<void>('share', {
          'list': [filePath],
          'type': isHeic ? 'image' : 'file',
        });
        return;
      }
      await Share.shareXFiles([xFile]);
    } catch (e) {
      debugPrint('shareFile error: $e');
    }
  }

  /// Save to a user-selected location on desktop, or to the system photo
  /// library on mobile. Returns the destination path when available.
  static Future<String?> saveFile(
    String filePath, {
    String? suggestedName,
  }) async {
    try {
      if (!File(filePath).existsSync()) return null;
      if (Platform.isAndroid || Platform.isIOS || _isOhos) {
        final saved = await saveToGallery(filePath);
        return saved ? filePath : null;
      }
      final destination = await FilePicker.platform.saveFile(
        dialogTitle: '保存 XDRemux 输出',
        fileName: suggestedName ?? filePath.split(Platform.pathSeparator).last,
        type: FileType.custom,
        allowedExtensions: const <String>['heic', 'heif'],
      );
      if (destination == null || destination.isEmpty) return null;
      final normalized =
          destination.toLowerCase().endsWith('.heic') ||
              destination.toLowerCase().endsWith('.heif')
          ? destination
          : '$destination.heic';
      await File(filePath).copy(normalized);
      return normalized;
    } catch (e) {
      debugPrint('saveFile error: $e');
      return null;
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
      final isIOS = Platform.isIOS;
      final result = await OpenFilex.open(
        filePath,
        // Android needs a MIME type; iOS needs the UTI so
        // UIDocumentInteractionController presents the HEIC preview with
        // the correct document type and can return to Flutter cleanly.
        type: isHeic && !isIOS ? 'image/*' : null,
        uti: isIOS && isHeic
            ? (lower.endsWith('.heif') ? 'public.heif' : 'public.heic')
            : null,
      );
      if (result.type != ResultType.done) {
        debugPrint('openFile failed: ${result.type} ${result.message}');
      }
      return result.type == ResultType.done;
    } catch (e) {
      debugPrint('openFile error: $e');
      return false;
    }
  }

  /// Copy output file to the source directory (same dir as input).
  ///
  /// Returns the new file path, or null on failure.
  static Future<String?> copyToSourceDir(
    String outputPath,
    String inputPath,
  ) async {
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
      debugPrint('copyToSourceDir error: $e');
      return null;
    }
  }
}
