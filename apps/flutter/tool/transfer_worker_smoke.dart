// Real DLL + persistent Dart worker smoke. Run with `dart run`, not an image engine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:xdremux/services/transfer/transfer_intake.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

void check(bool ok, String label) {
  if (!ok) throw StateError(label);
}

Future<T> until<T>(Future<T?> Function() attempt) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    final value = await attempt();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('smoke deadline');
}

Future<Map<String, dynamic>> event(TransferService service, String kind) =>
    until(() async {
      final page = await service.drainEvents();
      check(page['resync'] == false, 'unexpected loss in bounded smoke');
      for (final body in page['events'] as List) {
        if (body['kind'] == 'event' && body['event']['kind'] == kind) {
          return Map<String, dynamic>.from(body['event'] as Map);
        }
      }
      return null;
    });
Future<String> fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    throw ArgumentError('DLL_PATH REPORT_PATH [LEGACY_DLL_PATH]');
  }
  final library = File(args[0]).absolute.path;
  final root = await Directory.systemTemp.createTemp('xdremux-worker-smoke-');
  final services = <TransferService>[];
  TransferService make() {
    final s = TransferService();
    services.add(s);
    return s;
  }

  final checks = <String>[];
  try {
    final missing = make();
    final unavailable = await missing.start(
      supportRoot: '${root.path}/missing',
      libraryPath: '${root.path}/absent.dll',
    );
    check(
      !unavailable.available && unavailable.reason == 'library_missing',
      'missing library capability',
    );
    await missing.dispose();
    checks.add('missing_library_degrades');
    if (args.length > 2) {
      final legacy = make();
      final mismatch = await legacy.start(
        supportRoot: '${root.path}/legacy',
        libraryPath: File(args[2]).absolute.path,
      );
      check(
        !mismatch.available && mismatch.reason == 'abi_mismatch',
        'unsupported ABI capability',
      );
      await legacy.dispose();
      checks.add('old_abi_degrades');
    }
    final a = make(), b = make();
    check(
      (await a.start(
        supportRoot: '${root.path}/a',
        libraryPath: library,
      )).available,
      'sender startup',
    );
    check(
      (await b.start(
        supportRoot: '${root.path}/b',
        libraryPath: library,
      )).available,
      'receiver startup',
    );
    final peer = await a.command({
      'command': 'probe',
      'address': b.ready!['address'],
    });
    check(peer['fingerprint'] == b.ready!['fingerprint'], 'certificate');
    try {
      await b.command({
        'command': 'check_space',
        'bytes': 0,
        'reserve': 9223372036854775807,
      });
      throw StateError('expected no_space');
    } on TransferException catch (e) {
      check(e.code == 'no_space', 'space failure code');
    }
    checks.add('no_space_propagates');
    final photo = File('${root.path}/照片😀.jpg');
    await photo.writeAsBytes([
      255,
      216,
      255,
      ...List<int>.generate(2 * 1024 * 1024, (i) => i % 256),
    ]);
    final movie = File('${root.path}/clip.mov');
    await movie.writeAsBytes([0, 1, 2, 3]);
    final originalHash = await fileHash(photo);
    var transferredFiles = 0, transferredBytes = 0;
    Future<void> send(List<File> paths) async {
      final started = await a.command({
        'command': 'send',
        'peer': peer,
        'paths': paths.map((p) => p.path).toList(),
      });
      final offer = (await event(b, 'offer'))['offer'] as Map;
      await b.command({
        'command': 'decide',
        'transfer_id': offer['session_id'],
        'accept': true,
      });
      final sent = await event(a, 'sent');
      check(
        sent['transfer_id'] == started['transfer_id'] &&
            sent['report']['error'] == null,
        'send result',
      );
      transferredFiles += paths.length;
      for (final file in paths) {
        transferredBytes += await file.length();
      }
    }

    await send([photo, movie]);
    await send([photo]);
    final receipts =
        await b.command({'command': 'receipts', 'limit': 64}) as List;
    check(receipts.length == 3, 'persistent inbox');
    final photos = receipts
        .where((r) => r['name'] == photo.uri.pathSegments.last)
        .toList();
    final queued = <String>{};
    var simulateAckLoss = true;
    final intake = TransferIntake(b, (input) async {
      final isNew = queued.add(input.path);
      check(
        await fileHash(File(input.path)) == originalHash,
        'independent checkpoint bytes',
      );
      check(
        !input.outputDirectory.startsWith(File(input.path).parent.path),
        'separate output directory',
      );
      if (simulateAckLoss) {
        simulateAckLoss = false;
        throw const TransferException('io');
      }
      return TransferIntakeAck(
        isNew ? TransferIntakeStatus.added : TransferIntakeStatus.duplicate,
        queueId: 'queue-${queued.length}',
      );
    });
    try {
      await intake.importReceipt(photos[0]['id'] as String);
      throw StateError('expected ACK loss');
    } on TransferException catch (e) {
      check(e.code == 'io', 'ACK loss');
    }
    final repeat = await intake.importReceipt(photos[0]['id'] as String);
    check(
      repeat.status == TransferIntakeStatus.duplicate,
      'retry deduplication',
    );
    final click = intake.importReceipt(photos[1]['id'] as String);
    check(
      identical(click, intake.importReceipt(photos[1]['id'] as String)),
      'concurrent click coalescing',
    );
    check((await click).status == TransferIntakeStatus.added, 'second receipt');
    check(queued.length == 2, 'same name uses independent buckets');
    final unknown = receipts.firstWhere((r) => r['name'] == 'clip.mov');
    check(
      (await intake.importReceipt(unknown['id'] as String)).status ==
          TransferIntakeStatus.unsupported,
      'opaque file remains in inbox',
    );
    for (final r in photos) {
      await b.command({'command': 'delete_receipt', 'receipt_id': r['id']});
    }
    for (final path in queued) {
      check(
        await fileHash(File(path)) == originalHash,
        'inbox cleanup preserves queue',
      );
    }
    checks.addAll([
      'worker_https_transfer',
      'unicode_private_copy_hash',
      'same_name_isolated',
      'ack_loss_retry',
      'concurrent_click_coalescing',
      'opaque_mov_not_queued',
      'inbox_delete_keeps_checkpoint',
    ]);
    final before = Map<String, dynamic>.from(b.ready!);
    // Exercise disposal only after a real streaming copy has started writing.
    final large = File('${root.path}/stop-during-copy.jpg');
    final writer = await large.open(mode: FileMode.writeOnly);
    try {
      await writer.writeFrom([255, 216, 255]);
      final chunk = List<int>.generate(65536, (i) => i % 256);
      for (var i = 0; i < 1024; i++) {
        await writer.writeFrom(chunk);
      }
    } finally {
      await writer.close();
    }
    await send([large]);
    final allReceipts =
        await b.command({'command': 'receipts', 'limit': 64}) as List;
    final largeReceipt = allReceipts.firstWhere(
      (r) => r['name'] == 'stop-during-copy.jpg',
    );
    var copyDone = false;
    final copying = b
        .prepareInput(largeReceipt['id'] as String)
        .whenComplete(() => copyDone = true);
    await until(() async {
      final directory = Directory('${root.path}/b/xdremux_checkpoint_inputs');
      await for (final child in directory.list()) {
        if (child is Directory && child.path.contains('transfer-staging-')) {
          final staged = File('${child.path}/stop-during-copy.jpg');
          if (await staged.exists() && await staged.length() > 0) return true;
        }
      }
      return null;
    });
    check(!copyDone, 'stop begins during streaming copy');
    await b.dispose();
    final completedCopy = await copying;
    check(
      await fileHash(File(completedCopy.path)) == await fileHash(large),
      'stop waits for copy and lease release',
    );
    checks.add('stop_waits_for_active_copy');
    await b.dispose();
    final restarted = make();
    check(
      (await restarted.start(
        supportRoot: '${root.path}/b',
        libraryPath: library,
        bind: before['address'] as String,
      )).available,
      'restart root and port',
    );
    check(
      restarted.ready!['core_instance_id'] != before['core_instance_id'],
      'fresh instance',
    );
    check(
      restarted.ready!['fingerprint'] == before['fingerprint'],
      'persistent identity',
    );
    final after =
        await restarted.command({'command': 'receipts', 'limit': 64}) as List;
    check(
      after.length == 2 && after.any((r) => r['name'] == 'clip.mov'),
      'inbox restart',
    );
    checks.add('restart_root_port_and_receipts');
    await restarted.dispose();
    await a.dispose();
    final address = (before['address'] as String).split(':');
    final listener = await ServerSocket.bind(address[0], int.parse(address[1]));
    await listener.close();
    check(await fileHash(photo) == originalHash, 'original unchanged');
    final report = {
      'passed': true,
      'date': '2026-10-19',
      'abi': 65538,
      'checks': checks,
      'transferredFiles': transferredFiles,
      'bytes': transferredBytes,
      'originalAndCopiesHashMatch': true,
      'librarySha256': await fileHash(File(library)),
    };
    final output = File(args[1]);
    await output.parent.create(recursive: true);
    await output.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    for (final service in services.reversed) {
      await service.dispose();
    }
    await root.delete(recursive: true);
  }
}
