import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'l10n/l10n.dart';
import 'platform_x.dart';
import 'services/output_export_service.dart';
import 'services/xdremux_service.dart';
import 'services/transfer/transfer_controller.dart';
import 'services/transfer/transfer_export.dart';
import 'services/transfer/transfer_live_photo.dart';
import 'services/transfer/transfer_models.dart';
import 'transfer_storage_dialog.dart';

String transferErrorText(String code) => switch (code) {
  'batch_too_large' => t(
    '文件路径清单过长，请减少文件数量后分批发送',
    'The path list is too long; send fewer files per batch',
  ),
  'port_in_use' => t(
    '接收端口已被占用或被系统限制，请换一个端口后重试',
    'Receive port is in use or unavailable; choose another port',
  ),
  'discovery_unavailable' => t(
    '自动发现不可用，可继续使用下方 IP/端口直连',
    'Discovery unavailable; use IP/port below',
  ),
  'source_changed' => t(
    '源文件已变化，请重新选择文件并发送',
    'Source changed; select the files again',
  ),
  'cancelled' => t(
    '传输已取消，已接收成功的文件会保留',
    'Cancelled; successfully received files are retained',
  ),
  'invalid_input' => t(
    '请检查 IP 地址、端口或文件选择',
    'Check the IP address, port or selected files',
  ),
  'already_exists' => t(
    '目标目录已有同名文件，请选择其他目录',
    'The destination already contains that name; choose another folder',
  ),
  'library_missing' || 'abi_mismatch' || 'unsupported_platform' => t(
    '此版本尚未包含可用的互传组件',
    'Transfer is unavailable in this build',
  ),
  'network' || 'timed_out' => t(
    '连接失败：检查地址、端口、同一局域网和防火墙',
    'Connection failed: check address, port, LAN and firewall',
  ),
  'no_space' => t('可用空间不足，请清理后重试', 'Not enough free space'),
  'invalid_live_photo' => t(
    '实况照片包内容不完整，原文件已保留在收件箱',
    'The Live Photo package is incomplete; the inbox original is retained',
  ),
  'permission_denied' => t(
    '没有相册权限，请在系统设置中允许后重试',
    'No photo library access; allow it in system settings',
  ),
  'identity_mismatch' => t(
    '设备身份发生变化，请重新选择设备',
    'Device identity changed; select the device again',
  ),
  'authentication' => t('接收端 PIN 不正确', 'Receiver PIN was not accepted'),
  'declined' => t('对方拒绝了接收', 'The receiver declined'),
  'busy' => t(
    '当前操作尚未结束，请稍后重试',
    'An operation is still running; try again shortly',
  ),
  'closed' => t('互传已停止，请重新开启', 'Transfer stopped; enable it again'),
  'outcome_unknown' => t(
    '结果未确认，请刷新记录后再决定是否重试',
    'Result unknown; refresh records before retrying',
  ),
  'checksum_mismatch' || 'truncated' => t(
    '文件校验失败，原收件箱文件已保留',
    'File verification failed; the inbox original is retained',
  ),
  _ => t(
    '操作未完成，文件已保留；请检查后重试',
    'Operation failed; files are retained. Check and retry',
  ),
};
String _bytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB'];
  var value = n / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// A conversion-queue item that the send tab can pick from.
class TransferSource {
  const TransferSource({
    required this.name,
    required this.original,
    this.converted = const [],
  });
  final String name;
  final String original;

