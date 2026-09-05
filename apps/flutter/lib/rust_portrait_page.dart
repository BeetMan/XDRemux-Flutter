import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models/app_models.dart';
import 'services/conversion_backend.dart';
import 'services/file_action_service.dart';
import 'services/xdremux_service.dart';
import 'l10n/l10n.dart';

/// Portable Rust Apple Portrait workflow for Windows/Android and other
/// platforms where Apple-native research APIs are unavailable.
class RustPortraitPage extends StatefulWidget {
  const RustPortraitPage({super.key});

  @override
  State<RustPortraitPage> createState() => _RustPortraitPageState();
}

class _RustPortraitResult {
  final String input;
  final String? output;
  final Map<String, dynamic> diagnosis;
  final bool success;
  final String? error;

  const _RustPortraitResult({
    required this.input,
    required this.output,
    required this.diagnosis,
    required this.success,
    this.error,
  });
}

class _RustPortraitPageState extends State<RustPortraitPage> {
  final List<String> _inputs = <String>[];
  final List<_RustPortraitResult> _results = <_RustPortraitResult>[];
  String? _outputDirectory;
  bool _running = false;
  String _status = t('选择包含 rear.depth 的 OPPO 后置人像照片。', 'Choose OPPO rear portrait photos that include rear.depth.');

