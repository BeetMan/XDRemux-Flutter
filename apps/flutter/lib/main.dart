import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models/app_models.dart';
import 'services/xdremux_service.dart';

void main() {
  runApp(const XdRemuxApp());
}

class XdRemuxApp extends StatelessWidget {
  const XdRemuxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XDRemux',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
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
  int? _selectedIndex;

  String _version = '';
  Timer? _configSaveTimer;

  @override
  void initState() {
    super.initState();
    _initAsync();
  }

  Future<void> _initAsync() async {
    _config = await XdRemuxService.loadConfig();
    try {
      _version = await XdRemuxService.getVersion();
    } catch (e) {
      _version = 'core error: $e';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _configSaveTimer?.cancel();
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

  bool get _canStart => !_isProcessing &&
      _queue.any((item) =>
          item.status == QueueItemStatus.pending &&
          !item.outputPlanStatus.blocksConversion);

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

  double get _progressFraction =>
      _totalFiles > 0 ? _processedCount / _totalFiles : 0.0;

  void _updateStatusText() {
    if (_isProcessing) {
      setState(() => _statusText = '转换中');
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

  Future<void> _addFiles() async {
    if (!_canEditQueue) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['heic', 'HEIC'],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    final existing = _queue.map((item) => item.inputPath).toSet();
    int added = 0;

    for (final file in result.files) {
      if (file.path == null) continue;
      final path = file.path!;
      if (existing.contains(path)) continue;

      final outputPath = _config.outputPathFor(path);
      _queue.add(QueueItem(
        id: _makeId(),
        inputPath: path,
        outputPath: outputPath,
        outputPlanStatus: _computeOutputPlan(path, outputPath),
      ));
      existing.add(path);
      added++;
    }

    _validateOutputPlans();
    _updateStatusText();
    setState(() => _currentFileName = added > 0 ? '已添加 $added 个文件' : '未添加新文件');
  }

  OutputPlanStatus _computeOutputPlan(String inputPath, String outputPath) {
    final inputFile = File(inputPath);
    if (!inputFile.existsSync()) return OutputPlanStatus.inputMissing;

    final outputFile = File(outputPath);
    final parent = outputFile.parent;
    if (parent.existsSync() && !parent.path.endsWith(Platform.pathSeparator)) {
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
        item.outputPath = _config.outputPathFor(item.inputPath);
        item.outputPlanStatus =
            _computeOutputPlan(item.inputPath, item.outputPath);
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
      }
    }

    scheduleNext();
  }

  Future<void> _convertOne(int index) async {
    final item = _queue[index];
    final runConfig = _config.copy();

    try {
      // Check skipExisting
      if (runConfig.skipExisting &&
          File(item.outputPath).existsSync() &&
          await XdRemuxService.verifyOutput(item.outputPath)) {
        item.status = QueueItemStatus.skippedExisting;
        item.finishedAt = DateTime.now();
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
    if (mounted) setState(() {});
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
  }

  void _clearQueue() {
    if (!_canEditQueue) return;
    setState(() {
      _queue.clear();
      _selectedIndex = null;
      _statusText = '就绪';
      _currentFileName = '';
    });
  }

  void _clearCompleted() {
    if (!_canEditQueue) return;
    setState(() {
      _queue.removeWhere(
          (item) => item.status == QueueItemStatus.converted || item.status == QueueItemStatus.skippedExisting);
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

  void _revealInExplorer(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      // Open containing directory
      Process.run('xdg-open', [File(path).parent.path]);
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
    final selectedItem = _selectedIndex != null && _selectedIndex! < _queue.length
        ? _queue[_selectedIndex!]
        : (_queue.isNotEmpty ? _queue.first : null);

    return Scaffold(
      appBar: AppBar(
        title: Text('XDRemux$_versionSuffix'),
        backgroundColor: theme.colorScheme.inversePrimary,
        actions: [
          // Add files
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            tooltip: '添加 HEIC',
            onPressed: _canEditQueue ? _addFiles : null,
          ),
          const SizedBox(width: 4),
          // Start conversion
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始'),
            onPressed: _canStart ? _startConversion : null,
          ),
          const SizedBox(width: 8),
          // OPPO compatibility toggle
          if (_canEditQueue)
            _OppoCompatToggle(
              mode: _config.oppoCompatibility,
              onChanged: (v) {
                setState(() => _config.oppoCompatibility = v);
                _scheduleConfigSave();
              },
            ),
          const SizedBox(width: 4),
          // Cancel
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: '取消',
            onPressed: _isProcessing ? _cancelConversion : null,
          ),
          const SizedBox(width: 4),
          // Settings
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '设置',
            onPressed: () => _openSettings(context),
          ),
          const SizedBox(width: 4),
          // Clear
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空队列',
            onPressed: _canEditQueue && _queue.isNotEmpty ? _clearQueue : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Progress bar
          _buildProgressBar(theme),
          const Divider(height: 1),
          // Main content
          Expanded(
            child: _queue.isEmpty ? _buildEmptyState(theme) : _buildQueueView(theme, selectedItem),
          ),
          // Footer
          if (_queue.isNotEmpty) _buildFooter(theme),
        ],
      ),
    );
  }

  String get _versionSuffix => _version.isNotEmpty ? '  $_version' : '';

  Widget _buildProgressBar(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_statusText,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$_processedCount / $_totalFiles',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace')),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: _progressFraction,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              _buildStatChip('已转换', _convertedCount, Colors.green),
              const SizedBox(width: 4),
              _buildStatChip('跳过', _skippedCount, Colors.grey),
              const SizedBox(width: 4),
              _buildStatChip(
                  '失败', _failedCount, _failedCount > 0 ? Colors.red : Colors.grey),
            ],
          ),
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
                const SizedBox(width: 8),
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
      child: Text('$label $count',
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined,
              size: 64, color: theme.colorScheme.primary.withAlpha(100)),
          const SizedBox(height: 16),
          Text('拖拽或选择 ProXDR HEIC 文件', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('添加文件'),
            onPressed: _addFiles,
          ),
        ],
      ),
    );
  }

  Widget _buildQueueView(ThemeData theme, QueueItem? selectedItem) {
    return Row(
      children: [
        // Left sidebar — queue list
        SizedBox(
          width: 320,
          child: ListView.builder(
            itemCount: _queue.length,
            itemBuilder: (context, index) {
              final item = _queue[index];
              final isSelected = index == _selectedIndex;
              return _QueueListTile(
                item: item,
                isSelected: isSelected,
                onTap: () => setState(() => _selectedIndex = index),
                onRemove: () => _removeItem(index),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        // Right panel — detail
        Expanded(
          child: selectedItem != null
              ? _QueueDetailView(
                  item: selectedItem,
                  revealInput: () => _revealInExplorer(selectedItem.inputPath),
                  revealOutput: () =>
                      _revealInExplorer(selectedItem.outputPath),
                )
              : Center(
                  child: Text('选择队列项目查看详情',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
        ),
      ],
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (_failedCount > 0)
            Expanded(
              child: Text(
                _queue.reversed
                        .where((item) => item.status == QueueItemStatus.failed)
                        .take(3)
                        .map((item) =>
                            '${item.fileName}: ${item.errorMessage ?? '?'}')
                        .join(' | '),
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.red),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试失败'),
            onPressed: _canEditQueue && _failedCount > 0 ? _retryFailed : null,
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.checklist, size: 16),
            label: const Text('清除已完成'),
            onPressed: _canEditQueue &&
                    (_convertedCount + _skippedCount) > 0
                ? _clearCompleted
                : null,
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('打开输出目录'),
            onPressed: _queue.any((item) => item.isSuccessful)
                ? _revealOutputs
                : null,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Settings sheet
  // ---------------------------------------------------------------------------

  void _openSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
// Queue List Tile
// ============================================================================

class _QueueListTile extends StatelessWidget {
  final QueueItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueListTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor();

    return ListTile(
      selected: isSelected,
      leading: Icon(_statusIcon(), color: color, size: 22),
      title: Text(
        item.fileName,
        style: theme.textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w500),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(item.status.displayName,
              style: TextStyle(fontSize: 11, color: color)),
          if (item.outputPlanStatus != OutputPlanStatus.ready) ...[
            const SizedBox(width: 4),
            Text(item.outputPlanStatus.displayName,
                style: TextStyle(
                    fontSize: 11,
                    color: item.outputPlanStatus.blocksConversion
                        ? Colors.red
                        : Colors.orange)),
          ],
          if (item.duration != null) ...[
            const SizedBox(width: 4),
            Text(_formatDuration(item.duration!),
                style: const TextStyle(fontSize: 10)),
          ],
        ],
      ),
      dense: true,
      onTap: onTap,
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 16),
        onPressed: onRemove,
        tooltip: '移除',
      ),
    );
  }

  IconData _statusIcon() {
    switch (item.status) {
      case QueueItemStatus.pending:
        return Icons.hourglass_empty;
      case QueueItemStatus.running:
        return Icons.bolt;
      case QueueItemStatus.converted:
        return Icons.check_circle;
      case QueueItemStatus.skippedExisting:
        return Icons.skip_next;
      case QueueItemStatus.failed:
        return Icons.cancel;
      case QueueItemStatus.cancelled:
        return Icons.remove_circle;
    }
  }

  Color _statusColor() {
    switch (item.status) {
      case QueueItemStatus.pending:
        return Colors.grey;
      case QueueItemStatus.running:
        return Colors.blue;
      case QueueItemStatus.converted:
        return Colors.green;
      case QueueItemStatus.skippedExisting:
        return Colors.grey;
      case QueueItemStatus.failed:
        return Colors.red;
      case QueueItemStatus.cancelled:
        return Colors.orange;
    }
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 10) return '${d.inMilliseconds / 1000}s';
    return '${d.inSeconds}s';
  }
}

// ============================================================================
// Queue Detail View
// ============================================================================

class _QueueDetailView extends StatelessWidget {
  final QueueItem item;
  final VoidCallback revealInput;
  final VoidCallback revealOutput;

  const _QueueDetailView({
    required this.item,
    required this.revealInput,
    required this.revealOutput,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(item.fileName, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatusChip(
                  label: item.status.displayName,
                  color: item.status == QueueItemStatus.converted
                      ? Colors.green
                      : item.status == QueueItemStatus.failed
                          ? Colors.red
                          : Colors.grey),
              const SizedBox(width: 8),
              _StatusChip(
                  label: item.outputPlanStatus.displayName,
                  color: item.outputPlanStatus.blocksConversion
                      ? Colors.red
                      : Colors.orange.shade300),
            ],
          ),
          const SizedBox(height: 16),

          // Error message
          if (item.errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withAlpha(80)),
              ),
              child: Text(item.errorMessage!,
                  style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 16),
          ],

          // Buttons
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.file_open, size: 16),
                label: const Text('源文件'),
                onPressed: revealInput,
              ),
              const SizedBox(width: 8),
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

          // Details
          _DetailRow('状态', item.status.displayName),
          _DetailRow('输出计划', item.outputPlanStatus.displayName),
          if (item.startedAt != null)
            _DetailRow(
                '开始', '${item.startedAt!.hour.toString().padLeft(2, '0')}:${item.startedAt!.minute.toString().padLeft(2, '0')}:${item.startedAt!.second.toString().padLeft(2, '0')}'),
          if (item.finishedAt != null)
            _DetailRow(
                '结束', '${item.finishedAt!.hour.toString().padLeft(2, '0')}:${item.finishedAt!.minute.toString().padLeft(2, '0')}:${item.finishedAt!.second.toString().padLeft(2, '0')}'),
          if (item.duration != null)
            _DetailRow('耗时', '${item.duration!.inMilliseconds / 1000} 秒'),
          _DetailPathRow('输入路径', item.inputPath, revealInput),
          _DetailPathRow('输出路径', item.outputPath, revealOutput),
        ],
      ),
    );
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
      child: Text(label,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w600)),
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
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
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
              Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const Spacer(),
              InkWell(
                onTap: onReveal,
                child: const Icon(Icons.open_in_new, size: 14),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(path,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
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
    widget.config.skipExisting = _cfg.skipExisting;
    widget.config.maxConcurrentJobs = _cfg.maxConcurrentJobs;
    widget.config.fileNameSuffix = _cfg.fileNameSuffix;
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

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        .map((f) => ButtonSegment<Family>(
                            value: f, label: Text(f.appTitle)))
                        .toList(),
                    selected: {_cfg.family},
                    onSelectionChanged: (v) {
                      setState(() => _cfg.family = v.first);
                      _emit();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text('Auto 自动检测 X6/X7 设备族。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 20),

                  // OPPO compat
                  Text('OPPO 兼容模式', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SegmentedButton<OppoCompatMode>(
                    segments: OppoCompatMode.values
                        .map((m) => ButtonSegment<OppoCompatMode>(
                            value: m, label: Text(m.appTitle)))
                        .toList(),
                    selected: {_cfg.oppoCompatibility},
                    onSelectionChanged: (v) {
                      setState(() => _cfg.oppoCompatibility = v.first);
                      _emit();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(_cfg.oppoCompatibility.appHelp,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 20),

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
                      Text('${_cfg.maxConcurrentJobs}',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontFamily: 'monospace')),
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
                    controller: TextEditingController(text: _cfg.fileNameSuffix),
                    onChanged: (v) {
                      _cfg.fileNameSuffix = v.isEmpty ? '_iso' : v;
                      _emit();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text('设置输出目录后，后缀将被忽略。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),

                  // Output directory
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
