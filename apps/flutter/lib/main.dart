import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/app_models.dart';
import 'models/checkpoint_model.dart';
import 'apple_portrait_page.dart';
import 'rust_portrait_page.dart';
import 'apple_oppo_workflow_page.dart';
import 'organize_page.dart';
import 'services/foreground_service.dart';
import 'services/notification_service.dart';
import 'services/tray_service.dart';
import 'services/update_service.dart';
import 'services/xdremux_service.dart';
import 'services/checkpoint_service.dart';
import 'services/file_action_service.dart';
import 'services/hardware_encoder.dart';
import 'services/conversion_backend.dart';
import 'services/drop_file_service.dart';
import 'ffi/xdremux_ffi.dart';

/// File extensions accepted by both the picker and the desktop drop target.
bool isSupportedInputPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.heic') || lower.endsWith('.heif');
}

void main() {
  runApp(const XdRemuxApp());
}

/// Remove persisted Apple feature flags when the current native capability
/// probe cannot support them. OutputMode.apple remains independent: it is a
/// clean output target. Rust Photographic Styles and the R5 Portrait graph are
/// implemented in the Rust core; Swift remains available for Apple-native paths.
bool _sanitizeConfigForCapabilities(
  ConversionConfig config,
  BackendCapabilities capabilities,
) {
  var changed = false;
  if (!capabilities.isAvailable(config.backend)) {
    config.backend = ConversionBackend.rust;
    changed = true;
  }
  if (config.backend != ConversionBackend.swift) {
    // Rust now includes the R5 native Portrait graph writer.
  } else {
    if (config.applePhotographicStyles &&
        !capabilities.swiftPhotographicStyles) {
      config.applePhotographicStyles = false;
      changed = true;
    }
    if (config.applePortrait && !capabilities.swiftPortrait) {
      config.applePortrait = false;
      changed = true;
    }
  }
  return changed;
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

enum _QueueMenuAction {
  retryFailed,
  clearCompleted,
  saveAllToGallery,
  minimizeToTray,
  clearQueue,
}

enum _PreflightSeverity { warning, blocking }

class _PreflightIssue {
  final _PreflightSeverity severity;
  final String title;
  final String? fileName;
  final String detail;

  const _PreflightIssue({
    required this.severity,
    required this.title,
    required this.detail,
    this.fileName,
  });

  bool get isBlocking => severity == _PreflightSeverity.blocking;

  String get displayText =>
      fileName == null ? '$title：$detail' : '$fileName：$title（$detail）';
}

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
  final List<_PreflightIssue> _preflightIssues = <_PreflightIssue>[];
  int? _selectedIndex;
  Timer? _progressTimer;
  final GlobalKey _rootKey = GlobalKey();

  String _version = '';
  BackendCapabilities _backendCapabilities =
      BackendCapabilities.forCurrentPlatform();
  Timer? _configSaveTimer;
  Checkpoint? _checkpoint;

  /// Android: app-specific external directory for output (scoped storage).
  String? _androidOutputDir;
  static const _dropChannel = MethodChannel('xdremux/drop');
  static const _batteryChannel = MethodChannel('xdremux/battery');

  /// Android: stream of media shared into the app while it is running.
  StreamSubscription<List<SharedMediaFile>>? _shareSubscription;

  @override
  void initState() {
    super.initState();
    _initAsync();
    _initDropChannel();
    _initShareIntake();
    NotificationService.init();
    ForegroundService.init();
    if (Platform.isWindows) {
      TrayService.init(
        onShowWindow: TrayService.showWindow,
        onExit: () => exit(0),
      );
    }
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
    _backendCapabilities = await XdRemuxService.getBackendCapabilities();
    // Swift is intentionally not exposed on Windows/Android. If a shared
    // preferences store contains an unavailable backend or Apple-only choice,
    // normalize it before any conversion can start.
    if (_sanitizeConfigForCapabilities(_config, _backendCapabilities)) {
      _scheduleConfigSave();
    }
    try {
      _version = await XdRemuxService.getVersion();
    } catch (e) {
      _version = 'core error: $e';
    }
    // Mobile: resolve the app-scoped output directory.
    // Android: app-specific external storage. iOS: Documents/ (sandboxed).
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
    } else if (Platform.isIOS) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final outDir = Directory('${dir.path}${Platform.pathSeparator}output');
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        _androidOutputDir = outDir.path;
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
      // Previous run completed successfully; remove stale state and any
      // persistent picker copies left by an interrupted cleanup.
      await CheckpointService.cleanupMaterializedInputs(checkpoint);
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
      // User declined or dismissed — discard old checkpoint and its private
      // picker copies as well.
      await CheckpointService.cleanupMaterializedInputs(checkpoint);
      await CheckpointService.delete();
    }
  }

  /// Restore queue state from a checkpoint.
  void _restoreFromCheckpoint(Checkpoint checkpoint) {
    final existing = _queue.map((item) => item.inputPath).toSet();
    var restored = 0;
    var unavailable = 0;

    for (final cpItem in checkpoint.items) {
      if (existing.contains(cpItem.inputPath)) continue;
      if (!CheckpointService.isSourceUnchanged(cpItem)) {
        unavailable++;
        continue;
      }

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
      restored++;
    }

    _checkpoint = checkpoint;
    _validateOutputPlans();
    _updateStatusText();
    setState(() {
      final message = StringBuffer(
        '已恢复 ${checkpoint.completedCount}/${checkpoint.items.length} 个文件的进度',
      );
      if (restored == 0 && unavailable > 0) {
        message.write('；临时源文件已失效，请重新选择');
      } else if (unavailable > 0) {
        message.write('；$unavailable 个源文件不可用，已跳过');
      }
      _currentFileName = message.toString();
    });
  }

  void _initDropChannel() {
    // Desktop-only: native window sends dropped file paths via MethodChannel.
    if (Platform.isAndroid || Platform.isIOS) return;
    _dropChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFilesDropped') {
        final paths = List<String>.from(call.arguments as List);
        DropFileService.publish(paths);
        if (!DropFileService.workflowActive) {
          await _handleDrop(paths);
        }
      }
    });
  }

  /// Android: prompt the user to exempt the app from battery optimization
  /// if not already done. Without this, ColorOS and other OEM ROMs freeze
  /// the Dart VM in background even with a foreground service.
  Future<void> _checkBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    try {
      final ignoring = await _batteryChannel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      if (ignoring == true) return;

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.battery_saver),
          title: const Text('后台转换需要关闭电池限制'),
          content: const Text(
            '切换到后台时，系统会冻结应用以省电，导致转换暂停。\n\n'
            '需要完成两步设置：\n'
            '1. 允许"忽略电池优化"（系统对话框）\n'
            '2. 在"耗电行为控制"中设为"允许后台运行"（OPPO/一加/realme）',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('暂不'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _batteryChannel.invokeMethod<bool>('openOemBatterySettings');
              },
              child: const Text('耗电行为控制'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _batteryChannel.invokeMethod<bool>(
                  'requestIgnoreBatteryOptimizations',
                );
              },
              child: const Text('忽略电池优化'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('[XDRemux][battery] check failed: $e');
    }
  }

  /// Android / iOS: accept HEIC files shared from the gallery or a file
  /// manager. On Android the plugin copies content-URI bytes into the app
  /// cache; on iOS the Share Extension copies them into the app group
  /// container. Either way incoming paths are plain local files the Rust
  /// FFI layer can read.
  void _initShareIntake() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _shareSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) => _handleSharedMedia(files),
      onError: (Object e) =>
          debugPrint('[XDRemux][share] media stream error: $e'),
    );
    ReceiveSharingIntent.instance.getInitialMedia().then((files) async {
      await _handleSharedMedia(files);
      // Tell the plugin the cold-start payload was consumed so it isn't
      // delivered again on the next launch.
      await ReceiveSharingIntent.instance.reset();
    });
  }

  Future<void> _handleSharedMedia(List<SharedMediaFile> files) async {
    if (files.isEmpty || !mounted) return;
    final paths = <String>[];
    int ignored = 0;
    int unreadable = 0;
    for (final file in files) {
      if (!isSupportedInputPath(file.path)) {
        ignored++;
        continue;
      }
      try {
        final entity = await File(file.path).stat();
        if (entity.type == FileSystemEntityType.file && entity.size > 0) {
          paths.add(file.path);
        } else {
          unreadable++;
          debugPrint(
            '[XDRemux][share] not a readable file: ${file.path} '
            '(type=${entity.type}, size=${entity.size})',
          );
        }
      } catch (e) {
        unreadable++;
        debugPrint('[XDRemux][share] cannot read ${file.path}: $e');
      }
    }
    await _enqueuePaths(paths, verb: '接收', ignored: ignored + unreadable);
  }

  @override
  void dispose() {
    _configSaveTimer?.cancel();
    _progressTimer?.cancel();
    _shareSubscription?.cancel();
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

  // Keep the start action enabled when there are pending items with
  // blockers, so the user can see the preflight explanation instead of a
  // mysteriously disabled button.
  bool get _canStart =>
      !_isProcessing &&
      _queue.any((item) => item.status == QueueItemStatus.pending);

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

    // Sum partial progress from ALL currently-running items.
    double partial = 0.0;
    for (final item in _queue) {
      final p = item.progress;
      if (p != null && item.status == QueueItemStatus.running) {
        if (p.total > 0) {
          partial += (p.current / p.total).clamp(0.0, 1.0);
        }
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

  /// Resolve a file returned by Android's document picker to a real local
  /// path. Some OEM document providers return readable bytes but no usable
  /// filesystem path; keep a private app-cache copy for the Rust FFI layer in
  /// that case.
  Future<String?> _resolvePickedFile(PlatformFile file, int index) async {
    // On Android, file_picker resolves content:// URIs by copying the file to
    // its own cache directory — and on OPPO/ColorOS that copy drops the EXIF
    // GPS block, so conversions lose location data. With all-files access we
    // first read the original file by its real filesystem path (GPS intact);
    // only fall back to the content-URI copy when no real path resolves.
    if (Platform.isAndroid) {
      // Reading the real filesystem path (to preserve GPS) only works with
      // MANAGE_EXTERNAL_STORAGE granted. Without it, the scoped-storage layer
      // lets File.exists() report true but the native Rust fs::read on that
      // path fails with Permission denied — so only take the real-path route
      // when all-files access is actually granted, and otherwise fall through
      // to a content-URI copy (readable via the picker's grant).
      final hasAllFiles = await allFilesAccessGranted();
      if (hasAllFiles) {
        final realPath = _resolveRealPathFromName(file.name);
        if (realPath != null) {
          debugPrint(
            '[XDRemux][file_picker] resolved ${file.name} to real path '
            '$realPath (GPS preserved)',
          );
          return realPath;
        }
      } else {
        debugPrint(
          '[XDRemux][file_picker] all-files access not granted; '
          'using content-URI copy for ${file.name}',
        );
      }
      final identifier = file.identifier;
      if (identifier != null &&
          (identifier.startsWith('content://') ||
              identifier.startsWith('file://'))) {
        try {
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
          const channel = MethodChannel('xdremux/file-import');
          final imported = await channel.invokeMethod<String?>(
            'importFromUri',
            {'uri': identifier, 'destPath': cachedPath},
          );
          if (imported != null && File(imported).existsSync()) {
            debugPrint(
              '[XDRemux][file_picker] re-imported ${file.name} from '
              'content URI to $imported',
            );
            return imported;
          }
          debugPrint(
            '[XDRemux][file_picker] content-URI re-import failed for '
            '${file.name}, falling back to file_picker path',
          );
        } catch (e) {
          debugPrint('[XDRemux][file_picker] content-URI re-import error: $e');
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

  /// With MANAGE_EXTERNAL_STORAGE the app can read any file under
  /// /storage/emulated/0 by path. Try the standard camera/download locations
  /// for a HEIC whose display name we know; reading the real file preserves
  /// EXIF GPS that OPPO's content stream strips. Returns the real path if the
  /// file exists and is readable, else null.
  String? _resolveRealPathFromName(String? name) {
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

  static const _photoPickerChannel = MethodChannel('xdremux/photo-picker');

  Future<void> _addFiles() async {
    if (!_canEditQueue) return;
    if (Platform.isIOS) {
      final source = await showModalBottomSheet<_ImportSource>(
        context: context,
        useSafeArea: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                subtitle: const Text('保留原始 HEIC、HDR 和深度数据'),
                onTap: () => Navigator.pop(ctx, _ImportSource.photos),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('从文件选择'),
                subtitle: const Text('打开“文件”App 或 iCloud Drive'),
                onTap: () => Navigator.pop(ctx, _ImportSource.files),
              ),
            ],
          ),
        ),
      );
      if (source == null) return;
      if (source == _ImportSource.photos) {
        await _addFromPhotos();
        return;
      }
    }
    await _addFilesFromFiles();
  }

  Future<void> _addFromPhotos() async {
    try {
      final rawPaths = await _photoPickerChannel.invokeMethod<List<dynamic>>(
        'pickPhotos',
      );
      final paths = (rawPaths ?? []).whereType<String>().toList();
      if (paths.isEmpty) return;
      final files = paths
          .map(
            (path) => PlatformFile(
              name: path.split('/').last,
              size: File(path).lengthSync(),
              path: path,
            ),
          )
          .toList();
      await _ingestPickedFiles(files, source: 'photo_picker');
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开相册：${e.message ?? e.code}')),
        );
      }
    }
  }

  Future<void> _addFilesFromFiles() async {
    if (!_canEditQueue) return;

    // Android uses the system document picker (SAF), which grants temporary
    // access to the selected content URI. Do not request READ_MEDIA_IMAGES or
    // MANAGE_EXTERNAL_STORAGE here: both are optional for importing. Users
    // who need OPPO GPS preservation can enable "保留位置信息" in Settings;
    // gallery-save permission is requested only when saving an output.

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['heic', 'heif'],
      allowMultiple: true,
      // Keep withData off: withData: true makes file_picker read every picked
      // file's full bytes into memory and marshal them back to Dart, which
      // OOMs when selecting several multi-MB HEICs at once. The picked file
      // path is available on Android in practice; _resolvePickedFile falls
      // back to a byte cache only when a path is missing.
      withData: false,
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
    await _ingestPickedFiles(result.files, source: 'file_picker');
  }

  Future<void> _ingestPickedFiles(
    List<PlatformFile> files, {
    required String source,
  }) async {
    if (files.isEmpty) {
      if (mounted) setState(() => _currentFileName = '文件选择器未返回文件');
      return;
    }
    debugPrint(
      '[XDRemux][$source] returned ${files.length} file(s): '
      '${files.map((file) => '${file.name}|path=${file.path}|bytes=${file.bytes?.length}|id=${file.identifier}').join('; ')}',
    );

    final existing = _queue.map((item) => item.inputPath).toSet();
    int added = 0;
    int skipped = 0;
    int skippedExisting = 0;
    int skippedUnsupportedPortrait = 0;
    final unsupportedPortraitFiles = <String>[];
    String? firstError;

    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final resolvedPath = await _resolvePickedFile(file, index);
      if (resolvedPath == null) {
        skipped++;
        continue;
      }
      // file_picker and PHPicker both hand us an OS-cache path. Persist that
      // input before it enters the queue so it survives app restarts.
      final path = await CheckpointService.materializeTemporaryInput(
        resolvedPath,
      );
      if (existing.contains(path)) continue;

      if (_config.applePortrait) {
        final portraitReason = await _portraitImportRejection(path);
        if (portraitReason != null) {
          skippedUnsupportedPortrait++;
          unsupportedPortraitFiles.add(file.name);
          debugPrint(
            '[XDRemux][portrait] rejected ${file.name}: $portraitReason',
          );
          continue;
        }
      }

      try {
        final classification = await XdRemuxService.classify(path);
        final folderName = classification['folderName'] as String?;
        final outputPath = _config.outputPathFor(
          resolvedPath,
          fallbackDir: _androidOutputDir,
          captureModeFolderName: folderName,
        );
        if (_config.skipExisting) {
          final inputIsConverted = await XdRemuxService.verifyOutput(path);
          debugPrint(
            '[XDRemux][skip] input=$path verifyOutput=$inputIsConverted',
          );
          if (inputIsConverted) {
            skippedExisting++;
            continue;
          }
        }
        _queue.add(
          QueueItem(
            id: _makeId(),
            inputPath: path,
            outputPath: outputPath,
            outputPlanStatus: _computeOutputPlan(path, outputPath),
            captureModeKey: classification['modeKey'] as String?,
            captureModeFolderName: folderName,
            classificationStatus: classification['status'] as String?,
            hdrKind: classification['hdrKind'] as String?,
            family: classification['family'] as String?,
          ),
        );
        existing.add(path);
        added++;
      } catch (e) {
        firstError ??= '$e';
        debugPrint('[XDRemux][$source] classify failed for $path: $e');
        if (mounted) {
          setState(() => _currentFileName = '添加失败: $e');
        }
      }
    }

    _preflightIssues.clear();
    _validateOutputPlans();
    _updateStatusText();
    if (!mounted) return;
    setState(() {
      final parts = <String>[];
      if (added > 0) parts.add('已添加 $added 个文件');
      if (skippedExisting > 0) parts.add('跳过 $skippedExisting 个已转换');
      if (skippedUnsupportedPortrait > 0) {
        parts.add('跳过 $skippedUnsupportedPortrait 个不支持人像模式的文件');
      }
      if (skipped > 0) parts.add('$skipped 个无法读取');
      if (firstError != null) parts.add(firstError);
      _currentFileName = parts.isEmpty ? '未添加新文件' : parts.join('，');
    });
    if (unsupportedPortraitFiles.isNotEmpty && mounted) {
      await _showPortraitImportRejection(unsupportedPortraitFiles);
    }
    if (skippedExisting > 0 && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('$skippedExisting 个文件已是转换后的 HDR 照片，已跳过')),
        );
    }
  }

  Future<String?> _portraitImportRejection(String inputPath) async {
    // The native diagnostic bridge is currently available on Apple platforms.
    // Other platforms keep the existing conversion behavior until a portable
    // Rust diagnostic FFI is exposed.
    if (!Platform.isMacOS && !Platform.isIOS) return null;

    final report = await XdRemuxService.diagnosePortrait(inputPath);
    if (report['classification'] == 'missing-rear-depth') {
      return '缺少 rear.depth（仅包含前置深度数据）';
    }
    return null;
  }

  Future<void> _showPortraitImportRejection(List<String> fileNames) async {
    if (!mounted) return;
    final shown = fileNames.take(8).join('\n');
    final more = fileNames.length > 8 ? '\n还有 ${fileNames.length - 8} 个文件' : '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('部分照片不支持 Apple 人像模式'),
        content: Text(
          '这些照片没有后置人像所需的 rear.depth，已跳过：\n\n'
          '$shown$more',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
    _preflightIssues.clear();
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
  // Conversion preflight and execution
  // ---------------------------------------------------------------------------

  List<_PreflightIssue> _collectPreflightIssues() {
    final issues = <_PreflightIssue>[];
    final runnable = _queue.where(
      (item) =>
          item.status == QueueItemStatus.pending ||
          item.status == QueueItemStatus.failed ||
          item.status == QueueItemStatus.cancelled,
    );

    if (runnable.isEmpty) {
      issues.add(
        const _PreflightIssue(
          severity: _PreflightSeverity.blocking,
          title: '没有待处理文件',
          detail: '请先添加照片，或重试失败项目。',
        ),
      );
      return issues;
    }

    for (final item in runnable) {
      final file = File(item.inputPath);
      if (!file.existsSync()) {
        issues.add(
          _PreflightIssue(
            severity: _PreflightSeverity.blocking,
            title: '输入文件不可用',
            fileName: item.fileName,
            detail: '文件不存在或临时源已失效。请重新添加该文件。',
          ),
        );
        continue;
      }
      if (!isSupportedInputPath(item.inputPath)) {
        issues.add(
          _PreflightIssue(
            severity: _PreflightSeverity.blocking,
            title: '输入格式不支持',
            fileName: item.fileName,
            detail: '仅支持 HEIC / HEIF 文件。',
          ),
        );
      }
      if (item.outputPlanStatus.blocksConversion) {
        issues.add(
          _PreflightIssue(
            severity: _PreflightSeverity.blocking,
            title: '输出计划不可用',
            fileName: item.fileName,
            detail: item.outputPlanStatus.displayName,
          ),
        );
      } else if (item.outputPlanStatus ==
          OutputPlanStatus.willOverwriteExisting) {
        issues.add(
          _PreflightIssue(
            severity: _PreflightSeverity.warning,
            title: '将覆盖已有输出',
            fileName: item.fileName,
            detail: '输出文件已存在，继续后会覆盖它。',
          ),
        );
      }
    }

    if (!_backendCapabilities.isAvailable(_config.backend)) {
      issues.add(
        _PreflightIssue(
          severity: _PreflightSeverity.blocking,
          title: '转换后端不可用',
          detail: _backendCapabilities.statusFor(_config.backend),
        ),
      );
    }
    if (_config.applePhotographicStyles &&
        _config.backend == ConversionBackend.swift &&
        !_backendCapabilities.swiftPhotographicStyles) {
      issues.add(
        const _PreflightIssue(
          severity: _PreflightSeverity.blocking,
          title: 'Apple 相册摄影风格不可用',
          detail: '当前平台 capability 未就绪。',
        ),
      );
    }
    if (_config.applePortrait &&
        _config.backend == ConversionBackend.swift &&
        !_backendCapabilities.swiftPortrait) {
      issues.add(
        const _PreflightIssue(
          severity: _PreflightSeverity.blocking,
          title: 'Apple 人像模式不可用',
          detail: '当前平台 capability 未就绪。',
        ),
      );
    }
    return issues;
  }

  Future<bool> _runPreflight() async {
    final issues = _collectPreflightIssues();
    if (!mounted) return false;
    setState(() {
      _preflightIssues
        ..clear()
        ..addAll(issues);
      if (issues.any((issue) => issue.isBlocking)) {
        _statusText = '需要修复转换前检查问题';
      } else if (issues.isNotEmpty) {
        _statusText = '转换前检查发现警告';
      } else {
        _statusText = '检查通过，准备转换';
      }
    });

    final blocking = issues.where((issue) => issue.isBlocking).toList();
    if (blocking.isNotEmpty) {
      await _showPreflightDialog(
        title: '无法开始转换',
        issues: blocking,
        confirmLabel: '返回队列',
      );
      return false;
    }
    if (issues.isEmpty) return true;

    return _showPreflightDialog(
      title: '开始前检查',
      issues: issues,
      confirmLabel: '继续转换',
    );
  }

  Future<bool> _showPreflightDialog({
    required String title,
    required List<_PreflightIssue> issues,
    required String confirmLabel,
  }) async {
    final canContinue = issues.every((issue) => !issue.isBlocking);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(canContinue ? '以下项目需要你确认：' : '请先处理以下问题后再开始：'),
                const SizedBox(height: 12),
                ...issues
                    .take(12)
                    .map(
                      (issue) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              issue.isBlocking
                                  ? Icons.error_outline
                                  : Icons.warning_amber_outlined,
                              size: 20,
                              color: issue.isBlocking
                                  ? Theme.of(ctx).colorScheme.error
                                  : Theme.of(ctx).colorScheme.tertiary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(issue.displayText)),
                          ],
                        ),
                      ),
                    ),
                if (issues.length > 12)
                  Text('还有 ${issues.length - 12} 项，请在队列中查看。'),
              ],
            ),
          ),
        ),
        actions: [
          if (canContinue)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, canContinue),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true && canContinue;
  }

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

    if (!await _runPreflight()) return;
    if (!mounted) return;

    // Android: check battery optimization before starting a batch.
    // ColorOS/other OEMs freeze the Dart VM in background without this.
    if (Platform.isAndroid) {
      await _checkBatteryOptimization();
      if (!mounted) return;
    }

    setState(() {
      _preflightIssues.clear();
      _isProcessing = true;
      _statusText = '准备转换...';
    });

    // Android: start foreground service so the OS doesn't freeze the
    // conversion isolates when the app goes to background.
    await ForegroundService.start();

    // M6: Create or update checkpoint
    _initCheckpoint();

    final concurrency = _config.maxConcurrentJobs.clamp(1, 4);
    _currentConcurrency = concurrency;

    // Single batch-level progress timer.
    _startProgressTimer(concurrency);

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
        _progressTimer?.cancel();
        setState(() {
          _isProcessing = false;
          _currentConcurrency = 0;
          _currentFileName = '';
        });
        _updateStatusText();
        ForegroundService.stop();
        _onBatchComplete();
      }
    }

    scheduleNext();
  }

  Future<void> _convertOne(int index) async {
    final item = _queue[index];
    final runConfig = _config.copy();
    item.backend = runConfig.backend;
    final effectiveOppoCompatibility = runConfig.outputMode == OutputMode.apple
        ? OppoCompatMode.off
        : runConfig.oppoCompatibility;
    final effectiveOppoCameraTail = runConfig.outputMode == OutputMode.apple
        ? OppoCameraTailMode.off
        : runConfig.oppoCameraTail;

    // Claim a Rust progress handle only for Rust-backed work. Swift progress
    // will use the same request id through the native backend contract.
    item.progressHandle = runConfig.backend == ConversionBackend.rust
        ? XdRemuxFFI.progressBegin()
        : 0;

    try {
      // Skip if the input is already a converted ISO HDR output —
      // re-converting produces a broken nested gain map.
      if (runConfig.skipExisting &&
          await XdRemuxService.verifyOutputForBackend(
            runConfig.backend,
            item.inputPath,
            applePhotographicStyles: runConfig.applePhotographicStyles,
            applePortrait: runConfig.applePortrait,
          )) {
        item.status = QueueItemStatus.skippedExisting;
        item.finishedAt = DateTime.now();
        item.progress = null;
        if (item.progressHandle != 0) {
          XdRemuxFFI.progressEnd(item.progressHandle);
          item.progressHandle = 0;
        }
        if (mounted) setState(() {});
        _updateCheckpointForItem(item);
        return;
      }

      // Remove existing output file if present
      final outFile = File(item.outputPath);
      if (outFile.existsSync() && item.inputPath != item.outputPath) {
        outFile.deleteSync();
      }

      // Android (MediaCodec) + Apple (VideoToolbox on macOS/iOS) + toggle on:
      // try the hardware encode path. Any failure falls back to the proven
      // software path so conversion never silently breaks.
      Map<String, dynamic>? result;
      if (runConfig.backend == ConversionBackend.rust &&
          !runConfig.applePhotographicStyles &&
          (Platform.isAndroid || Platform.isMacOS || Platform.isIOS) &&
          runConfig.hardwareEncode &&
          await HardwareEncodeService.isAvailable()) {
        result = await _convertOneHardware(item, runConfig);
      }

      result ??= (await XdRemuxService.convertWithBackend(
        ConversionRequest(
          id: item.id,
          backend: runConfig.backend,
          outputMode: runConfig.outputMode,
          inputPath: item.inputPath,
          outputPath: item.outputPath,
          oppoCompat: effectiveOppoCompatibility.rustValue,
          oppoCameraTail: effectiveOppoCameraTail.rustValue,
          strictTmap: runConfig.strictTmap,
          applePhotographicStyles: runConfig.applePhotographicStyles,
          applePortrait: runConfig.applePortrait,
          progressHandle: item.progressHandle,
        ),
      )).toMap();

      final cancelled =
          item.status == QueueItemStatus.cancelled ||
          result['cancelled'] == true ||
          XdRemuxService.takeCancellation(item.id);
      if (cancelled) {
        item.status = QueueItemStatus.cancelled;
        item.errorMessage = '已取消';
      } else if (result['success'] == true) {
        item.status = QueueItemStatus.converted;
      } else {
        item.status = QueueItemStatus.failed;
        final message = result['errorMessage'] ?? '未知错误';
        item.errorMessage = _backendError(runConfig.backend, message);
      }
    } catch (e) {
      if (item.status == QueueItemStatus.cancelled ||
          XdRemuxService.takeCancellation(item.id)) {
        item.status = QueueItemStatus.cancelled;
        item.errorMessage = '已取消';
      } else {
        item.status = QueueItemStatus.failed;
        item.errorMessage = _backendError(runConfig.backend, e.toString());
      }
    }

    if (item.progressHandle != 0) {
      XdRemuxFFI.progressEnd(item.progressHandle);
      item.progressHandle = 0;
    }
    item.finishedAt = DateTime.now();
    item.progress = null;
    if (mounted) setState(() {});

    // M6: Update checkpoint after each file completes
    _updateCheckpointForItem(item);
  }

  /// Hardware-encoding conversion path:
  /// 1. Rust prepares tiled YUV420 (+ owns an opaque context).
  /// 2. MediaCodec encodes each tile to an HEVC byte stream.
  /// 3. Rust assembles the final ISO HEIC.
  /// Returns null on any failure so the caller falls back to software encode.
  Future<Map<String, dynamic>?> _convertOneHardware(
    QueueItem item,
    ConversionConfig runConfig,
  ) async {
    final handle = item.progressHandle;
    PreparedTilesResult? prepared;
    try {
      // Synchronous FFI call — do not block the UI isolate. prepareTiles is
      // short (parse + decode + tile), but keep the same isolate discipline as
      // the software path.
      prepared = await Isolate.run(
        () => XdRemuxFFI.prepareTiles(
          item.inputPath,
          oppoCompat: runConfig.outputMode == OutputMode.apple
              ? OppoCompatMode.off.rustValue
              : runConfig.oppoCompatibility.rustValue,
          oppoCameraTail: runConfig.outputMode == OutputMode.apple
              ? OppoCameraTailMode.off.rustValue
              : runConfig.oppoCameraTail.rustValue,
          strictTmap: runConfig.strictTmap,
          progressHandle: handle,
        ),
      );
      if (prepared == null) return null;
      if (!prepared.success ||
          prepared.opaque == ffi.nullptr ||
          prepared.tileData == ffi.nullptr) {
        // Hardware path unavailable — fall back to software encode.
        return null;
      }
      // `prepared` is captured by the finally block, so promotion is lost
      // across awaits — hold a final non-null reference for the rest.
      final prep = prepared;

      // Slice the packed tile buffer into per-tile YUV420 frames.
      final ySize = prep.tileW * prep.tileH;
      final cSize = (prep.tileW ~/ 2) * (prep.tileH ~/ 2);
      final perTile = ySize + 2 * cSize;
      final tileData = prep.tileData.asTypedList(prep.tileDataLen);
      final tiles = <TileInput>[];
      for (var i = 0; i < prep.tileCount; i++) {
        final start = i * perTile;
        tiles.add(
          TileInput(Uint8List.sublistView(tileData, start, start + perTile), i),
        );
      }

      final streams = await HardwareEncodeService.encodeTiles(tiles);
      if (streams == null) {
        // A tile failed to encode — fall back to software encode.
        return null;
      }
      if (streams.length != prep.tileCount) {
        return null;
      }

      // Report progress so the UI bar reflects the encode loop.
      for (var i = 0; i < streams.length; i++) {
        XdRemuxFFI.progressReport(handle, i + 1, streams.length);
      }

      final assembled = await Isolate.run(
        () => XdRemuxFFI.assembleTiles(
          prep.opaque,
          streams,
          item.outputPath,
          progressHandle: handle,
        ),
      );
      try {
        if (!assembled.success) {
          // Assembly failed — fall back to the proven software path.
          return null;
        }
        // Structural sanity check: a corrupt assembly must not be kept, or the
        // user gets a silently broken HDR file. Fall back if it fails.
        final valid = await XdRemuxService.verifyOutput(item.outputPath);
        if (!valid) {
          return null;
        }
        return {
          'success': true,
          'mode': assembled.mode.toDartStringOrNull(),
          'family': assembled.family.toDartStringOrNull(),
          'edrScale': assembled.edrScale,
          'gainMapMax': assembled.gainMapMax,
          'errorMessage': null,
        };
      } finally {
        XdRemuxFFI.freeResult(assembled);
      }
    } catch (e) {
      // Any error here must fall back to software encoding, not fail the item.
      return null;
    } finally {
      if (prepared != null) {
        XdRemuxFFI.freePrepared(prepared);
      }
    }
  }

  /// Single batch-level progress timer. With concurrency=1, reads the Rust
  /// tile-level progress buffer for the sole running item. With higher
  /// concurrency, estimates progress from elapsed time (the global buffer
  /// is shared by all concurrent conversions and would be garbled).
  /// Single batch-level progress timer. Every running item reports its real
  /// Rust tile progress through its own handle, so per-file bars are accurate
  /// in both single and concurrent modes.
  void _startProgressTimer(int concurrency) {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted || !_isProcessing) return;
      try {
        for (int i = 0; i < _queue.length; i++) {
          final item = _queue[i];
          if (item.status == QueueItemStatus.running &&
              item.progressHandle != 0) {
            final progress = XdRemuxService.readProgress(
              ConversionRequest(
                id: item.id,
                backend: item.backend,
                inputPath: item.inputPath,
                outputPath: item.outputPath,
                oppoCompat: 0,
                oppoCameraTail: 255,
                strictTmap: false,
                progressHandle: item.progressHandle,
              ),
            );
            item.progress = (
              stage: progress.stage,
              current: progress.current,
              total: progress.total,
            );
          }
        }
        _updateStatusText();
        setState(() {});
        // Sync progress to the foreground service notification.
        final done = _convertedCount + _skippedCount;
        final running = _queue
            .where((i) => i.status == QueueItemStatus.running)
            .map((i) => i.fileName)
            .take(3)
            .toList();
        final runningText = running.isEmpty
            ? ''
            : ' — ${running.join(', ')}${running.length < _queue.where((i) => i.status == QueueItemStatus.running).length ? '…' : ''}';
        ForegroundService.updateProgress('$done/$_totalFiles 完成$runningText');
        // Keep the Windows tray tooltip in sync so the batch stays
        // observable while the window is hidden.
        if (Platform.isWindows && TrayService.isHidden) {
          TrayService.setToolTip('XDRemux — $done/$_totalFiles 完成');
        }
      } catch (_) {}
    });
  }

  void _cancelConversion() {
    if (!_isProcessing) return;
    for (final item in _queue) {
      if (item.status == QueueItemStatus.running) {
        XdRemuxService.cancel(item.id);
      }
    }
    setState(() {
      _isProcessing = false;
      _statusText = '已取消';
      _currentConcurrency = 0;
      _currentFileName = '';
    });
    ForegroundService.stop();
    if (Platform.isWindows) TrayService.setToolTip('XDRemux');
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
      // All success — remove checkpoint and release private picker copies.
      final completedCheckpoint = _checkpoint!;
      unawaited(
        CheckpointService.cleanupMaterializedInputs(completedCheckpoint),
      );
      unawaited(CheckpointService.delete());
      _checkpoint = null;
    } else {
      // Has failures — keep checkpoint for potential resume
      _saveCheckpoint();
    }

    // System notification so background batches are observable.
    final done = _convertedCount + _skippedCount + _failedCount;
    if (mounted && done > 0) {
      setState(() {
        _statusText = _failedCount > 0
            ? '完成：成功 $_convertedCount，跳过 $_skippedCount，失败 $_failedCount'
            : '全部完成：$_convertedCount 个文件';
      });
    }
    if (done > 0) {
      NotificationService.notifyBatchComplete(
        converted: _convertedCount,
        skipped: _skippedCount,
        failed: _failedCount,
      );
      if (mounted) {
        final outcome = _failedCount > 0 ? '完成（有失败）' : '完成';
        final summary =
            '${_config.backend.appTitle}：$outcome，成功 $_convertedCount 个';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(summary)));
      }
    }

    // Mobile: optional auto-save of every converted output to the gallery.
    if ((Platform.isAndroid || Platform.isIOS) &&
        _config.autoSaveToGallery &&
        _convertedCount > 0) {
      _saveAllConvertedToGallery().then((result) {
        if (result == null) return;
        final (saved, failed) = result;
        if (failed > 0) {
          debugPrint(
            '[XDRemux][gallery] auto-save: $saved saved, $failed failed',
          );
        }
      });
    }

    if (Platform.isWindows) TrayService.setToolTip('XDRemux');
  }

  String _backendError(ConversionBackend backend, String message) {
    if (backend == ConversionBackend.swift && !message.startsWith('Swift 后端')) {
      return 'Swift 后端：$message';
    }
    return message;
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
    final oldCheckpoint = _checkpoint;
    setState(() {
      _queue.clear();
      _selectedIndex = null;
      _statusText = '就绪';
      _currentFileName = '';
    });
    // M6: Clear checkpoint when queue is manually cleared.
    _checkpoint = null;
    if (oldCheckpoint != null) {
      unawaited(CheckpointService.cleanupMaterializedInputs(oldCheckpoint));
    }
    unawaited(CheckpointService.delete());
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

  Future<void> _handleDrop(List<String> paths) =>
      _enqueuePaths(paths, verb: '拖入');

  /// Shared intake for desktop drop and Android share: classifies each
  /// supported path and appends it to the queue, then reports how many
  /// files were added and how many were ignored as non-HEIC.
  Future<void> _enqueuePaths(
    List<String> paths, {
    required String verb,
    int ignored = 0,
  }) async {
    final existing = _queue.map((item) => item.inputPath).toSet();
    int added = 0;
    int skippedExisting = 0;
    int skippedUnsupportedPortrait = 0;
    final unsupportedPortraitFiles = <String>[];
    for (final resolvedPath in paths) {
      if (!isSupportedInputPath(resolvedPath)) {
        ignored++;
        continue;
      }
      // Shared-media intake and some picker implementations hand us a cache
      // path. Use the same persistent materialization path as file picking so
      // share/drop and picker have identical resume semantics.
      final path = await CheckpointService.materializeTemporaryInput(
        resolvedPath,
      );
      if (existing.contains(path)) continue;
      if (_config.applePortrait) {
        final portraitReason = await _portraitImportRejection(path);
        if (portraitReason != null) {
          skippedUnsupportedPortrait++;
          unsupportedPortraitFiles.add(
            resolvedPath.split(RegExp(r'[/\\]')).last,
          );
          debugPrint(
            '[XDRemux][portrait] rejected ${resolvedPath}: $portraitReason',
          );
          continue;
        }
      }
      try {
        final classification = await XdRemuxService.classify(path);
        final folderName = classification['folderName'] as String?;
        final outputPath = _config.outputPathFor(
          resolvedPath,
          fallbackDir: _androidOutputDir,
          captureModeFolderName: folderName,
        );
        // Skip files that are already converted ISO HDR outputs —
        // re-converting produces a broken nested gain map.
        if (_config.skipExisting) {
          final inputIsConverted = await XdRemuxService.verifyOutput(path);
          debugPrint(
            '[XDRemux][skip] input=$path verifyOutput=$inputIsConverted',
          );
          if (inputIsConverted) {
            skippedExisting++;
            continue;
          }
        }
        _queue.add(
          QueueItem(
            id: _makeId(),
            inputPath: path,
            outputPath: outputPath,
            outputPlanStatus: _computeOutputPlan(path, outputPath),
            captureModeKey: classification['modeKey'] as String?,
            captureModeFolderName: folderName,
            classificationStatus: classification['status'] as String?,
            hdrKind: classification['hdrKind'] as String?,
            family: classification['family'] as String?,
          ),
        );
        existing.add(path);
        added++;
      } catch (_) {
        // Keep the intake responsive even if metadata classification fails.
      }
    }
    if (added > 0) {
      _preflightIssues.clear();
      _validateOutputPlans();
      _updateStatusText();
    }
    if (added == 0 &&
        ignored == 0 &&
        skippedExisting == 0 &&
        skippedUnsupportedPortrait == 0) {
      return;
    }

    final parts = <String>[];
    if (added > 0) parts.add('已$verb $added 个文件');
    if (skippedExisting > 0) parts.add('跳过 $skippedExisting 个已转换');
    if (skippedUnsupportedPortrait > 0) {
      parts.add('跳过 $skippedUnsupportedPortrait 个不支持人像模式的文件');
    }
    if (ignored > 0) parts.add('忽略 $ignored 个非 HEIC');
    final summary = parts.isEmpty ? '未添加新文件' : parts.join('，');
    setState(() => _currentFileName = summary);
    if (unsupportedPortraitFiles.isNotEmpty && mounted) {
      await _showPortraitImportRejection(unsupportedPortraitFiles);
    }
    if (ignored > 0 ||
        skippedExisting > 0 ||
        skippedUnsupportedPortrait > 0 ||
        verb == '接收') {
      if (!mounted) return;
      final snackText = skippedExisting > 0
          ? '$skippedExisting 个文件已是转换后的 HDR 照片，已跳过'
          : summary;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(snackText)));
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
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: open file with system default app (Gallery/file viewer).
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
    } else if (Platform.isAndroid || Platform.isIOS) {
      _revealInExplorer(outputs.first);
    }
  }

  /// Android: batch-save all converted outputs to the gallery.
  /// Uses per-item albums (capture mode folder) when categorize is on.
  Future<void> _saveAllToGallery() async {
    final result = await _saveAllConvertedToGallery(showDeniedHint: true);
    if (result == null || !mounted) return;
    final (saved, failed) = result;
    final msg = failed > 0 ? '已保存 $saved 个到相册，$failed 个失败' : '已保存 $saved 个到相册';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Core of the gallery batch-save. Returns (saved, failed), or null when
  /// there was nothing to save or gallery permission was denied.
  Future<(int, int)?> _saveAllConvertedToGallery({
    bool showDeniedHint = false,
  }) async {
    final items = _queue
        .where((item) => item.status == QueueItemStatus.converted)
        .toList();
    if (items.isEmpty) return null;

    final hasAccess = await FileActionService.hasGalleryPermission();
    if (!hasAccess) {
      final granted = await FileActionService.requestGalleryPermission();
      if (!granted) {
        if (showDeniedHint && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未获得存储权限')));
        }
        return null;
      }
    }

    int saved = 0, failed = 0;
    for (final item in items) {
      final ok = await FileActionService.saveToGallery(
        item.outputPath,
        album: _galleryAlbum(item),
      );
      if (ok) {
        saved++;
      } else {
        failed++;
      }
    }
    return (saved, failed);
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
    if (Platform.isIOS) return '相册「$album」';
    // gal/MediaStore places image albums under Pictures/, not DCIM/.
    return 'Pictures/$album';
  }

  /// Presents output actions and only starts the native action after the
  /// bottom-sheet route has fully returned. Presenting UIKit while this route
  /// is still dismissing is rejected on iOS.
  Future<void> _showOutputActions(QueueItem item) async {
    final action = await showModalBottomSheet<_OutputAction>(
      context: context,
      useSafeArea: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (Platform.isAndroid || Platform.isIOS)
                ListTile(
                  leading: const Icon(Icons.photo_library),
                  title: const Text('保存到相册'),
                  subtitle: Text(_galleryAlbumSubtitle(item)),
                  onTap: () => Navigator.pop(ctx, _OutputAction.save),
                ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('分享'),
                onTap: () => Navigator.pop(ctx, _OutputAction.share),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('打开'),
                subtitle: const Text('用系统图库打开'),
                onTap: () => Navigator.pop(ctx, _OutputAction.open),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;

    // Give UIKit one frame after the Flutter route has disappeared.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    switch (action) {
      case _OutputAction.save:
        final hasAccess = await FileActionService.hasGalleryPermission();
        if (!hasAccess) {
          final granted = await FileActionService.requestGalleryPermission();
          if (!granted) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('未获得存储权限')));
            }
            return;
          }
        }
        final ok = await FileActionService.saveToGallery(
          item.outputPath,
          album: _galleryAlbum(item),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(ok ? '已保存到相册' : '保存失败')));
        }
      case _OutputAction.share:
        await FileActionService.shareFile(item.outputPath);
      case _OutputAction.open:
        await FileActionService.openFile(item.outputPath);
    }
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
                if (_queue.isNotEmpty) _buildQueueSummary(theme),
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
            label: const Text('开始转换'),
            onPressed: _startConversion,
          ),
        ),
      if (!compact)
        IconButton(
          icon: const Icon(Icons.stop),
          tooltip: '取消',
          onPressed: _isProcessing ? _cancelConversion : null,
        ),
      // Desktop: one-tap output-folder access without digging the menu.
      // iOS 上 open_filex 只能预览单个文件而非打开目录，改为设置页入口
      // （shareddocuments:// 跳转 Files）。
      if (!Platform.isAndroid && !Platform.isIOS)
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: '打开输出目录',
          onPressed: !_isProcessing && _queue.any((item) => item.isSuccessful)
              ? _revealOutputs
              : null,
        ),
      IconButton(
        icon: const Icon(Icons.tune),
        tooltip: '设置',
        onPressed: () => _openSettings(context),
      ),
      if (Platform.isMacOS ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isAndroid)
        IconButton(
          icon: const Icon(Icons.auto_awesome_motion_outlined),
          tooltip: '一帧影像，动用两台手机',
          onPressed: _openAppleOppoWorkflow,
        ),
      // Apple 原生研究实验室只在 Apple 平台开放；Windows/Android 使用
      // Rust 人像输出实验室，验证可编辑图结构而不伪装成 Apple 原生能力。
      if (Platform.isMacOS || Platform.isIOS || Platform.isWindows)
        IconButton(
          icon: const Icon(Icons.camera_alt_outlined),
          tooltip: Platform.isWindows ? 'Rust 人像模式实验室' : 'Apple 人像模式实验室',
          onPressed: _openApplePortraitLab,
        ),
      // 整理页依赖目录递归扫描 + 任意位置复制，Android scoped storage 和
      // iOS 沙盒下都不可用。
      if (!Platform.isAndroid && !Platform.isIOS)
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
          case _QueueMenuAction.saveAllToGallery:
            _saveAllToGallery();
          case _QueueMenuAction.minimizeToTray:
            TrayService.hideWindow();
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
        if (Platform.isAndroid || Platform.isIOS)
          PopupMenuItem(
            value: _QueueMenuAction.saveAllToGallery,
            enabled: _canEditQueue && _convertedCount > 0,
            child: const ListTile(
              leading: Icon(Icons.photo_library),
              title: Text('全部保存到相册'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (Platform.isWindows)
          PopupMenuItem(
            value: _QueueMenuAction.minimizeToTray,
            child: const ListTile(
              leading: Icon(Icons.minimize),
              title: Text('最小化到托盘'),
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
    final showSaveAll = !_isProcessing && _convertedCount > 0;

    // 两侧的辅助动作用纯图标按钮，给中间的主按钮留足文字空间，避免换行。
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
            IconButton.filledTonal(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              tooltip: '添加文件',
              onPressed: _canEditQueue ? _addFiles : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: Icon(primaryIcon),
                label: Text(primaryLabel),
                onPressed: primaryAction,
              ),
            ),
            if (showSaveAll) ...[
              const SizedBox(width: 12),
              IconButton.filledTonal(
                icon: const Icon(Icons.photo_library_outlined),
                tooltip: '全部保存到相册',
                onPressed: _saveAllToGallery,
              ),
            ],
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
                  if (Platform.isIOS)
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('从相册选择'),
                            onPressed: _addFromPhotos,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('从文件选择'),
                            onPressed: _addFilesFromFiles,
                          ),
                        ),
                      ],
                    )
                  else
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

  Widget _buildQueueSummary(ThemeData theme) {
    final blocking = _preflightIssues.where((issue) => issue.isBlocking).length;
    final warnings = _preflightIssues.length - blocking;
    final done = _processedCount == _totalFiles && _totalFiles > 0;
    final summary = done
        ? (_failedCount > 0 ? '已完成：失败 $_failedCount 项' : '已完成，可导出结果')
        : blocking > 0
        ? '需要修复 $blocking 项问题'
        : warnings > 0
        ? '$warnings 项警告待确认'
        : '可以开始转换';
    final color = done && _failedCount == 0
        ? Colors.green.shade700
        : blocking > 0
        ? theme.colorScheme.error
        : warnings > 0
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              done && _failedCount > 0
                  ? Icons.error_outline
                  : blocking > 0
                  ? Icons.error_outline
                  : warnings > 0
                  ? Icons.warning_amber_outlined
                  : Icons.check_circle_outline,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_queue.length} 个文件 · 输出：${_config.outputMode.appTitle} · $summary',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            if (!_isProcessing && blocking > 0)
              TextButton(onPressed: _runPreflight, child: const Text('检查')),
          ],
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
                  '待转换队列',
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
            _handleItemTap(item);
          },
          onRetry: () => _retryItem(itemIndex),
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
                _handleItemTap(_queue[index]);
              },
              onRevealInput: () => _revealInExplorer(_queue[index].inputPath),
              onRevealOutput: () {
                if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
                  _showOutputActions(_queue[index]);
                } else {
                  _revealInExplorer(_queue[index].outputPath);
                }
              },
              onRetry: () => _retryItem(index),
              onRemove: () => _removeItem(index),
            );
          },
        );
      },
    );
  }

  void _showItemFailure(QueueItem item) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '转换失败',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(item.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            SelectableText(item.errorMessage ?? '未提供错误信息'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重新尝试'),
                onPressed: () {
                  Navigator.pop(ctx);
                  final index = _queue.indexOf(item);
                  if (index >= 0) _retryItem(index);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tap behavior per item status:
  /// - Completed → output actions (save/share/open)
  /// - Failed/cancelled → error details; retry is explicit
  /// - Pending/running → select only
  void _handleItemTap(QueueItem item) {
    if (item.isSuccessful) {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        _showOutputActions(item);
      } else {
        _revealInExplorer(item.outputPath);
      }
    } else if (item.status == QueueItemStatus.failed ||
        item.status == QueueItemStatus.cancelled) {
      _showItemFailure(item);
    }
  }

  void _retryItem(int index) {
    if (index < 0 || index >= _queue.length) return;
    setState(() {
      _queue[index].status = QueueItemStatus.pending;
      _queue[index].errorMessage = null;
      _queue[index].startedAt = null;
      _queue[index].finishedAt = null;
    });
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

  void _openAppleOppoWorkflow() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AppleOppoWorkflowPage()),
    );
  }

  void _openApplePortraitLab() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Platform.isWindows
            ? const RustPortraitPage()
            : const ApplePortraitPage(),
      ),
    );
  }
}

