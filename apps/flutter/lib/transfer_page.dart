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

part 'transfer_page_receive.dart';
part 'transfer_page_send.dart';

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

  Future<void> _enableReceiving() =>
      transfer.enableReceiving(port: int.tryParse(_listenPort.text) ?? 0);

  final Map<String, String> _bundleZips = {};
  final Map<String, Future<Uint8List?>> _previews = {};

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

  /// setState for the tab extensions in the part files.
  void _update(VoidCallback change) => setState(change);

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
