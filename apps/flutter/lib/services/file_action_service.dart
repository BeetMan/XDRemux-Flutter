import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';

/// File actions: save to gallery, share, open with system app.
class FileActionService {
  FileActionService._();

  /// True on the CPF-Flutter OpenHarmony fork (dart:io reports "ohos").
  static bool get _isOhos => Platform.operatingSystem == 'ohos';

  static const _nativeShareChannel = MethodChannel('xdremux/native-share');

  // OHOS-only channel registered by the vendored gallery_saver fork
  // (invoked by name so stock platforms never import that package).
  static const _ohosGalleryChannel = MethodChannel('gallery_saver');

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
      await shareFiles([filePath]);
    } catch (e) {
      debugPrint('shareFile error: $e');
    }
  }

  /// Strict multi-file export for Live Photo originals. Errors must reach the
  /// caller instead of silently sharing only the still image.
  static Future<void> shareFiles(
    List<String> paths, {
    bool asOriginalFiles = false,
  }) async {
    if (paths.isEmpty) throw ArgumentError('No files to share');
    for (final path in paths) {
      // A `.pvt` Live Photo bundle is shared as a directory on Apple hosts.
      if (!await File(path).exists() && !await Directory(path).exists()) {
        throw FileSystemException('Missing share resource', path);
      }
    }
    if (Platform.isIOS) {
      final ok = await _nativeShareChannel.invokeMethod<bool>(
        paths.length == 1 ? 'shareFile' : 'shareFiles',
        paths.length == 1 ? {'path': paths.single} : {'paths': paths},
      );
      if (ok != true) throw StateError('Could not present file sharing');
      return;
    }
    if (_isOhos) {
      if (paths.length != 1) {
        throw UnsupportedError(
          'Paired file sharing is not implemented on this platform',
        );
      }
      await const MethodChannel(
        'xdremux/share',
      ).invokeMethod<void>('shareFile', {'path': paths.single});
      return;
    }
    final files = paths.map((path) {
      final lower = path.toLowerCase();
      return XFile(
        path,
        mimeType: asOriginalFiles
            ? 'application/octet-stream'
            : lower.endsWith('.heif')
            ? 'image/heif'
            : lower.endsWith('.heic')
            ? 'image/heic'
            : null,
      );
    }).toList();
    // Shared API supported by both mainline v13 and the OHOS v10 fork.
    // ignore: deprecated_member_use
    await Share.shareXFiles(files);
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
      // file_picker v12: saveFile takes the bytes and writes them itself.
      var fileName =
          suggestedName ?? filePath.split(Platform.pathSeparator).last;
      if (!fileName.toLowerCase().endsWith('.heic') &&
          !fileName.toLowerCase().endsWith('.heif')) {
        fileName = '$fileName.heic';
      }
      final destUri = await FilePicker.saveFile(
        dialogTitle: t('保存 XDRemux 输出', 'Save XDRemux output'),
        fileName: fileName,
        bytes: await File(filePath).readAsBytes(),
        mimeType: 'image/heic',
      );
      if (destUri == null) return null;
      return destUri.scheme == 'file'
          ? destUri.toFilePath()
          : destUri.toString();
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
