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
  static const _materializedInputDirName = 'xdremux_checkpoint_inputs';
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
  // Input materialization
  // ---------------------------------------------------------------------------

  /// Keep picker/cache-backed inputs alive for checkpoint resume.
  ///
  /// File pickers on iOS and Android commonly return a path under the OS
  /// temporary directory. That path can disappear when the app is killed,
  /// leaving a checkpoint that points at an unreadable source. Only temporary
  /// inputs are copied; real user paths stay in place so EXIF/GPS and output
  /// directory behavior remain unchanged.
  static Future<String> materializeTemporaryInput(String inputPath) async {
    final source = File(inputPath);
    if (!source.existsSync()) return inputPath;

    final tempDir = await getTemporaryDirectory();
    if (!_isWithin(inputPath, tempDir.path)) return inputPath;

    try {
      final stat = await source.stat();
      final supportDir = await getApplicationSupportDirectory();
      final dir = Directory(
        '${supportDir.path}${Platform.pathSeparator}$_materializedInputDirName',
      );
      await dir.create(recursive: true);

      final originalName = inputPath.split(RegExp(r'[/\\]')).last;
      final safeName = originalName.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
        '_',
      );
      final key = _stableInputKey(inputPath, stat.size, stat.modified);
      // Keep the original basename visible in the queue; use a deterministic
      // private subdirectory for collision avoidance instead of prefixing the
      // user-facing filename with an internal hash.
      final bucket = Directory('${dir.path}${Platform.pathSeparator}$key');
      await bucket.create(recursive: true);
      final destination = File(
        '${bucket.path}${Platform.pathSeparator}${safeName.isEmpty ? 'input.heic' : safeName}',
      );

      if (!destination.existsSync() ||
          await destination.length() != stat.size) {
        await source.copy(destination.path);
      }
      return destination.path;
    } catch (_) {
      // The picker path remains usable for the current run even if the
      // persistent copy cannot be made. The caller will surface a missing
      // source on a later resume rather than failing file selection now.
      return inputPath;
    }
  }

  static bool _isWithin(String child, String parent) {
    String normalize(String value) {
      var result = value.replaceAll('\\', '/');
      while (result.length > 1 && result.endsWith('/')) {
        result = result.substring(0, result.length - 1);
      }
      return result.toLowerCase();
    }

    final c = normalize(child);
    final p = normalize(parent);
    return c == p || c.startsWith('$p/');
  }

  static String _stableInputKey(String path, int size, DateTime modified) {
    // FNV-1a keeps the materialized filename deterministic across app
    // launches without adding a crypto dependency.
    var hash = 0xcbf29ce484222325;
    final text = '$path|$size|${modified.millisecondsSinceEpoch}';
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Remove persistent picker copies after a completely successful batch.
  /// Failed/cancelled checkpoints retain them for resume.
  static Future<void> cleanupMaterializedInputs(Checkpoint checkpoint) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(
      '${supportDir.path}${Platform.pathSeparator}$_materializedInputDirName',
    );
    for (final item in checkpoint.items) {
      if (!_isWithin(item.inputPath, dir.path)) continue;
      try {
        final file = File(item.inputPath);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
    try {
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is Directory && entity.listSync().isEmpty) {
            await entity.delete();
          }
        }
        if (dir.listSync().isEmpty) await dir.delete();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Config hash (for signature-based resume validation)
  // ---------------------------------------------------------------------------

  /// Compute a simple hash of the conversion config that affects output.
  /// If config changes significantly, the checkpoint may be invalidated.
  static String computeConfigHash(ConversionConfig config) {
    final payload = jsonEncode({
      'family': config.family.name,
      'backend': config.backend.name,
      'outputMode': config.outputMode.name,
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
  ///
  /// Saves are serialized: parallel conversions complete in bursts, and two
  /// concurrent saves sharing one tmp path made the loser fail the rename
  /// (unhandled PathNotFoundException). Chaining keeps writes atomic and
  /// races impossible.
  static Future<void> _saveChain = Future.value();

  static Future<void> save(Checkpoint checkpoint) {
    final task = _saveChain.then((_) => _saveNow(checkpoint));
    // Keep the chain alive even if one save fails.
    _saveChain = task.catchError((_) {});
    return task;
  }

  static Future<void> _saveNow(Checkpoint checkpoint) async {
    final file = await _getFile();
    await file.parent.create(recursive: true);
    final tmpPath = '${file.path}.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(checkpoint.toJsonl(), flush: true);
    try {
      await tmpFile.rename(file.path);
    } on FileSystemException {
      // Extremely defensive: if the rename target vanished mid-flight the
      // checkpoint is simply skipped (the next save rewrites it).
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }
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
        captureModeKey: item.captureModeKey,
        captureModeFolderName: item.captureModeFolderName,
        classificationStatus: item.classificationStatus,
        hdrKind: item.hdrKind,
        family: item.family,
        motionPhoto:
            item.motionPhoto == null
                ? null
                : {
                  'kind': item.motionPhoto!.kind,
                  'stillBytes': item.motionPhoto!.stillBytes,
                  'videoBytes': item.motionPhoto!.videoBytes,
                  'streamCount': item.motionPhoto!.streamCount,
                },
        motionPhotoMode: item.motionPhotoMode.name,
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
