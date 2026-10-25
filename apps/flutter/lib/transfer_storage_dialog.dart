import 'dart:async';
import 'package:flutter/material.dart';
import 'l10n/l10n.dart';
import 'services/transfer/transfer_controller.dart';
import 'services/transfer/transfer_storage.dart';

class TransferStorageDialog extends StatefulWidget {
  const TransferStorageDialog({
    super.key,
    required this.controller,
    required this.errorText,
  });
  final TransferController controller;
  final String Function(String code) errorText;
  @override
  State<TransferStorageDialog> createState() => _TransferStorageDialogState();
}

class _TransferStorageDialogState extends State<TransferStorageDialog> {
  TransferStorageSnapshot? _plan;
  TransferStorageCleanup? _last;
  final _selected = <String>{}, _unknown = <String>{};
  bool _busy = false;
  String? _error;

  String _errorText(String code) => switch (code) {
    'io' => t(
      '清理未完成，请刷新并检查剩余项目后重试',
      'Cleanup incomplete; refresh and review remaining items before retrying',
    ),
    'source_changed' => t(
      '文件状态已变化，已保留；请刷新后重新核对',
      'File state changed; retained. Refresh and review again',
    ),
    'checksum_mismatch' || 'truncated' || 'unsafe_storage' => t(
      '无法核对文件，已保留；请检查后重试',
      'File could not be verified; retained. Review before retrying',
    ),
    _ => widget.errorText(code),
  };

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await widget.controller.inspectStorage();
      if (!mounted) return;
      setState(() {
        if (_plan?.runtimeId != plan.runtimeId) _unknown.clear();
        _plan = plan;
        _selected.removeWhere(
          (id) => !plan.items.any(
            (item) => item.id == id && item.canClean && !_unknown.contains(id),
          ),
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _plan = null;
          _error = _errorText(TransferController.code(error));
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clean() async {
    final plan = _plan;
    if (_busy || plan == null || _selected.isEmpty) return;
    final ids = Set<String>.of(_selected);
    final bytes = plan.items
        .where((item) => ids.contains(item.id))
        .fold<int>(0, (sum, item) => sum + item.bytes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('确认清理', 'Confirm cleanup')),
        content: Text(
          t(
            '删除所选 ${ids.length} 项，文件内容共 ${transferStorageBytes(bytes)}。已导出的文件和队列接管的副本会保留。',
            'Delete ${ids.length} selected items (${transferStorageBytes(bytes)} of file contents). Exported files and queue-owned copies are retained.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            key: const ValueKey('confirm-storage-clean'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('删除所选', 'Delete selected')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.controller.cleanStorage(plan, ids);
      if (!mounted) return;
      setState(() {
        _last = result;
        _unknown.addAll(
          result.failed.entries
              .where((entry) => entry.value == 'outcome_unknown')
              .map((entry) => entry.key),
        );
        _selected
          ..clear()
          ..addAll(result.failed.keys.where((id) => !_unknown.contains(id)));
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _errorText(TransferController.code(error)));
      }
    } finally {
      if (mounted) {
        if (!widget.controller.running || widget.controller.stopping) {
          // Home/close may have stopped the service while cleanup was awaited.
          // An automatic refresh must not start a replacement runtime.
          setState(() {
            _busy = false;
            _plan = null;
            _selected.clear();
            _error ??= _errorText('closed');
          });
        } else {
          final error = _error;
          await _refresh();
          if (mounted && error != null) setState(() => _error = error);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(t('传输存储管理', 'Transfer storage')),
        content: SizedBox(
          width: 560,
          height: MediaQuery.sizeOf(context).height * .55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(_error!, key: const ValueKey('storage-error')),
              if (plan != null) ...[
                Text(
                  t(
                    '收件箱：${plan.countFor('inbox')} 个文件 · ${transferStorageBytes(plan.bytesFor('inbox'))}',
                    'Inbox: ${plan.countFor('inbox')} files · ${transferStorageBytes(plan.bytesFor('inbox'))}',
                  ),
                ),
                Text(
                  t(
                    '导入副本：${plan.countFor('copy')} 项 · ${transferStorageBytes(plan.bytesFor('copy'))}',
                    'Import copies: ${plan.countFor('copy')} items · ${transferStorageBytes(plan.bytesFor('copy'))}',
                  ),
                ),
                Text(
                  t(
                    '按已识别的文件内容统计。队列接管或无法核对的副本会保留。',
                    'Counts recognized file contents. Queue-owned or unverifiable copies are retained.',
                  ),
                ),
                if (_last != null)
                  Text(
                    t(
                      '已清理 ${_last!.deleted.length} 项，未完成 ${_last!.failed.length} 项',
                      'Removed ${_last!.deleted.length}; incomplete ${_last!.failed.length}',
                    ),
                    key: const ValueKey('storage-result'),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: plan.items.length,
                    itemBuilder: (context, index) {
                      final item = plan.items[index];
                      final unknown = _unknown.contains(item.id);
                      final label = item.reason == 'queue'
                          ? t('队列保留', 'Retained by queue')
                          : item.reason != null
                          ? t('无法核对，保留', 'Unverifiable; retained')
                          : item.kind == 'inbox'
                          ? t('收件原件', 'Inbox original')
                          : t('未入队副本', 'Unused import copy');
                      return CheckboxListTile(
                        key: ValueKey('storage-${item.id}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          item.reason == 'unknown'
                              ? t('无法核对的副本', 'Unverifiable copy')
                              : item.signature == 'empty-trash'
                              ? t('待完成的清理', 'Pending cleanup')
                              : item.name,
                        ),
                        subtitle: Text(
                          unknown
                              ? t(
                                  '结果未确认，请重新打开互传页后核对',
                                  'Result unknown; reopen transfer and review',
                                )
                              : '$label · ${transferStorageBytes(item.bytes)}${_last?.failed[item.id] == null ? '' : '\n${_errorText(_last!.failed[item.id]!)}'}',
                        ),
                        value: _selected.contains(item.id),
                        onChanged: _busy || !item.canClean || unknown
                            ? null
                            : (checked) => setState(() {
                                if (checked == true) {
                                  _selected.add(item.id);
                                } else {
                                  _selected.remove(item.id);
                                }
                              }),
                      );
                    },
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(t('关闭', 'Close')),
          ),
          TextButton(
            key: const ValueKey('refresh-storage'),
            onPressed: _busy ? null : _refresh,
            child: Text(t('刷新', 'Refresh')),
          ),
          FilledButton(
            key: const ValueKey('clean-storage'),
            onPressed: _busy || plan == null || _selected.isEmpty
                ? null
                : _clean,
            child: Text(
              _last?.failed.isNotEmpty == true && _selected.isNotEmpty
                  ? t('重试所选', 'Retry selected')
                  : t('清理所选', 'Clean selected'),
            ),
          ),
        ],
      ),
    );
  }
}
