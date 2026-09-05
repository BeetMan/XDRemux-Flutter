import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/app_models.dart';
import 'services/file_action_service.dart';
import 'services/xdremux_service.dart';
import 'l10n/l10n.dart';

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
  String _status = t('选择一张或多张 OPPO 后置人像照片。', 'Choose one or more OPPO rear portrait photos.');

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
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
      // ignore: deprecated_member_use - multi-select still requires this flag
      allowMultiple: true,
    );
    if (!mounted) return;
    final paths = files
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
      _status = t('已选择 ${paths.length} 张照片。', 'Selected ${paths.length} photos.');
    });
  }

  Future<void> _pickOutputDirectory() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null || !mounted) return;
    setState(() {
      _outputDirectory = directory;
      _manifest = null;
      _status = t('输出目录已选择。', 'Output directory selected.');
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
            ? t('当前 macOS 未通过 Apple 人像模式研究能力验证。', 'Current macOS did not pass the Apple Portrait research capability check.')
            : _capabilities.swiftAppleFeaturesUnavailableReason,
      );
      return;
    }
    final outputDirectory = _outputDirectory ?? _defaultOutputDirectory();
    setState(() {
      _running = true;
      _status = t('正在生成 Apple 人像模式研究输出…', 'Generating Apple Portrait research output…');
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
        _status = t('研究输出完成：$completed/${samples.length} 张样本。', 'Research output complete: $completed/${samples.length} samples.');
      });
    } catch (error) {
      _showError(t('Apple 人像模式研究失败：$error', 'Apple Portrait research failed: $error'));
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
      _showError(t('无法打开路径：$path', 'Cannot open path: $path'));
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
      t(
        '样本：${samples.where((sample) => sample['success'] == true).length}/${samples.length}',
        'Samples: ${samples.where((sample) => sample['success'] == true).length}/${samples.length}',
      ),
      t('validator：$passed/${outputs.length} 通过', 'validator: $passed/${outputs.length} passed'),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = Platform.isMacOS || Platform.isIOS;
    final outputs = _outputs();
    return Scaffold(
      appBar: AppBar(title: Text(t('Apple 人像模式实验室', 'Apple Portrait Lab'))),
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
                      Expanded(
                        child: Text(
                          t(
                            '实验性独立模块：只生成 Apple 人像模式文件，不做 OPPO 回传、水印写回或 OPPO/Apple 双模式转换。请使用 Apple 相册验证人像编辑行为。',
                            'Experimental standalone module: it only generates Apple Portrait files — no OPPO round-trip, watermark writeback, or OPPO/Apple dual-mode conversion. Use Apple Photos to validate portrait editing behavior.',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    supported
                        ? (_capabilities.swiftPortraitResearch
                              ? '${Platform.isIOS ? 'iOS' : 'macOS'} research capability: ${t('可用', 'available')}'
                              : '${Platform.isIOS ? 'iOS' : 'macOS'} research capability: ${t('不可用', 'unavailable')}')
                        : t('Apple 人像模式研究当前只支持 macOS/iOS。', 'Apple Portrait research currently only supports macOS/iOS.'),
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
                  Text(t('1. 输入样本', '1. Input samples'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _inputPaths.isEmpty
                        ? t('尚未选择照片。', 'No photos selected yet.')
                        : _inputPaths.map(_fileName).join('\n'),
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _running ? null : _pickPhotos,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(t('选择 OPPO 人像照片', 'Choose OPPO portrait photos')),
                  ),
                  const SizedBox(height: 20),
                  Text(t('2. 输出目录', '2. Output directory'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _outputDirectory ??
                        (_inputPaths.isEmpty
                            ? Platform.isIOS
                                  ? t('未选择（运行时使用 App 文档目录下的 xdremux-portrait-research）', 'Not set (uses xdremux-portrait-research under the app Documents directory at runtime)')
                                  : t('未选择（运行时使用输入目录下的 xdremux-portrait-research）', 'Not set (uses xdremux-portrait-research under the input directory at runtime)')
                            : _defaultOutputDirectory()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  if (!Platform.isIOS)
                    OutlinedButton.icon(
                      onPressed: _running ? null : _pickOutputDirectory,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(t('选择输出目录', 'Choose output directory')),
                    ),
                  const SizedBox(height: 20),
                  Text(t('3. 研究候选', '3. Research candidates'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(t('每张输入生成：p20、p50、p80、uniform-0.005。', 'Each input generates: p20, p50, p80, uniform-0.005.')),
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
                    label: Text(
                      _running
                          ? t('处理中…', 'Processing…')
                          : t('生成 Apple 人像模式输出', 'Generate Apple Portrait output'),
                    ),
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
                        Text(t('研究输出', 'Research output'), style: theme.textTheme.titleMedium),
                        const Spacer(),
                        if (_outputDirectory != null)
                          IconButton(
                            tooltip: t('打开输出目录', 'Open output directory'),
                            icon: const Icon(Icons.folder_open_outlined),
                            onPressed: () =>
                                _openPath(_outputDirectory!, reveal: false),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t(
                        '输出已通过 Apple 人像模式验证；这不等同于正式稳定能力。',
                        'Output passed Apple Portrait validation; this is not equivalent to a stable, officially supported capability.',
                      ),
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
        path == null
            ? (output['error']?.toString() ?? t('无输出', 'No output'))
            : _fileName(path),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: path == null || !success
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: t('在默认应用中打开', 'Open in default app'),
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => _openPath(path),
                ),
                IconButton(
                  tooltip: t('分享', 'Share'),
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => FileActionService.shareFile(path),
                ),
              ],
            ),
    );
  }
}
