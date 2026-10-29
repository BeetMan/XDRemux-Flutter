import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'transfer_copy.dart';
import 'transfer_models.dart';
import 'transfer_queue.dart';
import 'transfer_service.dart';

final _bucket = RegExp(
  r'^transfer-(?:trash-)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

class TransferStorageItem {
  const TransferStorageItem({
    required this.id,
    required this.name,
    required this.bytes,
    required this.kind,
    required this.signature,
    this.reason,
    this.hash,
  });
  final String id, name, kind, signature;
  final int bytes;
  final String? reason, hash;
  bool get canClean => reason == null;
}

class TransferStorageSnapshot {
  TransferStorageSnapshot(this.runtimeId, Iterable<TransferStorageItem> items)
    : items = List.unmodifiable(items);
  final String runtimeId;
  final List<TransferStorageItem> items;
  int bytesFor(String kind) => items
      .where((item) => item.kind == kind)
      .fold(0, (sum, item) => sum + item.bytes);
  int countFor(String kind) => items.where((item) => item.kind == kind).length;
}

class TransferStorageCleanup {
  final Set<String> deleted = {};
  final Map<String, String> failed = {};
}

String transferStorageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _normalized(String value) {
  final path = File(value).absolute.path.replaceAll('\\', '/');
  return Platform.isWindows ? path.toLowerCase() : path;
}

Future<bool> _plain(String path, FileSystemEntityType type) async =>
    await FileSystemEntity.type(path, followLinks: false) == type;

// A lenient checkpoint loader is unsuitable for authorizing deletion. Both the
// published checkpoint and a pending atomic-save file must be fully readable.
Future<Set<String>?> _protected(String root, Set<String> retained) async {
  final paths = retained.map(_normalized).toSet();
  for (final suffix in ['', '.tmp']) {
    final file = File('$root/xdremux_checkpoint.jsonl$suffix');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file || suffix == '.tmp') return null;
    var header = false;
    var declared = 0, observed = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final row = jsonDecode(line) as Map;
        if (!header) {
          if (row['type'] != 'header' ||
              row['totalJobs'] is! int ||
              row['totalJobs'] < 0) {
            return null;
          }
          declared = row['totalJobs'] as int;
          header = true;
        } else {
          if (row['type'] != 'item' ||
              row['inputPath'] is! String ||
              (row['inputPath'] as String).isEmpty) {
            return null;
          }
          paths.add(_normalized(row['inputPath'] as String));
          observed++;
        }
      }
      if (!header || declared != observed) return null;
    } catch (_) {
      return null;
    }
  }
  return paths;
}