  /// Converted output files (a Live Photo is its still and MOV, or its `.pvt`
  /// folder); empty until converted.
  final List<String> converted;
}

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    this.controller,
    this.initialPaths = const [],
    this.sourceLabel,
    this.sources = const [],
    this.autoReceive = false,
  });
  final TransferController? controller;
  final List<String> initialPaths;
  final String? sourceLabel;

  /// Conversion-queue items offered by "Add from conversion list".
  final List<TransferSource> sources;

  /// Start receiving (and so discovery) as soon as the page opens.
  final bool autoReceive;
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with WidgetsBindingObserver {
  late final TransferController transfer;
  final _host = TextEditingController(),
      _port = TextEditingController(text: '53319');
  final _listenPort = TextEditingController(text: '53319'),
      _pin = TextEditingController();
  late List<String> _paths;
  Future<int>? _selectionSize;
  Map<String, dynamic>? _peer;
  bool _working = false, _canLeave = false, _allPaths = false;
  bool _manual = false, _showPin = false;
  String? _message;
  final Map<String, int> _visibleFiles = {};
  @override
  void initState() {
    super.initState();
    transfer = widget.controller ?? TransferController.instance;
    final initial = widget.initialPaths;
    _paths = [
      for (final p in initial)
        if (!FileSystemEntity.isDirectorySync(p)) p,
    ];
    _selectionSize = _measure(_paths);
    transfer.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    transfer.enumerateInterfaces().catchError((_) {});
    if (_paths.length != initial.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(() => _addPaths(initial));
      });
    }
    if (widget.autoReceive && !transfer.receiving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !transfer.receiving) _run(_enableReceiving);
      });
    }
  }

  /// Mobile reception stops in the background; coming back to this page
  /// resumes it, so discovery and receiving need no extra tap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.autoReceive &&
        !transfer.receiving &&
        !_working &&
        !transfer.busy) {
      _run(_enableReceiving);
    }
  }

  Future<String> _nameFuture = TransferController.deviceName();

  Future<void> _renameDevice(String current) async {
    final model = await TransferController.modelName();
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(current: current, model: model),
    );
    if (name == null || !mounted) return;
    await _run(() async {
      await TransferController.setDeviceName(name);
      setState(() {
        _nameFuture = TransferController.deviceName();
      });
      // The name is announced by the running listener; restart it.
      if (transfer.receiving) {
        await transfer.stop();
        await _enableReceiving();
      }
    });
  }

  Future<void> _enableReceiving() =>
      transfer.enableReceiving(port: int.tryParse(_listenPort.text) ?? 0);

  final Map<String, String> _bundleZips = {};
  final Map<String, Future<Uint8List?>> _previews = {};

  /// Receipts stay in private storage, so previews render from the leased
  /// file (a Live Photo zip through its still) and are cached per size.
  Future<Uint8List?> _preview(Map<String, dynamic> row, int size) {
    final id = row['id'] as String;
    final name = row['name'] as String;
    return _previews['$id@$size'] ??= transfer
        .withReceipt(id, (lease) async {
          var path = lease['path'] as String;
          Directory? temp;
          try {
            if (isLivePhotoZip(name)) {
              temp = await Directory.systemTemp.createTemp('xdremux-preview-');
              path = await extractLivePhotoStill(path, temp.path);
            }
            return await XdRemuxService.getThumbnail(path, maxPixelSize: size);
          } finally {
            await temp?.delete(recursive: true).catchError((_) => temp!);
          }
        })
        .then<Uint8List?>((bytes) => bytes, onError: (_) => null);
  }

  Widget _thumbnail(Map<String, dynamic> row, IconData fallback) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.surfaceContainerHighest,
      child: Icon(fallback, color: scheme.onSurfaceVariant),
    );
    return InkWell(
      key: ValueKey('preview-${row['id']}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showPreview(row),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 64,
          child: FutureBuilder<Uint8List?>(
            future: _preview(row, 256),
            builder: (_, snapshot) => snapshot.data == null
                ? placeholder
                : Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _showPreview(Map<String, dynamic> row) => showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: FutureBuilder<Uint8List?>(
              future: _preview(row, 2048),
              builder: (_, snapshot) => switch (snapshot) {
                AsyncSnapshot(hasData: true, :final data?) => InteractiveViewer(
                  child: Image.memory(data),
                ),
                AsyncSnapshot(connectionState: ConnectionState.done) =>
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(t('无法预览此文件', 'No preview available')),
                  ),
                _ => const Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              },
            ),
          ),
          ListTile(
            title: Text(row['name'] as String, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: t('关闭', 'Close'),
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ],
      ),
    ),
  );

  /// A Live Photo output is a `.pvt` folder. LocalSend moves files, so it
  /// travels as `<stem>.pvt.zip`, which the receiving app unpacks again.
  Future<String?> _resolve(String path) async {
    if (!FileSystemEntity.isDirectorySync(path)) return path;
    if (!path.toLowerCase().endsWith('.pvt')) return null;
    return _bundleZips[path] ??= await zipLivePhotoBundle(path);
  }

  Future<int> _measure(List<String> paths) async {
    var bytes = 0;
    for (final path in paths) {
      bytes += await File(path).length();
    }
    return bytes;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Success feedback stays visible wherever the list is scrolled; errors use
  /// the persistent banner at the top instead.
  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _setPaths(List<String> paths) {
    setState(() {
      _paths = paths;
      _allPaths = false;
      _selectionSize = _measure(paths);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    transfer.removeListener(_changed);
    _host.dispose();
    _port.dispose();
    _listenPort.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = transferErrorText(TransferController.code(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _leave() async {
    await _run(() async {
      await transfer.stop();
      if (mounted) {
        setState(() => _canLeave = true);
        Navigator.of(context).pop();
      }
    });
  }

  /// Like LocalSend, picking a device selects it directly. The probe still
  /// pins its certificate, and a discovered device must answer with the
  /// identity it advertised.
  Future<void> _connect({Map<String, dynamic>? expected}) async {
    setState(() => _peer = null);
    final peer = await transfer.probe(
      _host.text,
      int.tryParse(_port.text) ?? 0,
    );
    if (!mounted) return;
    if (expected != null && peer['fingerprint'] != expected['fingerprint']) {
      throw const TransferException('identity_mismatch');
    }
    await transfer.confirmPeer(peer, remember: false);
    if (mounted) setState(() => _peer = peer);
  }

  Future<void> _selectPeer(Map<String, dynamic> peer) async {
    final address = peer['address'] as String;
    final colon = address.lastIndexOf(':');
    _host.text = address.substring(0, colon).replaceAll(RegExp(r'^\[|\]$'), '');
    _port.text = address.substring(colon + 1);
    setState(() => _peer = null);
    await _connect(expected: peer);
  }

  Future<void> _retry(String id) async {
    if (_peer == null) throw const TransferException('identity_mismatch');
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('重试未确认成功的文件？', 'Retry unacknowledged files?')),
        content: Text(
          t(
            '已发送成功的文件不会重发。',
            'Files already delivered are not sent again.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            key: const ValueKey('confirm-retry'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('重试', 'Retry')),
          ),
        ],
      ),
    );
    if (yes == true) {
      await transfer.retry(
        id,
        _peer!,
        pin: _pin.text.isEmpty ? null : _pin.text,
      );
    }
  }

  Future<void> _pick() async {
    // Android and HarmonyOS pickers background the app, which stops LAN
    // reception anyway; stop first so it never ends halfway through a batch.
    // Reception comes back afterwards, so discovery keeps working.
    final resume =
        (Platform.isAndroid || PlatformX.isOhos) && transfer.receiving;
    if (resume) await transfer.stop();
    try {
      final result = await FilePicker.pickFiles();
      if (result.isEmpty) return;
      final paths = result.map((f) => f.path).whereType<String>().toList();
      if (paths.length != result.length) {
        throw const TransferException('invalid_input');
      }
      if (mounted) await _addPaths(paths);
    } finally {
      if (resume && mounted && !transfer.receiving) await _enableReceiving();
    }
  }

  Future<void> _addPaths(List<String> paths) async {
    final resolved = [for (final p in paths) await _resolve(p)];
    if (!mounted) return;
    final seen = _paths.toSet();
    _setPaths([
      ..._paths,
      for (final p in resolved)
        if (p != null && seen.add(p)) p,
    ]);
  }

  Future<void> _pickFromQueue() async {
    final sources = widget.sources;
    var converted = sources.any((s) => s.converted.isNotEmpty);
    final chosen = <int>{
      for (var i = 0; i < sources.length; i++)
        if (!converted || sources[i].converted.isNotEmpty) i,
    };
    final paths = await showModalBottomSheet<List<String>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          bool usable(int i) => !converted || sources[i].converted.isNotEmpty;
          final picked = chosen.where(usable).toList()..sort();
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    t('从转换列表添加', 'Add from conversion list'),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(t('转换结果', 'Converted')),
                        enabled: sources.any((s) => s.converted.isNotEmpty),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(t('原文件', 'Originals')),
                      ),
                    ],
                    selected: {converted},
                    onSelectionChanged: (v) => update(() {
                      converted = v.first;
                      chosen
                        ..clear()
                        ..addAll([
                          for (var i = 0; i < sources.length; i++)
                            if (usable(i)) i,
                        ]);
                    }),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (var i = 0; i < sources.length; i++)
                        CheckboxListTile(
                          key: ValueKey('queue-source-$i'),
                          value: usable(i) && chosen.contains(i),
                          title: Text(
                            sources[i].name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: usable(i)
                              ? null
                              : Text(t('尚未转换', 'Not converted yet')),
                          onChanged: usable(i)
                              ? (v) => update(
                                  () => v == true
                                      ? chosen.add(i)
                                      : chosen.remove(i),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    key: const ValueKey('add-queue-sources'),
                    onPressed: picked.isEmpty
                        ? null
                        : () => Navigator.pop(ctx, [
                            for (final i in picked)
                              if (converted)
                                ...sources[i].converted
                              else
                                sources[i].original,
                          ]),
                    child: Text(
                      t('添加 ${picked.length} 项', 'Add ${picked.length}'),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (paths != null && mounted) await _run(() => _addPaths(paths));
  }

  /// The `.mov` received alongside a still of the same name: how LocalSend
  /// and loose XDRemux pairs carry a Live Photo.
  Map<String, dynamic>? _pairedMovie(Map<String, dynamic> row) {
    final name = row['name'] as String;
    if (!transferImageName(name)) return null;
    final stem = name.substring(0, name.lastIndexOf('.')).toLowerCase();
    for (final other in transfer.inbox.values) {
      if ((other['name'] as String).toLowerCase() == '$stem.mov') return other;
    }
    return null;
  }

  bool _isPairedMovie(Map<String, dynamic> row) {
    final name = (row['name'] as String).toLowerCase();
    if (!name.endsWith('.mov')) return false;
    final stem = name.substring(0, name.length - 4);
    return transfer.inbox.values.any((other) {
      final n = (other['name'] as String).toLowerCase();
      return transferImageName(n) && n.substring(0, n.lastIndexOf('.')) == stem;
    });
  }

  Future<void> _saveAll() async {
    var saved = 0, failed = 0;
    for (final row in transfer.inbox.values.toList()) {
      final name = row['name'] as String;
      // A paired MOV is saved together with its still.
      if (!TransferExport.galleryName(name) || _isPairedMovie(row)) continue;
      try {
        await TransferExport.saveToGallery(
          transfer,
          row,
          movie: _pairedMovie(row),
        );
        saved++;
      } catch (_) {
        failed++;
      }
    }
    _notify(
      t(
        '已存入相册 $saved 项${failed > 0 ? '，$failed 项失败' : ''}',
        'Saved $saved to Photos${failed > 0 ? ', $failed failed' : ''}',
      ),
    );
  }

  Future<void> _clearInbox() async {
    final count = transfer.inbox.length;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('清空收件箱？', 'Clear the inbox?')),
        content: Text(
          t(
            '删除收件箱里的 $count 个文件。已存入相册或导出的副本不受影响。',
            'Deletes $count inbox files. Copies already saved or exported stay.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            key: const ValueKey('confirm-clear-inbox'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('清空', 'Clear')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(() async {
      for (final id in transfer.inbox.keys.toList()) {
        await transfer.deleteReceipt(id);
      }
    });
  }

  Future<void> _importAll() async {
    var added = 0, skipped = 0;
    for (final row in transfer.inbox.values.toList()) {
      if (!transferImageName(row['name'] as String)) continue;
      final ack = await transfer.importReceipt(row['id'] as String);
      if (ack.status == TransferIntakeStatus.added) {
        added++;
      } else if (ack.status != TransferIntakeStatus.duplicate) {
        skipped++;
      }
    }
    _notify(
      t(
        '已加入转换队列 $added 张${skipped > 0 ? '，$skipped 张未加入' : ''}',
        'Added $added to the conversion queue${skipped > 0 ? ', $skipped not added' : ''}',
      ),
    );
  }

  Future<bool> _confirmDelete(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('删除收件箱文件？', 'Delete inbox file?')),
          content: Text(name),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('删除', 'Delete')),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final disabled = _working || transfer.busy;
    final offers = [
      for (final row in transfer.transfers.values)
        if (row['phase'] == 'pending' && row['direction'] == 'receive') row,
    ];
    List<Map<String, dynamic>> history(String direction) => [
      for (final row in transfer.transfers.values)
        if (!offers.contains(row) && row['direction'] == direction) row,
    ];
    final error =
        _message ??
        (transfer.error == null ? null : transferErrorText(transfer.error!));
    // Errors and incoming offers sit on top of whichever tab is open.
    Widget tab(String key, List<Widget> children) => LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth > 792
            ? (constraints.maxWidth - 760) / 2
            : 16.0;
        return SingleChildScrollView(
          key: ValueKey(key),
          padding: EdgeInsets.fromLTRB(side, 16, side, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                _errorBanner(context, error),
                const SizedBox(height: 12),
              ],
              for (final row in offers) ...[
                _offerCard(row, disabled),
                const SizedBox(height: 12),
              ],
              ...children,
            ],
          ),
        );
      },
    );
    final sent = history('send'), received = history('receive');
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(t('局域网互传', 'Local transfer')),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: disabled ? null : _leave,
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _chip(
                  context,
                  transfer.receiving
                      ? t('可被发现', 'Visible')
                      : t('不可被发现', 'Hidden'),
                  active: transfer.receiving,
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(kTextTabBarHeight + 4),
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(
                        key: const ValueKey('tab-send'),
                        text: t('发送', 'Send'),
                      ),
                      Tab(
                        key: const ValueKey('tab-receive'),
                        child: Badge(
                          isLabelVisible: offers.isNotEmpty,
                          label: Text('${offers.length}'),
                          child: Text(t('接收', 'Receive')),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 4,
                    child: disabled ? const LinearProgressIndicator() : null,
                  ),
                ],
              ),
            ),
          ),
          body: SafeArea(
            child: TabBarView(
              children: [
                tab('send-tab', [
                  _filesCard(context, disabled),
                  const SizedBox(height: 12),
                  _deviceCard(context, disabled),
                  const SizedBox(height: 12),
                  ..._sendAction(context, disabled),
                  if (sent.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _section(
                      context,
                      icon: Icons.upload,
                      title: t('发送记录', 'Sent'),
                      children: [
                        for (final row in sent) _transferCard(row, disabled),
                      ],
                    ),
                  ],
                ]),
                tab('receive-tab', [
                  _receiveSection(context, disabled),
                  if (received.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _section(
                      context,
                      icon: Icons.download,
                      title: t('接收记录', 'Received'),
                      children: [
                        for (final row in received)
                          _transferCard(row, disabled),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _inboxSection(context, disabled),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).hintColor),
    ),
  );

  Widget _hint(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _chip(BuildContext context, String label, {required bool active}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: active ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: active
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('transfer-message'),
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          if (_message != null)
            IconButton(
              tooltip: t('关闭', 'Dismiss'),
              icon: Icon(Icons.close, color: scheme.onErrorContainer),
              onPressed: () => setState(() => _message = null),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _offerCard(Map<String, dynamic> row, bool disabled) {
    final id = row['id'] as String;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allFiles = transfer.files[id] ?? <Map<String, dynamic>>[];
    final total = allFiles.fold<int>(0, (sum, f) => sum + (f['size'] as int));
    final shown = _visibleFiles[id] ?? 5;
    return Card(
      key: ValueKey('offer-$id'),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.move_to_inbox, color: scheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t(
                      '${row['alias'] ?? '对方设备'} 想发送 ${row['file_count']} 个文件',
                      '${row['alias'] ?? 'A device'} wants to send ${row['file_count']} files',
                    ),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (allFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${[for (final f in allFiles.take(shown)) f['name'] as String].join('、')}'
                  '${allFiles.length > shown ? ' …' : ''} · ${_bytes(total)}',
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ),
            if (allFiles.length > shown)
              TextButton(
                onPressed: () => setState(() => _visibleFiles[id] = shown + 64),
                child: Text(
                  t(
                    '显示更多文件（已显示 $shown / ${allFiles.length}），接收确认适用于整批',
                    'Show more ($shown / ${allFiles.length}); acceptance applies to the entire batch',
                  ),
                ),
              ),
            if (!transfer.receiving)
              _hint(
                context,
                t('接收已关闭，重新开启后才能接收', 'Receiving is off; enable it to accept'),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: disabled || !transfer.receiving
                      ? null
                      : () => _run(() => transfer.decide(id, true)),
                  child: Text(t('接收全部', 'Accept all')),
                ),
                OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() => transfer.decide(id, false)),
                  child: Text(t('拒绝', 'Decline')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _receiveSection(BuildContext context, bool disabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final port = transfer.ready == null
        ? null
        : (transfer.ready!['address'] as String).split(':').last;
    return _section(
      context,
      icon: Icons.wifi_tethering,
      title: t('本机接收', 'Receive on this device'),
      subtitle: transfer.receiving
          ? t(
              '附近设备可以找到本机；收到的文件需要你点接收后才会保存',
              'Nearby devices can find this one; files are saved only after you accept',
            )
          : t(
              '开启后才能被发现和收文件。手机切到后台或离开此页会停止。',
              'Enable to be found and receive. Mobile reception stops in the background or when leaving this page.',
            ),
      trailing: _chip(
        context,
        transfer.receiving
            ? t('正在接收', 'Receiving enabled')
            : t('接收已关闭', 'Receiving disabled'),
        active: transfer.receiving,
      ),
      children: [
        if (!transfer.receiving) ...[
          DropdownButtonFormField<String>(
            key: const ValueKey('discovery-interface'),
            initialValue: transfer.discoveryInterface ?? '',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t('使用的网卡', 'Network'),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  t('所有网卡（含 VPN/虚拟网卡）', 'All networks (including VPN/virtual)'),
                ),
              ),
              for (final entry in transfer.interfaces.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(
                    '${entry.value} · ${entry.key}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (transfer.discoveryInterface != null &&
                  !transfer.interfaces.containsKey(transfer.discoveryInterface))
                DropdownMenuItem(
                  value: transfer.discoveryInterface,
                  child: Text(
                    t(
                      '原网卡已断开，请重新选择',
                      'Previous network disconnected; choose again',
                    ),
                  ),
                ),
            ],
            onChanged: disabled
                ? null
                : (value) => setState(() {
                    transfer.discoveryInterface = value == '' ? null : value;
                  }),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            if (!transfer.receiving) ...[
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('listen-port'),
                  controller: _listenPort,
                  enabled: !disabled,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('接收端口', 'Receive port'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('receive-toggle'),
                style: transfer.receiving
                    ? FilledButton.styleFrom(
                        backgroundColor: scheme.surfaceContainerHighest,
                        foregroundColor: scheme.onSurface,
                      )
                    : null,
                icon: Icon(
                  transfer.receiving ? Icons.stop : Icons.wifi_tethering,
                ),
                label: Text(
                  transfer.receiving
                      ? t('停止接收', 'Stop receiving')
                      : t('开启接收', 'Enable receiving'),
                ),
                onPressed: disabled
                    ? null
                    : () => _run(
                        () => transfer.receiving
                            ? transfer.stop()
                            : _enableReceiving(),
                      ),
              ),
            ),
          ],
        ),
        FutureBuilder<String>(
          future: _nameFuture,
          builder: (context, snapshot) => snapshot.hasData
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(
                            '其他设备看到的本机名称：${snapshot.data}',
                            'Other devices see this one as: ${snapshot.data}',
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('edit-device-name'),
                        tooltip: t('修改名称', 'Rename'),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: disabled
                            ? null
                            : () => _renameDevice(snapshot.data!),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (transfer.receiving && transfer.ready != null) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(
              t('对方找不到本机？', 'Not found by the other device?'),
              style: theme.textTheme.bodyMedium,
            ),
            children: [
              _hint(
                context,
                t(
                  '在对方的「发送」页手动输入以下任一地址',
                  'Enter one of these addresses on the other device',
                ),
              ),
              for (final ip in transfer.addresses)
                Row(
                  children: [
                    Expanded(child: SelectableText('$ip:$port')),
                    IconButton(
                      tooltip: t('复制', 'Copy'),
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: '$ip:$port'),
                        );
                        _notify(t('已复制 $ip:$port', 'Copied $ip:$port'));
                      },
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _filesCard(BuildContext context, bool disabled) {
    final scheme = Theme.of(context).colorScheme;
    final visiblePaths = _allPaths ? 64 : 5;
    return _section(
      context,
      icon: Icons.photo_library_outlined,
      title: t('要发送的文件', 'Files to send'),
      subtitle: _paths.isEmpty
          ? widget.sourceLabel
          : null,
      trailing: _paths.isEmpty
          ? null
          : TextButton(
              onPressed: disabled ? null : () => _setPaths(const []),
              child: Text(t('清空', 'Clear')),
            ),
      children: [
        if (_paths.isNotEmpty)
          FutureBuilder<int>(
            future: _selectionSize,
            builder: (_, snapshot) => _hint(
              context,
              '${_paths.length} ${t('文件', 'files')} · '
              '${snapshot.hasError
                  ? t('文件不可读，请重新选择', 'Unreadable file; select again')
                  : snapshot.hasData
                  ? _bytes(snapshot.data!)
                  : t('统计大小中…', 'Calculating size…')}',
            ),
          ),
        for (final path in _paths.take(visiblePaths))
          Row(
            children: [
              Icon(
                transferImageName(path)
                    ? Icons.image_outlined
                    : Icons.insert_drive_file_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  File(path).uri.pathSegments.last,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: t('移除', 'Remove'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: disabled
                    ? null
                    : () => _setPaths(List.of(_paths)..remove(path)),
              ),
            ],
          ),
        if (_paths.length > visiblePaths)
          Align(
            alignment: Alignment.centerLeft,
            child: _allPaths
                ? Text(
                    t('共 ${_paths.length} 个文件', '${_paths.length} files total'),
                  )
                : TextButton(
                    onPressed: () => setState(() => _allPaths = true),
                    child: Text(
                      t(
                        '显示其余 ${_paths.length - visiblePaths} 个',
                        'Show ${_paths.length - visiblePaths} more',
                      ),
                    ),
                  ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.sources.isNotEmpty)
              FilledButton.tonalIcon(
                key: const ValueKey('add-from-queue'),
                icon: const Icon(Icons.playlist_add_check),
                onPressed: disabled ? null : _pickFromQueue,
                label: Text(t('从转换列表添加', 'From conversion list')),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              onPressed: disabled ? null : () => _run(_pick),
              label: Text(t('选择文件', 'Choose files')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _deviceCard(BuildContext context, bool disabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final confirmedPeer = _peer != null && transfer.isPeerConfirmed(_peer!);
    final manual =
        _manual || transfer.peers.isEmpty || _host.text.isNotEmpty;
    return _section(
      context,
      icon: Icons.devices,
      title: t('发给谁', 'Send to'),
      subtitle: transfer.discovering
          ? t('正在自动发现附近设备', 'Discovering nearby devices')
          : transfer.receiving
          ? t('自动发现已关闭', 'Discovery disabled')
          : t('尚未搜索附近设备', 'Not searching for nearby devices'),
      trailing: transfer.receiving
          ? IconButton(
              key: const ValueKey('refresh-discovery'),
              tooltip: t('重新发现', 'Discover again'),
              icon: const Icon(Icons.refresh),
              onPressed: disabled || transfer.scanning
                  ? null
                  : () => _run(() async {
                      await transfer.discover();
                      // Runs in the background; the page stays usable.
                      unawaited(transfer.scanSubnet().catchError((_) {}));
                    }),
            )
          : null,
      children: [
        // Discovery rides on reception (LocalSend answers announcements from
        // its own listener), so searching here simply turns both on.
        if (!transfer.receiving)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('start-discovery'),
              icon: const Icon(Icons.radar),
              onPressed: disabled ? null : () => _run(_enableReceiving),
              label: Text(t('搜索附近设备', 'Find nearby devices')),
            ),
          ),
        if (transfer.discoveryError != null)
          _hint(context, transferErrorText(transfer.discoveryError!)),
        if (transfer.scanning)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _hint(
                    context,
                    t('正在扫描局域网…', 'Scanning the local network…'),
                  ),
                ),
              ],
            ),
          )
        else if (transfer.receiving && transfer.peers.isEmpty)
          _hint(
            context,
            t(
              '暂未找到设备。确认对方也打开了互传；多播被网络阻止时可用 IP 直连。',
              'No devices yet. Make sure the other device has transfer open; use a direct IP if multicast is blocked.',
            ),
          ),
        for (final peer in transfer.peers)
          ListTile(
            key: ValueKey('peer-${peer['fingerprint']}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smartphone),
            title: Text(peer['alias'] as String),
            subtitle: Text(peer['address'] as String),
            selected:
                confirmedPeer && _peer!['fingerprint'] == peer['fingerprint'],
            trailing:
                confirmedPeer && _peer!['fingerprint'] == peer['fingerprint']
                ? const Icon(Icons.check_circle)
                : Text(t('选择', 'Select')),
            onTap: disabled ? null : () => _run(() => _selectPeer(peer)),
          ),
        if (!manual)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _manual = true),
              child: Text(t('输入 IP 地址', 'Enter an IP address')),
            ),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('peer-host'),
                  controller: _host,
                  enabled: !disabled,
                  onChanged: (_) => setState(() => _peer = null),
                  decoration: InputDecoration(
                    labelText: t('对方 IP 地址', 'Peer IP address'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 84,
                child: TextField(
                  key: const ValueKey('peer-port'),
                  controller: _port,
                  enabled: !disabled,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() => _peer = null),
                  decoration: InputDecoration(labelText: t('端口', 'Port')),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('connect-peer'),
                onPressed: disabled ? null : () => _run(_connect),
                child: Text(t('连接', 'Connect')),
              ),
            ],
          ),
        if (confirmedPeer)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('已选择', 'Selected'),
                        style: TextStyle(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        [
                          if (_peer!['alias'] is String)
                            _peer!['alias'] as String,
                          _peer!['address'] as String,
                        ].join(' · '),
                        style: TextStyle(color: scheme.onSecondaryContainer),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _sendAction(BuildContext context, bool disabled) {
    final confirmedPeer = _peer != null && transfer.isPeerConfirmed(_peer!);
    final blocked = _paths.isEmpty
        ? t('先添加要发送的文件', 'Add files to send first')
        : !confirmedPeer
        ? t('先选择接收设备', 'Choose a receiving device first')
        : null;
    return [
      if (_showPin)
        TextField(
          controller: _pin,
          enabled: !disabled,
          obscureText: true,
          maxLength: 128,
          decoration: InputDecoration(
            labelText: t('对方接收 PIN', 'Receiver PIN'),
          ),
        ),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          key: const ValueKey('send-files'),
          icon: const Icon(Icons.send),
          label: Text(
            _paths.isEmpty
                ? t('发送', 'Send')
                : t('发送 ${_paths.length} 个文件', 'Send ${_paths.length} files'),
          ),
          onPressed: disabled || blocked != null
              ? null
              : () => _run(() async {
                  await transfer.send(
                    _peer!,
                    _paths,
                    pin: _pin.text.isEmpty ? null : _pin.text,
                  );
                  _notify(
                    t(
                      '已开始发送，进度见下方发送记录',
                      'Sending started; see Sent below for progress',
                    ),
                  );
                }),
        ),
      ),
      Row(
        children: [
          Expanded(
            child: blocked != null && !disabled
                ? _hint(context, blocked)
                : const SizedBox.shrink(),
          ),
          if (!_showPin)
            TextButton(
              onPressed: () => setState(() => _showPin = true),
              child: Text(t('对方要求 PIN？', 'Receiver needs a PIN?')),
            ),
        ],
      ),
    ];
  }

  Widget _transferCard(Map<String, dynamic> row, bool disabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = row['id'] as String;
    final phase = row['phase'] as String;
    final send = row['direction'] == 'send';
    final allFiles = transfer.files[id] ?? <Map<String, dynamic>>[];
    final shown = _visibleFiles[id] ?? 64;
    final total = allFiles.fold<int>(0, (sum, f) => sum + (f['size'] as int));
    final moved = allFiles.fold<int>(0, (sum, f) => sum + (f['bytes'] as int));
    final complete = allFiles
        .where((f) => ['sent', 'committed'].contains(f['phase']))
        .length;
    final canRetry =
        _peer != null &&
        transfer.isPeerConfirmed(_peer!) &&
        _peer!['fingerprint'] == row['peer_fingerprint'];
    const labels = {
      'preparing': ['准备文件', 'Preparing'],
      'pending': ['等待对方确认', 'Waiting for confirmation'],
      'accepted': ['已接受', 'Accepted'],
      'transferring': ['传输中', 'Transferring'],
      'completed': ['已完成', 'Completed'],
      'failed': ['未完成', 'Failed'],
    };
    final label = labels[phase] ?? ['等待', 'Waiting'];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(send ? Icons.upload : Icons.download, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${send ? t('发送', 'Send') : t('接收', 'Receive')}'
                  '${row['alias'] != null ? ' · ${row['alias']}' : ''}'
                  ' · ${row['file_count']} ${t('文件', 'files')}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              _chip(
                context,
                t(label[0], label[1]),
                active: !['completed', 'failed'].contains(phase),
              ),
            ],
          ),
          if (row['error'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                transferErrorText(row['error'] as String),
                style: TextStyle(color: scheme.error),
              ),
            ),
          if (allFiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${t('整批进度', 'Batch progress')}: $complete/${row['file_count']} · ${_bytes(moved)} / ${_bytes(total)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: total == 0
                  ? complete / allFiles.length
                  : (moved / total).clamp(0, 1),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                t('文件明细（${allFiles.length}）', 'Files (${allFiles.length})'),
                style: theme.textTheme.bodyMedium,
              ),
              children: [
                for (final file in allFiles.take(shown))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${file['name']} · ${_bytes(file['size'] as int)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              file['error'] != null
                                  ? transferErrorText(file['error'] as String)
                                  : switch (file['phase']) {
                                      'sent' => t('已发送', 'Sent'),
                                      'committed' => t('已接收', 'Received'),
                                      'transferring' => t(
                                        '传输中',
                                        'Transferring',
                                      ),
                                      _ => t('等待', 'Waiting'),
                                    },
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        LinearProgressIndicator(
                          value: file['size'] == 0
                              ? (['sent', 'committed'].contains(file['phase'])
                                    ? 1
                                    : 0)
                              : ((file['bytes'] as int) / (file['size'] as int))
                                    .clamp(0, 1)
                                    .toDouble(),
                        ),
                      ],
                    ),
                  ),
                if (allFiles.length > shown)
                  TextButton(
                    onPressed: () =>
                        setState(() => _visibleFiles[id] = shown + 64),
                    child: Text(
                      t(
                        '显示更多文件（已显示 $shown / ${allFiles.length}）',
                        'Show more ($shown / ${allFiles.length})',
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (row['retry_available'] == true) ...[
            if (!canRetry)
              _hint(
                context,
                t(
                  '先选择原接收设备，再重试',
                  'Select the original receiver before retrying',
                ),
              ),
            TextButton(
              key: ValueKey('retry-$id'),
              onPressed: disabled || !canRetry
                  ? null
                  : () => _run(() => _retry(id)),
              child: Text(t('重试未确认成功的文件', 'Retry unacknowledged files')),
            ),
          ],
          if (!['completed', 'failed'].contains(phase))
            TextButton(
              onPressed: disabled
                  ? null
                  : () => _run(() => transfer.cancel(id)),
              child: Text(t('取消传输', 'Cancel transfer')),
            ),
        ],
      ),
    );
  }

  Widget _inboxSection(BuildContext context, bool disabled) => _section(
    context,
    icon: Icons.inbox,
    title: t('收件箱', 'Inbox'),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('refresh-inbox'),
          tooltip: t('刷新', 'Refresh'),
          icon: const Icon(Icons.refresh),
          onPressed: disabled
              ? null
              : () => _run(() async {
                  await transfer.ensureLocal();
                  await transfer.refresh();
                }),
        ),
        IconButton(
          key: const ValueKey('manage-transfer-storage'),
          tooltip: t('存储管理', 'Storage'),
          icon: const Icon(Icons.cleaning_services_outlined),
          onPressed: disabled
              ? null
              : () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => TransferStorageDialog(
                    controller: transfer,
                    errorText: transferErrorText,
                  ),
                ),
        ),
      ],
    ),
    children: [
      if (transfer.inbox.isEmpty) _empty(context, t('收件箱为空', 'Inbox is empty')),
      if (transfer.inbox.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (TransferExport.savesToGallery &&
                  transfer.inbox.values.any(
                    (r) => TransferExport.galleryName(r['name'] as String),
                  ))
                FilledButton.tonalIcon(
                  key: const ValueKey('save-all'),
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: disabled ? null : () => _run(_saveAll),
                  label: Text(t('全部存入相册', 'Save all to Photos')),
                ),
              if (transfer.inbox.values.any(
                (r) => transferImageName(r['name'] as String),
              ))
                FilledButton.tonalIcon(
                  key: const ValueKey('import-all'),
                  icon: const Icon(Icons.playlist_add),
                  onPressed: disabled ? null : () => _run(_importAll),
                  label: Text(t('全部加入转换队列', 'Queue all photos')),
                ),
              TextButton.icon(
                key: const ValueKey('clear-inbox'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: disabled ? null : _clearInbox,
                label: Text(t('清空', 'Clear')),
              ),
            ],
          ),
        ),
      for (final receipt in transfer.inbox.values)
        _receiptCard(receipt, disabled),
      if (transfer.moreInbox)
        TextButton(
          onPressed: disabled ? null : () => _run(() => transfer.loadInbox()),
          child: Text(t('加载更多', 'Load more')),
        ),
    ],
  );

  Widget _receiptCard(Map<String, dynamic> row, bool disabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = row['id'] as String;
    final name = row['name'] as String;
    final image = transferImageName(name);
    final movie = _pairedMovie(row);
    final live = isLivePhotoZip(name) || movie != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (live || image)
                _thumbnail(
                  row,
                  live
                      ? Icons.motion_photos_on_outlined
                      : Icons.image_outlined,
                )
              else
                Icon(
                  Icons.insert_drive_file_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, overflow: TextOverflow.ellipsis),
                    Text(
                      '${live ? '${t('实况照片', 'Live Photo')} · ' : ''}'
                      '${_bytes(row['size'] as int)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            children: [
              if (image)
                TextButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 18),
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          final ack = await transfer.importReceipt(id);
                          _notify(switch (ack.status) {
                            TransferIntakeStatus.added => t(
                              '已加入转换队列',
                              'Added to conversion queue',
                            ),
                            TransferIntakeStatus.duplicate => t(
                              '已在转换队列中',
                              'Already in conversion queue',
                            ),
                            _ => t(
                              '未加入队列，收件箱文件已保留',
                              'Not added; inbox file retained',
                            ),
                          });
                        }),
                  label: Text(t('加入转换队列', 'Add to conversion queue')),
                ),
              if (TransferExport.savesToGallery &&
                  TransferExport.galleryName(name))
                TextButton.icon(
                  key: ValueKey('save-$id'),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          await TransferExport.saveToGallery(
                            transfer,
                            row,
                            movie: movie,
                          );
                          _notify(
                            !live
                                ? t('已存入相册', 'Saved to Photos')
                                : Platform.isIOS
                                ? t('已存为实况照片', 'Saved as a Live Photo')
                                : t(
                                    '已存入相册（照片 + 视频）',
                                    'Saved to the gallery (photo + video)',
                                  ),
                          );
                        }),
                  label: Text(t('存入相册', 'Save to Photos')),
                ),
              TextButton.icon(
                icon: Icon(
                  TransferExport.viaShareSheet
                      ? Icons.ios_share
                      : Icons.save_alt,
                  size: 18,
                ),
                onPressed: disabled
                    ? null
                    : () => _run(() async {
                        if (await TransferExport.save(transfer, id, name) &&
                            !TransferExport.viaShareSheet) {
                          _notify(t('已导出', 'Exported'));
                        }
                      }),
                label: Text(
                  TransferExport.viaShareSheet
                      ? t('分享或存储', 'Share or save')
                      : live && PlatformX.isDesktop
                      ? t('导出为 .pvt', 'Export as .pvt')
                      : t('导出文件', 'Export file'),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: disabled
                    ? null
                    : () => _run(() async {
                        if (await _confirmDelete(name)) {
                          await transfer.deleteReceipt(id);
                        }
                      }),
                label: Text(t('删除', 'Delete')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Owns its text controller, so it outlives the dialog's exit animation.
class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.current, required this.model});
  final String current, model;
  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final _field = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('本机名称', 'Device name')),
    content: TextField(
      key: const ValueKey('device-name-field'),
      controller: _field,
      autofocus: true,
      maxLength: 64,
      decoration: InputDecoration(
        helperText: t(
          '留空则使用型号：${widget.model}',
          'Leave empty to use the model: ${widget.model}',
        ),
      ),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('取消', 'Cancel')),
      ),
      FilledButton(
        key: const ValueKey('save-device-name'),
        onPressed: () => Navigator.pop(context, _field.text),
        child: Text(t('保存', 'Save')),
      ),
    ],
  );
}
