part of 'transfer_page.dart';

/// The send tab: files, the receiving device and the send action.
extension _SendTab on _TransferPageState {
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
                    onPressed: () => _update(() => _allPaths = true),
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
              key: const ValueKey('pick-photos'),
              icon: const Icon(Icons.photo_library_outlined),
              onPressed: disabled ? null : () => _run(() => _pick(media: true)),
              label: Text(t('选择照片', 'Choose photos')),
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
              onPressed: () => _update(() => _manual = true),
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
                  onChanged: (_) => _update(() => _peer = null),
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
                  onChanged: (_) => _update(() => _peer = null),
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
              onPressed: () => _update(() => _showPin = true),
              child: Text(t('对方要求 PIN？', 'Receiver needs a PIN?')),
            ),
        ],
      ),
    ];
  }
}
