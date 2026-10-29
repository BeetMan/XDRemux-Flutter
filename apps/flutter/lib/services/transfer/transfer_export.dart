import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'transfer_controller.dart';
import 'transfer_models.dart';

/// General files: no gallery API, full-file byte buffers, or fabricated extension.
class TransferExport {
  static const _channel = MethodChannel('xdremux/transfer-documents');
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
    if (Platform.isWindows) {
      final directory = await FilePicker.getDirectoryPath();
      if (directory == null) return false;
      await transfer.exportDesktop(receiptId, directory);
      return true;
    }
    throw const TransferException('unsupported_platform');
  }
}
