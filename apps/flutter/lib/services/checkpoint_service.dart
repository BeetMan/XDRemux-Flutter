/// Checkpoint persistence service for batch conversion resume (M6).
///
/// Checkpoint file is stored in the app's application support directory
/// as `xdremux_checkpoint.jsonl`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_models.dart';
import '../models/checkpoint_model.dart';

class CheckpointService {
  CheckpointService._();

  static const _fileName = 'xdremux_checkpoint.jsonl';
  static File? _checkpointFile;

  // ---------------------------------------------------------------------------
  // File location
  // ---------------------------------------------------------------------------

  static Future<File> _getFile() async {
    if (_checkpointFile != null) return _checkpointFile!;
    final dir = await getApplicationSupportDirectory();
    _checkpointFile = File('${dir.path}${Platform.pathSeparator}$_fileName');
    return _checkpointFile!;
  }

  // ---------------------------------------------------------------------------
  // Config hash (for signature-based resume validation)
  // ---------------------------------------------------------------------------

  /// Compute a simple hash of the conversion config that affects output.
  /// If config changes significantly, the checkpoint may be invalidated.
  static String computeConfigHash(ConversionConfig config) {
    final payload = jsonEncode({
      'family': config.family.name,
      'oppoCompatibility': config.oppoCompatibility.name,
      'outputDirectory': config.outputDirectory,
      'fileNameSuffix': config.fileNameSuffix,
    });
    // Simple hash: use Dart's built-in hashCode (sufficient for change detection)
    return payload.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  /// Save checkpoint to disk (atomic write via temp file + rename).
  static Future<void> save(Checkpoint checkpoint) async {
    final file = await _getFile();
    final tmpPath = '${file.path}.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(checkpoint.toJsonl(), flush: true);
    await tmpFile.rename(file.path);
  }

  /// Incremental save: update a single item's status and persist.
  /// This is called after each file completes to minimize data loss on crash.
  static Future<void> saveIncremental(Checkpoint checkpoint) async {
    await save(checkpoint);
  }

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  /// Load existing checkpoint if present. Returns null if no checkpoint
  /// or if the file is corrupted.
  static Future<Checkpoint?> load() async {
    final file = await _getFile();
    if (!file.existsSync()) return null;

    try {
      final content = await file.readAsString();
      return Checkpoint.fromJsonl(content);
    } catch (_) {
      return null;
    }
  }

  /// Check if a resumable checkpoint exists.
  static Future<bool> hasCheckpoint() async {
    final file = await _getFile();
    return file.existsSync();
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  /// Delete the checkpoint file (called when all conversions succeed).
  static Future<void> delete() async {
    final file = await _getFile();
    if (file.existsSync()) {
      await file.delete();
    }
  }

  // ---------------------------------------------------------------------------
  // Resume validation
  // ---------------------------------------------------------------------------

  /// Validate whether a checkpoint item's source file is still valid
  /// (exists, same size, same mtime). Returns false if the file has
  /// changed since the checkpoint was created.
  static bool isSourceUnchanged(CheckpointItem item) {
    try {
      final file = File(item.inputPath);
      if (!file.existsSync()) return false;
      final stat = file.statSync();
      return stat.size == item.inputSize &&
          stat.modified.millisecondsSinceEpoch == item.inputMtimeMs;
    } catch (_) {
      return false;
    }
  }

  /// Create checkpoint items from the current queue, capturing file metadata.
  static List<CheckpointItem> createItemsFromQueue(List<QueueItem> queue) {
    return queue.map((item) {
      int size = 0;
      int mtimeMs = 0;
      try {
        final file = File(item.inputPath);
        if (file.existsSync()) {
          final stat = file.statSync();
          size = stat.size;
          mtimeMs = stat.modified.millisecondsSinceEpoch;
        }
      } catch (_) {}

      return CheckpointItem(
        inputPath: item.inputPath,
        outputPath: item.outputPath,
        status: CheckpointItemStatus.pending,
        inputSize: size,
        inputMtimeMs: mtimeMs,
      );
    }).toList();
  }

  /// Update a checkpoint item's status after conversion.
  static void updateItemStatus(
    Checkpoint checkpoint,
    String inputPath,
    CheckpointItemStatus status, {
    String? error,
  }) {
    for (final item in checkpoint.items) {
      if (item.inputPath == inputPath) {
        item.status = status;
        item.error = error;
        item.finishedAt = DateTime.now();
        break;
      }
    }
  }
}
