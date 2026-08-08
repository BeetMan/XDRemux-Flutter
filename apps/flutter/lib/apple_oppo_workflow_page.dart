import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/app_models.dart';
import 'services/apple_oppo_workflow_service.dart';
import 'services/file_action_service.dart';
import 'services/xdremux_service.dart';

/// Dedicated five-stage Apple/OPPO round-trip workflow.
///
/// This page deliberately does not add items to the normal conversion queue:
/// the baseline donor and the returned iPhone photo must stay paired.
class AppleOppoWorkflowPage extends StatefulWidget {
  const AppleOppoWorkflowPage({super.key});

  @override
  State<AppleOppoWorkflowPage> createState() => _AppleOppoWorkflowPageState();
}

class _AppleOppoWorkflowPageState extends State<AppleOppoWorkflowPage> {
  String? _sourcePath;
  String? _baselinePath;
  String? _appleEditPath;
  String? _returnedPath;
  String? _finalPath;
  bool _sourceIsBaseline = false;
  BackendCapabilities _capabilities = BackendCapabilities.forCurrentPlatform();
  AppleWatermarkPolicy _watermarkPolicy = AppleWatermarkPolicy.preserve;
  OutputMode _outputMode = Platform.isIOS ? OutputMode.apple : OutputMode.oppo;
  bool _restoreWatermark = true;
  bool _running = false;
  String _status = '请先选择原始 OPPO 照片或已有 baseline。';

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    final capabilities = await XdRemuxService.getBackendCapabilities();
    if (!mounted) return;
    setState(() => _capabilities = capabilities);
  }

  Future<String?> _pickPhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.path != null && file.path!.isNotEmpty) {
      final candidate = File(file.path!);
      if (await candidate.exists() && await candidate.length() > 0) {
        return candidate.path;
      }
    }
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}${Platform.pathSeparator}workflow');
    await dir.create(recursive: true);
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path =
        '${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$safeName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _selectSource() async {
    final path = await _pickPhoto();
    if (path == null || !mounted) return;
    setState(() {
      _sourcePath = path;
      _sourceIsBaseline = false;
      _baselinePath = null;
      _appleEditPath = null;
      _returnedPath = null;
      _finalPath = null;
      _status = '已选择 ${_fileLabel(path)}。可以生成或复用 baseline。';
    });
  }

  Future<String> _workflowDirectory(String sourcePath) async {
    if (Platform.isMacOS) {
      return File(sourcePath).parent.path;
    }
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}xdremux_workflow',
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  String _stem(String path) {
    final name = File(path).uri.pathSegments.last;
    return name.replaceFirst(
      RegExp(r'\.(heic|heif)$', caseSensitive: false),
      '',
    );
  }

  Future<void> _prepareBaseline() async {
    final source = _sourcePath;
    if (source == null || _running) return;
    setState(() {
      _running = true;
      _status = '正在检查 baseline…';
      _finalPath = null;
    });
    try {
      final directory = await _workflowDirectory(source);
      final baseline =
          '$directory${Platform.pathSeparator}${_stem(source)}.oppo-baseline.heic';
      final selected = await AppleOppoWorkflowService.ensureBaseline(
        sourcePath: source,
        baselinePath: baseline,
        sourceIsBaseline: _sourceIsBaseline,
        onStatus: _setStatus,
      );
      if (!mounted) return;
      setState(() {
        _baselinePath = selected;
        _appleEditPath = null;
        _returnedPath = null;
        _status = 'baseline 已就绪：${_fileLabel(selected)}';
      });
    } catch (error) {
      _showError('baseline 失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _createAppleEditCopy() async {
    final baseline = _baselinePath;
    if (baseline == null || _running) return;
    if (!_capabilities.swiftPhotographicStyles) {
      _showError(
        _capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
            ? '当前设备未通过 Apple Photographic Styles capability 验证。'
            : _capabilities.swiftAppleFeaturesUnavailableReason,
      );
      return;
    }
    setState(() {
      _running = true;
      _status = '正在准备 Apple 编辑副本…';
      _returnedPath = null;
      _finalPath = null;
    });
    try {
      final directory = await _workflowDirectory(baseline);
      final suffix = _watermarkPolicy == AppleWatermarkPolicy.isolate
          ? '.apple-edit-isolated.heic'
          : '.apple-edit.heic';
      final output =
          '$directory${Platform.pathSeparator}${_stem(baseline)}$suffix';
      final result = await AppleOppoWorkflowService.createAppleStylesCopy(
        baselinePath: baseline,
        outputPath: output,
        watermarkPolicy: _watermarkPolicy,
        onStatus: _setStatus,
      );
      if (!mounted) return;
      setState(() {
        _appleEditPath = result;
        _status = 'Apple 编辑副本已生成：${_fileLabel(result)}';
      });
    } catch (error) {
      _showError('Apple Styles 失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _selectReturnedPhoto() async {
    final path = await _pickPhoto();
    if (path == null || !mounted) return;
    setState(() {
      _returnedPath = path;
      _finalPath = null;
      _status = '已选择 iPhone 回传照片：${_fileLabel(path)}';
    });
  }

  Future<void> _writeback() async {
    final returned = _returnedPath;
    final baseline = _baselinePath;
    if (returned == null || _running) return;
    if (_outputMode == OutputMode.oppo && baseline == null) {
      _showError('OPPO 输出必须保留 baseline donor。');
      return;
    }
    if (_restoreWatermark &&
        baseline == null &&
        !(Platform.isIOS && _outputMode == OutputMode.apple)) {
      _showError('需要写回正常水印时必须保留 baseline donor。');
      return;
    }
    if (!Platform.isMacOS &&
        !(Platform.isIOS && _outputMode == OutputMode.apple)) {
      _showError('回传照片写回目前只在 macOS 上验证。');
      return;
    }
    setState(() {
      _running = true;
      _status = '正在生成最终 ${_outputMode.appTitle} 输出…';
    });
    try {
      final directory = await _workflowDirectory(returned);
      final output =
          '$directory${Platform.pathSeparator}${_stem(returned)}.${_outputMode.name}-final.heic';
      if (Platform.isIOS && _outputMode == OutputMode.apple) {
        await AppleOppoWorkflowService.preserveAppleReturnedPhoto(
          returnedPath: returned,
          outputPath: output,
          onStatus: _setStatus,
        );
      } else {
        await AppleOppoWorkflowService.writebackReturnedPhoto(
          baselinePath: baseline,
          returnedPath: returned,
          outputPath: output,
          outputMode: _outputMode,
          restoreWatermark: _restoreWatermark,
          onStatus: _setStatus,
        );
      }
      if (!mounted) return;
      setState(() {
        _finalPath = output;
        _status = '最终输出已生成：${_fileLabel(output)}';
      });
    } catch (error) {
      _showError(
        Platform.isIOS && _outputMode == OutputMode.apple
            ? '处理失败：$error'
            : '写回失败：$error',
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _fileLabel(String path) => File(path).uri.pathSegments.last;

  bool get _canWriteback => Platform.isMacOS;

  bool get _canFinalizeApple => Platform.isMacOS || Platform.isIOS;

  String get _outputModeHelp {
    if (Platform.isIOS && _outputMode == OutputMode.apple) {
      return '原样保留 iPhone/Photos 回传文件，不写入 OPPO 私有兼容信息。';
    }
    return _outputMode.appHelp;
  }

  String get _appleCapabilityMessage {
    if (_capabilities.swiftAppleFeaturesUnavailableReason.isNotEmpty) {
      return _capabilities.swiftAppleFeaturesUnavailableReason;
    }
    return Platform.isIOS
        ? 'iOS 当前只验证 Rust baseline；Apple Styles 仍等待嵌入式 Swift Library。'
        : '当前设备未通过 Apple Styles capability 验证。';
  }

  Widget _stepCard({
    required BuildContext context,
    required int step,
    required String title,
    required String description,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(radius: 16, child: Text('$step')),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(description, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  Widget _pathText(String? path, {String empty = '尚未选择'}) {
    return Text(
      path == null ? empty : '${_fileLabel(path)}\n$path',
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canUseApple = _capabilities.swiftPhotographicStyles;
    final sharePath = _appleEditPath ?? _baselinePath;
    final sharingAppleEdit = _appleEditPath != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OPPO ↔ Apple 工作流'),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                Platform.isIOS
                    ? '这是独立的五阶段流程。当前 iOS 已开放 Rust baseline 生成、文件选择和分享；Apple Styles、回传写回与最终双模式输出仍保持 capability gating，尚未宣称可用。'
                    : '这是独立的五阶段流程。baseline 与 iPhone 回传照片会保持配对，普通“批量转换”队列不会参与此流程。Apple 功能仍属于 experimental。',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 1,
            title: '生成或复用 OPPO baseline',
            description: '选择原始 OPPO 照片，或直接选择已经生成的 OPPO-compatible 文件。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _pathText(_sourcePath),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('选择的文件已经是 OPPO baseline'),
                  subtitle: const Text('开启后会先验证并直接复用，不再重复生成。'),
                  value: _sourceIsBaseline,
                  onChanged: _running
                      ? null
                      : (value) => setState(() {
                          _sourceIsBaseline = value;
                          _baselinePath = null;
                          _appleEditPath = null;
                        }),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _running ? null : _selectSource,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('选择照片'),
                    ),
                    FilledButton.icon(
                      onPressed: _sourcePath == null || _running
                          ? null
                          : _prepareBaseline,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('生成 / 复用 baseline'),
                    ),
                  ],
                ),
                if (_baselinePath != null) ...[
                  const SizedBox(height: 12),
                  Text('baseline', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _pathText(_baselinePath),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 2,
            title: '生成 Apple Photographic Styles 编辑副本',
            description: Platform.isIOS
                ? 'iOS 当前不生成 Apple Styles 副本；上游实现尚未作为嵌入式 Swift Library 接入。'
                : '只对 baseline 执行 Apple Styles，生成交给 iPhone 的工作文件。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<AppleWatermarkPolicy>(
                  segments: AppleWatermarkPolicy.values
                      .map(
                        (policy) => ButtonSegment<AppleWatermarkPolicy>(
                          value: policy,
                          label: Text(policy.appTitle),
                        ),
                      )
                      .toList(),
                  selected: {_watermarkPolicy},
                  onSelectionChanged: _running || !canUseApple
                      ? null
                      : (value) {
                          setState(() {
                            _watermarkPolicy = value.first;
                            _appleEditPath = null;
                          });
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  _watermarkPolicy.appHelp,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _baselinePath == null || !canUseApple || _running
                      ? null
                      : _createAppleEditCopy,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('生成 Apple 编辑副本'),
                ),
                if (!canUseApple) ...[
                  const SizedBox(height: 8),
                  Text(
                    _appleCapabilityMessage,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_appleEditPath != null) ...[
                  const SizedBox(height: 12),
                  Text('iPhone 编辑副本', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _pathText(_appleEditPath),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 3,
            title: '在 iPhone 上编辑',
            description: Platform.isIOS
                ? '可以先把 Rust baseline 分享到 Photos/文件；Apple Styles 编辑副本接入后再启用完整回传链。'
                : '把上一步生成的文件传到 iPhone，在 Photos 中完成自己的调整并导出/回传。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: sharePath == null || _running
                      ? null
                      : () => FileActionService.shareFile(sharePath),
                  icon: const Icon(Icons.ios_share),
                  label: Text(
                    sharingAppleEdit ? '分享 Apple 编辑副本' : '分享 Rust baseline',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _running ? null : _selectReturnedPhoto,
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('选择 iPhone 回传照片'),
                ),
                if (_returnedPath != null) ...[
                  const SizedBox(height: 10),
                  _pathText(_returnedPath),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 4,
            title: Platform.isIOS ? '回传照片写回（待接入）' : '写回正常水印',
            description: Platform.isIOS
                ? 'iOS 当前不执行写回；避免在未验证的设备路径上伪造 OPPO 水印或 footer。'
                : '使用 baseline donor 处理回传照片；目前 macOS 已验证。',
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('按 baseline 写回正常水印'),
              subtitle: Text(
                Platform.isIOS
                    ? 'iOS 先完成 Swift/回写 Library 的真机验证后再开放。'
                    : '关闭后保留 iPhone 回传画面，但 OPPO 模式仍会恢复兼容 footer。',
              ),
              value: _restoreWatermark,
              onChanged: _running || !_canWriteback
                  ? null
                  : (value) => setState(() => _restoreWatermark = value),
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 5,
            title: '选择最终输出模式',
            description: Platform.isIOS
                ? 'iOS 的 Apple 模式只保留回传文件并做 ImageIO 可读性检查；OPPO 模式仍需要 macOS 写回。'
                : 'OPPO 模式恢复 OPPO 兼容结构；Apple 模式保留 Apple 结果且不写入 OPPO 私有 footer。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<OutputMode>(
                  segments: OutputMode.values
                      .map(
                        (mode) => ButtonSegment<OutputMode>(
                          value: mode,
                          label: Text(mode.appTitle),
                          enabled: Platform.isMacOS || mode == OutputMode.apple,
                        ),
                      )
                      .toList(),
                  selected: {_outputMode},
                  onSelectionChanged: _running || !_canFinalizeApple
                      ? null
                      : (value) => setState(() {
                          _outputMode = value.first;
                          _finalPath = null;
                        }),
                ),
                const SizedBox(height: 8),
                Text(_outputModeHelp, style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed:
                      _returnedPath == null ||
                          _running ||
                          (!_canWriteback &&
                              !(_canFinalizeApple &&
                                  _outputMode == OutputMode.apple))
                      ? null
                      : _writeback,
                  icon: _running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.output),
                  label: Text(_running ? '处理中…' : '生成最终输出'),
                ),
                if (!_canWriteback) ...[
                  const SizedBox(height: 8),
                  Text(
                    'iOS 当前可保留 Apple 回传文件并分享；OPPO 水印写回和 OPPO 最终输出暂只在 macOS 开放。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_finalPath != null) ...[
                  const SizedBox(height: 12),
                  Text('最终文件', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _pathText(_finalPath),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => FileActionService.shareFile(_finalPath!),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('分享最终文件'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _status,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