Future<TransferStorageItem> _copyItem(
  String root,
  String bucket,
  Set<String>? protected,
) async {
  final directory = Directory('$root/xdremux_checkpoint_inputs/$bucket');
  final trash = bucket.startsWith('transfer-trash-');
  TransferStorageItem blocked() => TransferStorageItem(
    id: 'copy:$bucket',
    name: bucket,
    bytes: 0,
    kind: 'copy',
    signature: '',
    reason: 'unknown',
  );
  if (!_bucket.hasMatch(bucket) ||
      !await _plain(directory.path, FileSystemEntityType.directory)) {
    return blocked();
  }
  try {
    final children = await directory.list(followLinks: false).toList();
    if (trash && children.isEmpty) {
      return TransferStorageItem(
        id: 'copy:$bucket',
        name: bucket,
        bytes: 0,
        kind: 'copy',
        signature: 'empty-trash',
        reason: protected == null ? 'unknown' : null,
      );
    }
    final marker = File('${directory.path}/receipt.json');
    if (!await _plain(marker.path, FileSystemEntityType.file) ||
        await marker.length() > 16384) {
      return blocked();
    }
    final text = await marker.readAsString();
    final data = jsonDecode(text) as Map;
    final id = bucket.replaceFirst(trash ? 'transfer-trash-' : 'transfer-', '');
    final name = data['name'];
    if (data['id'] != id ||
        name is! String ||
        !transferSafeName(name) ||
        !transferImageName(name) ||
        data['size'] is! int ||
        data['size'] < 0 ||
        data['sha256'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(data['sha256'] as String)) {
      return blocked();
    }
    if (children.any(
          (entry) =>
              entry is! File ||
              !['receipt.json', name].contains(entry.uri.pathSegments.last),
        ) ||
        children.length > 2) {
      return blocked();
    }
    final payload = File('${directory.path}/$name');
    final exists = await _plain(payload.path, FileSystemEntityType.file);
    if (!exists && !trash) return blocked();
    final bytes = exists ? await payload.length() : 0;
    final validSize = !exists || bytes == data['size'];
    // A retained reference may use an older support-directory alias. Retaining
    // the same immutable receipt bucket/name across roots is conservative.
    final suffix = '/$bucket/$name';
    final referenceSuffix = Platform.isWindows ? suffix.toLowerCase() : suffix;
    final queued =
        protected?.any((path) => path.endsWith(referenceSuffix)) == true;
    // An ACK only hands the copy to the queue. Once neither the live queue nor
    // a readable checkpoint references it (batch finished, queue cleared, app
    // restarted), nothing ever will again and it would otherwise leak.
    final state = data['state'];
    final acknowledged =
        (state == 'added' || state == 'duplicate') && data['queueId'] is String;
    final reason = queued
        ? 'queue'
        : protected == null ||
              !validSize ||
              !(acknowledged ||
                  (state == 'prepared' && data['queueId'] == null))
        ? 'unknown'
        : null;
    return TransferStorageItem(
      id: 'copy:$bucket',
      name: name,
      bytes: bytes,
      kind: 'copy',
      signature: sha256.convert(utf8.encode(text)).toString(),
      reason: reason,
      hash: (data['sha256'] as String).toLowerCase(),
    );
  } catch (_) {
    return blocked();
  }
}

Future<List<TransferStorageItem>> scanTransferCopies(
  String root,
  Set<String> retained,
) async {
  if (!await _plain(root, FileSystemEntityType.directory)) {
    throw const TransferException('unsafe_storage');
  }
  final inputs = Directory('$root/xdremux_checkpoint_inputs');
  if (await FileSystemEntity.type(inputs.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return [];
  }
  if (!await _plain(inputs.path, FileSystemEntityType.directory)) {
    throw const TransferException('unsafe_storage');
  }
  final protected = await _protected(root, retained);
  final items = <TransferStorageItem>[];
  await for (final child in inputs.list(followLinks: false)) {
    final name = child.path.split(RegExp(r'[/\\]')).last;
    if (_bucket.hasMatch(name)) {
      items.add(await _copyItem(root, name, protected));
    }
  }
  return items..sort((a, b) => a.id.compareTo(b.id));
}

Future<TransferStorageCleanup> cleanTransferCopies(
  String root,
  List<TransferStorageItem> selected,
  Set<String> retained,
) async {
  final result = TransferStorageCleanup();
  if (!await _plain(root, FileSystemEntityType.directory) ||
      !await _plain(
        '$root/xdremux_checkpoint_inputs',
        FileSystemEntityType.directory,
      )) {
    throw const TransferException('unsafe_storage');
  }
  final protected = await _protected(root, retained);
  for (final item in selected) {
    var key = item.id;
    try {
      final bucket = item.id.substring('copy:'.length);
      if (!_bucket.hasMatch(bucket)) {
        throw const TransferException('unsafe_storage');
      }
      final fresh = await _copyItem(root, bucket, protected);
      if (!fresh.canClean) throw const TransferException('busy');
      if (fresh.signature != item.signature || fresh.bytes != item.bytes) {
        throw const TransferException('source_changed');
      }
      var directory = Directory('$root/xdremux_checkpoint_inputs/$bucket');
      final payload = File('${directory.path}/${fresh.name}');
      if (fresh.hash != null &&
          await payload.exists() &&
          (await sha256.bind(payload.openRead()).first).toString() !=
              fresh.hash) {
        throw const TransferException('checksum_mismatch');
      }
      if (!bucket.startsWith('transfer-trash-')) {
        final trash = bucket.replaceFirst('transfer-', 'transfer-trash-');
        final target = '${directory.parent.path}/$trash';
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const TransferException('busy');
        }
        directory = await directory.rename(target);
        key = 'copy:$trash';
      }
      // Every child was validated above. No recursive deletion or traversal.
      final data = File('${directory.path}/${fresh.name}');
      if (fresh.hash != null &&
          await _plain(data.path, FileSystemEntityType.file)) {
        await data.delete();
      }
      final marker = File('${directory.path}/receipt.json');
      if (await _plain(marker.path, FileSystemEntityType.file)) {
        await marker.delete();
      }
      await directory.delete();
      result.deleted.add(item.id);
    } catch (error) {
      result.failed[key] = error is TransferException ? error.code : 'io';
    }
  }
  return result;
}

Future<List<TransferStorageItem>> _scanInWorker(
  String root,
  Set<String> retained,
) => Isolate.run(() => scanTransferCopies(root, retained));

Future<TransferStorageCleanup> _cleanInWorker(
  String root,
  List<TransferStorageItem> copies,
  Set<String> retained,
) => Isolate.run(() => cleanTransferCopies(root, copies, retained));

class TransferStorage {
  TransferStorage(this.root, this.native);
  final String root;
  final TransferService native;
  Future<T> _access<T>(Future<T> Function() action) {
    if (TransferQueue.admitting) {
      return Future<T>.error(const TransferException('busy'));
    }
    TransferQueue.imports++;
    return TransferQueue.withInputAccess(
      action,
    ).whenComplete(() => TransferQueue.imports--);
  }

  Future<Map<String, Map<String, dynamic>>> _receipts() async {
    final rows = <String, Map<String, dynamic>>{};
    String? after;
    while (true) {
      final page =
          await native.command({
                'command': 'receipts',
                'after': after,
                'limit': 64,
              })
              as List;
      for (final value in page) {
        final row = Map<String, dynamic>.from(value as Map);
        rows[row['id'] as String] = row;
      }
      if (page.length < 64) return rows;
      final next = page.last['id'] as String;
      if (next == after) throw const TransferException('io');
      after = next;
    }
  }

  Future<TransferStorageSnapshot> preview() => _access(() async {
    final rows = await _receipts();
    final support = root, retained = TransferQueue.retainedInputPaths;
    final copies = await _scanInWorker(support, retained);
    return TransferStorageSnapshot(
      native.ready!['core_instance_id'] as String,
      [
        for (final row in rows.values)
          TransferStorageItem(
            id: 'inbox:${row['id']}',
            name: row['name'] as String,
            bytes: row['size'] as int,
            kind: 'inbox',
            signature: jsonEncode(row),
          ),
        ...copies,
      ],
    );
  });

  Future<TransferStorageCleanup> clean(
    TransferStorageSnapshot plan,
    Set<String> ids,
  ) => _access(() async {
    if (native.ready?['core_instance_id'] != plan.runtimeId) {
      throw const TransferException('closed');
    }
    final selected = plan.items
        .where((item) => ids.contains(item.id) && item.canClean)
        .toList();
    if (selected.length != ids.length) {
      throw const TransferException('invalid_input');
    }
    final current = await _receipts();
    final result = TransferStorageCleanup();
    for (final item in selected.where((item) => item.kind == 'inbox')) {
      final id = item.id.substring('inbox:'.length);
      try {
        final row = current[id];
        if (row != null) {
          if (jsonEncode(row) != item.signature) {
            throw const TransferException('source_changed');
          }
          await native.command({'command': 'delete_receipt', 'receipt_id': id});
        }
        result.deleted.add(item.id);
      } catch (error) {
        result.failed[item.id] = error is TransferException ? error.code : 'io';
      }
    }
    final copies = selected.where((item) => item.kind == 'copy').toList();
    if (copies.isNotEmpty) {
      try {
        final support = root, retained = TransferQueue.retainedInputPaths;
        final cleaned = await _cleanInWorker(support, copies, retained);
        result.deleted.addAll(cleaned.deleted);
        result.failed.addAll(cleaned.failed);
      } catch (error) {
        for (final item in copies) {
          result.failed[item.id] = error is TransferException
              ? error.code
              : 'io';
        }
      }
    }
    return result;
  });
}
