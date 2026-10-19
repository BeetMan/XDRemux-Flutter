import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'l10n/l10n.dart';
import 'services/transfer/transfer_controller.dart';
import 'services/transfer/transfer_export.dart';
import 'services/transfer/transfer_models.dart';

String transferErrorText(String code) => switch (code) {
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
String _bytes(int n) =>
    n >= 1024 * 1024 ? '${(n / (1024 * 1024)).toStringAsFixed(1)} MB' : '$n B';
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
  bool _working = false, _canLeave = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    transfer = widget.controller ?? TransferController.instance;
    _paths = List.of(widget.initialPaths);
    _selectionSize = _measure(_paths);
    transfer.addListener(_changed);
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

  Future<void> _connect() async {
    final peer = await transfer.probe(
      _host.text,
      int.tryParse(_port.text) ?? 0,
    );
    if (!mounted) return;
    final fp = peer['fingerprint'] as String;
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
                  Text(peer['address'] as String),
                  const SizedBox(height: 12),
                  Text(
                    t(
                      '在对方设备核对完整指纹，确认后才发送文件清单和内容。',
                      'Compare the complete fingerprint on the other device before sending file metadata or content.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(_fingerprint(fp)),
                  if (transfer.trusted.contains(fp.toUpperCase()))
                    Text(
                      t(
                        '此指纹曾被你记住',
                        'You previously remembered this fingerprint',
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

  Future<void> _pick() async {
    if (Platform.isAndroid) await transfer.stop();
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final paths = result.map((f) => f.path).whereType<String>().toList();
    if (paths.length != result.length) {
      throw const TransferException('invalid_input');
    }
    if (mounted) {
      setState(() {
        _paths = paths;
        _selectionSize = _measure(paths);
      });
    }
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
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  '开启接收后，对方可通过下方地址连接。手机仅在前台接收；切后台或离开此页会停止。',
                  'Enable receiving to connect at the addresses below. Mobile reception stops in the background or when leaving this page.',
                ),
              ),
              if (disabled) const LinearProgressIndicator(),
              if (_message != null || transfer.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _message ?? transferErrorText(transfer.error!),
                    key: const ValueKey('transfer-message'),
                  ),
                ),
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
                  Text(
                    transfer.receiving
                        ? t('正在接收', 'Receiving enabled')
                        : t('接收已关闭', 'Receiving disabled'),
                  ),
                ],
              ),
              if (transfer.receiving && transfer.ready != null) ...[
                const SizedBox(height: 8),
                for (final ip in transfer.addresses)
                  SelectableText(
                    '$ip:${(transfer.ready!['address'] as String).split(':').last}',
                  ),
                const SizedBox(height: 8),
                Text(t('本机证书指纹', 'This device fingerprint')),
                SelectableText(
                  _fingerprint(transfer.ready!['fingerprint'] as String),
                ),
              ],
              const Divider(height: 32),
              Text(
                t('发送文件', 'Send files'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (widget.sourceLabel != null) Text(widget.sourceLabel!),
              FutureBuilder<int>(
                future: _selectionSize,
                builder: (_, snapshot) => Text(
                  '${_paths.length} ${t('文件', 'files')} · '
                  '${snapshot.hasError
                      ? t('文件不可读，请重新选择', 'Unreadable file; select again')
                      : snapshot.hasData
                      ? _bytes(snapshot.data!)
                      : t('统计大小中…', 'Calculating size…')}',
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 230,
                    child: TextField(
                      key: const ValueKey('peer-host'),
                      controller: _host,
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
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() => _peer = null),
                      decoration: InputDecoration(
                        labelText: t('对方端口', 'Peer port'),
                      ),
                    ),
                  ),
                  OutlinedButton(
                    key: const ValueKey('connect-peer'),
                    onPressed: disabled ? null : () => _run(_connect),
                    child: Text(t('连接并核对', 'Connect and verify')),
                  ),
                ],
              ),
              if (_peer != null)
                Text(t('已确认设备身份', 'Device identity confirmed')),
              TextField(
                controller: _pin,
                obscureText: true,
                maxLength: 128,
                decoration: InputDecoration(
                  labelText: t('对方接收 PIN（如有）', 'Receiver PIN (if required)'),
                ),
              ),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: disabled ? null : () => _run(_pick),
                    child: Text(t('选择文件', 'Choose files')),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('send-files'),
                    icon: const Icon(Icons.send),
                    label: Text(t('发送所列文件', 'Send listed files')),
                    onPressed: disabled || _peer == null || _paths.isEmpty
                        ? null
                        : () => _run(() async {
                            await transfer.send(
                              _peer!,
                              _paths,
                              pin: _pin.text.isEmpty ? null : _pin.text,
                            );
                            if (mounted) {
                              setState(
                                () => _message = t(
                                  '发送任务已建立',
                                  'Send task started',
                                ),
                              );
                            }
                          }),
                  ),
                ],
              ),
              for (final path in _paths.take(64))
                Text(File(path).uri.pathSegments.last),
              if (_paths.length > 64)
                Text(
                  t('共 ${_paths.length} 个文件', '${_paths.length} files total'),
                ),
              const Divider(height: 32),
              Text(
                t('传输记录', 'Transfers'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final row in transfer.transfers.values)
                _transferCard(row, disabled),
              const Divider(height: 32),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('收件箱', 'Inbox'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('refresh-inbox'),
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await transfer.ensureLocal();
                            await transfer.refresh();
                          }),
                    child: Text(t('刷新', 'Refresh')),
                  ),
                ],
              ),
              Text(
                t(
                  '原件保存在应用私有收件箱。导入转换队列和导出会另建副本，请预留额外空间。',
                  'Originals stay in the private inbox. Queue import and export create extra copies; allow additional space.',
                ),
              ),
              for (final receipt in transfer.inbox.values)
                _receiptCard(receipt, disabled),
              if (transfer.moreInbox)
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() => transfer.loadInbox()),
                  child: Text(t('加载更多', 'Load more')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transferCard(Map<String, dynamic> row, bool disabled) {
    final id = row['id'] as String;
    final phase = row['phase'] as String;
    final pending = phase == 'pending' && row['direction'] == 'receive';
    const labels = {
      'preparing': ['准备文件', 'Preparing'],
      'pending': ['等待确认', 'Waiting for confirmation'],
      'accepted': ['已接受', 'Accepted'],
      'transferring': ['传输中', 'Transferring'],
      'completed': ['已完成', 'Completed'],
      'failed': ['未完成', 'Failed'],
    };
    final label = labels[phase] ?? ['等待', 'Waiting'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${row['direction'] == 'send' ? t('发送', 'Send') : t('接收', 'Receive')} · ${t(label[0], label[1])} · ${row['file_count']} ${t('文件', 'files')}',
            ),
            if (row['alias'] != null) Text(row['alias'] as String),
            if (pending && row['peer_fingerprint'] != null)
              SelectableText(_fingerprint(row['peer_fingerprint'] as String)),
            if (row['error'] != null)
              Text(transferErrorText(row['error'] as String)),
            for (final file
                in transfer.files[id] ?? <Map<String, dynamic>>[]) ...[
              Text('${file['name']} · ${_bytes(file['size'] as int)}'),
              LinearProgressIndicator(
                value: file['size'] == 0
                    ? (['sent', 'committed'].contains(file['phase']) ? 1 : 0)
                    : ((file['bytes'] as int) / (file['size'] as int))
                          .clamp(0, 1)
                          .toDouble(),
              ),
            ],
            if ((row['file_count'] as int) > (transfer.files[id]?.length ?? 0))
              Text(
                t(
                  '仅显示前 64 项，确认将接收整批文件',
                  'Showing first 64; acceptance applies to the entire batch',
                ),
              ),
            if (pending)
              Wrap(
                spacing: 12,
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
              )
            else if (!['completed', 'failed'].contains(phase))
              TextButton(
                onPressed: disabled
                    ? null
                    : () => _run(() => transfer.cancel(id)),
                child: Text(t('取消传输', 'Cancel transfer')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _receiptCard(Map<String, dynamic> row, bool disabled) {
    final id = row['id'] as String;
    final name = row['name'] as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            Text(_bytes(row['size'] as int)),
            Text(
              row['peer_hash_present'] == true
                  ? t('长度与对端哈希已核对', 'Length and peer hash verified')
                  : t('长度已核对；无对端哈希', 'Length verified; peer supplied no hash'),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (transferImageName(name))
                  TextButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            final ack = await transfer.importReceipt(id);
                            if (mounted) {
                              setState(
                                () => _message = switch (ack.status) {
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
                                },
                              );
                            }
                          }),
                    child: Text(t('加入转换队列', 'Add to conversion queue')),
                  ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          if (await TransferExport.save(transfer, id, name) &&
                              mounted) {
                            setState(
                              () => _message = t(
                                '文件已导出并校验',
                                'File exported and verified',
                              ),
                            );
                          }
                        }),
                  child: Text(t('导出文件', 'Export file')),
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          if (await _confirmDelete(name)) {
                            await transfer.deleteReceipt(id);
                          }
                        }),
                  child: Text(t('删除', 'Delete')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