  Future<void> _pickPhotos() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
      // ignore: deprecated_member_use - multi-select still requires this flag
      allowMultiple: true,
    );
    if (!mounted) return;
    final paths = result
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList();
    if (paths.isEmpty) return;
    setState(() {
      _inputs
        ..clear()
        ..addAll(paths);
      _results.clear();
      _status = t('已选择 ${paths.length} 张照片。', 'Selected ${paths.length} photos.');
    });
  }

  Future<void> _pickOutputDirectory() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null || !mounted) return;
    setState(() {
      _outputDirectory = directory;
      _results.clear();
      _status = t('输出目录已选择。', 'Output directory selected.');
    });
  }

  String _fileName(String path) => File(path).uri.pathSegments.last;

  String _stem(String path) => _fileName(
    path,
  ).replaceFirst(RegExp(r'\.(heic|heif)$', caseSensitive: false), '');

  String _defaultOutputDirectory() =>
      '${File(_inputs.first).parent.path}${Platform.pathSeparator}xdremux-portrait';

  bool _hasRearDepth(Map<String, dynamic> report) {
    final resources = report['resources'];
    return report['available'] == true &&
        resources is List &&
        resources.any((resource) => resource.toString() == 'rear.depth');
  }

  String _diagnosisSummary(Map<String, dynamic> report) {
    if (report['available'] != true) {
      return report['classification']?.toString() ?? t('诊断不可用', 'Diagnosis unavailable');
    }
    final classification = report['classification'] ?? 'available';
    final calibration = report['calibration'];
    final decision = calibration is Map ? calibration['decision'] : null;
    final mode = decision is Map ? decision['mode'] : null;
    return mode == null ? classification.toString() : '$classification / $mode';
  }

  Future<void> _run() async {
    if (_running || _inputs.isEmpty) return;
    final directory = _outputDirectory ?? _defaultOutputDirectory();
    setState(() {
      _running = true;
      _results.clear();
      _status = t('正在诊断并生成 Rust 人像输出…', 'Diagnosing and generating Rust portrait output…');
    });
    try {
      await Directory(directory).create(recursive: true);
      for (final input in _inputs) {
        if (!mounted) return;
        final diagnosis = await XdRemuxService.diagnosePortrait(input);
        if (!_hasRearDepth(diagnosis)) {
          _results.add(
            _RustPortraitResult(
              input: input,
              output: null,
              diagnosis: diagnosis,
              success: false,
              error: t('缺少可用 rear.depth，人像转换已跳过。', 'No usable rear.depth; portrait conversion skipped.'),
            ),
          );
          setState(() {});
          continue;
        }
        final output =
            '$directory${Platform.pathSeparator}${_stem(input)}_portrait.heic';
        try {
          final result = await XdRemuxService.convertWithBackend(
            ConversionRequest(
              id: 'rust-portrait-${DateTime.now().microsecondsSinceEpoch}',
              backend: ConversionBackend.rust,
              outputMode: OutputMode.apple,
              inputPath: input,
              outputPath: output,
              oppoCompat: OppoCompatMode.off.rustValue,
              oppoCameraTail: OppoCameraTailMode.off.rustValue,
              strictTmap: false,
              applePortrait: true,
            ),
          );
          _results.add(
            _RustPortraitResult(
              input: input,
              output: result.success ? output : null,
              diagnosis: diagnosis,
              success: result.success && result.outputValid == true,
              error: result.errorMessage,
            ),
          );
        } catch (error) {
          _results.add(
            _RustPortraitResult(
              input: input,
              output: null,
              diagnosis: diagnosis,
              success: false,
              error: error.toString(),
            ),
          );
        }
        setState(() {});
      }
      final passed = _results.where((result) => result.success).length;
      if (mounted) {
        setState(() {
          _outputDirectory = directory;
          _status = t(
            '完成：$passed/${_results.length} 张通过 Rust 人像结构验证。',
            'Done: $passed/${_results.length} photos passed Rust portrait structure validation.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _openDirectory() async {
    final directory = _outputDirectory;
    if (directory == null) return;
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [directory]);
    } else {
      await FileActionService.openFile(directory);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('Rust 人像模式实验室', 'Rust Portrait Lab'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                t(
                  '这是跨平台 Rust 实验室：负责 rear.depth 诊断、可编辑人像图生成和结构验证。Windows 查看器不会直接显示 Apple 景深虚化，请将输出交给 Apple Photos 验证。',
                  'This is a cross-platform Rust lab for rear.depth diagnosis, editable portrait graph generation, and structural validation. Windows viewers do not render Apple bokeh; hand the output to Apple Photos for verification.',
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('1. 输入样本', '1. Input samples'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _inputs.isEmpty
                        ? t('尚未选择照片。', 'No photos selected yet.')
                        : _inputs.map(_fileName).join('\n'),
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _running ? null : _pickPhotos,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(t('选择 OPPO 人像照片', 'Choose OPPO portrait photos')),
                  ),
                  const SizedBox(height: 18),
                  Text(t('2. 输出目录', '2. Output directory'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _outputDirectory ??
                        (_inputs.isEmpty
                            ? t('默认使用输入文件所在目录。', 'Defaults to the input file directory.')
                            : _defaultOutputDirectory()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _running ? null : _pickOutputDirectory,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(t('选择输出目录', 'Choose output directory')),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _running || _inputs.isEmpty ? null : _run,
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
                          : t('诊断并生成 Rust 人像输出', 'Diagnose & generate Rust portrait output'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(_status, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(t('诊断结果', 'Diagnosis results'), style: theme.textTheme.titleMedium),
                        const Spacer(),
                        if (_outputDirectory != null)
                          IconButton(
                            tooltip: t('打开输出目录', 'Open output directory'),
                            onPressed: _openDirectory,
                            icon: const Icon(Icons.folder_open_outlined),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final result in _results) _resultTile(result),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultTile(_RustPortraitResult result) {
    final color = result.success
        ? Colors.green
        : Theme.of(context).colorScheme.error;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        result.success ? Icons.check_circle_outline : Icons.error_outline,
        color: color,
      ),
      title: Text(_fileName(result.input)),
      subtitle: Text(
        result.success
            ? '${_diagnosisSummary(result.diagnosis)}\n${_fileName(result.output!)}'
            : '${_diagnosisSummary(result.diagnosis)}\n${result.error ?? t('未生成输出', 'No output generated')}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: result.output == null
          ? null
          : IconButton(
              tooltip: t('打开输出', 'Open output'),
              icon: const Icon(Icons.open_in_new),
              onPressed: () => FileActionService.openFile(result.output!),
            ),
    );
  }
}
