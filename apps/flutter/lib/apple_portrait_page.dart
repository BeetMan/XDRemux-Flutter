import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/app_models.dart';
import 'services/file_action_service.dart';
import 'services/xdremux_service.dart';

/// Standalone Apple Portrait research module.
///
/// This page intentionally has no OPPO/Apple output switch, donor pairing,
/// watermark writeback, or returned-photo step. Its only job is to generate
/// experimental Apple Portrait candidates for Photos validation.
class ApplePortraitPage extends StatefulWidget {
  const ApplePortraitPage({super.key});

  @override
  State<ApplePortraitPage> createState() => _ApplePortraitPageState();
}

class _ApplePortraitPageState extends State<ApplePortraitPage> {
  static const _variants = <String>['p20', 'p50', 'p80', 'uniform:0.005'];

  final List<String> _inputPaths = <String>[];
  BackendCapabilities _capabilities = BackendCapabilities.forCurrentPlatform();
  String? _outputDirectory;
  Map<String, dynamic>? _manifest;
  bool _running = false;
  String _documentsDir = '';
  String _status = '选择一张或多张 OPPO 后置人像照片。';

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
    if (Platform.isIOS) {
      getApplicationDocumentsDirectory().then((directory) {
        if (mounted) setState(() => _documentsDir = directory.path);
      });
    }
  }

  Future<void> _loadCapabilities() async {
    final capabilities = await XdRemuxService.getBackendCapabilities();
    if (!mounted) return;
    setState(() => _capabilities = capabilities);
  }

  Future<void> _pickPhotos() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
      allowMultiple: true,
    );
    if (result == null || !mounted) return;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList();
    if (paths.isEmpty) return;
    setState(() {
      _inputPaths
        ..clear()
        ..addAll(paths);
      _manifest = null;
      _status = '已选择 ${paths.length} 张照片。';
    });
  }

  Future<void> _pickOutputDirectory() async {
    final directory = await FilePicker.platform.getDirectoryPath();
    if (directory == null || !mounted) return;
    setState(() {
      _outputDirectory = directory;
      _manifest = null;
      _status = '输出目录已选择。';
    });
  }

  String _defaultOutputDirectory() {
    if (Platform.isIOS) {
      // 输入在选择器 tmp 缓存里，写完即失；研究输出放进 app Documents，
      // Files App「我的 iPhone -> XDRemux」可见，方便存相册做 Photos 验收。
      return '$_documentsDir/xdremux-portrait-research';
    }
    final parent = File(_inputPaths.first).parent.path;
    return '$parent${Platform.pathSeparator}xdremux-portrait-research';
  }

  Future<void> _runResearch() async {
    if (_running || _inputPaths.isEmpty) return;
    if (!_capabilities.swiftPortraitResearch) {
      _showError(
        _capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
            ? '当前 macOS 未通过 Portrait research capability 验证。'
            : _capabilities.swiftAppleFeaturesUnavailableReason,
      );
      return;
    }
    final outputDirectory = _outputDirectory ?? _defaultOutputDirectory();
    setState(() {
      _running = true;
      _status = '正在生成 Apple Portrait 研究输出…';
      _manifest = null;
    });
    try {
      await Directory(outputDirectory).create(recursive: true);
      final manifest = await XdRemuxService.researchPortrait(
        inputPaths: _inputPaths,
        outputDirectory: outputDirectory,
        variants: _variants,
      );
      if (!mounted) return;
      final samples = _asMapList(manifest['samples']);
      final completed = samples
          .where((sample) => sample['success'] == true)
          .length;
      setState(() {
        _outputDirectory = outputDirectory;
        _manifest = manifest;
        _status = '研究输出完成：$completed/${samples.length} 张样本。';
      });
    } catch (error) {
      _showError('Portrait research 失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is! List) return <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((map) => map.map((key, value) => MapEntry(key.toString(), value)))
        .toList();
  }

  List<Map<String, dynamic>> _outputs() {
    final outputs = <Map<String, dynamic>>[];
    for (final sample in _asMapList(_manifest?['samples'])) {
      outputs.addAll(_asMapList(sample['outputs']));
    }
    return outputs;
  }

  String _fileName(String path) => File(path).uri.pathSegments.last;

  Future<void> _openPath(String path, {bool reveal = false}) async {
    if (Platform.isIOS) {
      // iOS 没有 Finder；用系统分享面板，用户可存储到「照片」做
      // Apple Photos 导入/编辑/保存/退出/重开验收。
      await FileActionService.shareFile(path);
      return;
    }
    if (!Platform.isMacOS) return;
    final result = await Process.run('open', reveal ? ['-R', path] : [path]);
    if (result.exitCode != 0 && mounted) {
      _showError('无法打开路径：$path');
    }
  }

  String _manifestSummary() {
    final manifest = _manifest;
    if (manifest == null) return '';
    final samples = _asMapList(manifest['samples']);
    final outputs = _outputs();
    final passed = outputs.where((output) => output['valid'] == true).length;
    return [
      'schema：${manifest['schema'] ?? 'unknown'}',
      '样本：${samples.where((sample) => sample['success'] == true).length}/${samples.length}',
      'validator：$passed/${outputs.length} 通过',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = Platform.isMacOS || Platform.isIOS;
    final outputs = _outputs();
    return Scaffold(
      appBar: AppBar(title: const Text('Apple Portrait 实验室')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '实验性独立模块：只生成 Apple Portrait 文件，不做 OPPO 回传、水印写回或 OPPO/Apple 双模式转换。请使用 Apple 相册验证景深编辑行为。',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    supported
                        ? (_capabilities.swiftPortraitResearch
                              ? '${Platform.isIOS ? 'iOS' : 'macOS'} research capability：可用'
                              : '${Platform.isIOS ? 'iOS' : 'macOS'} research capability：不可用')
                        : 'Apple Portrait research 当前只支持 macOS/iOS。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!_capabilities.swiftPortraitResearch && supported)
                    Text(
                      _capabilities.swiftAppleFeaturesUnavailableReason,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1. 输入样本', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _inputPaths.isEmpty
                        ? '尚未选择照片。'
                        : _inputPaths.map(_fileName).join('\n'),
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _running ? null : _pickPhotos,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('选择 OPPO 人像照片'),
                  ),
                  const SizedBox(height: 20),
                  Text('2. 输出目录', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _outputDirectory ??
                        (_inputPaths.isEmpty
                            ? Platform.isIOS
                                  ? '未选择（运行时使用 App 文档目录下的 xdremux-portrait-research）'
                                  : '未选择（运行时使用输入目录下的 xdremux-portrait-research）'
                            : _defaultOutputDirectory()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  if (!Platform.isIOS)
                    OutlinedButton.icon(
                      onPressed: _running ? null : _pickOutputDirectory,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('选择输出目录'),
                    ),
                  const SizedBox(height: 20),
                  Text('3. 研究候选', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('每张输入生成：p20、p50、p80、uniform-0.005。'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _running || _inputPaths.isEmpty || !supported
                        ? null
                        : _runResearch,
                    icon: _running
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_running ? '处理中…' : '生成 Apple Portrait 输出'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (outputs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('研究输出', style: theme.textTheme.titleMedium),
                        const Spacer(),
                        if (_outputDirectory != null)
                          IconButton(
                            tooltip: '打开输出目录',
                            icon: const Icon(Icons.folder_open_outlined),
                            onPressed: () =>
                                _openPath(_outputDirectory!, reveal: false),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '输出已通过 native Apple Portrait validator；这不等同于正式稳定能力。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _manifestSummary(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final output in outputs) _outputTile(output),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _outputTile(Map<String, dynamic> output) {
    final path = output['output'] as String?;
    final success = output['success'] == true;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        success ? Icons.check_circle_outline : Icons.error_outline,
        color: success ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: Text(output['variant']?.toString() ?? 'variant'),
      subtitle: Text(
        path == null ? (output['error']?.toString() ?? '无输出') : _fileName(path),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: path == null || !success
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '在默认应用中打开',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => _openPath(path),
                ),
                IconButton(
                  tooltip: '分享',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => FileActionService.shareFile(path),
                ),
              ],
            ),
    );
  }
}
