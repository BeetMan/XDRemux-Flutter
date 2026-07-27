import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/app_models.dart';
import 'models/checkpoint_model.dart';
import 'organize_page.dart';
import 'services/update_service.dart';
import 'services/xdremux_service.dart';
import 'services/checkpoint_service.dart';
import 'services/file_action_service.dart';
import 'ffi/xdremux_ffi.dart';

/// File extensions accepted by both the picker and the desktop drop target.
bool isSupportedInputPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.heic') || lower.endsWith('.heif');
}

void main() {
  runApp(const XdRemuxApp());
}

class XdRemuxApp extends StatelessWidget {
  const XdRemuxApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Use Microsoft YaHei on Windows for proper CJK rendering; keep system
    // default on other platforms.
    final String? fontFamily = Platform.isWindows ? 'Microsoft YaHei' : null;
    return MaterialApp(
      title: 'XDRemux',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2856D7),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FC),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
      ),
      darkTheme: ThemeData(
        fontFamily: fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C9AFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

enum _QueueMenuAction { retryFailed, clearCompleted, revealOutputs, clearQueue }

// ============================================================================
// HomePage
// ============================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<QueueItem> _queue = [];
  ConversionConfig _config = ConversionConfig();
  String _statusText = '就绪';
  String _currentFileName = '';
  int _currentConcurrency = 0;
  bool _isProcessing = false;
  int? _selectedIndex;
  Timer? _progressTimer;
  final GlobalKey _rootKey = GlobalKey();

  String _version = '';
  Timer? _configSaveTimer;
  Checkpoint? _checkpoint;

  /// Android: app-specific external directory for output (scoped storage).
  String? _androidOutputDir;
  static const _dropChannel = MethodChannel('xdremux/drop');

  @override
  void initState() {
    super.initState();
    _initAsync();
    _initDropChannel();
    _checkForUpdate();
  }

  /// Silent GitHub Releases check; shows a SnackBar only when a newer
  /// version exists. Never blocks startup or reports errors.
  Future<void> _checkForUpdate() async {
    final update = await UpdateService.checkForUpdate();
    if (update == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text('发现新版本 ${update.releaseName}'),
        action: SnackBarAction(
          label: '去下载',
          onPressed: () => launchUrl(
            Uri.parse(update.releaseUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }

  Future<void> _initAsync() async {
    _config = await XdRemuxService.loadConfig();
    try {
      _version = await XdRemuxService.getVersion();
    } catch (e) {
      _version = 'core error: $e';
    }
    // Android: resolve app-specific external output directory
    if (Platform.isAndroid) {
      try {
        final dir = await getExternalStorageDirectory();
        if (dir != null) {
          _androidOutputDir = dir.path;
          // Ensure the output subdirectory exists
          final outDir = Directory(
            '${dir.path}${Platform.pathSeparator}output',
          );
          if (!outDir.existsSync()) outDir.createSync(recursive: true);
          _androidOutputDir = outDir.path;
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});

    // M6: Check for resumable checkpoint
    await _checkForResumeCheckpoint();
  }

  /// Check if a previous incomplete checkpoint exists and prompt to resume.
  Future<void> _checkForResumeCheckpoint() async {
    final checkpoint = await CheckpointService.load();
    if (checkpoint == null) return;
    if (checkpoint.allSuccess) {
      // Previous run completed successfully, clean up stale checkpoint
      await CheckpointService.delete();
      return;
    }
    if (!mounted) return;

    // Show resume dialog
    final shouldResume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ResumeCheckpointDialog(checkpoint: checkpoint),
    );

    if (shouldResume == true && mounted) {
      _restoreFromCheckpoint(checkpoint);
    } else {
      // User declined or dismissed — discard old checkpoint
      await CheckpointService.delete();
    }
  }

  /// Restore queue state from a checkpoint.
  void _restoreFromCheckpoint(Checkpoint checkpoint) {
    final existing = _queue.map((item) => item.inputPath).toSet();

    for (final cpItem in checkpoint.items) {
      if (existing.contains(cpItem.inputPath)) continue;

      final QueueItemStatus status;
      switch (cpItem.status) {
        case CheckpointItemStatus.converted:
          status = QueueItemStatus.converted;
        case CheckpointItemStatus.skippedExisting:
          status = QueueItemStatus.skippedExisting;
        case CheckpointItemStatus.failed:
          status = QueueItemStatus.failed;
        case CheckpointItemStatus.pending:
          status = QueueItemStatus.pending;
      }

      _queue.add(
        QueueItem(
          id: _makeId(),
          inputPath: cpItem.inputPath,
          outputPath: cpItem.outputPath,
          status: status,
          errorMessage: cpItem.error,
          outputPlanStatus: _computeOutputPlan(
            cpItem.inputPath,
            cpItem.outputPath,
          ),
          finishedAt: cpItem.finishedAt,
        ),
      );
      existing.add(cpItem.inputPath);
    }

    _checkpoint = checkpoint;
    _validateOutputPlans();
    _updateStatusText();
    setState(() {
      _currentFileName =
          '已恢复 ${checkpoint.completedCount}/${checkpoint.items.length} 个文件的进度';
    });
  }

  void _initDropChannel() {
    // Desktop-only: native window sends dropped file paths via MethodChannel.
    if (Platform.isAndroid || Platform.isIOS) return;
    _dropChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFilesDropped') {
        final paths = List<String>.from(call.arguments as List);
        await _handleDrop(paths);
      }
    });
  }

  @override
  void dispose() {
    _configSaveTimer?.cancel();
    _progressTimer?.cancel();
    _captureFocusNode.dispose();
    super.dispose();
  }

  void _scheduleConfigSave() {
    _configSaveTimer?.cancel();
    _configSaveTimer = Timer(const Duration(milliseconds: 500), () {
      XdRemuxService.saveConfig(_config);
    });
  }

  // ---------------------------------------------------------------------------
  // Queue management
  // ---------------------------------------------------------------------------

  bool get _canEditQueue => !_isProcessing;

  bool get _canStart =>
      !_isProcessing &&
      _queue.any(
        (item) =>
            item.status == QueueItemStatus.pending &&
            !item.outputPlanStatus.blocksConversion,
      );

  int get _totalFiles => _queue.length;

  int get _processedCount =>
      _queue.where((item) => item.status.isTerminal).length;

  int get _pendingCount =>
      _queue.where((item) => item.status == QueueItemStatus.pending).length;

  int get _convertedCount =>
      _queue.where((item) => item.status == QueueItemStatus.converted).length;

  int get _skippedCount => _queue
      .where((item) => item.status == QueueItemStatus.skippedExisting)
      .length;

  int get _failedCount =>
      _queue.where((item) => item.status == QueueItemStatus.failed).length;

  double get _progressFraction {
    if (_totalFiles == 0) return 0.0;

    // Count fully completed files.
    final completed = _convertedCount + _skippedCount + _failedCount;

    // Add partial progress from the currently-running items.
    double partial = 0.0;
    for (final item in _queue) {
      final p = item.progress;
      if (p != null && item.status == QueueItemStatus.running) {
        // The HEVC tile encoding phase (~stage 3) dominates runtime.
        // Other stages contribute a fixed small fraction each.
        if (p.stage == 3 && p.total > 0) {
          partial += p.current / p.total;
        }
        // Give each running job equal weight.
        partial = partial.clamp(0.0, 1.0);
        break; // only show the first running job's granular progress
      }
    }

    return (completed + partial) / _totalFiles;
  }

  void _updateStatusText() {
    if (_isProcessing) {
      // Show progress of the currently-active file.
      String label = '转换中';
      for (final item in _queue) {
        if (item.status == QueueItemStatus.running) {
          final pl = item.progressLabel;
          if (pl.isNotEmpty) {
            label = pl;
          }
          break;
        }
      }
      setState(() => _statusText = label);
    } else if (_queue.isEmpty) {
      setState(() => _statusText = '就绪');
    } else if (_failedCount > 0) {
      setState(() => _statusText = '完成(有失败)');
    } else {
      setState(() => _statusText = '完成');
    }
  }

  // ---------------------------------------------------------------------------
  // File selection
  // ---------------------------------------------------------------------------

  /// Request storage/photo read permission on Android.
  /// permission_handler internally maps to the correct permission per API level:
  /// - Android 13+ (API 33): READ_MEDIA_IMAGES
  /// - Older: READ_EXTERNAL_STORAGE
  Future<void> _requestStoragePermission() async {
    try {
      // Try photos first (Android 13+); fall back to storage for older devices.
      var status = await Permission.photos.request();
      if (status.isPermanentlyDenied) {
        status = await Permission.storage.request();
      }
      if (!status.isGranted && !status.isLimited && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未获得存储权限，可能无法读取文件'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // Permission request failed; file_picker may still work via SAF.
    }
  }

  /// Resolve a file returned by Android's document picker to a real local
  /// path. Some OEM document providers return readable bytes but no usable
  /// filesystem path; keep a private app-cache copy for the Rust FFI layer in
  /// that case.
  Future<String?> _resolvePickedFile(PlatformFile file, int index) async {
    final pickedPath = file.path;
    if (pickedPath != null && pickedPath.isNotEmpty) {
      try {
        final entity = await File(pickedPath).stat();
        if (entity.type == FileSystemEntityType.file && entity.size > 0) {
          return pickedPath;
        }
        debugPrint(
          '[XDRemux][file_picker] path is not a readable file: '
          '$pickedPath (type=${entity.type}, size=${entity.size})',
        );
      } catch (e) {
        debugPrint(
          '[XDRemux][file_picker] returned path cannot be read: '
          '$pickedPath ($e)',
        );
      }
    }

    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      debugPrint(
        '[XDRemux][file_picker] no usable path or bytes for '
        '${file.name} (identifier=${file.identifier})',
      );
      return null;
    }

    final tempRoot = await getTemporaryDirectory();
    final importDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}picked_files',
    );
    await importDir.create(recursive: true);
    final safeName = file.name.replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
      '_',
    );
    final name = safeName.isEmpty ? 'picked_$index.heic' : safeName;
    final cachedPath =
        '${importDir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$name';
    await File(cachedPath).writeAsBytes(bytes, flush: true);
    debugPrint(
      '[XDRemux][file_picker] materialized ${file.name} '
      '(${bytes.length} bytes) at $cachedPath',
    );
    return cachedPath;
  }

  Future<void> _addFiles() async {
    if (!_canEditQueue) return;

    // Android: request storage/photo permission before picking files
    if (Platform.isAndroid) {
      await _requestStoragePermission();
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['heic', 'heif'],
      allowMultiple: true,
      // Keep a byte fallback for OEM pickers that don't return a path from
      // their content provider. The Rust core requires a local filesystem
      // path, so _resolvePickedFile() materializes these bytes into cache.
      withData: true,
    );

    if (result == null) {
      debugPrint('[XDRemux][file_picker] picker returned null');
      if (mounted) setState(() => _currentFileName = '未选择文件');
      return;
    }
    debugPrint(
      '[XDRemux][file_picker] returned ${result.files.length} file(s): '
      '${result.files.map((file) => '${file.name}|path=${file.path}|bytes=${file.bytes?.length}|id=${file.identifier}').join('; ')}',
    );
    if (result.files.isEmpty) {
      if (mounted) setState(() => _currentFileName = '文件选择器未返回文件');
      return;
    }

    final existing = _queue.map((item) => item.inputPath).toSet();
    int added = 0;
    int skipped = 0;
    String? firstError;

    for (var index = 0; index < result.files.length; index++) {
      final file = result.files[index];
      final path = await _resolvePickedFile(file, index);
      if (path == null) {
        skipped++;
        continue;
      }
      if (existing.contains(path)) continue;

      try {
        final classification = await XdRemuxService.classify(path);
        final folderName = classification['folderName'] as String?;
        final outputPath = _config.outputPathFor(
          path,
          fallbackDir: _androidOutputDir,
          captureModeFolderName: folderName,
        );
        _queue.add(
          QueueItem(
            id: _makeId(),
            inputPath: path,
            outputPath: outputPath,
            outputPlanStatus: _computeOutputPlan(path, outputPath),
            captureModeKey: classification['modeKey'] as String?,
            captureModeFolderName: folderName,
            classificationStatus: classification['status'] as String?,
          ),
        );
        existing.add(path);
        added++;
      } catch (e) {
        firstError ??= '$e';
        debugPrint('[XDRemux][file_picker] classify failed for $path: $e');
        if (mounted) {
          setState(() => _currentFileName = '添加失败: $e');
        }
      }
    }

    _validateOutputPlans();
    _updateStatusText();
    if (!mounted) return;
    setState(() {
      if (added > 0 && skipped == 0 && firstError == null) {
        _currentFileName = '已添加 $added 个文件';
      } else if (added > 0) {
        _currentFileName =
            '已添加 $added 个文件'
            '${skipped > 0 ? '，$skipped 个文件无法读取' : ''}'
            '${firstError != null ? '，$firstError' : ''}';
      } else if (firstError != null) {
        _currentFileName = '添加失败：$firstError';
      } else if (skipped > 0) {
        _currentFileName = '未添加：$skipped 个文件无法读取';
      } else {
        _currentFileName = '未添加新文件';
      }
    });
  }

  OutputPlanStatus _computeOutputPlan(String inputPath, String outputPath) {
    try {
      final inputFile = File(inputPath);
      if (!inputFile.existsSync()) return OutputPlanStatus.inputMissing;

      final outputFile = File(outputPath);
      final parent = outputFile.parent;
      if (parent.existsSync() &&
          !parent.path.endsWith(Platform.pathSeparator)) {
        try {
          if (FileSystemEntity.typeSync(parent.path) !=
              FileSystemEntityType.directory) {
            return OutputPlanStatus.outputParentIsFile;
          }
        } catch (_) {}
      }

      if (!outputFile.existsSync()) return OutputPlanStatus.ready;

      if (_config.skipExisting) {
        return OutputPlanStatus.skipsExistingValidOutput;
      }
      return OutputPlanStatus.willOverwriteExisting;
    } catch (_) {
      return OutputPlanStatus.ready;
    }
  }

  void _validateOutputPlans() {
    // Mark duplicate output paths
    final seen = <String, List<int>>{};
    for (int i = 0; i < _queue.length; i++) {
      final item = _queue[i];
      if (item.status == QueueItemStatus.pending ||
          item.status == QueueItemStatus.failed ||
          item.status == QueueItemStatus.cancelled) {
        seen.putIfAbsent(item.outputPath, () => []).add(i);
      }
    }
    for (final entry in seen.values) {
      if (entry.length > 1) {
        for (final i in entry) {
          _queue[i].outputPlanStatus = OutputPlanStatus.duplicateOutput;
        }
      }
    }
  }

  void _refreshOutputPaths() {
    for (int i = 0; i < _queue.length; i++) {
      final item = _queue[i];
      if (item.status == QueueItemStatus.pending ||
          item.status == QueueItemStatus.failed ||
          item.status == QueueItemStatus.cancelled) {
        item.outputPath = _config.outputPathFor(
          item.inputPath,
          fallbackDir: _androidOutputDir,
          captureModeFolderName: item.captureModeFolderName,
        );
        item.outputPlanStatus = _computeOutputPlan(
          item.inputPath,
          item.outputPath,
        );
      }
    }
    _validateOutputPlans();
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Conversion
  // ---------------------------------------------------------------------------

  Future<void> _startConversion() async {
    if (!_canStart) return;

    // Retry failed, reset cancelled
    for (int i = 0; i < _queue.length; i++) {
      if (_queue[i].status == QueueItemStatus.failed ||
          _queue[i].status == QueueItemStatus.cancelled) {
        _queue[i].status = QueueItemStatus.pending;
        _queue[i].errorMessage = null;
        _queue[i].startedAt = null;
        _queue[i].finishedAt = null;
      }
    }
    _refreshOutputPaths();

    // Mark output-plan blockers as failed
    for (int i = 0; i < _queue.length; i++) {
      if (_queue[i].status == QueueItemStatus.pending &&
          _queue[i].outputPlanStatus.blocksConversion) {
        _queue[i].status = QueueItemStatus.failed;
        _queue[i].errorMessage =
            '输出计划不可用: ${_queue[i].outputPlanStatus.displayName}';
        _queue[i].finishedAt = DateTime.now();
      }
    }

    setState(() {
      _isProcessing = true;
      _statusText = '准备转换...';
    });

    // M6: Create or update checkpoint
    _initCheckpoint();

    final concurrency = _config.maxConcurrentJobs.clamp(1, 4);
    _currentConcurrency = concurrency;

    int active = 0;
    int cursor = 0;

    void scheduleNext() {
      if (!mounted || !_isProcessing) return;
      setState(() {});

      // Feed next pending item
      while (active < concurrency && cursor < _queue.length) {
        if (_queue[cursor].status == QueueItemStatus.pending &&
            !_queue[cursor].outputPlanStatus.blocksConversion) {
          final idx = cursor;
          _queue[idx].status = QueueItemStatus.running;
          _queue[idx].startedAt = DateTime.now();
          _queue[idx].errorMessage = null;
          _currentFileName = _queue[idx].fileName;
          active++;
          _convertOne(idx).then((_) {
            active--;
            scheduleNext();
          });
        }
        cursor++;
      }

      // Check if done
      if (active == 0 && cursor >= _queue.length) {
        setState(() {
          _isProcessing = false;
          _currentConcurrency = 0;
          _currentFileName = '';
        });
        _updateStatusText();
        _onBatchComplete();
      }
    }

    scheduleNext();
  }

  Future<void> _convertOne(int index) async {
    final item = _queue[index];
    final runConfig = _config.copy();

    // Start polling progress from the Rust core.
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      try {
        final (stage, current, total) = XdRemuxFFI.readProgress();
        if (_queue.length > index) {
          _queue[index].progress = (
            stage: stage,
            current: current,
            total: total,
          );
          _updateStatusText();
          setState(() {});
        }
      } catch (_) {}
    });

    try {
      // Check skipExisting
      if (runConfig.skipExisting &&
          File(item.outputPath).existsSync() &&
          await XdRemuxService.verifyOutput(item.outputPath)) {
        item.status = QueueItemStatus.skippedExisting;
        item.finishedAt = DateTime.now();
        item.progress = null;
        if (mounted) setState(() {});
        return;
      }

      // Remove existing output file if present
      final outFile = File(item.outputPath);
      if (outFile.existsSync() && item.inputPath != item.outputPath) {
        outFile.deleteSync();
      }

      final result = await XdRemuxService.convert(
        item.inputPath,
        item.outputPath,
        oppoCompat: runConfig.oppoCompatibility.rustValue,
        oppoCameraTail: runConfig.oppoCameraTail.rustValue,
        strictTmap: runConfig.strictTmap,
      );

      if (result['success'] == true) {
        item.status = QueueItemStatus.converted;
      } else {
        item.status = QueueItemStatus.failed;
        item.errorMessage = result['errorMessage'] ?? '未知错误';
      }
    } catch (e) {
      item.status = QueueItemStatus.failed;
      item.errorMessage = e.toString();
    }

    item.finishedAt = DateTime.now();
    item.progress = null;
    if (mounted) setState(() {});

    // M6: Update checkpoint after each file completes
    _updateCheckpointForItem(item);
  }

  void _cancelConversion() {
    if (!_isProcessing) return;
    setState(() {
      _isProcessing = false;
      _statusText = '已取消';
      _currentConcurrency = 0;
      _currentFileName = '';
    });
    // Mark running/pending as cancelled
    for (int i = 0; i < _queue.length; i++) {
      if (_queue[i].status == QueueItemStatus.running ||
          _queue[i].status == QueueItemStatus.pending) {
        _queue[i].status = QueueItemStatus.cancelled;
        _queue[i].finishedAt ??= DateTime.now();
      }
    }
    // M6: Save checkpoint on cancel so progress is preserved
    _saveCheckpoint();
  }

  // ---------------------------------------------------------------------------
  // Checkpoint (M6)
  // ---------------------------------------------------------------------------

  /// Initialize checkpoint at the start of a batch conversion.
  /// If resuming, keep existing completed items; otherwise create fresh.
  void _initCheckpoint() {
    final configHash = CheckpointService.computeConfigHash(_config);

    if (_checkpoint != null && _checkpoint!.header.configHash == configHash) {
      // Resuming: update pending items from current queue, preserve completed
      final cpItems = _checkpoint!.items;
      final cpByPath = {for (final ci in cpItems) ci.inputPath: ci};

      for (final qItem in _queue) {
        if (!cpByPath.containsKey(qItem.inputPath)) {
          // New item not in checkpoint
          cpItems.add(
            CheckpointItem(
              inputPath: qItem.inputPath,
              outputPath: qItem.outputPath,
              status: CheckpointItemStatus.pending,
              inputSize: _fileSize(qItem.inputPath),
              inputMtimeMs: _fileMtimeMs(qItem.inputPath),
            ),
          );
        }
      }
    } else {
      // Fresh start: create new checkpoint from queue
      _checkpoint = Checkpoint(
        header: CheckpointHeader(
          configHash: configHash,
          totalJobs: _queue.length,
          startedAt: DateTime.now(),
          appVersion: _version,
        ),
        items: CheckpointService.createItemsFromQueue(_queue),
      );
    }
    _saveCheckpoint();
  }

  /// Update checkpoint status for a completed queue item and persist.
  void _updateCheckpointForItem(QueueItem item) {
    if (_checkpoint == null) return;

    final CheckpointItemStatus cpStatus;
    switch (item.status) {
      case QueueItemStatus.converted:
        cpStatus = CheckpointItemStatus.converted;
      case QueueItemStatus.skippedExisting:
        cpStatus = CheckpointItemStatus.skippedExisting;
      case QueueItemStatus.failed:
        cpStatus = CheckpointItemStatus.failed;
      default:
        return; // Don't record non-terminal states
    }

    CheckpointService.updateItemStatus(
      _checkpoint!,
      item.inputPath,
      cpStatus,
      error: item.errorMessage,
    );
    _saveCheckpoint();
  }

  /// Persist current checkpoint to disk.
  void _saveCheckpoint() {
    if (_checkpoint == null) return;
    CheckpointService.save(_checkpoint!);
  }

  /// Called when the entire batch finishes.
  /// Deletes checkpoint if zero failures; otherwise keeps it for resume.
  void _onBatchComplete() {
    if (_checkpoint == null) return;

    if (_failedCount == 0) {
      // All success — remove checkpoint
      CheckpointService.delete();
      _checkpoint = null;
    } else {
      // Has failures — keep checkpoint for potential resume
      _saveCheckpoint();
    }
  }

  static int _fileSize(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  static int _fileMtimeMs(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.statSync().modified.millisecondsSinceEpoch : 0;
    } catch (_) {
      return 0;
    }
  }

  void _clearQueue() {
    if (!_canEditQueue) return;
    setState(() {
      _queue.clear();
      _selectedIndex = null;
      _statusText = '就绪';
      _currentFileName = '';
    });
    // M6: Clear checkpoint when queue is manually cleared
    _checkpoint = null;
    CheckpointService.delete();
  }

  void _clearCompleted() {
    if (!_canEditQueue) return;
    setState(() {
      _queue.removeWhere(
        (item) =>
            item.status == QueueItemStatus.converted ||
            item.status == QueueItemStatus.skippedExisting,
      );
      if (_selectedIndex != null && _selectedIndex! >= _queue.length) {
        _selectedIndex = _queue.isEmpty ? null : _queue.length - 1;
      }
      if (_queue.isEmpty) {
        _statusText = '就绪';
      }
    });
  }

  void _retryFailed() {
    if (!_canEditQueue) return;
    bool hadFailed = false;
    for (int i = 0; i < _queue.length; i++) {
      if (_queue[i].status == QueueItemStatus.failed) {
        _queue[i].status = QueueItemStatus.pending;
        _queue[i].errorMessage = null;
        _queue[i].startedAt = null;
        _queue[i].finishedAt = null;
        hadFailed = true;
      }
    }
    if (hadFailed) _refreshOutputPaths();
  }

  void _removeItem(int index) {
    if (!_canEditQueue) return;
    setState(() {
      _queue.removeAt(index);
      if (_selectedIndex != null) {
        if (_selectedIndex! >= _queue.length) {
          _selectedIndex = _queue.isEmpty ? null : _queue.length - 1;
        }
      }
      if (_queue.isEmpty) {
        _statusText = '就绪';
      }
    });
  }

  void _openOrganizePage() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const OrganizePage()));
  }

  // ---------------------------------------------------------------------------
  // Drag & drop
  // ---------------------------------------------------------------------------

  Widget _buildDropTarget(BuildContext context, Widget child) {
    // Drag & drop is desktop-only; on mobile just return the child directly.
    if (Platform.isAndroid || Platform.isIOS) return child;
    return DragTarget<List<String>>(
      onWillAcceptWithDetails: (_) => _canEditQueue,
      onAcceptWithDetails: (details) => _handleDrop(details.data),
      builder: (context, candidate, rejected) {
        final isHovering = candidate.isNotEmpty && _canEditQueue;
        return Stack(
          children: [
            child,
            if (isHovering)
              Positioned.fill(
                child: Container(
                  color: Theme.of(context).colorScheme.primary.withAlpha(30),
                  child: Center(
                    child: Icon(
                      Icons.cloud_upload,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _handleDrop(List<String> paths) async {
    final existing = _queue.map((item) => item.inputPath).toSet();
    int added = 0;
    int ignored = 0;
    for (final path in paths) {
      if (!isSupportedInputPath(path)) {
        ignored++;
        continue;
      }
      if (existing.contains(path)) continue;
      try {
        final classification = await XdRemuxService.classify(path);
        final folderName = classification['folderName'] as String?;
        final outputPath = _config.outputPathFor(
          path,
          fallbackDir: _androidOutputDir,
          captureModeFolderName: folderName,
        );
        _queue.add(
          QueueItem(
            id: _makeId(),
            inputPath: path,
            outputPath: outputPath,
            outputPlanStatus: _computeOutputPlan(path, outputPath),
            captureModeKey: classification['modeKey'] as String?,
            captureModeFolderName: folderName,
            classificationStatus: classification['status'] as String?,
          ),
        );
        existing.add(path);
        added++;
      } catch (_) {
        // Keep drag-and-drop responsive even if metadata classification fails.
      }
    }
    if (added > 0) {
      _validateOutputPlans();
      _updateStatusText();
    }
    if (added == 0 && ignored == 0) return;

    final summary = added > 0 && ignored > 0
        ? '已拖入 $added 个文件，已忽略 $ignored 个非 HEIC 文件'
        : added > 0
        ? '已拖入 $added 个文件'
        : '未添加：$ignored 个文件都不是 HEIC';
    setState(() => _currentFileName = summary);
    if (ignored > 0 && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(summary)));
    }
  }

  void _revealInExplorer(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      // Open containing directory
      Process.run('xdg-open', [File(path).parent.path]);
    } else if (Platform.isAndroid) {
      // Android: open file with system default app (Gallery/file viewer).
      FileActionService.openFile(path).then((ok) {
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('无法打开: $path'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      });
    }
  }

  void _revealOutputs() {
    final outputs = _queue
        .where((item) => item.isSuccessful)
        .map((item) => item.outputPath)
        .toList();
    if (outputs.isEmpty) return;
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,', outputs.first]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', outputs.first]);
    } else if (Platform.isAndroid) {
      _revealInExplorer(outputs.first);
    }
  }

  /// Gallery album for an output item: capture-mode folder name when
  /// categorize-by-mode is on and the mode was recognized, else 'XDRemux'.
  String? _galleryAlbum(QueueItem item) {
    if (_config.categorizeOutputByMode &&
        item.captureModeFolderName != null &&
        item.captureModeFolderName!.isNotEmpty) {
      return item.captureModeFolderName;
    }
    return null; // service default 'XDRemux'
  }

  String _galleryAlbumSubtitle(QueueItem item) {
    final album = _galleryAlbum(item) ?? 'XDRemux';
    // gal/MediaStore places image albums under Pictures/, not DCIM/.
    return 'Pictures/$album';
  }

  /// Android: show bottom sheet with output file actions.
  void _showOutputActions(QueueItem item) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('保存到图库'),
                subtitle: Text(_galleryAlbumSubtitle(item)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final hasAccess =
                      await FileActionService.hasGalleryPermission();
                  if (!hasAccess) {
                    final granted =
                        await FileActionService.requestGalleryPermission();
                    if (!granted) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('未获得存储权限')),
                        );
                      }
                      return;
                    }
                  }
                  final ok = await FileActionService.saveToGallery(
                    item.outputPath,
                    album: _galleryAlbum(item),
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(ok ? '已保存到图库' : '保存失败')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('分享'),
                onTap: () {
                  Navigator.pop(ctx);
                  FileActionService.shareFile(item.outputPath);
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('打开'),
                subtitle: const Text('用系统图库打开'),
                onTap: () {
                  Navigator.pop(ctx);
                  FileActionService.openFile(item.outputPath);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  static String _makeId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final ms = (DateTime.now().millisecondsSinceEpoch % 100000);
    return '${ts.toRadixString(36)}-${ms.toString().padLeft(5, '0')}';
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;

    return KeyboardListener(
      focusNode: _captureFocusNode,
      onKeyEvent: _onKey,
      child: RepaintBoundary(
        key: _rootKey,
        child: Scaffold(
          appBar: _buildAppBar(theme, compact),
          bottomNavigationBar: compact ? _buildMobileActionBar(theme) : null,
          body: _buildDropTarget(
            context,
            Column(
              children: [
                _buildProgressBar(theme),
                const Divider(height: 1),
                Expanded(
                  child: _queue.isEmpty
                      ? _buildEmptyState(theme)
                      : _buildQueueView(theme, compact),
                ),
                if (_queue.isNotEmpty && !compact) _buildFooter(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar(ThemeData theme, bool compact) {
    final actions = <Widget>[
      if (!compact)
        IconButton(
          icon: const Icon(Icons.add_photo_alternate),
          tooltip: '添加 HEIC',
          onPressed: _canEditQueue ? _addFiles : null,
        ),
      if (!compact && _canStart)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始'),
            onPressed: _startConversion,
          ),
        ),
      if (_canEditQueue)
        Padding(
          padding: EdgeInsets.only(left: compact ? 0 : 4),
          child: _OppoCompatToggle(
            mode: _config.oppoCompatibility,
            onChanged: (mode) {
              setState(() => _config.oppoCompatibility = mode);
              _scheduleConfigSave();
            },
          ),
        ),
      if (!compact)
        IconButton(
          icon: const Icon(Icons.stop),
          tooltip: '取消',
          onPressed: _isProcessing ? _cancelConversion : null,
        ),
      IconButton(
        icon: const Icon(Icons.tune),
        tooltip: '设置',
        onPressed: () => _openSettings(context),
      ),
      // 整理页依赖目录递归扫描 + 任意位置复制，Android scoped storage 下不可用。
      if (!Platform.isAndroid)
        IconButton(
          icon: const Icon(Icons.folder_copy_outlined),
          tooltip: '按拍摄模式整理',
          onPressed: _openOrganizePage,
        ),
      _buildQueueOverflowMenu(),
      const SizedBox(width: 4),
    ];

    return AppBar(
      titleSpacing: compact ? 16 : null,
      title: compact ? const Text('XDRemux') : Text('XDRemux$_versionSuffix'),
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      actions: actions,
    );
  }

  Widget _buildQueueOverflowMenu() {
    return PopupMenuButton<_QueueMenuAction>(
      tooltip: '更多操作',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _QueueMenuAction.retryFailed:
            _retryFailed();
          case _QueueMenuAction.clearCompleted:
            _clearCompleted();
          case _QueueMenuAction.revealOutputs:
            _revealOutputs();
          case _QueueMenuAction.clearQueue:
            _clearQueue();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _QueueMenuAction.retryFailed,
          enabled: _canEditQueue && _failedCount > 0,
          child: const ListTile(
            leading: Icon(Icons.refresh),
            title: Text('重试失败项'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: _QueueMenuAction.clearCompleted,
          enabled: _canEditQueue && (_convertedCount + _skippedCount) > 0,
          child: const ListTile(
            leading: Icon(Icons.checklist),
            title: Text('清除已完成'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (!Platform.isAndroid)
          PopupMenuItem(
            value: _QueueMenuAction.revealOutputs,
            enabled: _queue.any((item) => item.isSuccessful),
            child: const ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('打开输出目录'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QueueMenuAction.clearQueue,
          enabled: _canEditQueue && _queue.isNotEmpty,
          child: const ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('清空队列'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Widget _buildMobileActionBar(ThemeData theme) {
    final primaryLabel = _isProcessing ? '取消转换' : '开始转换';
    final primaryIcon = _isProcessing
        ? Icons.stop_circle_outlined
        : Icons.play_arrow;
    final primaryAction = _isProcessing
        ? _cancelConversion
        : (_canStart ? _startConversion : null);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('添加文件'),
                onPressed: _canEditQueue ? _addFiles : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: Icon(primaryIcon),
                label: Text(primaryLabel),
                onPressed: primaryAction,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Save a PNG screenshot of the app window to the project screenshots dir.
  Future<void> _captureScreenshot() async {
    try {
      final boundary =
          _rootKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final dir = Directory('screenshots');
      if (!dir.existsSync()) dir.createSync();
      final file = File('screenshots/windows_main.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      if (mounted) {
        setState(() => _currentFileName = '截图已保存: ${file.path}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _currentFileName = '截图失败: $e');
      }
    }
  }

  String get _versionSuffix => _version.isNotEmpty ? ' $_version' : '';

  // Keyboard handler for screenshot capture (Ctrl+Shift+S).
  final FocusNode _captureFocusNode = FocusNode();
  void _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyS) {
      _captureScreenshot();
    }
  }

  Widget _buildProgressBar(ThemeData theme) {
    final currentItem = _queue
        .where((i) => i.status == QueueItemStatus.running)
        .firstOrNull;
    final narrow = MediaQuery.of(context).size.width < 480;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 16,
        vertical: narrow ? 8 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row: status text + file count
          Row(
            children: [
              if (currentItem != null)
                Icon(Icons.bolt, size: 14, color: Colors.blue.shade700),
              if (currentItem != null) const SizedBox(width: 4),
              Expanded(
                child: Text(
                  currentItem != null
                      ? '${currentItem.progressLabel} · ${currentItem.fileName}'
                      : _statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: currentItem != null ? Colors.blue.shade700 : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              Text(
                '$_processedCount/$_totalFiles',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Progress bar + stat chips
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: _progressFraction,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              _buildStatChip('✓', _convertedCount, Colors.green),
              if (_skippedCount > 0) ...[
                const SizedBox(width: 4),
                _buildStatChip('⏭', _skippedCount, Colors.grey),
              ],
              if (_failedCount > 0) ...[
                const SizedBox(width: 4),
                _buildStatChip('✗', _failedCount, Colors.red),
              ],
            ],
          ),
          // Extra info row (desktop only)
          if (!narrow) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.memory, size: 14),
                const SizedBox(width: 4),
                Text(
                  '并发 ${_currentConcurrency > 0 ? _currentConcurrency : _config.maxConcurrentJobs}',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(width: 16),
                const Icon(Icons.schedule, size: 14),
                const SizedBox(width: 4),
                Text('待处理 $_pendingCount', style: theme.textTheme.labelSmall),
                const SizedBox(width: 16),
                if (_currentFileName.isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      _currentFileName,
                      style: theme.textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final isAndroid = Platform.isAndroid;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 20 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            color: theme.colorScheme.surface,
            child: Padding(
              padding: EdgeInsets.all(compact ? 24 : 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: compact ? 72 : 88,
                    height: compact ? 72 : 88,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      size: compact ? 36 : 44,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  SizedBox(height: compact ? 20 : 24),
                  Text(
                    '让 ProXDR HEIC 更容易分享',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isAndroid
                        ? '选择 OPPO / OnePlus / realme 的 HEIC，转换为通用 HDR 格式。'
                        : '拖拽 HEIC 到窗口，或选择文件后转换为通用 HDR 格式。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('添加文件'),
                    onPressed: _addFiles,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      _FeatureChip(icon: Icons.shield_outlined, label: '本地处理'),
                      _FeatureChip(
                        icon: Icons.hdr_on_outlined,
                        label: '保留 HDR',
                      ),
                      _FeatureChip(
                        icon: Icons.batch_prediction_outlined,
                        label: '支持批量',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQueueView(ThemeData theme, bool compact) {
    return compact ? _buildMobileQueue(theme) : _buildPhotoGrid(theme);
  }

  Widget _buildMobileQueue(ThemeData theme) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
      itemCount: _queue.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
            child: Row(
              children: [
                Text(
                  '转换队列',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_queue.length} 个文件',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        final itemIndex = index - 1;
        final item = _queue[itemIndex];
        return _MobileQueueCard(
          item: item,
          isSelected: itemIndex == _selectedIndex,
          onTap: () {
            setState(() => _selectedIndex = itemIndex);
            _showItemDetail(item);
          },
          onRevealOutput: () {
            if (Platform.isAndroid) {
              _showOutputActions(item);
            } else {
              _revealInExplorer(item.outputPath);
            }
          },
          onRetry: _retryFailed,
          onRemove: () => _removeItem(itemIndex),
        );
      },
    );
  }

  Widget _buildPhotoGrid(ThemeData theme) {
    if (_queue.isEmpty) {
      return Center(
        child: Text(
          '选择队列项目查看详情',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 1500
            ? 5
            : constraints.maxWidth >= 1120
            ? 4
            : constraints.maxWidth >= 800
            ? 3
            : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.9,
          ),
          itemCount: _queue.length,
          itemBuilder: (context, index) {
            return _PhotoCard(
              item: _queue[index],
              isSelected: index == _selectedIndex,
              onTap: () {
                setState(() => _selectedIndex = index);
                _showItemDetail(_queue[index]);
              },
              onRevealInput: () => _revealInExplorer(_queue[index].inputPath),
              onRevealOutput: () {
                if (Platform.isAndroid) {
                  _showOutputActions(_queue[index]);
                } else {
                  _revealInExplorer(_queue[index].outputPath);
                }
              },
              onRetry: () => _retryFailed(),
              onRemove: () => _removeItem(index),
            );
          },
        );
      },
    );
  }

  void _showItemDetail(QueueItem item) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxWidth: compact ? double.infinity : 720),
      builder: (ctx) => _ItemDetailSheet(
        item: item,
        revealInput: () => _revealInExplorer(item.inputPath),
        revealOutput: () => _revealInExplorer(item.outputPath),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final narrow = MediaQuery.of(context).size.width < 480;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (_failedCount > 0 && !narrow)
            Expanded(
              child: Text(
                _queue.reversed
                    .where((item) => item.status == QueueItemStatus.failed)
                    .take(3)
                    .map(
                      (item) => '${item.fileName}: ${item.errorMessage ?? '?'}',
                    )
                    .join(' | '),
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.red),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: narrow ? const SizedBox.shrink() : const Text('重试失败'),
            onPressed: _canEditQueue && _failedCount > 0 ? _retryFailed : null,
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.checklist, size: 16),
            label: narrow ? const SizedBox.shrink() : const Text('清除已完成'),
            onPressed: _canEditQueue && (_convertedCount + _skippedCount) > 0
                ? _clearCompleted
                : null,
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: narrow ? const SizedBox.shrink() : const Text('打开输出目录'),
            onPressed: _queue.any((item) => item.isSuccessful)
                ? _revealOutputs
                : null,
          ),
        ],
      ),
    );
  }

  void _openSettings(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxWidth: compact ? double.infinity : 720),
      builder: (ctx) => _SettingsSheet(
        config: _config,
        onChanged: () {
          _scheduleConfigSave();
          _refreshOutputPaths();
        },
      ),
    );
  }
}

// ============================================================================
// Expandable error message
// ============================================================================

class _ExpandableError extends StatefulWidget {
  final String message;

  const _ExpandableError({required this.message});

  @override
  State<_ExpandableError> createState() => _ExpandableErrorState();
}

class _ExpandableErrorState extends State<_ExpandableError> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withAlpha(20),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withAlpha(80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, size: 16, color: Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.message,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.red,
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.message));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制错误信息'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy, size: 12, color: Colors.red.shade300),
                    const SizedBox(width: 4),
                    Text(
                      '复制错误信息',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.red.shade300,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Output preview
// ============================================================================

class _OutputPreview extends StatelessWidget {
  final String outputPath;

  const _OutputPreview({required this.outputPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: FutureBuilder<Uint8List?>(
        future: _generatePreview(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('输出预览', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    snapshot.data!,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: 240,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  Future<Uint8List?> _generatePreview() async {
    // All platforms: Rust FFI extracts the embedded EXIF JPEG thumbnail.
    try {
      return XdRemuxFFI.extractThumbnail(outputPath);
    } catch (_) {
      return null;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DetailPathRow extends StatelessWidget {
  final String label;
  final String path;
  final VoidCallback onReveal;

  const _DetailPathRow(this.label, this.path, this.onReveal);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onReveal,
                child: const Icon(Icons.open_in_new, size: 14),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            path,
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// OPPO Compat Toggle (app bar)
// ============================================================================

class _OppoCompatToggle extends StatelessWidget {
  final OppoCompatMode mode;
  final ValueChanged<OppoCompatMode> onChanged;

  const _OppoCompatToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOn = mode != OppoCompatMode.off;

    return Tooltip(
      message: isOn ? 'OPPO 兼容：开启' : 'OPPO 兼容：关闭',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          onChanged(isOn ? OppoCompatMode.off : OppoCompatMode.on);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isOn
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOn ? Icons.phone_android : Icons.phone_android,
                size: 16,
                color: isOn
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'OPPO',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isOn
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Settings Sheet
// ============================================================================

class _SettingsSheet extends StatefulWidget {
  final ConversionConfig config;
  final VoidCallback onChanged;

  const _SettingsSheet({required this.config, required this.onChanged});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ConversionConfig _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.config.copy();
  }

  void _emit() {
    widget.config.family = _cfg.family;
    widget.config.outputDirectory = _cfg.outputDirectory;
    widget.config.oppoCompatibility = _cfg.oppoCompatibility;
    widget.config.oppoCameraTail = _cfg.oppoCameraTail;
    widget.config.strictTmap = _cfg.strictTmap;
    widget.config.skipExisting = _cfg.skipExisting;
    widget.config.maxConcurrentJobs = _cfg.maxConcurrentJobs;
    widget.config.fileNameSuffix = _cfg.fileNameSuffix;
    widget.config.categorizeOutputByMode = _cfg.categorizeOutputByMode;
    widget.onChanged();
    setState(() {});
  }

  Future<void> _chooseDirectory() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      if (mounted) {
        setState(() => _cfg.outputDirectory = dir);
        _emit();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;

    return SizedBox(
      height: compact ? MediaQuery.sizeOf(context).height * 0.9 : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 20 : 28,
          compact ? 10 : 28,
          compact ? 20 : 28,
          compact ? 16 : 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(90),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            Row(
              children: [
                Text('转换设置', style: theme.textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Family
                    Text('输入 HDR 类型', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    SegmentedButton<Family>(
                      segments: Family.values
                          .map(
                            (f) => ButtonSegment<Family>(
                              value: f,
                              label: Text(f.appTitle),
                            ),
                          )
                          .toList(),
                      selected: {_cfg.family},
                      onSelectionChanged: (v) {
                        setState(() => _cfg.family = v.first);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Auto 自动检测 X6/X7 设备族。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Output directory — desktop only. Android scoped storage
                    // makes an arbitrary writable directory impossible without
                    // MANAGE_EXTERNAL_STORAGE; output goes to the app-specific
                    // dir and is exported via 保存到图库 / 分享.
                    if (!Platform.isAndroid) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _cfg.outputDirectory ?? '使用源文件目录',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: _cfg.outputDirectory == null
                                    ? theme.colorScheme.onSurfaceVariant
                                    : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.folder_open),
                            tooltip: '选择目录',
                            onPressed: _chooseDirectory,
                          ),
                          IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: '清除',
                            onPressed: _cfg.outputDirectory != null
                                ? () {
                                    setState(() => _cfg.outputDirectory = null);
                                    _emit();
                                  }
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],

                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('按拍摄模式分目录输出'),
                      subtitle: const Text('将已识别的照片写入“大师模式 / 人像 / 夜景”等子目录。'),
                      value: _cfg.categorizeOutputByMode,
                      onChanged: (value) {
                        setState(() => _cfg.categorizeOutputByMode = value);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 12),

                    DropdownButtonFormField<OppoCompatMode>(
                      initialValue: _cfg.oppoCompatibility,
                      decoration: const InputDecoration(
                        labelText: 'OPPO 兼容模式',
                        border: OutlineInputBorder(),
                      ),
                      items: OppoCompatMode.values
                          .map(
                            (mode) => DropdownMenuItem(
                              value: mode,
                              child: Text(mode.appTitle),
                            ),
                          )
                          .toList(),
                      onChanged: (mode) {
                        if (mode == null) return;
                        setState(() => _cfg.oppoCompatibility = mode);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _cfg.oppoCompatibility.appHelp,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),

                    DropdownButtonFormField<OppoCameraTailMode>(
                      initialValue: _cfg.oppoCameraTail,
                      decoration: const InputDecoration(
                        labelText: 'OPPO 相机尾部元数据',
                        border: OutlineInputBorder(),
                      ),
                      items: OppoCameraTailMode.values
                          .map(
                            (mode) => DropdownMenuItem(
                              value: mode,
                              child: Text(mode.appTitle),
                            ),
                          )
                          .toList(),
                      onChanged: (mode) {
                        if (mode == null) return;
                        setState(() => _cfg.oppoCameraTail = mode);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _cfg.oppoCameraTail.appHelp,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),

                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用严格 ISO tmap'),
                      subtitle: const Text(
                        '在 tmap 头后加入 3 个 ISO 21496-1 保留字节（65 / 145 字节）。',
                      ),
                      value: _cfg.strictTmap,
                      onChanged: (value) {
                        setState(() => _cfg.strictTmap = value);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 12),

                    // Advanced settings (collapsible)
                    ExpansionTile(
                      title: Text(
                        '高级',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      tilePadding: EdgeInsets.zero,
                      initiallyExpanded: false,
                      childrenPadding: const EdgeInsets.only(top: 8),
                      children: [
                        // Skip existing
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('跳过已有有效输出'),
                          subtitle: const Text('如果输出文件已包含 ISO gain map 则跳过。'),
                          value: _cfg.skipExisting,
                          dense: true,
                          onChanged: (v) {
                            setState(() => _cfg.skipExisting = v);
                            _emit();
                          },
                        ),
                        const SizedBox(height: 12),

                        // Concurrency
                        Row(
                          children: [
                            Text('最大并行数', style: theme.textTheme.bodyLarge),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed: _cfg.maxConcurrentJobs > 1
                                  ? () {
                                      setState(() => _cfg.maxConcurrentJobs--);
                                      _emit();
                                    }
                                  : null,
                            ),
                            Text(
                              '${_cfg.maxConcurrentJobs}',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: _cfg.maxConcurrentJobs < 4
                                  ? () {
                                      setState(() => _cfg.maxConcurrentJobs++);
                                      _emit();
                                    }
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // File name suffix
                        TextField(
                          decoration: const InputDecoration(
                            labelText: '输出文件名后缀',
                            hintText: '_iso',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: _cfg.outputDirectory == null,
                          controller: TextEditingController(
                            text: _cfg.fileNameSuffix,
                          ),
                          onChanged: (v) {
                            _cfg.fileNameSuffix = v.isEmpty ? '_iso' : v;
                            _emit();
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '设置输出目录后，后缀将被忽略。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Queue cards
// ============================================================================

class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _MobileQueueCard extends StatelessWidget {
  final QueueItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRevealOutput;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  const _MobileQueueCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onRevealOutput,
    required this.onRetry,
    required this.onRemove,
  });

  Color _statusColor(ThemeData theme) {
    return switch (item.status) {
      QueueItemStatus.converted => Colors.green.shade700,
      QueueItemStatus.failed => theme.colorScheme.error,
      QueueItemStatus.running => theme.colorScheme.primary,
      QueueItemStatus.skippedExisting ||
      QueueItemStatus.cancelled => theme.colorScheme.onSurfaceVariant,
      QueueItemStatus.pending => Colors.orange.shade800,
    };
  }

  String get _supportingText {
    if (item.status == QueueItemStatus.running) {
      return item.progressLabel.isEmpty ? '正在准备转换…' : item.progressLabel;
    }
    if (item.status == QueueItemStatus.failed) {
      return item.errorMessage ?? '转换未完成，轻触查看详情。';
    }
    if (item.isSuccessful) return item.outputPlanStatus.displayName;
    return item.outputPlanStatus.blocksConversion
        ? item.outputPlanStatus.displayName
        : item.classificationLabel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(theme);
    final canRetry =
        item.status == QueueItemStatus.failed ||
        item.status == QueueItemStatus.cancelled;

    return Card(
      color: isSelected
          ? theme.colorScheme.secondaryContainer.withAlpha(150)
          : theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: isSelected
            ? BorderSide(color: theme.colorScheme.primary, width: 1.5)
            : BorderSide(color: theme.dividerColor.withAlpha(90)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                height: 76,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _ThumbnailWidget(inputPath: item.inputPath),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _MobileStatusPill(
                          label: item.status.displayName,
                          color: statusColor,
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      item.captureModeLabel ?? item.classificationLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _supportingText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: item.status == QueueItemStatus.failed
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_MobileQueueAction>(
                tooltip: '项目操作',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _MobileQueueAction.revealOutput:
                      onRevealOutput();
                    case _MobileQueueAction.retry:
                      onRetry();
                    case _MobileQueueAction.remove:
                      onRemove();
                  }
                },
                itemBuilder: (context) => [
                  if (item.isSuccessful)
                    const PopupMenuItem(
                      value: _MobileQueueAction.revealOutput,
                      child: ListTile(
                        leading: Icon(Icons.folder_open),
                        title: Text('查看输出文件'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (canRetry)
                    const PopupMenuItem(
                      value: _MobileQueueAction.retry,
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('重新尝试'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: _MobileQueueAction.remove,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('移出队列'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MobileQueueAction { revealOutput, retry, remove }

class _MobileStatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _MobileStatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ============================================================================
// Desktop photo card (grid cell)
// ============================================================================

class _PhotoCard extends StatelessWidget {
  static final Map<String, Uint8List?> _thumbCache = {};

  final QueueItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRevealInput;
  final VoidCallback onRevealOutput;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  const _PhotoCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onRevealInput,
    required this.onRevealOutput,
    required this.onRetry,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = item.status;
    final isRunning = status == QueueItemStatus.running;
    final isDone = status == QueueItemStatus.converted;
    final isFailed = status == QueueItemStatus.failed;
    final isSkipped = status == QueueItemStatus.skippedExisting;

    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: isSelected ? 4 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isSelected
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _ThumbnailWidget(inputPath: item.inputPath),
                  if (item.captureModeLabel != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(160),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item.captureModeLabel!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (isRunning)
                    _OverlayBadge(
                      icon: Icons.bolt,
                      label: item.progress != null
                          ? '${item.progress!.current}/${item.progress!.total}'
                          : '转换中',
                      color: Colors.blue,
                      bottom: 0,
                    ),
                  if (isDone)
                    const _OverlayBadge(
                      icon: Icons.check_circle,
                      label: '完成',
                      color: Colors.green,
                      bottom: 0,
                    ),
                  if (isFailed)
                    const _OverlayBadge(
                      icon: Icons.cancel,
                      label: '失败',
                      color: Colors.red,
                      bottom: 0,
                    ),
                  if (isSkipped)
                    const _OverlayBadge(
                      icon: Icons.skip_next,
                      label: '已跳过',
                      color: Colors.grey,
                      bottom: 0,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.fileName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  if (item.status == QueueItemStatus.running &&
                      item.progress != null)
                    Text(
                      '${item.progress!.current}/${item.progress!.total}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (item.isSuccessful)
                    _cardAction(theme, Icons.check_circle, onRevealOutput),
                  if (isFailed || status == QueueItemStatus.cancelled)
                    _cardAction(theme, Icons.refresh, onRetry),
                  _cardAction(theme, Icons.close, onRemove),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardAction(ThemeData theme, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ThumbnailWidget extends StatelessWidget {
  final String inputPath;

  const _ThumbnailWidget({required this.inputPath});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _PhotoCard._thumbCache.containsKey(inputPath)
          ? Future.value(_PhotoCard._thumbCache[inputPath])
          : XdRemuxService.getThumbnail(inputPath, maxPixelSize: 256).then((t) {
              _PhotoCard._thumbCache[inputPath] = t;
              return t;
            }),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );
        }
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
            child: Icon(Icons.photo, size: 32, color: Colors.grey),
          ),
        );
      },
    );
  }
}

class _OverlayBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double bottom;

  const _OverlayBadge({
    required this.icon,
    required this.label,
    required this.color,
    required this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 6,
      bottom: bottom + 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(160),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Item detail bottom sheet
// ============================================================================

class _ItemDetailSheet extends StatelessWidget {
  final QueueItem item;
  final VoidCallback revealInput;
  final VoidCallback revealOutput;

  const _ItemDetailSheet({
    required this.item,
    required this.revealInput,
    required this.revealOutput,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;

    return DraggableScrollableSheet(
      initialChildSize: compact ? 0.82 : 0.6,
      minChildSize: compact ? 0.58 : 0.4,
      maxChildSize: 0.94,
      expand: false,
      builder: (ctx, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(
            compact ? 20 : 28,
            compact ? 10 : 28,
            compact ? 20 : 28,
            28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (compact)
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withAlpha(90),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.fileName,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _StatusChip(
                    label: item.status.displayName,
                    color: item.status == QueueItemStatus.converted
                        ? Colors.green
                        : item.status == QueueItemStatus.failed
                        ? Colors.red
                        : Colors.grey,
                  ),
                  _StatusChip(
                    label: item.outputPlanStatus.displayName,
                    color: item.outputPlanStatus.blocksConversion
                        ? Colors.red
                        : Colors.orange.shade300,
                  ),
                  if (item.classificationStatus != null ||
                      item.captureModeLabel != null)
                    _StatusChip(
                      label: item.classificationLabel,
                      color: Colors.deepPurple,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (item.errorMessage != null) ...[
                _ExpandableError(message: item.errorMessage!),
                const SizedBox(height: 16),
              ],
              if (item.isSuccessful && item.status == QueueItemStatus.converted)
                _OutputPreview(outputPath: item.outputPath),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_open, size: 16),
                    label: const Text('源文件'),
                    onPressed: revealInput,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('输出文件'),
                    onPressed: item.isSuccessful ? revealOutput : null,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              _DetailRow('状态', item.status.displayName),
              _DetailRow('输出计划', item.outputPlanStatus.displayName),
              if (item.startedAt != null)
                _DetailRow(
                  '开始',
                  '${item.startedAt!.hour.toString().padLeft(2, '0')}:${item.startedAt!.minute.toString().padLeft(2, '0')}:${item.startedAt!.second.toString().padLeft(2, '0')}',
                ),
              if (item.finishedAt != null)
                _DetailRow(
                  '结束',
                  '${item.finishedAt!.hour.toString().padLeft(2, '0')}:${item.finishedAt!.minute.toString().padLeft(2, '0')}:${item.finishedAt!.second.toString().padLeft(2, '0')}',
                ),
              if (item.duration != null)
                _DetailRow('耗时', '${item.duration!.inMilliseconds / 1000} 秒'),
              _DetailPathRow('输入路径', item.inputPath, revealInput),
              _DetailPathRow('输出路径', item.outputPath, revealOutput),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================================
// Resume checkpoint dialog (M6)
// ============================================================================

class _ResumeCheckpointDialog extends StatelessWidget {
  final Checkpoint checkpoint;

  const _ResumeCheckpointDialog({required this.checkpoint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = checkpoint.completedCount;
    final failed = checkpoint.failedCount;
    final pending = checkpoint.pendingCount;
    final total = checkpoint.items.length;
    final startedAt = checkpoint.header.startedAt;
    final timeStr =
        '${startedAt.month}/${startedAt.day} ${startedAt.hour.toString().padLeft(2, '0')}:${startedAt.minute.toString().padLeft(2, '0')}';

    return AlertDialog(
      title: const Text('发现未完成的转换任务'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '上次转换开始于 $timeStr，共 $total 个文件：',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _cpStat('已完成', completed, Colors.green),
              const SizedBox(width: 12),
              _cpStat('失败', failed, failed > 0 ? Colors.red : Colors.grey),
              const SizedBox(width: 12),
              _cpStat('待处理', pending, Colors.orange),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '是否恢复并继续转换未完成的文件？',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('放弃'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('恢复'),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  Widget _cpStat(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
