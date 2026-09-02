import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/xdremux_service.dart';
import '../ffi/xdremux_ffi.dart';

/// Standalone "organize photos by capture mode" page.
///
/// Mirrors the upstream `categorize` command: scan HEIC/HEIF/JPEG files,
/// classify each by its OPPO UserComment capture-mode flags, preview the
/// plan, then copy into per-mode Chinese folders.
class OrganizePage extends StatefulWidget {
  const OrganizePage({super.key});

  @override
  State<OrganizePage> createState() => _OrganizePageState();
}

/// Returns a non-colliding path for `[subdir]/[stem][ext]`.
///
/// Collision = reserved by another planned copy (case-insensitive) or an
/// existing file, except when the existing file IS [keepPath] — organizing a
/// photo into its own directory must not count as a collision and must not
/// force a rename.
String organizeAvoidCollision(
  String subdir,
  String stem,
  String ext,
  Set<String> reserved, {
  String? keepPath,
}) {
  bool collides(String candidate) {
    if (reserved.contains(candidate.toLowerCase())) return true;
    if (!File(candidate).existsSync()) return false;
    if (keepPath == null) return true;
    return File(candidate).absolute.path != File(keepPath).absolute.path;
  }

  var candidate = '$subdir/$stem$ext';
  var seq = 2;
  while (collides(candidate)) {
    candidate = '$subdir/$stem ($seq)$ext';
    seq++;
  }
  return candidate;
}

class _OrganizeItem {
  final String sourcePath;
  final String fileName;
  String? modeKey;
  String? folderName;
  String? status;
  String destinationPath = '';
  String copyState = 'pending'; // pending | copied | duplicate | failed
  String? error;

  /// Non-null when this image + a same-basename MOV form a validated
  /// Apple Live Photo pair. The MOV is copied together with the image.
  String? pairedVideoPath;

  /// Collision-avoided destination for the paired MOV. Computed together
  /// with the still's destination so the preview shows the final layout.
  String? pairedVideoDestination;
  bool get isLivePhoto => pairedVideoPath != null;

  _OrganizeItem({required this.sourcePath, required this.fileName});
}

class _OrganizePageState extends State<OrganizePage> {
  final List<_OrganizeItem> _items = [];
  String? _outputDir;
  bool _scanning = false;
  bool _copying = false;
  String _statusText = '选择包含 HEIC / JPEG 照片的目录开始扫描';

  static const _supportedExt = {'.heic', '.heif', '.jpg', '.jpeg'};
  static const _assetLayoutPrefix = '静态照片';
  static const _liveLayoutPrefix = '实况照片';

