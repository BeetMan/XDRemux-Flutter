import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../platform_x.dart';
import '../file_action_service.dart';
import '../output_export_service.dart';
import 'transfer_controller.dart';
import 'transfer_live_photo.dart';
import 'transfer_models.dart';

/// General files: no gallery API, full-file byte buffers, or fabricated extension.
/// Android uses SAF, desktops a chosen folder, iOS/HarmonyOS the share sheet.
class TransferExport {
  static const _channel = MethodChannel('xdremux/transfer-documents');

  /// iOS and HarmonyOS hand the verified copy to the system share sheet
  /// (Save to Files, Photos, other apps) instead of writing to a folder.
  static bool get viaShareSheet => Platform.isIOS || PlatformX.isOhos;
  static Future<bool> save(
    TransferController transfer,
    String receiptId,
    String name,
  ) async {
    if (Platform.isAndroid) {
      // Do not depend on an OEM picker delivering Flutter's paused event.
      await transfer.stop();
      final uri = await _channel.invokeMethod<String>('createDocument', {
        'name': name,
      });
      if (uri == null) return false;
      var writing = false;
      try {
        if (transfer.stopping) await transfer.stop();
        // The system picker may pause the app and stop LAN reception. This explicit
        // export action may reopen local storage, never automatically a LAN listener.
        await transfer.withReceipt(receiptId, (lease) async {
          final receipt = lease['receipt'] as Map;
          writing = true;
          final result = await _channel.invokeMethod<bool>('writeDocument', {
            'uri': uri,
            'path': lease['path'],
            'size': receipt['size'],
            'sha256': receipt['sha256'],
          });
          if (result != true) throw const TransferException('io');
        });
      } catch (_) {
        // A failed write deletes its own target; one that never started would
        // otherwise leave the picker's empty document behind.
        if (!writing) {
          await _channel
              .invokeMethod<void>('discardDocument', {'uri': uri})
              .catchError((_) {});
        }
        rethrow;
      }
      return true;
    }
    if (PlatformX.isDesktop) {
      final directory = await FilePicker.getDirectoryPath();
      if (directory == null) return false;
      if (isLivePhotoZip(name)) {
        await _unpack(transfer, receiptId, directory, name);
      } else {
        await transfer.exportDesktop(receiptId, directory);
      }
      return true;
    }
    if (viaShareSheet) {
      // One private folder per export; the previous one is no longer needed
      // once the share sheet that used it has been dismissed.
      final base = Directory(
        '${(await getTemporaryDirectory()).path}/transfer-export',
      );
      if (await base.exists()) await base.delete(recursive: true);
      final directory = Directory(
        '${base.path}/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
      // iOS shares a .pvt folder as one Live Photo package.
      if (Platform.isIOS && isLivePhotoZip(name)) {
        final parts = await _unpack(transfer, receiptId, directory.path, name);
        await FileActionService.shareFiles([
          parts.bundle,
        ], asOriginalFiles: true);
        return true;
      }
      await transfer.exportDesktop(receiptId, directory.path);
      await FileActionService.shareFiles([
        '${directory.path}${Platform.pathSeparator}$name',
      ], asOriginalFiles: true);
      return true;
    }
    throw const TransferException('unsupported_platform');
  }

  static Future<LivePhotoParts> _unpack(
    TransferController transfer,
    String receiptId,
    String directory,
    String name,
  ) => transfer.withReceipt(
    receiptId,
    (lease) => extractLivePhotoZip(lease['path'] as String, directory, name),
  );

  /// Gallery save is offered where the photo library takes a Live Photo
  /// (iOS) or its HEIF + MOV pair (Android).
  static bool get savesLivePhoto => Platform.isIOS || Platform.isAndroid;

  /// Unpacks a received `.pvt.zip` and saves it to the photo library.
  static Future<void> saveLivePhoto(
    TransferController transfer,
    String receiptId,
    String name,
  ) async {
    final temp = await Directory.systemTemp.createTemp('xdremux-live-in-');
    try {
      final parts = await _unpack(transfer, receiptId, temp.path, name);
      const gallery = NativeOutputExportDestination();
      if (Platform.isIOS) {
        await gallery.saveLivePhoto(parts.still, parts.movie);
        return;
      }
      if (!await gallery.galleryPermission()) {
        throw const TransferException('permission_denied');
      }
      await gallery.saveImage(parts.still, null);
      await gallery.saveVideo(parts.movie, null);
    } finally {
      await temp.delete(recursive: true).catchError((_) => temp);
    }
  }
}
