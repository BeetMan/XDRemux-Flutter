import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/app_models.dart';
import 'services/apple_oppo_workflow_service.dart';
import 'services/file_action_service.dart';
import 'services/drop_file_service.dart';
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
  ConversionBackend _stylesBackend = ConversionBackend.rust;
  OutputMode _outputMode = Platform.isIOS ? OutputMode.apple : OutputMode.oppo;
  bool _restoreWatermark = true;
  bool _running = false;
  StreamSubscription<List<String>>? _dropSubscription;
  String _status = '请先选择 OPPO 手机原图或已有 OPPO 兼容文件。';

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      DropFileService.workflowActive = true;
      _dropSubscription = DropFileService.files.listen(_handleDroppedFiles);
    }
    _loadCapabilities();
  }

  @override
  void dispose() {
    DropFileService.workflowActive = false;
    _dropSubscription?.cancel();
    super.dispose();
  }

  void _handleDroppedFiles(List<String> paths) {
    final candidates = paths.where((path) {
      final lower = path.toLowerCase();
      return lower.endsWith('.heic') || lower.endsWith('.heif');
    }).toList();
    if (candidates.isEmpty || !mounted) return;
    setState(() {
      _returnedPath = candidates.first;
      _finalPath = null;
      _status = '已拖入 iPhone 回传照片：${_fileLabel(candidates.first)}';
    });
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
      _status = '已选择 ${_fileLabel(path)}。可以生成或复用 OPPO 兼容文件。';
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
      _status = '正在检查 OPPO 兼容文件…';
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
        _status = 'OPPO 兼容文件已就绪：${_fileLabel(selected)}';
      });
    } catch (error) {
      _showError('OPPO 兼容文件生成失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _createAppleEditCopy() async {
    final baseline = _baselinePath;
    if (baseline == null || _running) return;
    final backendAvailable =
        _stylesBackend == ConversionBackend.rust ||
        _capabilities.swiftPhotographicStyles;
    if (!backendAvailable) {
      _showError(
        _capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
            ? '当前设备未通过 Swift Apple 相册摄影风格能力验证。'
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
        backend: _stylesBackend,
        watermarkPolicy: _watermarkPolicy,
        onStatus: _setStatus,
      );
      if (!mounted) return;
      setState(() {
        _appleEditPath = result;
        _status = 'Apple 编辑副本已生成：${_fileLabel(result)}';
      });
    } catch (error) {
      _showError('Apple 相册摄影风格失败：$error');
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
      _showError('OPPO 兼容输出必须保留 OPPO 手机原图。');
      return;
    }
    if (_restoreWatermark &&
        baseline == null &&
        !((Platform.isIOS || Platform.isWindows) &&
            _outputMode == OutputMode.apple)) {
      _showError('需要写回正常水印时必须保留 OPPO 手机原图。');
      return;
    }
    if (!Platform.isMacOS &&
        !Platform.isIOS &&
        !Platform.isWindows &&
        !Platform.isAndroid) {
      _showError('当前平台不支持回传照片处理。');
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

  bool get _canWriteback =>
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isAndroid;

  bool get _canFinalizeApple =>
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isAndroid;

  String get _outputModeHelp {
    if ((Platform.isIOS || Platform.isWindows || Platform.isAndroid) &&
        _outputMode == OutputMode.apple) {
      if ((Platform.isWindows || Platform.isAndroid) &&
          _restoreWatermark &&
          _baselinePath != null) {
        return 'Rust 恢复可见 OPPO 水印画布后输出 Apple 文件，不写入 OPPO 私有 footer。';
      }
      return '原样保留 Apple Photos 回传文件，不写入 OPPO 私有兼容信息。';
    }
    if (Platform.isIOS && _outputMode == OutputMode.oppo) {
      return '用 OPPO 手机原图恢复 OPPO 水印画布与完整附加信息；iOS 路径尚未完成真机验证，属于实验性能力。';
    }
    return _outputMode.appHelp;
  }

  String get _appleCapabilityMessage {
    if (_capabilities.swiftAppleFeaturesUnavailableReason.isNotEmpty) {
      return _capabilities.swiftAppleFeaturesUnavailableReason;
    }
    return Platform.isIOS
        ? 'iOS 当前只验证 Rust OPPO 兼容文件；Apple 相册摄影风格仍等待嵌入式 Swift Library。'
        : '当前设备未通过 Apple 相册摄影风格能力验证。';
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
    final canUseSelectedStylesBackend =
        _stylesBackend == ConversionBackend.rust ||
        _capabilities.swiftPhotographicStyles;
    final sharePath = _appleEditPath ?? _baselinePath;
    final sharingAppleEdit = _appleEditPath != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('一帧影像，动用两台手机'),
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
                Platform.isWindows
                    ? '这是独立的文件往返流程。Windows 负责生成 Rust Apple 编辑副本、交换和验证 Apple 回传文件；Rust 使用统一 HEIF 编解码器恢复可见 OPPO 水印画布和 metadata。普通“批量转换”队列不会参与此流程。'
                    : Platform.isAndroid
                    ? '这是独立的文件往返流程。Android 使用 SAF 选择文件，Rust 使用统一 HEIF 编解码器恢复可见水印画布和 OPPO metadata。'
                    : Platform.isIOS
                    ? '这是独立的五阶段流程。当前 iOS 已开放 Rust OPPO 兼容文件生成、文件选择和分享，并提供 Apple 标准与 OPPO 兼容两种最终输出；Apple 相册摄影风格生成仍等待嵌入式 Swift Library，OPPO 写回属于实验性能力。'
                    : '这是独立的五阶段流程。OPPO 手机原图与 iPhone 回传照片会保持配对，普通“批量转换”队列不会参与此流程。Apple 相册功能仍属于实验性能力。',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 1,
            title: '生成或复用 OPPO 兼容文件',
            description: '选择 OPPO 手机原图，或直接选择已经生成的 OPPO 兼容文件。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _pathText(_sourcePath),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('选择的文件已经是 OPPO 兼容文件'),
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
                      label: const Text('生成 / 复用兼容文件'),
                    ),
                  ],
                ),
                if (_baselinePath != null) ...[
                  const SizedBox(height: 12),
                  Text('OPPO 兼容文件', style: theme.textTheme.labelLarge),
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
            title: '生成 Apple 相册摄影风格编辑副本',
            description:
                '选择转换引擎后，只对 OPPO 兼容文件生成 Apple 相册摄影风格编辑副本，作为交给 iPhone 的工作文件。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('转换引擎', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                SegmentedButton<ConversionBackend>(
                  segments: ConversionBackend.values
                      .where((backend) => _capabilities.isVisible(backend))
                      .map(
                        (backend) => ButtonSegment<ConversionBackend>(
                          value: backend,
                          label: Text(backend.appTitle),
                          enabled:
                              backend == ConversionBackend.rust ||
                              _capabilities.swiftPhotographicStyles,
                        ),
                      )
                      .toList(),
                  selected: {_stylesBackend},
                  onSelectionChanged: _running
                      ? null
                      : (value) {
                          setState(() {
                            _stylesBackend = value.first;
                            _appleEditPath = null;
                          });
                        },
                ),
                const SizedBox(height: 12),
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
                  onSelectionChanged: _running || !canUseSelectedStylesBackend
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
                  onPressed:
                      _baselinePath == null ||
                          !canUseSelectedStylesBackend ||
                          _running
                      ? null
                      : _createAppleEditCopy,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('生成 Apple 相册编辑副本'),
                ),
                if (!canUseSelectedStylesBackend) ...[
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
                ? '可以先把 Rust 兼容文件分享至 Apple 相册/文件；Apple 相册摄影风格编辑副本接入后再启用完整回传链。'
                : '把上一步生成的文件传到 iPhone，在 Apple 相册中完成自己的调整并导出/回传。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: sharePath == null || _running
                      ? null
                      : () => FileActionService.shareFile(sharePath),
                  icon: const Icon(Icons.ios_share),
                  label: Text(
                    sharingAppleEdit ? '分享 Apple 相册编辑副本' : '分享 Rust 兼容文件',
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '支持 HEIC / HEIF 照片；macOS 可直接从 Apple 相册拖到此窗口。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 10),
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
            title: '写回正常水印',
            description: Platform.isWindows || Platform.isAndroid
                ? 'Rust 跨平台恢复可见 OPPO 水印画布与 metadata。'
                : Platform.isIOS
                ? '使用 OPPO 手机原图处理回传照片；iOS 路径与 macOS 共用同一套 ImageIO 实现，尚未完成真机验证。'
                : '使用 OPPO 手机原图处理回传照片；目前 macOS 已验证。',
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('按 OPPO 手机原图写回正常水印'),
              subtitle: Text(
                Platform.isWindows || Platform.isAndroid
                    ? 'Rust 会解码、恢复水印画布并重新编码回传 HEIF，同时保留 OPPO metadata。'
                    : '关闭后保留 iPhone 回传画面，但 OPPO 兼容模式仍会恢复附加信息。',
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
                ? 'Apple 标准原样保留回传文件并做 ImageIO 可读性检查；OPPO 兼容模式恢复 OPPO 兼容结构（实验性，待真机验证）。'
                : Platform.isWindows || Platform.isAndroid
                ? 'Rust 恢复 OPPO 兼容 footer、可见水印画布与 metadata；Apple 标准保留 Apple 结果且不写入 OPPO 私有附加信息。'
                : 'OPPO 兼容模式恢复 OPPO 兼容结构；Apple 标准保留 Apple 结果且不写入 OPPO 私有附加信息。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<OutputMode>(
                  segments: OutputMode.values
                      .map(
                        (mode) => ButtonSegment<OutputMode>(
                          value: mode,
                          label: Text(mode.appTitle),
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
                if (Platform.isWindows || Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  Text(
                    '当前平台由 Rust 完成水印画布、OPPO footer 和 metadata 写回；输出仍需在 Apple/OPPO 设备上做最终兼容性确认。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
                if (Platform.isIOS) ...[
                  const SizedBox(height: 8),
                  Text(
                    'iOS 的 OPPO 写回与 macOS 共用同一套 ImageIO/ISOBMFF 实现；尚未在实体 iPhone 上完成端到端验证，输出请先在 OPPO 设备上确认。',
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