// ============================================================================
// All-files access (Android) — top-level so the settings sheet and picker both
// use the same helpers.
// ============================================================================

/// Whether "all files access" (MANAGE_EXTERNAL_STORAGE) is currently granted.
/// Only checks the status; never prompts.
Future<bool> allFilesAccessGranted() async {
  if (!Platform.isAndroid) return true;
  try {
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  } catch (_) {
    return false;
  }
}

/// Request MANAGE_EXTERNAL_STORAGE ("all files access"). Returns true when
/// granted. On Android 11+ this opens the system Settings page for the app.
Future<bool> ensureAllFilesAccess() async {
  if (!Platform.isAndroid) return true;
  if (await allFilesAccessGranted()) return true;
  try {
    var status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      // Jump to the "All files access" settings page.
      await openAppSettings();
      status = await Permission.manageExternalStorage.request();
    }
    return status.isGranted;
  } catch (_) {
    return false;
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
  late final TextEditingController _suffixController;
  BackendCapabilities _backendCapabilities =
      BackendCapabilities.forCurrentPlatform();

  /// Hardware-encoding availability probe result (null = not yet known).
  /// Only probed on Android, where the MediaCodec path exists.
  bool? _hwAvailable;

  String? _writebackDonorPath;
  String? _writebackReturnedPath;
  bool _writebackRunning = false;

  @override
  void initState() {
    super.initState();
    _cfg = widget.config.copy();
    _suffixController = TextEditingController(text: _cfg.fileNameSuffix);
    if (Platform.isMacOS || Platform.isIOS) {
      XdRemuxService.getBackendCapabilities().then((capabilities) {
        if (!mounted) return;
        final changed = _sanitizeConfigForCapabilities(_cfg, capabilities);
        setState(() => _backendCapabilities = capabilities);
        if (changed) _emit();
      });
    }
    if (Platform.isAndroid || Platform.isMacOS || Platform.isIOS) {
      HardwareEncodeService.isAvailable().then((ok) {
        if (mounted) setState(() => _hwAvailable = ok);
      });
    }
  }

  @override
  void dispose() {
    _suffixController.dispose();
    super.dispose();
  }

  String _t(String chinese, String english) =>
      _cfg.language == AppLanguage.english ? english : chinese;

  String _outputTitle(OutputMode mode) {
    if (_cfg.language == AppLanguage.english) {
      return mode == OutputMode.oppo ? 'OPPO Compatible' : 'Apple Standard';
    }
    return mode.appTitle;
  }

  void _emit() {
    widget.config.language = _cfg.language;
    widget.config.family = _cfg.family;
    widget.config.backend = _cfg.backend;
    widget.config.outputMode = _cfg.outputMode;
    widget.config.outputDirectory = _cfg.outputDirectory;
    widget.config.oppoCompatibility = _cfg.oppoCompatibility;
    widget.config.oppoCameraTail = _cfg.oppoCameraTail;
    widget.config.strictTmap = _cfg.strictTmap;
    widget.config.applePhotographicStyles = _cfg.applePhotographicStyles;
    widget.config.applePortrait = _cfg.applePortrait;
    widget.config.skipExisting = _cfg.skipExisting;
    widget.config.maxConcurrentJobs = _cfg.maxConcurrentJobs;
    widget.config.fileNameSuffix = _cfg.fileNameSuffix;
    widget.config.categorizeOutputByMode = _cfg.categorizeOutputByMode;
    widget.config.autoSaveToGallery = _cfg.autoSaveToGallery;
    widget.config.hardwareEncode = _cfg.hardwareEncode;
    widget.onChanged();
    setState(() {});
  }

  void _setOutputMode(OutputMode mode) {
    setState(() {
      _cfg.outputMode = mode;
      if (mode == OutputMode.apple) {
        _cfg.oppoCompatibility = OppoCompatMode.off;
        _cfg.oppoCameraTail = OppoCameraTailMode.off;
      } else {
        _cfg.applePhotographicStyles = false;
        _cfg.applePortrait = false;
        if (_cfg.oppoCompatibility == OppoCompatMode.off) {
          _cfg.oppoCompatibility = OppoCompatMode.on;
        }
        if (_cfg.oppoCameraTail == OppoCameraTailMode.off) {
          _cfg.oppoCameraTail = OppoCameraTailMode.automatic;
        }
      }
    });
    _emit();
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

  Future<void> _pickWritebackPhoto({required bool donor}) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
    );
    final path = picked == null || picked.files.isEmpty
        ? null
        : picked.files.single.path;
    if (path == null || !mounted) return;
    setState(() {
      if (donor) {
        _writebackDonorPath = path;
      } else {
        _writebackReturnedPath = path;
      }
    });
  }

  String _writebackOutputPath() {
    final returned = File(_writebackReturnedPath!);
    final baseName = returned.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.(heic|heif)$', caseSensitive: false),
      '',
    );
    final directory = _cfg.outputDirectory ?? returned.parent.path;
    final suffix = _cfg.outputMode == OutputMode.oppo ? '_oppo' : '_apple';
    return '$directory${Platform.pathSeparator}$baseName$suffix.heic';
  }

  Future<void> _runReturnedPhotoWriteback() async {
    final returned = _writebackReturnedPath;
    if (returned == null ||
        (_cfg.outputMode == OutputMode.oppo && _writebackDonorPath == null) ||
        _writebackRunning) {
      return;
    }
    setState(() => _writebackRunning = true);
    final output = _writebackOutputPath();
    try {
      final result = await XdRemuxService.writebackReturnedPhoto(
        originalPath: _writebackDonorPath,
        returnedPath: returned,
        outputPath: output,
        outputMode: _cfg.outputMode,
      );
      if (!mounted) return;
      final success = result['success'] == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '${_cfg.outputMode.appTitle} 输出已生成：${File(output).uri.pathSegments.last}'
                : (result['errorMessage']?.toString() ?? '回传照片输出验证失败'),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('回传照片回写失败：$error')));
    } finally {
      if (mounted) setState(() => _writebackRunning = false);
    }
  }

  /// Render the MediaCodec probe result returned by the Kotlin side.
  void _showProbeResultDialog(Map<Object?, Object?>? raw) {
    final result = raw?.map((k, v) => MapEntry(k.toString(), v));
    final encoders = result?['encoders'] as List<dynamic>? ?? [];
    final colorFormats = result?['colorFormats'] as List<dynamic>? ?? [];
    final config420 = result?['config420Flexible'];
    final config444 = result?['config444Flexible'];

    String colorNames(int fmt) => switch (fmt) {
      0x13 => 'YUV420 semi-planar (0x13)',
      0x7F420888 => 'YUV420 flexible (0x7F420888)',
      0x7F420789 => 'YUV420 tiled (0x7F420789)',
      0x7F420444 => 'YUV444 flexible (0x7F420444)',
      _ => '0x${fmt.toRadixString(16)}',
    };

    final content = StringBuffer()
      ..writeln('设备：${result?['manufacturer']} ${result?['model']}')
      ..writeln('系统：SDK ${result?['sdkInt']}')
      ..writeln('芯片：${result?['chipset']}')
      ..writeln('')
      ..writeln('HEVC 编码器：')
      ..writeln(
        encoders.isEmpty ? '  (无)' : encoders.map((e) => '  $e').join('\n'),
      )
      ..writeln('')
      ..writeln('支持颜色格式：')
      ..writeln(
        colorFormats.isEmpty
            ? '  (无)'
            : colorFormats.map((f) => '  ${colorNames(f as int)}').join('\n'),
      )
      ..writeln('')
      ..writeln('4:2:0 flexible 配置：$config420')
      ..writeln('4:4:4 flexible 配置：$config444');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('硬件编码检测结果'),
        content: SingleChildScrollView(
          child: SelectableText(content.toString()),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content.toString()));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
                Text(_t('转换设置', 'Settings'), style: theme.textTheme.titleLarge),
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
                    Text(
                      _t('常用设置', 'General'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<AppLanguage>(
                      initialValue: _cfg.language,
                      decoration: InputDecoration(
                        labelText: _t('界面语言', 'Language'),
                        border: const OutlineInputBorder(),
                      ),
                      items: AppLanguage.values
                          .map(
                            (language) => DropdownMenuItem(
                              value: language,
                              child: Text(language.appTitle),
                            ),
                          )
                          .toList(),
                      onChanged: (language) {
                        if (language == null) return;
                        setState(() => _cfg.language = language);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _t('输出模式', 'Output mode'),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    SegmentedButton<OutputMode>(
                      segments: OutputMode.values
                          .map(
                            (mode) => ButtonSegment<OutputMode>(
                              value: mode,
                              label: Text(_outputTitle(mode)),
                            ),
                          )
                          .toList(),
                      selected: {_cfg.outputMode},
                      onSelectionChanged: (value) {
                        _setOutputMode(value.first);
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _cfg.language == AppLanguage.english
                          ? (_cfg.outputMode == OutputMode.oppo
                                ? 'Choose this for OPPO/OnePlus Gallery. Keeps compatibility metadata for further editing.'
                                : 'Apple Photos-compatible standard file format. Supports next-generation Photographic Styles.')
                          : (_cfg.outputMode == OutputMode.oppo
                                ? '兼容 OPPO/一加相册的标准文件格式，支持后续编辑'
                                : '兼容 Apple 相册的标准文件格式，支持开启新一代摄影风格'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _t('高级设置', 'Advanced'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Swift is visible only on Apple platforms. It remains
                    // disabled until the embedded Swift Core capability probe
                    // reports a linked and verified implementation.
                    if (Platform.isMacOS || Platform.isIOS) ...[
                      Text(
                        _t('转换引擎', 'Conversion engine'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<ConversionBackend>(
                        initialValue: _cfg.backend,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: ConversionBackend.rust,
                            child: Text(_t('Rust（推荐）', 'Rust (Recommended)')),
                          ),
                          DropdownMenuItem(
                            value: ConversionBackend.swift,
                            enabled: _backendCapabilities.swiftAvailable,
                            child: Text('Swift'),
                          ),
                        ],
                        onChanged: (backend) {
                          if (backend == null ||
                              !_backendCapabilities.isAvailable(backend)) {
                            return;
                          }
                          setState(() {
                            _cfg.backend = backend;
                            if (backend != ConversionBackend.swift) {
                              _cfg.applePhotographicStyles = false;
                              _cfg.applePortrait = false;
                            }
                          });
                          _emit();
                        },
                      ),
                      if (_cfg.backend == ConversionBackend.swift &&
                          _backendCapabilities.swiftAppleFeatures) ...[
                        const SizedBox(height: 12),
                        Text(
                          _t(
                            'Apple 相册功能（实验性）',
                            'Apple Photos features (Experimental)',
                          ),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _t(
                            '这里写入的是可继续调节的数据，不会把风格直接烘焙进照片。',
                            'These options write editable data; the look is not baked into the photo.',
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (_backendCapabilities.swiftPhotographicStyles)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              _t(
                                'Apple 相册摄影风格（Swift）',
                                'Apple Photos Photographic Styles (Swift)',
                              ),
                            ),
                            subtitle: Text(
                              _t(
                                '使用 Swift 生成可在 Apple 相册中继续调节的摄影风格数据；仅 Apple 原生能力可用时显示。',
                                'Uses Swift to generate Photographic Styles data editable in Apple Photos; available only with Apple-native capabilities.',
                              ),
                            ),
                            value: _cfg.applePhotographicStyles,
                            onChanged: (value) {
                              setState(() {
                                _cfg.applePhotographicStyles = value;
                                if (value) {
                                  _cfg.outputMode = OutputMode.apple;
                                  _cfg.oppoCompatibility = OppoCompatMode.off;
                                  _cfg.oppoCameraTail = OppoCameraTailMode.off;
                                }
                              });
                              _emit();
                            },
                          ),
                        if (_backendCapabilities.swiftPortrait)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Apple 人像模式（Swift）'),
                            value: _cfg.applePortrait,
                            onChanged: (value) {
                              setState(() {
                                _cfg.applePortrait = value;
                                if (value) {
                                  _cfg.outputMode = OutputMode.apple;
                                  _cfg.oppoCompatibility = OppoCompatMode.off;
                                  _cfg.oppoCameraTail = OppoCameraTailMode.off;
                                }
                              });
                              _emit();
                            },
                          ),
                      ],
                      const SizedBox(height: 20),
                    ],

                    if (_cfg.backend == ConversionBackend.rust) ...[
                      Text(
                        _t(
                          'Apple 相册功能（实验性）',
                          'Apple Photos features (Experimental)',
                        ),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _t(
                          '这里写入的是可继续调节的数据，不会把风格直接烘焙进照片。',
                          'These options write editable data; the look is not baked into the photo.',
                        ),
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          _t(
                            'Apple 相册摄影风格（Rust）',
                            'Apple Photos Photographic Styles (Rust)',
                          ),
                        ),
                        subtitle: Text(
                          _t(
                            '使用 Rust 生成可在 Apple 相册中继续调节的摄影风格数据；自动使用 Apple 标准输出，并关闭 GPU 硬件编码。',
                            'Uses Rust to generate Photographic Styles data editable in Apple Photos; selects Apple Standard output and disables GPU encoding.',
                          ),
                        ),
                        value: _cfg.applePhotographicStyles,
                        onChanged: (value) {
                          setState(() {
                            _cfg.applePhotographicStyles = value;
                            if (value) {
                              _cfg.outputMode = OutputMode.apple;
                              _cfg.oppoCompatibility = OppoCompatMode.off;
                              _cfg.oppoCameraTail = OppoCameraTailMode.off;
                              _cfg.hardwareEncode = false;
                            }
                          });
                          _emit();
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          _t('Apple 人像模式（Rust）', 'Apple Portrait Mode (Rust)'),
                        ),
                        value: _cfg.applePortrait,
                        onChanged: (value) {
                          setState(() {
                            _cfg.applePortrait = value;
                            if (value) {
                              _cfg.outputMode = OutputMode.apple;
                              _cfg.oppoCompatibility = OppoCompatMode.off;
                              _cfg.oppoCameraTail = OppoCameraTailMode.off;
                              _cfg.hardwareEncode = false;
                            }
                          });
                          _emit();
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (Platform.isMacOS) ...[
                      ExpansionTile(
                        initiallyExpanded: false,
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        title: Text(_t('一帧影像，动用两台手机', 'One Frame, Two Phones')),
                        subtitle: Text(
                          _t(
                            '用 OPPO 手机原图提供兼容信息，再用 iPhone/Apple 相册完成编辑和回传。',
                            'Use the OPPO original for compatibility metadata, then edit and return it through iPhone/Apple Photos.',
                          ),
                        ),
                        children: [
                          const SizedBox(height: 8),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.photo_library_outlined),
                            title: Text(_t('OPPO 手机原图', 'OPPO original photo')),
                            subtitle: Text(
                              _writebackDonorPath ??
                                  _t(
                                    'OPPO 标准输出必需；Apple 标准输出可留空',
                                    'Required for OPPO Standard output; optional for Apple Standard output',
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: OutlinedButton(
                              onPressed: _writebackRunning
                                  ? null
                                  : () => _pickWritebackPhoto(donor: true),
                              child: Text(_t('选择', 'Choose')),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.phone_iphone),
                            title: Text(
                              _t('iPhone 回传照片', 'iPhone returned photo'),
                            ),
                            subtitle: Text(
                              _writebackReturnedPath ?? _t('必需', 'Required'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: OutlinedButton(
                              onPressed: _writebackRunning
                                  ? null
                                  : () => _pickWritebackPhoto(donor: false),
                              child: Text(_t('选择', 'Choose')),
                            ),
                          ),
                          SegmentedButton<OutputMode>(
                            segments: OutputMode.values
                                .map(
                                  (mode) => ButtonSegment<OutputMode>(
                                    value: mode,
                                    label: Text(_outputTitle(mode)),
                                  ),
                                )
                                .toList(),
                            selected: {_cfg.outputMode},
                            onSelectionChanged: _writebackRunning
                                ? null
                                : (value) => _setOutputMode(value.first),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _cfg.language == AppLanguage.english
                                ? (_cfg.outputMode == OutputMode.oppo
                                      ? 'OPPO Standard: requires the OPPO original; restores OPPO watermark and metadata.'
                                      : 'Apple Standard: keeps the iPhone/Apple Photos result without writing OPPO metadata.')
                                : (_cfg.outputMode == OutputMode.oppo
                                      ? 'OPPO 标准：需要 OPPO 手机原图；回写水印和 OPPO 附加信息。'
                                      : 'Apple 标准：保留 iPhone/Apple 相册结果，不写回 OPPO 信息。'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed:
                                  _writebackReturnedPath == null ||
                                      _writebackRunning ||
                                      (_cfg.outputMode == OutputMode.oppo &&
                                          _writebackDonorPath == null)
                                  ? null
                                  : _runReturnedPhotoWriteback,
                              icon: _writebackRunning
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.output),
                              label: Text(_writebackRunning ? '处理中…' : '生成输出'),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Output directory — desktop only. Android scoped storage
                    // and the iOS sandbox both make an arbitrary writable
                    // directory impossible; output goes to the app-scoped dir
                    // and is exported via 保存到图库 / 分享.
                    Text(
                      '输出与性能',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!Platform.isAndroid && !Platform.isIOS) ...[
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
                      title: Text(
                        (Platform.isAndroid || Platform.isIOS)
                            ? '按拍摄模式分相册'
                            : '按拍摄模式分目录输出',
                      ),
                      subtitle: Text(
                        (Platform.isAndroid || Platform.isIOS)
                            ? '保存到图库时按"大师模式 / 人像 / 夜景"等分相册。'
                            : '将已识别的照片写入"大师模式 / 人像 / 夜景"等子目录。',
                      ),
                      value: _cfg.categorizeOutputByMode,
                      onChanged: (value) {
                        setState(() => _cfg.categorizeOutputByMode = value);
                        _emit();
                      },
                    ),
                    const SizedBox(height: 12),

                    // Advanced output-format options. Defaults are correct
                    // for OPPO/OnePlus HDR files; changing them can make the
                    // result unreadable in OPPO's gallery, so keep them
                    // collapsed behind a warning header.
                    ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        '兼容性高级设置',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      subtitle: const Text('一般保持默认；只在排查相册兼容性时修改'),
                      leading: Icon(
                        Icons.tune,
                        size: 20,
                        color: theme.colorScheme.error,
                      ),
                      children: [
                        const SizedBox(height: 8),
                        Text('输入照片类型', style: theme.textTheme.titleSmall),
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
                          '自动检测 X6/X7；不确定时保持“自动”。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
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
                          onChanged: _cfg.outputMode == OutputMode.apple
                              ? null
                              : (mode) {
                                  if (mode == null) return;
                                  setState(() {
                                    _cfg.outputMode = OutputMode.oppo;
                                    _cfg.oppoCompatibility = mode;
                                    if (mode != OppoCompatMode.off) {
                                      _cfg.applePhotographicStyles = false;
                                      _cfg.applePortrait = false;
                                    }
                                  });
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
                            labelText: '保留 OPPO 相机附加信息',
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
                          onChanged: _cfg.outputMode == OutputMode.apple
                              ? null
                              : (mode) {
                                  if (mode == null) return;
                                  setState(() {
                                    _cfg.outputMode = OutputMode.oppo;
                                    _cfg.oppoCameraTail = mode;
                                  });
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
                          title: const Text('严格 ISO 兼容（高级）'),
                          subtitle: const Text(
                            '仅用于严格 ISO 21496-1 测试；普通用户建议关闭，可能降低部分相册兼容性。',
                          ),
                          value: _cfg.strictTmap,
                          onChanged: (value) {
                            setState(() => _cfg.strictTmap = value);
                            _emit();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

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
                      controller: _suffixController,
                      onChanged: (v) {
                        // Allow empty to mean "no suffix" instead of forcing
                        // back to '_iso' (which made clearing the field stick).
                        _cfg.fileNameSuffix = v.trim();
                        _emit();
                      },
                    ),
                    const SizedBox(height: 4),
                    if (!Platform.isAndroid && !Platform.isIOS)
                      Text(
                        '设置输出目录后，后缀将被忽略。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 20),

                    // Auto-save to gallery (mobile: Android/iOS)
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('转换完成后自动保存到图库'),
                        subtitle: Text(
                          '批量转换结束后自动存入相册（遵循分相册设置）。',
                          style: theme.textTheme.bodySmall,
                        ),
                        value: _cfg.autoSaveToGallery,
                        dense: true,
                        onChanged: (v) {
                          setState(() => _cfg.autoSaveToGallery = v);
                          _emit();
                        },
                      ),
                      const SizedBox(height: 8),
                    ],

                    // All-files access (Android only): needed to read original
                    // HEIC files by path and preserve GPS (OPPO's content
                    // stream strips it).
                    if (Platform.isAndroid) ...[
                      FutureBuilder<bool>(
                        future: allFilesAccessGranted(),
                        builder: (context, snapshot) {
                          final granted = snapshot.data ?? false;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.folder_special_outlined),
                            title: const Text('保留位置信息'),
                            subtitle: Text(
                              granted
                                  ? '「所有文件访问」已授予，转换保留 GPS'
                                  : '授予后可保留照片 GPS 位置',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: granted
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                    size: 20,
                                  )
                                : const Icon(Icons.open_in_new, size: 18),
                            onTap: () async {
                              final ok = await ensureAllFilesAccess();
                              if (!mounted) return;
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? '已授予「所有文件访问」，转换将保留 GPS'
                                        : '未授予权限，转换将丢失 GPS 位置',
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],

                    // Battery optimization entry (Android only)
                    if (Platform.isAndroid) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.battery_saver),
                        title: const Text('后台转换'),
                        subtitle: Text(
                          '设置耗电行为控制以保持后台转换',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: const Icon(Icons.open_in_new, size: 18),
                        onTap: () {
                          const batteryChannel = MethodChannel(
                            'xdremux/battery',
                          );
                          batteryChannel.invokeMethod<bool>(
                            'openOemBatterySettings',
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],

                    // Hardware encoding toggle (Android MediaCodec / Apple
                    // VideoToolbox on macOS+iOS, experimental)
                    if (Platform.isAndroid ||
                        Platform.isMacOS ||
                        Platform.isIOS) ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_t('GPU 硬件编码', 'GPU hardware encoding')),
                        subtitle: Text(
                          _cfg.applePhotographicStyles || _cfg.applePortrait
                              ? _t(
                                  'Apple 相册可调功能需要软件编码，已自动关闭。',
                                  'Apple Photos editable features require software encoding and disable this option.',
                                )
                              : '${_t('使用设备硬件加速普通 HDR 转换。', 'Use hardware acceleration for standard HDR conversion.')} '
                                    '${switch (_hwAvailable) {
                                      null => _t('正在检测硬件编码器…', 'Detecting hardware encoder…'),
                                      true => _t('硬件编码器：可用', 'Hardware encoder: available'),
                                      false => _t('硬件编码器：不可用', 'Hardware encoder: unavailable'),
                                    }}',
                          style: theme.textTheme.bodySmall,
                        ),
                        value: _cfg.hardwareEncode,
                        dense: true,
                        onChanged:
                            _cfg.applePhotographicStyles || _cfg.applePortrait
                            ? null
                            : (v) {
                                // GPU 硬件编码只输出 4:2:0 gain map，正好是 OPPO 图库
                                // 需要的格式。开启时强制 OPPO 兼容模式，保证输出能
                                // 被 OPPO 图库识别。
                                if (v &&
                                    _cfg.oppoCompatibility !=
                                        OppoCompatMode.on) {
                                  _cfg.oppoCompatibility = OppoCompatMode.on;
                                }
                                if (v) {
                                  _cfg.outputMode = OutputMode.oppo;
                                  _cfg.applePhotographicStyles = false;
                                  _cfg.applePortrait = false;
                                }
                                setState(() => _cfg.hardwareEncode = v);
                                _emit();
                              },
                      ),
                      const SizedBox(height: 8),
                    ],

                    // Hardware-encoding diagnostic probe (Android only, dev)
                    if (Platform.isAndroid) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.speed),
                        title: const Text('硬件编码检测'),
                        subtitle: Text(
                          '检测 MediaCodec HEVC 编码器对 4:4:4 的支持（开发用）',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: const Icon(Icons.open_in_new, size: 18),
                        onTap: () async {
                          const probeChannel = MethodChannel(
                            'xdremux/hevc-probe',
                          );
                          try {
                            final result = await probeChannel
                                .invokeMethod<Map<Object?, Object?>>('probe');
                            if (!context.mounted) return;
                            _showProbeResultDialog(result);
                          } catch (e) {
                            if (!context.mounted) return;
                            showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('硬件编码检测失败'),
                                content: Text('$e'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('知道了'),
                                  ),
                                ],
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                    ],

                    // iOS: jump to the app's Documents in Files
                    // (shareddocuments:// is the system URL for that).
                    if (Platform.isIOS) ...[
                      const Divider(),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_open),
                        title: const Text('打开输出目录'),
                        subtitle: Text(
                          '在「文件」App 中查看已转换的照片',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => launchUrl(Uri.parse('shareddocuments://')),
                      ),
                    ],

                    // Cache management (Android / iOS)
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      const Divider(),
                      const SizedBox(height: 8),
                      _CacheManagementTile(),
                    ],
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

/// Android / iOS: shows picked-files cache and output-dir sizes, with
/// buttons to clear them. The file picker and share intake write provider
/// bytes into the app cache; converted outputs accumulate in the app-scoped
/// output dir; neither is auto-cleaned.
class _CacheManagementTile extends StatefulWidget {
  @override
  State<_CacheManagementTile> createState() => _CacheManagementTileState();
}

class _CacheManagementTileState extends State<_CacheManagementTile> {
  int _cacheSize = 0;
  int _outputSize = 0;
  bool _cleared = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// App-scoped output directory: Android external files dir, iOS
  /// Documents/output. Returns null when unavailable.
  Future<Directory?> _outputDir() async {
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}output');
    }
    return await getExternalStorageDirectory();
  }

  Future<int> _dirSize(Directory dir) async {
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> _refresh() async {
    try {
      // Cache: picked_files (file picker / share intake fallback)
      final tempDir = await getTemporaryDirectory();
      final pickedDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}picked_files',
      );
      final cacheSize = await _dirSize(pickedDir);

      int outputSize = 0;
      final outDir = await _outputDir();
      if (outDir != null) {
        outputSize = await _dirSize(outDir);
      }

      if (mounted) {
        setState(() {
          _cacheSize = cacheSize;
          _outputSize = outputSize;
          _cleared = false;
        });
      }
    } catch (_) {}
  }

  Future<void> _clearCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final pickedDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}picked_files',
      );
      if (pickedDir.existsSync()) await pickedDir.delete(recursive: true);
      if (mounted)
        setState(() {
          _cacheSize = 0;
          _cleared = true;
        });
    } catch (_) {}
  }

  Future<void> _clearOutput() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber),
        title: const Text('清除输出目录？'),
        content: const Text('输出目录中的已转换文件将被删除，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final outDir = await _outputDir();
      if (outDir != null && outDir.existsSync()) {
        await for (final entity in outDir.list()) {
          if (entity is File) await entity.delete();
          if (entity is Directory) await entity.delete(recursive: true);
        }
        if (!outDir.existsSync()) await outDir.create(recursive: true);
      }
      if (mounted) setState(() => _outputSize = 0);
    } catch (_) {}
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _cleared && _cacheSize == 0
                ? Icons.check_circle_outline
                : Icons.delete_sweep_outlined,
            color: _cleared && _cacheSize == 0 ? Colors.green : null,
          ),
          title: const Text('清除文件缓存'),
          subtitle: Text(
            _cacheSize > 0
                ? '已缓存 ${_formatSize(_cacheSize)}（文件选择器临时副本）'
                : '无缓存文件',
            style: theme.textTheme.bodySmall,
          ),
          trailing: _cacheSize > 0
              ? TextButton(onPressed: _clearCache, child: const Text('清除'))
              : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.output_outlined),
          title: const Text('清除输出目录'),
          subtitle: Text(
            _outputSize > 0 ? '已转换文件共 ${_formatSize(_outputSize)}' : '输出目录为空',
            style: theme.textTheme.bodySmall,
          ),
          trailing: _outputSize > 0
              ? TextButton(onPressed: _clearOutput, child: const Text('清除'))
              : null,
        ),
      ],
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
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  const _MobileQueueCard({
    required this.item,
    required this.isSelected,
    required this.onTap,
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
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                height: 76,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _ThumbnailWidget(
                    inputPath: item.inputPath,
                    outputPath: item.outputPath,
                    showToggle: false,
                    isConverted: item.status == QueueItemStatus.converted,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
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
                      const SizedBox(height: 5),
                      // Format chips: HDR kind (LHDR/UHDR) + family (X6/X7) +
                      // capture mode. Stacked as small pills on the second line.
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (item.hdrKind != null)
                            _InfoChip(
                              label: item.hdrKind!.toUpperCase(),
                              color: item.hdrKind == 'uhdr'
                                  ? theme.colorScheme.tertiary
                                  : theme.colorScheme.primary,
                            ),
                          if (item.family != null)
                            _InfoChip(
                              label: item.family!.toUpperCase(),
                              color: theme.colorScheme.secondary,
                            ),
                          if (item.captureModeLabel != null &&
                              item.captureModeLabel!.isNotEmpty)
                            _InfoChip(
                              label: item.captureModeLabel!,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                        ],
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
                      // Per-file progress bar for the running item. Constrained to
                      // the column width so it never overflows the card.
                      if (item.status == QueueItemStatus.running) ...[
                        const SizedBox(height: 7),
                        LayoutBuilder(
                          builder: (context, constraints) => ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value:
                                  item.progress != null &&
                                      item.progress!.total > 0
                                  ? item.progress!.current /
                                        item.progress!.total
                                  : null,
                              minHeight: 4,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              valueColor: AlwaysStoppedAnimation(
                                theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Queue management is separate from completed-output actions.
              // Completed items use the card tap for save/share/open and are
              // removed by the global "清除已完成" action instead.
              if (!item.isSuccessful && item.status != QueueItemStatus.running)
                PopupMenuButton<_MobileQueueAction>(
                  tooltip: '项目操作',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    switch (action) {
                      case _MobileQueueAction.retry:
                        onRetry();
                      case _MobileQueueAction.remove:
                        onRemove();
                    }
                  },
                  itemBuilder: (context) => [
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

enum _ImportSource { photos, files }

enum _OutputAction { save, share, open }

enum _MobileQueueAction { retry, remove }

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

/// Small non-interactive chip for the queue card metadata row
/// (LHDR/UHDR, X6/X7, capture mode).
class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;

  const _InfoChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Small pill layered on top of the thumbnail image (dark backdrop for
/// legibility over arbitrary photo content). Used by the desktop photo card.
class _OverlayChip extends StatelessWidget {
  final String label;
  final Color color;

  const _OverlayChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(160),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
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
                  _ThumbnailWidget(
                    inputPath: item.inputPath,
                    outputPath: item.outputPath,
                    isConverted: isDone,
                  ),
                  // Format chips: HDR kind (LHDR/UHDR) + family (X6/X7) +
                  // capture mode. Same set as the mobile queue card.
                  if (item.hdrKind != null ||
                      item.family != null ||
                      (item.captureModeLabel != null &&
                          item.captureModeLabel!.isNotEmpty))
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        alignment: WrapAlignment.end,
                        children: [
                          if (item.hdrKind != null)
                            _OverlayChip(
                              label: item.hdrKind!.toUpperCase(),
                              color: item.hdrKind == 'uhdr'
                                  ? theme.colorScheme.tertiary
                                  : theme.colorScheme.primary,
                            ),
                          if (item.family != null)
                            _OverlayChip(
                              label: item.family!.toUpperCase(),
                              color: theme.colorScheme.secondary,
                            ),
                          if (item.captureModeLabel != null &&
                              item.captureModeLabel!.isNotEmpty)
                            _OverlayChip(
                              label: item.captureModeLabel!,
                              color: Colors.white,
                            ),
                        ],
                      ),
                    ),
                  if (isRunning)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _OverlayBadge(
                            icon: Icons.bolt,
                            label: item.progress != null
                                ? '${item.progress!.current}/${item.progress!.total}'
                                : '转换中',
                            color: Colors.blue,
                            bottom: 0,
                          ),
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value:
                                    item.progress != null &&
                                        item.progress!.total > 0
                                    ? item.progress!.current /
                                          item.progress!.total
                                    : null,
                                minHeight: 4,
                                backgroundColor: Colors.white.withAlpha(80),
                                valueColor: const AlwaysStoppedAnimation(
                                  Colors.blue,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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

class _ThumbnailWidget extends StatefulWidget {
  final String inputPath;
  final String? outputPath;

  /// Whether to show the "source / converted" toggle chip. Disabled for tiny
  /// thumbnails (list view) where the chip would be unusable.
  final bool showToggle;

  /// Whether this item was actually converted in this session. The "converted"
  /// (HDR) view must only be offered when the item really went through
  /// conversion — otherwise a pre-existing output file would wrongly show the
  /// toggle before conversion.
  final bool isConverted;

  const _ThumbnailWidget({
    required this.inputPath,
    this.outputPath,
    this.showToggle = true,
    this.isConverted = false,
  });

  @override
  State<_ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<_ThumbnailWidget> {
  /// Whether to show the converted output (HDR) instead of the source.
  /// Only meaningful on macOS where native ImageIO applies the HDR boost.
  bool _showOutput = true;

  /// The thumbnail Future is created once per (path) and held here so
  /// rebuilds of the parent (e.g. conversion progress updates) do not hand
  /// FutureBuilder a fresh Future every frame — that resets the async state
  /// and makes the image blink (waiting → done each rebuild).
  Future<Uint8List?>? _thumbFuture;

  /// Last successfully loaded thumbnail. Used as `initialData` when the path
  /// changes (e.g. a conversion finishes and _displayPath switches from the
  /// input to the output), so the image stays visible instead of flashing a
  /// placeholder while the new thumbnail loads.
  Uint8List? _lastThumb;

  @override
  void didUpdateWidget(_ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only reset the cached thumbnail when the *input* photo changes. The
    // converted output is the same photo, so switching _displayPath to it
    // (isConverted false→true) must not force a reload — that makes the
    // thumbnail blink for a couple of seconds after conversion completes.
    if (oldWidget.inputPath != widget.inputPath) {
      _thumbFuture = null;
      _lastThumb = null;
    }
  }

  /// The path to render: only show the converted output when this item was
  /// actually converted this session (isConverted). Otherwise a stale output
  /// file from a previous run would mask the source thumbnail.
  String get _displayPath {
    final out = widget.outputPath;
    if (widget.isConverted &&
        _showOutput &&
        out != null &&
        out.isNotEmpty &&
        File(out).existsSync()) {
      return out;
    }
    return widget.inputPath;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = _displayPath;
    final hasOutput =
        widget.isConverted &&
        widget.outputPath != null &&
        widget.outputPath!.isNotEmpty &&
        File(widget.outputPath!).existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<Uint8List?>(
          initialData: _lastThumb,
          future: _thumbFuture ??= _PhotoCard._thumbCache.containsKey(path)
              ? Future.value(_PhotoCard._thumbCache[path])
              : XdRemuxService.getThumbnail(path, maxPixelSize: 512).then((t) {
                  _PhotoCard._thumbCache[path] = t;
                  return t;
                }),
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data != null) {
              _lastThumb = data;
              return Image.memory(
                data,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              );
            }
            return Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(
                child: Icon(Icons.photo, size: 32, color: Colors.grey),
              ),
            );
          },
        ),
        // Source / converted toggle — macOS only, and only once a converted
        // output exists. Lets you A/B the HDR result against the original.
        // Bottom-right so it does not clash with the status badge (bottom-left).
        if (Platform.isMacOS && hasOutput && widget.showToggle)
          Positioned(
            right: 6,
            bottom: 6,
            child: InkWell(
              onTap: () => setState(() => _showOutput = !_showOutput),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(180),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showOutput ? Icons.hdr_on : Icons.photo_outlined,
                      size: 12,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _showOutput ? '转换后' : '源',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
