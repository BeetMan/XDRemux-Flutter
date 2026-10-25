import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_copy.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_queue.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'package:xdremux/services/transfer/transfer_storage.dart';
import 'package:xdremux/transfer_storage_dialog.dart';

const first = '11111111-1111-4111-8111-111111111111';
const second = '22222222-2222-4222-8222-222222222222';
final jpeg = [255, 216, 255, ...List.generate(8192, (i) => i % 256)];

class _Native extends TransferService {
  _Native() {
    ready = {'core_instance_id': 'storage-runtime'};
  }
  final rows = <Map<String, dynamic>>[];
  final busyIds = <String>{}, unknownIds = <String>{};
  final deleted = <String>[];
  @override
  Future<dynamic> command(Map<String, dynamic> request) async {
    if (request['command'] == 'receipts') {
      final after = request['after'];
      final start = after == null
          ? 0
          : rows.indexWhere((row) => row['id'] == after) + 1;
      return rows.skip(start).take(request['limit'] as int).toList();
    }
    if (request['command'] == 'delete_receipt') {
      final id = request['receipt_id'] as String;
      deleted.add(id);
      if (busyIds.contains(id)) throw const TransferException('busy');
      rows.removeWhere((row) => row['id'] == id);
      if (unknownIds.contains(id)) {
        throw const TransferException('outcome_unknown');
      }
      return null;
    }
    throw StateError('Unexpected command');
  }
}

