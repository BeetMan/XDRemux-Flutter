part of 'transfer_page.dart';

/// The receive tab, incoming offers, transfer cards and the inbox.
extension _ReceiveTab on _TransferPageState {
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
      _update(() {
        _nameFuture = TransferController.deviceName();
      });
      // The name is announced by the running listener; restart it.
      if (transfer.receiving) {
        await transfer.stop();
        await _enableReceiving();
      }
    });
  }

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
                onPressed: () => _update(() => _visibleFiles[id] = shown + 64),
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
                : (value) => _update(() {
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
                        _update(() => _visibleFiles[id] = shown + 64),
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
      // A loose Live Photo's MOV belongs to its still's card.
      for (final receipt in transfer.inbox.values)
        if (!_isPairedMovie(receipt)) _receiptCard(receipt, disabled),
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
                        var saved = await TransferExport.save(transfer, id, name);
                        if (saved && movie != null) {
                          saved = await TransferExport.save(
                            transfer,
                            movie['id'] as String,
                            movie['name'] as String,
                          );
                        }
                        if (saved && !TransferExport.viaShareSheet) {
                          _notify(t('已导出', 'Exported'));
                        }
                      }),
                label: Text(
                  TransferExport.viaShareSheet
                      ? t('分享或存储', 'Share or save')
                      : isLivePhotoZip(name) && PlatformX.isDesktop
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
                          if (movie != null) {
                            await transfer.deleteReceipt(movie['id'] as String);
                          }
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