  Future<void> _pickInputDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要整理的照片目录',
    );
    if (dir == null) return;
    setState(() {
      _items.clear();
      _statusText = '扫描中…';
      _scanning = true;
    });
    await _scanDirectory(Directory(dir));
  }

  Future<void> _pickOutputDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择分类输出目录',
    );
    if (dir == null) return;
    setState(() {
      _outputDir = dir;
      _recomputeDestinations();
    });
  }

  Future<void> _scanDirectory(Directory dir) async {
    final files = <File>[];
    final movs = <String, File>{};
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (_supportedExt.contains(
        entity.path.substring(entity.path.lastIndexOf('.')).toLowerCase(),
      )) {
        files.add(entity);
      } else if (lower.endsWith('.mov')) {
        final stem = entity.uri.pathSegments.last.replaceAll(RegExp(r'\.mov$'), '');
        movs[stem] = entity;
      }
    }

    if (files.isEmpty) {
      setState(() {
        _scanning = false;
        _statusText = '该目录下没有找到 HEIC / JPEG 照片';
      });
      return;
    }

    // Default output dir = input dir.
    _outputDir ??= dir.path;

    for (final file in files) {
      final item = _OrganizeItem(
        sourcePath: file.path,
        fileName: file.uri.pathSegments.last,
      );
      try {
        final result = await XdRemuxService.classify(file.path);
        item.modeKey = result['modeKey'] as String?;
        item.folderName = result['folderName'] as String?;
        item.status = result['status'] as String?;
      } catch (_) {
        item.status = 'unreadable-image';
      }
      // Asset-aware grouping: a same-basename MOV is only claimed as the
      // paired video when the content identifiers match on both sides
      // (upstream v1.4 semantics — never on filename alone).
      final stem = file.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
      final companion = movs[stem];
      if (companion != null &&
          XdRemuxFFI.livePhotoPairValid(file.path, companion.path)) {
        item.pairedVideoPath = companion.path;
      }
      _items.add(item);
    }

    _recomputeDestinations();
    setState(() {
      _scanning = false;
      final categorized = _items.where((i) => i.modeKey != null).length;
      final live = _items.where((i) => i.isLivePhoto).length;
      _statusText = '共 ${_items.length} 张照片，$categorized 张可分类，$live 组实况照片';
    });
  }

  void _recomputeDestinations() {
    final root = _outputDir;
    if (root == null) return;
    final reserved = <String, int>{};
    final videoReserved = <String>{};
    for (final item in _items) {
      // Asset-type level: 静态照片 / 实况照片 (upstream v1.4 layout).
      final assetPrefix = item.isLivePhoto ? _liveLayoutPrefix : _assetLayoutPrefix;
      final subdir = item.folderName != null
          ? '$root/$assetPrefix/${item.folderName}'
          : '$root/$assetPrefix';
      final dot = item.fileName.lastIndexOf('.');
      final stem = dot > 0 ? item.fileName.substring(0, dot) : item.fileName;
      final ext = dot > 0 ? item.fileName.substring(dot) : '';
      final candidate = organizeAvoidCollision(
        subdir,
        stem,
        ext,
        reserved.keys.toSet(),
        keepPath: item.sourcePath,
      );
      reserved[candidate.toLowerCase()] = 1;
      item.destinationPath = candidate;
      // Paired MOV gets its own collision-avoided destination (same stem,
      // .mov extension). Without this an existing MOV at the destination
      // would be silently overwritten by _executeCopy.
      if (item.isLivePhoto) {
        final videoCandidate = organizeAvoidCollision(
          subdir,
          stem,
          '.mov',
          videoReserved,
          keepPath: item.pairedVideoPath,
        );
        videoReserved.add(videoCandidate.toLowerCase());
        item.pairedVideoDestination = videoCandidate;
      } else {
        item.pairedVideoDestination = null;
      }
      // Same file => duplicate (skip).
      if (File(item.sourcePath).absolute.path == File(candidate).absolute.path) {
        item.copyState = 'duplicate';
      } else {
        item.copyState = 'pending';
      }
    }
  }

  Future<void> _executeCopy() async {
    final root = _outputDir;
    if (root == null) return;
    setState(() {
      _copying = true;
      _statusText = '复制中…';
    });
    var copied = 0, failed = 0, skipped = 0;
    for (final item in _items) {
      if (item.copyState == 'duplicate') {
        skipped++;
        continue;
      }
      try {
        final dest = File(item.destinationPath);
        await dest.parent.create(recursive: true);
        await File(item.sourcePath).copy(dest.path);
        // Live Photo pair: copy the paired MOV to its collision-avoided
        // destination. In-place organization (video source == destination)
        // needs no copy.
        if (item.isLivePhoto &&
            item.pairedVideoPath != null &&
            item.pairedVideoDestination != null &&
            File(item.pairedVideoDestination!).absolute.path !=
                File(item.pairedVideoPath!).absolute.path) {
          await File(item.pairedVideoPath!).copy(item.pairedVideoDestination!);
        }
        item.copyState = 'copied';
        copied++;
      } catch (e) {
        item.copyState = 'failed';
        item.error = e.toString();
        failed++;
      }
      if (mounted && (copied + failed + skipped) % 20 == 0) {
        setState(() => _statusText = '复制中… $copied 完成 / $failed 失败');
      }
    }
    setState(() {
      _copying = false;
      _statusText = '完成：$copied 张已复制，$skipped 张跳过，$failed 张失败';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = <String, List<_OrganizeItem>>{};
    for (final item in _items) {
      grouped.putIfAbsent(item.folderName ?? '（未分类）', () => []).add(item);
    }
    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '（未分类）') return 1;
        if (b == '（未分类）') return -1;
        return a.compareTo(b);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('按拍摄模式整理'),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.drive_folder_upload),
                    label: const Text('选择照片目录'),
                    onPressed: _scanning || _copying ? null : _pickInputDir,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.output),
                    label: Text(
                      _outputDir == null ? '选择输出目录' : '输出: ${_shorten(_outputDir!)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: _scanning || _copying ? null : _pickOutputDir,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.copy_all),
                  label: const Text('开始整理'),
                  onPressed: _items.isEmpty || _scanning || _copying
                      ? null
                      : _executeCopy,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_statusText, style: theme.textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text(
                      _scanning ? '扫描中…' : '尚未加载照片',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: sortedKeys.length,
                    itemBuilder: (context, index) {
                      final key = sortedKeys[index];
                      final group = grouped[key]!;
                      return _ModeGroupCard(
                        title: key,
                        items: group,
                        outputDir: _outputDir,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _shorten(String path) {
    if (path.length <= 28) return path;
    return '…${path.substring(path.length - 26)}';
  }
}

class _ModeGroupCard extends StatelessWidget {
  final String title;
  final List<_OrganizeItem> items;
  final String? outputDir;

  const _ModeGroupCard({
    required this.title,
    required this.items,
    required this.outputDir,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${items.length} 张',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...items.take(8).map(
                  (item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          item.copyState == 'copied'
                              ? Icons.check_circle
                              : item.copyState == 'failed'
                                  ? Icons.error
                                  : item.copyState == 'duplicate'
                                      ? Icons.skip_next
                                      : Icons.circle_outlined,
                          size: 14,
                          color: item.copyState == 'copied'
                              ? Colors.green
                              : item.copyState == 'failed'
                                  ? Colors.red
                                  : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.fileName,
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.copyState == 'failed' && item.error != null)
                          Tooltip(
                            message: item.error!,
                            child: const Icon(Icons.info_outline, size: 14),
                          ),
                      ],
                    ),
                  ),
                ),
            if (items.length > 8)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '… 共 ${items.length} 张',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