class _Controller extends TransferController {
  _Controller(this.items) : super(observeLifecycle: false);
  final List<TransferStorageItem> items;
  final calls = <Set<String>>[];
  String? failure;
  @override
  Future<TransferStorageSnapshot> inspectStorage() async =>
      TransferStorageSnapshot('ui-runtime', items);
  @override
  Future<TransferStorageCleanup> cleanStorage(
    TransferStorageSnapshot plan,
    Set<String> ids,
  ) async {
    calls.add(Set.of(ids));
    final result = TransferStorageCleanup();
    for (final id in ids) {
      if (failure != null) {
        result.failed[id] = failure!;
      } else {
        result.deleted.add(id);
        items.removeWhere((item) => item.id == id);
      }
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Native native;
  final owner = Object();
  var retained = <String>{};
  setUp(() async {
    root = await Directory.systemTemp.createTemp('xdremux-storage-');
    native = _Native();
    retained = {};
    TransferQueue.register(
      owner,
      (_) async => const TransferIntakeAck(TransferIntakeStatus.rejected),
      retainedInputs: () => retained,
    );
  });
  tearDown(() async {
    TransferQueue.unregister(owner);
    expect(TransferQueue.importing, isFalse);
    await root.delete(recursive: true);
  });
  Future<String> copy([String id = first]) async {
    final source = File('${root.path}/source-$id.jpg');
    await source.writeAsBytes(jpeg);
    final result = await copyTransferInput(root.path, {
      'path': source.path,
      'receipt': {
        'id': id,
        'name': '照片🧪.jpg',
        'size': jpeg.length,
        'sha256': sha256.convert(jpeg).toString(),
      },
    });
    return result['path'] as String;
  }

  test(
    'counts every inbox page and protects active and ACKed copies',
    () async {
      for (var i = 0; i < 65; i++) {
        native.rows.add({
          'id': '$i',
          'name': '$i.bin',
          'size': i,
          'sha256': 'fixture',
        });
      }
      retained.add(await copy());
      final acknowledged = await copy(second);
      await persistTransferAck(
        acknowledged,
        const TransferIntakeAck(
          TransferIntakeStatus.added,
          queueId: 'queue-item',
        ),
      );
      final plan = await TransferStorage(root.path, native).preview();
      expect(plan.countFor('inbox'), 65);
      expect(plan.bytesFor('inbox'), 2080);
      expect(plan.bytesFor('copy'), jpeg.length * 2);
      expect(
        plan.items
            .where((item) => item.kind == 'copy')
            .every((item) => item.reason == 'queue'),
        isTrue,
      );
      await expectLater(
        TransferStorage(
          root.path,
          native,
        ).clean(plan, {'copy:transfer-$first'}),
        throwsA(isA<TransferException>()),
      );
      expect(native.deleted, isEmpty);
    },
  );

  test(
    'rechecks queue adoption after preview and only deletes unused copies',
    () async {
      final path = await copy();
      final outputs = File(
        '${root.path}/xdremux_transfer_outputs/$first/rendered.heic',
      );
      await outputs.writeAsString('keep-output');
      final manager = TransferStorage(root.path, native);
      final plan = await manager.preview();
      final id = plan.items.single.id;
      retained.add(path);
      expect((await manager.clean(plan, {id})).failed[id], 'busy');
      expect(await File(path).exists(), isTrue);
      retained.clear();
      expect((await manager.clean(plan, {id})).deleted, {id});
      expect(await File(path).exists(), isFalse);
      expect(await outputs.readAsString(), 'keep-output');
      expect(await File('${root.path}/source-$first.jpg').readAsBytes(), jpeg);
    },
  );

  test(
    'published references, corrupt checkpoints and pending saves prevent cleanup',
    () async {
      final path = await copy();
      final checkpoint = File('${root.path}/xdremux_checkpoint.jsonl');
      await checkpoint.writeAsString(
        '${jsonEncode({'type': 'header', 'totalJobs': 1})}\n${jsonEncode({'type': 'item', 'inputPath': path})}\n',
      );
      expect((await scanTransferCopies(root.path, {})).single.reason, 'queue');
      await checkpoint.writeAsString('{"type":"header","totalJobs":1}\n');
      expect(
        (await scanTransferCopies(root.path, {})).single.reason,
        'unknown',
      );
      await checkpoint.delete();
      final pending = File('${checkpoint.path}.tmp');
      await pending.writeAsString('{"type":"header","totalJobs":0}\n');
      expect(
        (await scanTransferCopies(root.path, {})).single.reason,
        'unknown',
      );
      expect(await File(path).exists(), isTrue);
    },
  );

  test(
    'changed bytes are retained and an explicit corrected retry can succeed',
    () async {
      final path = await copy();
      final manager = TransferStorage(root.path, native);
      final plan = await manager.preview();
      final item = plan.items.single;
      await File(path).writeAsBytes(List.filled(jpeg.length, 0));
      expect(
        (await manager.clean(plan, {item.id})).failed[item.id],
        'checksum_mismatch',
      );
      expect(await File(path).exists(), isTrue);
      await File(path).writeAsBytes(jpeg);
      expect((await manager.clean(plan, {item.id})).deleted, {item.id});
    },
  );

  test(
    'unexpected children are preserved and interrupted deletion is retryable',
    () async {
      final path = await copy();
      final sentinel = File('${File(path).parent.path}/foreign.txt');
      await sentinel.writeAsString('keep');
      expect(
        (await scanTransferCopies(root.path, {})).single.reason,
        'unknown',
      );
      expect(await sentinel.readAsString(), 'keep');
      await sentinel.delete();
      final trash = await File(
        path,
      ).parent.rename('${File(path).parent.parent.path}/transfer-trash-$first');
      await File('${trash.path}/照片🧪.jpg').delete();
      final manager = TransferStorage(root.path, native);
      final plan = await manager.preview();
      expect(plan.items.single.bytes, 0);
      expect(
        (await manager.clean(plan, {plan.items.single.id})).failed,
        isEmpty,
      );
      expect(await trash.exists(), isFalse);
    },
  );

  test(
    'Windows junctions never authorize traversal or deletion',
    () async {
      await copy();
      final foreign = await Directory('${root.path}/foreign').create();
      final sentinel = File('${foreign.path}/照片🧪.jpg');
      await sentinel.writeAsBytes(jpeg);
      await File('${foreign.path}/receipt.json').writeAsString(
        jsonEncode({
          'id': second,
          'name': '照片🧪.jpg',
          'size': jpeg.length,
          'sha256': sha256.convert(jpeg).toString(),
          'state': 'prepared',
        }),
      );
      final junction =
          '${root.path}/xdremux_checkpoint_inputs/transfer-$second';
      final linked = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        junction.replaceAll('/', '\\'),
        foreign.path.replaceAll('/', '\\'),
      ]);
      expect(linked.exitCode, 0, reason: linked.stderr.toString());
      final items = await scanTransferCopies(root.path, {});
      expect(
        items.singleWhere((item) => item.id.endsWith(second)).canClean,
        isFalse,
      );
      expect(await sentinel.readAsBytes(), jpeg);
    },
    skip: !Platform.isWindows,
  );

