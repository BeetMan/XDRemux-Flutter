import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'l10n/l10n.dart';
import 'platform_x.dart';
import 'services/transfer/transfer_controller.dart';
import 'services/transfer/transfer_export.dart';
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
  'identity_mismatch' => t(
    '设备身份发生变化，请重新核对指纹',
    'Device identity changed; confirm its fingerprint again',
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

String _fingerprint(String value) =>
    RegExp('.{1,8}').allMatches(value).map((m) => m.group(0)).join(' ');

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    this.controller,
    this.initialPaths = const [],
    this.sourceLabel,
  });
  final TransferController? controller;
  final List<String> initialPaths;
  final String? sourceLabel;
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  late final TransferController transfer;
  final _host = TextEditingController(),
      _port = TextEditingController(text: '53319');
  final _listenPort = TextEditingController(text: '53319'),
      _pin = TextEditingController();
  late List<String> _paths;
  Future<int>? _selectionSize;
  Map<String, dynamic>? _peer;
  bool _working = false, _canLeave = false, _allPaths = false;
  String? _message;
  final Map<String, int> _visibleFiles = {};
  @override
  void initState() {
    super.initState();
    transfer = widget.controller ?? TransferController.instance;
    _paths = _expandBundles(widget.initialPaths);
    _selectionSize = _measure(_paths);
    transfer.addListener(_changed);
    transfer.enumerateInterfaces().catchError((_) {});
  }

  /// A Live Photo output is a `.pvt` folder (still, MOV, metadata.plist).
  /// LocalSend moves files, so send the still and the MOV inside it.
  static List<String> _expandBundles(List<String> paths) => [
    for (final path in paths)
      if (FileSystemEntity.isDirectorySync(path))
        ...(Directory(path)
            .listSync(followLinks: false)
            .whereType<File>()
            .map((f) => f.path)
            .where((p) {
              final name = p.split(Platform.pathSeparator).last;
              return !name.startsWith('.') && name != 'metadata.plist';
            })
            .toList()
          ..sort())
      else
        path,
  ];

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

  Future<void> _connect({Map<String, dynamic>? expected}) async {
    setState(() => _peer = null);
    final peer = await transfer.probe(
      _host.text,
      int.tryParse(_port.text) ?? 0,
    );
    if (!mounted) return;
    final fp = peer['fingerprint'] as String;
    if (expected != null && fp != expected['fingerprint']) {
      throw const TransferException('identity_mismatch');
    }
    var remember = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('核对设备身份', 'Confirm device identity')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (peer['alias'] is String)
                    Text(
                      peer['alias'] as String,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  Text(peer['address'] as String),
                  const SizedBox(height: 12),
                  Text(
                    t(
                      '在对方设备核对完整指纹，确认后才发送文件清单和内容。',
                      'Compare the complete fingerprint on the other device before sending file metadata or content.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _fingerprintBox(context, fp),
                  if (transfer.trusted.contains(fp.toUpperCase()))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        t(
                          '此指纹曾被你记住',
                          'You previously remembered this fingerprint',
                        ),
                      ),
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: remember,
                    title: Text(t('记住此指纹', 'Remember this fingerprint')),
                    onChanged: (v) => update(() => remember = v ?? false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              key: const ValueKey('confirm-peer'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('已核对', 'Confirmed')),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await transfer.confirmPeer(peer, remember: remember);
      if (mounted) setState(() => _peer = peer);
    }
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
            '已收到成功回执的文件不会重发。回执丢失时，对端可能已经保存，重试可能产生副本。源文件必须与上次准备的内容一致。',
            'Acknowledged files are excluded. A lost acknowledgement may leave an existing copy on the receiver. Retried sources must match the previous prepared content.',
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
    if (Platform.isAndroid || PlatformX.isOhos) await transfer.stop();
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final paths = result.map((f) => f.path).whereType<String>().toList();
    if (paths.length != result.length) {
      throw const TransferException('invalid_input');
    }
    if (mounted) _setPaths(paths);
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
    final history = [
      for (final row in transfer.transfers.values)
        if (!offers.contains(row)) row,
    ];
    final error =
        _message ??
        (transfer.error == null ? null : transferErrorText(transfer.error!));
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('局域网互传', 'Local transfer')),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: disabled ? null : _leave,
          ),
          actions: [
            IconButton(
              tooltip: t('忘记设备指纹', 'Forget fingerprints'),
              icon: const Icon(Icons.key_off),
              onPressed: disabled ? null : () => _run(transfer.forgetPeers),
            ),
          ],
          bottom: disabled
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(4),
                  child: LinearProgressIndicator(),
                )
              : null,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = constraints.maxWidth > 792
                  ? (constraints.maxWidth - 760) / 2
                  : 16.0;
              return SingleChildScrollView(
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
                    _receiveSection(context, disabled),
                    const SizedBox(height: 12),
                    _sendSection(context, disabled),
                    const SizedBox(height: 12),
                    _section(
                      context,
                      icon: Icons.swap_vert,
                      title: t('传输记录', 'Transfers'),
                      subtitle: t(
                        '本次开启以来的发送和接收',
                        'Sent and received since transfer was opened',
                      ),
                      children: [
                        if (history.isEmpty)
                          _empty(context, t('暂无传输', 'No transfers yet')),
                        for (final row in history) _transferCard(row, disabled),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _inboxSection(context, disabled),
                  ],
                ),
              );
            },
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

  Widget _step(BuildContext context, String number, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              number,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.titleSmall),
        ],
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

  Widget _fingerprintBox(BuildContext context, String fingerprint) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        _fingerprint(fingerprint),
        style: const TextStyle(fontFamily: 'monospace', height: 1.5),
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
            if (row['peer_fingerprint'] != null) ...[
              const SizedBox(height: 8),
              Text(
                t(
                  '对方证书指纹，可在对方设备上核对',
                  'Sender fingerprint; compare on the sender',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 4),
              _fingerprintBox(context, row['peer_fingerprint'] as String),
            ],
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
    final scheme = Theme.of(context).colorScheme;
    final port = transfer.ready == null
        ? null
        : (transfer.ready!['address'] as String).split(':').last;
    return _section(
      context,
      icon: Icons.wifi_tethering,
      title: t('本机接收', 'Receive on this device'),
      subtitle: transfer.receiving
          ? t(
              '同一网络中的设备现在可以找到本机并发送文件',
              'Devices on this network can now find this device and send files',
            )
          : t(
              '开启后其他设备才能发现本机，同时开启自动发现。手机切到后台或离开此页会停止。',
              'Enable to be discoverable and to discover others. Mobile reception stops in the background or when leaving this page.',
            ),
      trailing: _chip(
        context,
        transfer.receiving
            ? t('正在接收', 'Receiving enabled')
            : t('接收已关闭', 'Receiving disabled'),
        active: transfer.receiving,
      ),
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('discovery-interface'),
          initialValue: transfer.discoveryInterface ?? '',
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t('接收和自动发现使用的网卡', 'Network for receiving and discovery'),
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
          onChanged: disabled || transfer.receiving
              ? null
              : (value) => setState(() {
                  transfer.discoveryInterface = value == '' ? null : value;
                }),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 130,
              child: TextField(
                key: const ValueKey('listen-port'),
                controller: _listenPort,
                enabled: !disabled && !transfer.receiving,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('接收端口', 'Receive port'),
                ),
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('receive-toggle'),
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
                          : transfer.enableReceiving(
                              port: int.tryParse(_listenPort.text) ?? 0,
                            ),
                    ),
            ),
          ],
        ),
        if (transfer.receiving && transfer.ready != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(
                    '对方找不到本机时，可在对方输入以下地址',
                    'If the other device cannot find this one, enter an address below there',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
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
                const SizedBox(height: 8),
                Text(
                  t('本机证书指纹', 'This device fingerprint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                _fingerprintBox(
                  context,
                  transfer.ready!['fingerprint'] as String,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _sendSection(BuildContext context, bool disabled) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final confirmedPeer = _peer != null && transfer.isPeerConfirmed(_peer!);
    final visiblePaths = _allPaths ? 64 : 5;
    final blocked = _paths.isEmpty
        ? t('先选择要发送的文件', 'Choose files to send first')
        : !confirmedPeer
        ? t('先选择并核对接收设备', 'Choose and verify a receiving device first')
        : null;
    return _section(
      context,
      icon: Icons.send,
      title: t('发送文件', 'Send files'),
      subtitle: widget.sourceLabel,
      children: [
        _step(context, '1', t('选择文件', 'Choose files')),
        Row(
          children: [
            Expanded(
              child: FutureBuilder<int>(
                future: _selectionSize,
                builder: (_, snapshot) => Text(
                  _paths.isEmpty
                      ? t('尚未选择文件', 'No files selected')
                      : '${_paths.length} ${t('文件', 'files')} · '
                            '${snapshot.hasError
                                ? t('文件不可读，请重新选择', 'Unreadable file; select again')
                                : snapshot.hasData
                                ? _bytes(snapshot.data!)
                                : t('统计大小中…', 'Calculating size…')}',
                ),
              ),
            ),
            if (_paths.isNotEmpty)
              TextButton(
                onPressed: disabled ? null : () => _setPaths(const []),
                child: Text(t('清空', 'Clear')),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              onPressed: disabled ? null : () => _run(_pick),
              label: Text(t('选择文件', 'Choose files')),
            ),
          ],
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
        _step(context, '2', t('选择接收设备', 'Choose a receiving device')),
        Row(
          children: [
            Expanded(
              child: Text(
                transfer.discovering
                    ? t('自动发现已开启', 'Discovery enabled')
                    : transfer.receiving
                    ? t('自动发现已关闭', 'Discovery disabled')
                    : t(
                        '开启本机接收后会自动发现附近设备',
                        'Enable receiving to discover nearby devices',
                      ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (transfer.receiving)
              TextButton(
                key: const ValueKey('refresh-discovery'),
                onPressed: disabled ? null : () => _run(transfer.discover),
                child: Text(t('重新发现', 'Discover again')),
              ),
          ],
        ),
        if (transfer.discoveryError != null)
          _hint(context, transferErrorText(transfer.discoveryError!)),
        if (transfer.receiving && transfer.peers.isEmpty)
          _hint(
            context,
            t(
              '暂未找到设备。多播可能被网络阻止；可使用下方 IP/端口直连。',
              'No devices yet. Multicast may be blocked; direct IP/port remains available.',
            ),
          ),
        for (final peer in transfer.peers)
          ListTile(
            key: ValueKey('peer-${peer['fingerprint']}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices),
            title: Text(peer['alias'] as String),
            subtitle: Text(peer['address'] as String),
            selected:
                confirmedPeer && _peer!['fingerprint'] == peer['fingerprint'],
            trailing:
                confirmedPeer && _peer!['fingerprint'] == peer['fingerprint']
                ? const Icon(Icons.verified_user)
                : Text(t('核对', 'Verify')),
            onTap: disabled ? null : () => _run(() => _selectPeer(peer)),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 230,
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
            SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('peer-port'),
                controller: _port,
                enabled: !disabled,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _peer = null),
                decoration: InputDecoration(labelText: t('对方端口', 'Peer port')),
              ),
            ),
            OutlinedButton(
              key: const ValueKey('connect-peer'),
              onPressed: disabled ? null : () => _run(_connect),
              child: Text(t('连接并核对', 'Connect and verify')),
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
                Icon(Icons.verified_user, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('已确认设备身份', 'Device identity confirmed'),
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
        const SizedBox(height: 8),
        _step(context, '3', t('发送', 'Send')),
        TextField(
          controller: _pin,
          enabled: !disabled,
          obscureText: true,
          maxLength: 128,
          decoration: InputDecoration(
            labelText: t('对方接收 PIN（如有）', 'Receiver PIN (if required)'),
          ),
        ),
        FilledButton.icon(
          key: const ValueKey('send-files'),
          icon: const Icon(Icons.send),
          label: Text(t('发送所列文件', 'Send listed files')),
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
                      '发送任务已建立，进度见传输记录',
                      'Send task started; see Transfers for progress',
                    ),
                  );
                }),
        ),
        if (blocked != null && !disabled) _hint(context, blocked),
      ],
    );
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
                  '先连接并核对原接收设备，再重试',
                  'Connect and verify the original receiver before retrying',
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
      _hint(
        context,
        t(
          '原件保存在应用私有收件箱。导入转换队列和导出会另建副本，请预留额外空间。',
          'Originals stay in the private inbox. Queue import and export create extra copies; allow additional space.',
        ),
      ),
      if (transfer.inbox.isEmpty) _empty(context, t('收件箱为空', 'Inbox is empty')),
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
              Icon(
                image ? Icons.image_outlined : Icons.insert_drive_file_outlined,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, overflow: TextOverflow.ellipsis),
                    Text(
                      '${_bytes(row['size'] as int)} · '
                      '${row['peer_hash_present'] == true ? t('长度与对端哈希已核对', 'Length and peer hash verified') : t('长度已核对；无对端哈希', 'Length verified; peer supplied no hash')}',
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
                          _notify(t('文件已导出并校验', 'File exported and verified'));
                        }
                      }),
                label: Text(
                  TransferExport.viaShareSheet
                      ? t('分享或存储', 'Share or save')
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
