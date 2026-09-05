import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'models/app_models.dart';
import 'services/apple_oppo_workflow_service.dart';
import 'services/file_action_service.dart';
import 'services/drop_file_service.dart';
import 'services/motion_photo_service.dart';
import 'services/picked_file_resolver.dart';
import 'services/xdremux_service.dart';
import 'platform_x.dart';
import 'l10n/l10n.dart';

/// Dedicated Apple/OPPO round-trip workflow.
///
/// This page deliberately does not add items to the normal conversion queue:
/// the selected OPPO photo is both the styles-conversion input and the
/// writeback donor, and must stay paired with the returned iPhone photo.
class AppleOppoWorkflowPage extends StatefulWidget {
  const AppleOppoWorkflowPage({super.key});

  @override
  State<AppleOppoWorkflowPage> createState() => _AppleOppoWorkflowPageState();
}

class _AppleOppoWorkflowPageState extends State<AppleOppoWorkflowPage> {
  String? _sourcePath;
  String? _appleEditPath;
  String? _returnedPath;
  String? _finalPath;
  BackendCapabilities _capabilities = BackendCapabilities.forCurrentPlatform();
  AppleWatermarkPolicy _watermarkPolicy = AppleWatermarkPolicy.preserve;
  ConversionBackend _stylesBackend = ConversionBackend.rust;
  OutputMode _outputMode = Platform.isIOS ? OutputMode.apple : OutputMode.oppo;
  bool _restoreWatermark = true;
  bool _running = false;
  StreamSubscription<List<String>>? _dropSubscription;
  String _status = t('请先选择 OPPO 原始照片。', 'Select the original OPPO photo first.');

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
      _status = t('已拖入 iPhone 回传照片：${_fileLabel(candidates.first)}', 'Dropped iPhone returned photo: ${_fileLabel(candidates.first)}');
    });
  }

  Future<void> _loadCapabilities() async {
    final capabilities = await XdRemuxService.getBackendCapabilities();
    if (!mounted) return;
    setState(() => _capabilities = capabilities);
  }

  Future<String?> _pickPhoto() async {
    // file_picker v12: static pickFile for single selection; bytes load
    // lazily via readAsBytes().
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['heic', 'heif'],
    );
    if (file == null) return null;
    // Resolve via the shared picker resolver so Android prefers the original
    // file on disk (EXIF GPS intact) instead of file_picker's cache copy,
    // which OEM content providers strip of location data.
    return PickedFileResolver.resolve(
      await PickedFileResolver.fromPlatformFile(file),
    );
  }

  /// OHOS-only gallery pick: PhotoViewPicker with the API-26 HEIC-original
  /// declaration (preferredCompatibleMode=CURRENT), bridged natively.
  static const _ohosGalleryChannel = MethodChannel('xdremux/gallery');

  Future<String?> _pickFromGallery() async {
    try {
      final raw = await _ohosGalleryChannel.invokeMethod<List<dynamic>>(
        'pickImages',
      );
      final paths = (raw ?? []).whereType<String>().toList();
      if (paths.isEmpty) return null;
      return paths.first;
    } on PlatformException catch (e) {
      _showError(t('无法打开图库：${e.message ?? e.code}', 'Cannot open gallery: ${e.message ?? e.code}'));
      return null;
    }
  }

  Future<void> _selectSource({bool fromGallery = false}) async {
    final picked = fromGallery ? await _pickFromGallery() : await _pickPhoto();
    if (picked == null || !mounted) return;
    var path = picked;
    // Motion Photo: the donor must be the still image — the watermark graph,
    // EXIF and ProXDR metadata all live in the still byte range, and the
    // appended video stream would only confuse downstream parsers.
    final motion = await MotionPhotoService.inspect(path);
    var motionNote = '';
    if (motion != null) {
      try {
        path = await MotionPhotoService.extractStillToTemp(path);
        motionNote = t('（动态照片，已取静帧作为原图）', ' (motion photo; still extracted as source)');
      } catch (e) {
        _showError(t('动态照片静帧提取失败：$e', 'Failed to extract still from motion photo: $e'));
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _sourcePath = path;
      _appleEditPath = null;
      _returnedPath = null;
      _finalPath = null;
      _status = t(
        '已选择 ${_fileLabel(path)}$motionNote。它也是恢复原机水印和元数据的来源，请保留。',
        'Selected ${_fileLabel(path)}$motionNote. It is also the source for restoring the original watermark and metadata — please keep it.',
      );
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

  Future<void> _createAppleEditCopy() async {
    final source = _sourcePath;
    if (source == null || _running) return;
    final backendAvailable =
        _stylesBackend == ConversionBackend.rust ||
        _capabilities.swiftPhotographicStyles;
    if (!backendAvailable) {
      _showError(
        _capabilities.swiftAppleFeaturesUnavailableReason.isEmpty
            ? t('当前设备未通过 Swift Apple 照片摄影风格能力验证。', 'Current device did not pass the Swift Apple Photographic Styles capability check.')
            : _capabilities.swiftAppleFeaturesUnavailableReason,
      );
      return;
    }
    setState(() {
      _running = true;
      _status = t('正在准备 Apple 编辑副本…', 'Preparing Apple edit copy…');
      _returnedPath = null;
      _finalPath = null;
    });
    try {
      final directory = await _workflowDirectory(source);
      final suffix = _watermarkPolicy == AppleWatermarkPolicy.isolate
          ? '.apple-edit-isolated.heic'
          : '.apple-edit.heic';
      final output =
          '$directory${Platform.pathSeparator}${_stem(source)}$suffix';
      final result = await AppleOppoWorkflowService.createAppleStylesCopy(
        sourcePath: source,
        outputPath: output,
        backend: _stylesBackend,
        watermarkPolicy: _watermarkPolicy,
        onStatus: _setStatus,
      );
      if (!mounted) return;
      setState(() {
        _appleEditPath = result;
        _status = t('Apple 编辑副本已生成：${_fileLabel(result)}', 'Apple edit copy generated: ${_fileLabel(result)}');
      });
    } catch (error) {
      _showError(t('Apple 照片摄影风格失败：$error', 'Apple Photographic Styles failed: $error'));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _selectReturnedPhoto({bool fromGallery = false}) async {
    final path = fromGallery ? await _pickFromGallery() : await _pickPhoto();
    if (path == null || !mounted) return;
    setState(() {
      _returnedPath = path;
      _finalPath = null;
      _status = t('已选择 iPhone 回传照片：${_fileLabel(path)}', 'Selected iPhone returned photo: ${_fileLabel(path)}');
    });
  }

  Future<void> _writeback() async {
    final returned = _returnedPath;
    final donor = _sourcePath;
    if (returned == null || _running) return;
    if (_outputMode == OutputMode.oppo && donor == null) {
      _showError(t('OPPO 兼容输出必须保留 OPPO 原始照片。', 'OPPO Compatible output requires keeping the original OPPO photo.'));
      return;
    }
    if (_restoreWatermark &&
        donor == null &&
        !((Platform.isIOS || Platform.isWindows) &&
            _outputMode == OutputMode.apple)) {
      _showError(t('需要恢复原机水印时必须保留 OPPO 原始照片。', 'Restoring the original watermark requires keeping the original OPPO photo.'));
      return;
    }
    if (!Platform.isMacOS &&
        !Platform.isIOS &&
        !Platform.isWindows &&
        !Platform.isAndroid &&
        !PlatformX.isOhos) {
      _showError(t('当前平台不支持回传照片处理。', 'This platform does not support returned-photo processing.'));
      return;
    }
    setState(() {
      _running = true;
      _status = t('正在生成最终 ${_outputMode.appTitle} 输出…', 'Generating final ${_outputMode.appTitle} output…');
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
        final report = await AppleOppoWorkflowService.writebackReturnedPhoto(
          donorPath: donor,
          returnedPath: returned,
          outputPath: output,
          outputMode: _outputMode,
          restoreWatermark: _restoreWatermark,
          onStatus: _setStatus,
        );
        // Phase timing from the Rust core (decode/composite/x265/iso/styles).
        debugPrint('[XDRemux][writeback] timings: ${report['timingsMs']}');
      }
      if (!mounted) return;
      setState(() {
        _finalPath = output;
        _status = t('最终输出已生成：${_fileLabel(output)}', 'Final output generated: ${_fileLabel(output)}');
      });
    } catch (error) {
      _showError(
        Platform.isIOS && _outputMode == OutputMode.apple
            ? t('处理失败：$error', 'Processing failed: $error')
            : t('写回失败：$error', 'Writeback failed: $error'),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _saveFile(String path) async {
    if (_running) return;
    final destination = await FileActionService.saveFile(
      path,
      suggestedName: _fileLabel(path),
    );
    if (!mounted) return;
    setState(() {
      _status = destination == null
          ? t('保存已取消或失败', 'Save cancelled or failed')
          : PlatformX.isMobile
          ? t('已保存到照片图库', 'Saved to photo library')
          : t('已保存：${_fileLabel(destination)}', 'Saved: ${_fileLabel(destination)}');
    });
  }

  Widget _fileActions(String path) {
    final mobile = PlatformX.isMobile;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // OHOS: only share is wired (system share sheet); gallery save and
        // open-with are intentionally hidden until verified on that platform.
        if (!PlatformX.isOhos) ...[
          FilledButton.icon(
            onPressed: () => _saveFile(path),
            icon: Icon(
              mobile ? Icons.photo_library_outlined : Icons.save_alt_outlined,
            ),
            label: Text(mobile ? t('保存到照片', 'Save to Photos') : t('另存为…', 'Save as…')),
          ),
          OutlinedButton.icon(
            onPressed: () => FileActionService.openFile(path),
            icon: const Icon(Icons.open_in_new),
            label: Text(t('打开文件', 'Open file')),
          ),
        ],
        OutlinedButton.icon(
          onPressed: () => FileActionService.shareFile(path),
          icon: const Icon(Icons.share_outlined),
          label: Text(t('分享', 'Share')),
        ),
      ],
    );
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
      Platform.isAndroid ||
      PlatformX.isOhos;

  bool get _canFinalizeApple =>
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isAndroid ||
      PlatformX.isOhos;

  String get _outputModeHelp {
    if ((Platform.isIOS || Platform.isWindows || Platform.isAndroid) &&
        _outputMode == OutputMode.apple) {
      if ((Platform.isWindows || Platform.isAndroid) &&
          _restoreWatermark &&
          _sourcePath != null) {
        return t(
          'Rust 恢复可见原机水印后输出 Apple 文件，不写入 OPPO 私有尾部数据。',
          'Rust restores the visible original watermark and outputs an Apple file without writing OPPO private tail data.',
        );
      }
      return t(
        '保留 Apple 照片回传画面，不写入 OPPO 私有元数据和尾部数据。',
        'Keeps the Apple Photos returned image without writing OPPO private metadata and tail data.',
      );
    }
    if (Platform.isIOS && _outputMode == OutputMode.oppo) {
      return t(
        '按 OPPO 原始照片恢复可见原机水印、元数据和尾部数据；iOS 路径尚未完成真机验证，属于实验性能力。',
        'Restores the visible original watermark, metadata and tail data from the OPPO source; the iOS path is not yet device-verified and is experimental.',
      );
    }
    return _outputMode.appHelp;
  }

  String get _appleCapabilityMessage {
    if (_capabilities.swiftAppleFeaturesUnavailableReason.isNotEmpty) {
      return _capabilities.swiftAppleFeaturesUnavailableReason;
    }
    return Platform.isIOS
        ? t('iOS 当前只验证 Rust OPPO 兼容文件；Apple 照片中的摄影风格仍等待嵌入式 Swift Library。', 'iOS currently only validates Rust OPPO-compatible files; Photographic Styles in Apple Photos still await the embedded Swift Library.')
        : t('当前设备未通过 Apple 照片摄影风格能力验证。', 'Current device did not pass the Apple Photographic Styles capability check.');
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

  Widget _pathText(String? path, {String empty = ''}) {
    final emptyText = empty.isEmpty ? t('尚未选择', 'Not selected yet') : empty;
    return Text(
      path == null ? emptyText : '${_fileLabel(path)}\n$path',
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
    return Scaffold(
      appBar: AppBar(
        title: Text(t('一帧影像，动用两台手机', 'One photo, two phones')),
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
                    ? t('这是独立的四步文件往返流程：一次摄影风格转换生成 Apple 编辑副本，回传后由 Rust 恢复原机水印与 OPPO 元数据。普通“批量转换”队列不会参与此流程。', 'This is a standalone four-step file round-trip: a Photographic Styles conversion produces an Apple edit copy, then Rust restores the original watermark and OPPO metadata after round-trip. The normal batch queue is not involved.')
                    : Platform.isAndroid
                    ? t('这是独立的四步文件往返流程。Android 使用 SAF 选择文件；Rust 直接从 OPPO 原始照片生成 Apple 编辑副本并完成 OPPO 写回。', 'This is a standalone four-step file round-trip. Android selects files via SAF; Rust generates the Apple edit copy directly from the OPPO original and completes the OPPO writeback.')
                    : Platform.isIOS
                    ? t('这是独立的四步文件往返流程。iOS 支持通过相册、文件和分享导入/导出；Rust 直接从 OPPO 原始照片生成 Apple 编辑副本。', 'This is a standalone four-step file round-trip. iOS imports/exports via Photos, Files and Share; Rust generates the Apple edit copy directly from the OPPO original.')
                    : t('这是独立的四步文件往返流程。macOS 使用 Apple 原生图像读写路径；OPPO 原始照片与 iPhone 回传照片会保持配对。', 'This is a standalone four-step file round-trip. macOS uses Apple-native image read/write paths; the OPPO original and the iPhone returned photo stay paired.'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 1,
            title: t('选择 OPPO 原始照片', 'Select the original OPPO photo'),
            description: t('建议选择未经转换的 OPPO 原始照片；它也是后续恢复原机水印和元数据的来源。', 'Prefer an unconverted OPPO original; it is also the source for restoring the original watermark and metadata later.'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _pathText(_sourcePath),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (PlatformX.isOhos)
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _selectSource(fromGallery: true),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(t('从图库选择', 'Choose from gallery')),
                      ),
                    OutlinedButton.icon(
                      onPressed: _running ? null : () => _selectSource(),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(
                        PlatformX.isOhos ? t('从文件选择', 'Choose from files') : t('选择照片', 'Choose photo'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 2,
            title: t('生成 Apple 照片摄影风格编辑副本', 'Generate Apple Photographic Styles edit copy'),
            description: t('对所选 OPPO 原始照片做一次摄影风格转换，生成交给 iPhone 编辑的工作文件。', 'Run a Photographic Styles conversion on the selected OPPO original to produce a working file for editing on iPhone.'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('转换引擎', 'Conversion engine'), style: theme.textTheme.titleSmall),
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
                      _sourcePath == null ||
                          !canUseSelectedStylesBackend ||
                          _running
                      ? null
                      : _createAppleEditCopy,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(t('生成 Apple 照片编辑副本', 'Generate Apple Photos edit copy')),
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
                  Text(t('Apple 照片编辑副本', 'Apple Photos edit copy'), style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _pathText(_appleEditPath),
                  const SizedBox(height: 8),
                  _fileActions(_appleEditPath!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _stepCard(
            context: context,
            step: 3,
            title: t('在 iPhone 上编辑', 'Edit on iPhone'),
            description: Platform.isIOS
                ? t('生成编辑副本后分享至 Apple 照片或“文件”，在 iPhone 上完成调整并回传。', 'After generating the edit copy, share it to Apple Photos or Files, finish adjustments on iPhone and return it.')
                : t('把上一步生成的文件传到 iPhone，在 Apple 照片中完成调整并导出/回传。', 'Transfer the file from the previous step to iPhone, finish adjustments in Apple Photos and export/return it.'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    t('支持 HEIC / HEIF 照片；macOS 可直接从 Apple 照片拖到此窗口。', 'Supports HEIC / HEIF photos; on macOS you can drag them directly from Apple Photos into this window.'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (PlatformX.isOhos)
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _selectReturnedPhoto(fromGallery: true),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(t('从图库选择', 'Choose from gallery')),
                      ),
                    OutlinedButton.icon(
                      onPressed: _running ? null : () => _selectReturnedPhoto(),
                      icon: const Icon(Icons.file_download_outlined),
                      label: Text(
                        PlatformX.isOhos
                            ? t('从文件选择', 'Choose from files')
                            : t('选择 iPhone 回传照片', 'Select iPhone returned photo'),
                      ),
                    ),
                  ],
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
            title: t('恢复原机水印并生成最终输出', 'Restore original watermark & generate final output'),
            description: Platform.isIOS
                ? t('Apple 标准保留 Apple 照片回传文件并做 ImageIO 可读性检查；OPPO 兼容模式恢复 OPPO 兼容结构（实验性，待真机验证）。', 'Apple Standard keeps the Apple Photos returned file and runs an ImageIO readability check; OPPO Compatible restores the OPPO-compatible structure (experimental, pending device verification).')
                : Platform.isWindows || Platform.isAndroid
                ? t('Rust 恢复 OPPO 兼容尾部数据、可见原机水印和元数据；Apple 标准保留 Apple 照片结果且不写入 OPPO 私有信息，可按开关恢复可见原机水印。', 'Rust restores OPPO-compatible tail data, the visible original watermark and metadata; Apple Standard keeps the Apple Photos result without writing OPPO private info, and can restore the visible original watermark via the toggle.')
                : t('OPPO 兼容模式恢复 OPPO 兼容结构；Apple 标准保留 Apple 照片结果且不写入 OPPO 私有信息。', 'OPPO Compatible restores the OPPO-compatible structure; Apple Standard keeps the Apple Photos result without writing OPPO private info.'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('按 OPPO 原始照片恢复可见原机水印', 'Restore visible original watermark from OPPO source')),
                  subtitle: Text(
                    Platform.isWindows || Platform.isAndroid
                        ? t('Rust 会解码、恢复可见原机水印并重新编码回传 HEIF，同时保留 OPPO 元数据。', 'Rust decodes, restores the visible original watermark and re-encodes the returned HEIF while preserving OPPO metadata.')
                        : t('关闭后保留 iPhone 回传画面；OPPO 兼容模式仍会恢复 OPPO 元数据和尾部数据。', 'When off, keeps the iPhone returned image; OPPO Compatible still restores OPPO metadata and tail data.'),
                  ),
                  value: _restoreWatermark,
                  onChanged: _running || !_canWriteback
                      ? null
                      : (value) => setState(() => _restoreWatermark = value),
                ),
                const SizedBox(height: 12),
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
                  label: Text(_running ? t('处理中…', 'Processing…') : t('生成最终输出', 'Generate final output')),
                ),
                if (Platform.isWindows || Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  Text(
                    t(
                      '当前平台由 Rust 完成可见原机水印、OPPO 尾部数据和元数据写回；输出仍需在 Apple/OPPO 设备上做最终兼容性确认。',
                      'On this platform Rust performs the visible-original-watermark, OPPO tail-data and metadata writeback; the output still needs final compatibility confirmation on Apple/OPPO devices.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
                if (Platform.isIOS) ...[
                  const SizedBox(height: 8),
                  Text(
                    t(
                      'iOS 的 OPPO 写回与 macOS 共用 Apple ImageIO/ISOBMFF 路径；尚未在实体 iPhone 上完成端到端验证，输出请先在 OPPO 设备上确认。',
                      'iOS OPPO writeback shares the Apple ImageIO/ISOBMFF path with macOS; end-to-end verification on a real iPhone is not complete — confirm output on an OPPO device first.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_finalPath != null) ...[
                  const SizedBox(height: 12),
                  Text(t('最终文件', 'Final file'), style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _pathText(_finalPath),
                  const SizedBox(height: 8),
                  _fileActions(_finalPath!),
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