  test(
    'partial inbox failure retries only remaining ids; unknown deletion reconciles without replay',
    () async {
      native.rows.addAll([
        {'id': first, 'name': 'a.bin', 'size': 3},
        {'id': second, 'name': 'b.bin', 'size': 4},
      ]);
      native.busyIds.add(first);
      final manager = TransferStorage(root.path, native);
      final plan = await manager.preview();
      final result = await manager.clean(
        plan,
        plan.items.map((item) => item.id).toSet(),
      );
      expect(result.deleted, {'inbox:$second'});
      expect(result.failed, {'inbox:$first': 'busy'});
      native.busyIds.clear();
      native.unknownIds.add(first);
      expect((await manager.clean(plan, {'inbox:$first'})).failed, {
        'inbox:$first': 'outcome_unknown',
      });
      final calls = native.deleted.length;
      expect((await manager.clean(plan, {'inbox:$first'})).deleted, {
        'inbox:$first',
      });
      expect(native.deleted.length, calls);
    },
  );

  test('old runtime plans cannot mutate a replacement service', () async {
    final manager = TransferStorage(root.path, native);
    final plan = await manager.preview();
    native.ready!['core_instance_id'] = 'replacement';
    await expectLater(
      manager.clean(plan, {}),
      throwsA(isA<TransferException>()),
    );
    expect(native.deleted, isEmpty);
  });

  test(
    'a retained support-path alias conservatively protects the receipt bucket',
    () async {
      await copy();
      final items = await scanTransferCopies(root.path, {
        '/older/support/xdremux_checkpoint_inputs/transfer-$first/照片🧪.jpg',
      });
      expect(items.single.reason, 'queue');
    },
  );

  test(
    'in-flight ordinary queue admission prevents storage work until settled',
    () async {
      final resumed = Completer<void>();
      final admission = TransferQueue.withAdmission(() => resumed.future);
      expect(TransferQueue.admitting, isTrue);
      final manager = TransferStorage(root.path, native);
      await expectLater(manager.preview(), throwsA(isA<TransferException>()));
      resumed.complete();
      await admission;
      expect(TransferQueue.admitting, isFalse);
      expect((await manager.preview()).items, isEmpty);
    },
  );

  test(
    'copy storage failure preserves successful inbox deletion results',
    () async {
      final path = await copy();
      native.rows.add({'id': first, 'name': 'a.bin', 'size': 3});
      final manager = TransferStorage(root.path, native);
      final plan = await manager.preview();
      final inputs = File(path).parent.parent;
      final moved = await inputs.rename('${root.path}/moved-inputs');
      await File(inputs.path).writeAsString('blocked');
      final result = await manager.clean(
        plan,
        plan.items.map((item) => item.id).toSet(),
      );
      expect(result.deleted, {'inbox:$first'});
      expect(result.failed, {'copy:transfer-$first': 'unsafe_storage'});
      expect(
        await File('${moved.path}/transfer-$first/照片🧪.jpg').exists(),
        isTrue,
      );
    },
  );

  Future<_Controller> dialog(WidgetTester tester) async {
    final controller = _Controller([
      const TransferStorageItem(
        id: 'inbox:a',
        name: 'a.bin',
        bytes: 12,
        kind: 'inbox',
        signature: 'a',
      ),
      const TransferStorageItem(
        id: 'copy:b',
        name: 'b.jpg',
        bytes: 20,
        kind: 'copy',
        signature: 'b',
        reason: 'queue',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferStorageDialog(
            controller: controller,
            errorText: (code) => code,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('clean-storage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-storage-clean')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'storage preview requires selection and confirmation; queue copy stays disabled',
    (tester) async {
      final controller = await dialog(tester);
      final queueTile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('storage-copy:b')),
      );
      expect(queueTile.onChanged, isNull);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('clean-storage')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('storage-inbox:a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('clean-storage')));
      await tester.pumpAndSettle();
      expect(controller.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('confirm-storage-clean')));
      await tester.pumpAndSettle();
      expect(controller.calls, [
        {'inbox:a'},
      ]);
      expect(controller.items.single.reason, 'queue');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'failed selection stays retryable; unknown outcome remains disabled after refresh',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = await dialog(tester);
      controller.failure = 'busy';
      await tester.tap(find.byKey(const ValueKey('storage-inbox:a')));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(controller.calls.length, 1);
      await tester.tap(find.byKey(const ValueKey('refresh-storage')));
      await tester.pumpAndSettle();
      expect(controller.calls.length, 1);
      controller.failure = 'outcome_unknown';
      await confirm(tester);
      expect(controller.calls.length, 2);
      await tester.tap(find.byKey(const ValueKey('refresh-storage')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('storage-inbox:a')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('clean-storage')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
