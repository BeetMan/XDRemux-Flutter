import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Resolves a file returned by the system document picker to a path the Rust
/// FFI layer can read with its metadata intact.
///
/// On Android, file_picker resolves content:// URIs by copying the picked
/// file into its own cache directory, and on OPPO/ColorOS that copy drops the
/// EXIF GPS block. When "all files access" (MANAGE_EXTERNAL_STORAGE) is
/// granted we therefore read the original file by its real filesystem path
/// first; only when that is unavailable do we fall back to re-importing the
/// content URI or to the picker-provided cache copy.
class PickedFileResolver {
  PickedFileResolver._();

  static const _importChannel = MethodChannel('xdremux/file-import');

  /// Whether "all files access" is currently granted. Only checks; never
  /// prompts. Non-Android platforms are treated as granted.
  static Future<bool> allFilesAccessGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.manageExternalStorage.status;
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Resolve a picked file to a readable local path, preferring the original
  /// file so EXIF/GPS survive. Returns null when nothing readable was found.
  static Future<String?> resolve(PickedFileInput file, {int index = 0}) async {
    if (Platform.isAndroid) {
      final hasAllFiles = await allFilesAccessGranted();
      if (hasAllFiles) {
        final realPath = _resolveRealPathFromName(file.name);
        if (realPath != null) {
          debugPrint(
            '[XDRemux][picked-file] resolved ${file.name} to real path '
            '$realPath (GPS preserved)',
          );
          return realPath;
        }
      } else {
        debugPrint(
          '[XDRemux][picked-file] all-files access not granted; '
          'using content-URI copy for ${file.name}',
        );
      }
      final identifier = file.identifier;
      if (identifier != null &&
          (identifier.startsWith('content://') ||
              identifier.startsWith('file://'))) {
        try {
          final cachedPath = await _tempCopyPath(file.name, index);
          final imported = await _importChannel.invokeMethod<String?>(
            'importFromUri',
            {'uri': identifier, 'destPath': cachedPath},
          );
          if (imported != null && File(imported).existsSync()) {
            debugPrint(
              '[XDRemux][picked-file] re-imported ${file.name} from '
              'content URI to $imported',
            );
            return imported;
          }
          debugPrint(
            '[XDRemux][picked-file] content-URI re-import failed for '
            '${file.name}, falling back to file_picker path',
          );
        } catch (e) {
          debugPrint('[XDRemux][picked-file] content-URI re-import error: $e');
        }
      }
    }

    final pickedPath = file.path;
    if (pickedPath != null && pickedPath.isNotEmpty) {
      try {
        final entity = await File(pickedPath).stat();
        if (entity.type == FileSystemEntityType.file && entity.size > 0) {
          return pickedPath;
        }
        debugPrint(
          '[XDRemux][picked-file] path is not a readable file: '
          '$pickedPath (type=${entity.type}, size=${entity.size})',
        );
      } catch (e) {
        debugPrint('[XDRemux][picked-file] returned path cannot be read: '
            '$pickedPath ($e)');
      }
    }

    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      debugPrint(
        '[XDRemux][picked-file] no usable path or bytes for '
        '${file.name} (identifier=${file.identifier})',
      );
      return null;
    }

    final cachedPath = await _tempCopyPath(file.name, index);
    await File(cachedPath).writeAsBytes(bytes, flush: true);
    debugPrint(
      '[XDRemux][picked-file] materialized ${file.name} '
      '(${bytes.length} bytes) at $cachedPath',
    );
    return cachedPath;
  }

  /// With MANAGE_EXTERNAL_STORAGE the app can read any file under
  /// /storage/emulated/0 by path. Try the standard camera/download locations
  /// for a HEIC whose display name we know; reading the real file preserves
  /// EXIF GPS that OPPO's content stream strips. Returns the real path if the
  /// file exists and is readable, else null.
  static String? _resolveRealPathFromName(String? name) {
    if (name == null || name.isEmpty) return null;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.heic') && !lower.endsWith('.heif')) return null;

    const bases = [
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures/XDRemux',
    ];
    for (final base in bases) {
      try {
        final f = File('$base/$name');
        if (f.existsSync() && f.lengthSync() > 0) {
          return f.path;
        }
      } catch (_) {
        // keep trying
      }
    }
    return null;
  }

  static Future<String> _tempCopyPath(String name, int index) async {
    final tempRoot = await getTemporaryDirectory();
    final importDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}picked_files',
    );
    await importDir.create(recursive: true);
    final safeName = name.replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
      '_',
    );
    final fileName = safeName.isEmpty ? 'picked_$index.heic' : safeName;
    return '${importDir.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}_$fileName';
  }
}

/// Plain snapshot of a file_picker result so this service stays decoupled
/// from the concrete package type.
class PickedFileInput {
  const PickedFileInput({
    required this.name,
    this.path,
    this.bytes,
    this.identifier,
  });

  final String name;
  final String? path;
  final Uint8List? bytes;
  final String? identifier;
}
