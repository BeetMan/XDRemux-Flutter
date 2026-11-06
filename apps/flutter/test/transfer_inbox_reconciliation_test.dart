import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

Map<String, dynamic> receipt(int index) => {
  'id': '11111111-1111-4111-8111-${index.toString().padLeft(12, '0')}',
  'name': 'photo-$index.jpg',
  'size': 3,
};

class _InboxNative extends TransferService {
  _InboxNative(this.rows);
  final List<Map<String, dynamic>> rows;
  final calls = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];
  Completer<void>? readGate, readEntered, deleteGate, deleteEntered;
  String? deleteError;
  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
    ready = {'address': bind, 'fingerprint': 'A' * 64};
    return const TransferAvailability(true);
  }

  @override
  Future<dynamic> command(Map<String, dynamic> request) async {
    calls.add(request);
    switch (request['command']) {
      case 'snapshot':
        return {'transfers': [], 'next': null};
      case 'receipts':
        final page = rows
            .where(
              (r) =>
                  request['after'] == null ||
                  (r['id'] as String).compareTo(request['after'] as String) > 0,
            )
            .take(64)
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        if (readEntered?.isCompleted == false) readEntered!.complete();
        await readGate?.future;
        return page;
      case 'delete_receipt':
        if (deleteError != null) throw TransferException(deleteError!);
        rows.removeWhere((r) => r['id'] == request['receipt_id']);
        if (deleteEntered?.isCompleted == false) deleteEntered!.complete();
        await deleteGate?.future;
        return null;
      default:
        throw StateError('Unexpected command: $request');
    }
  }

  @override
  Future<Map<String, dynamic>> drainEvents() async {
    final page = {'events': List.of(events), 'resync': false};
    events.clear();
    return page;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> rows;
  late List<_InboxNative> created;
  late TransferController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rows = [receipt(0)];
    created = [];
    controller = TransferController(
      serviceFactory: () {
        final native = _InboxNative(rows);
        created.add(native);
        return native;
      },
      supportDirectory: () async => Directory.systemTemp,
      observeLifecycle: false,
    );
  });
  tearDown(() async {
    for (final native in created) {
      for (final gate in [native.readGate, native.deleteGate]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
    }
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    controller.dispose();
  });

  for (final reset in [false, true]) {
    test(
      'inbox reconciliation: stale page cannot undo deletion reset=$reset',
      () async {
        rows = List.generate(reset ? 65 : 130, receipt);
        await controller.ensureLocal();
        final native = created.single;
        final removed = receipt(reset ? 63 : 127)['id'] as String;
        native.readGate = Completer<void>();
        native.readEntered = Completer<void>();
        final reading = controller.loadInbox(reset: reset);
        await native.readEntered!.future;
        await controller.deleteReceipt(removed);
        native.readGate!.complete();
        await reading;
        expect(controller.inbox, isNot(contains(removed)));
        expect(controller.moreInbox, isTrue);
        native.readGate = null;
        await controller.loadInbox();
        expect(native.calls.last['after'], removed);
        expect(controller.inbox.length, reset ? 64 : 129);
        expect(controller.moreInbox, isFalse);
      },
    );
  }

  test(
    'inbox reconciliation: queued commit cannot undo acknowledged deletion',
    () async {
      await controller.ensureLocal();
      final old = receipt(0), id = old['id'] as String;
      await controller.deleteReceipt(id);
      created.single.events.add({
        'kind': 'event',
        'event': {'kind': 'committed', 'receipt': old},
      });
      await controller.poll();
      expect(controller.inbox, isNot(contains(id)));
      await controller.refresh();
      expect(controller.inbox, isEmpty);
    },
  );

  test(
    'inbox reconciliation: deletion event wins over an in-flight page',
    () async {
      await controller.ensureLocal();
      final native = created.single, id = receipt(0)['id'] as String;
      native.readGate = Completer<void>();
      native.readEntered = Completer<void>();
      final reading = controller.loadInbox(reset: true);
      await native.readEntered!.future;
      rows.clear();
      native.events.add({
        'kind': 'event',
        'event': {'kind': 'receipt_deleted', 'receipt_id': id},
      });
      final polling = controller.poll();
      await Future<void>.delayed(Duration.zero);
      expect(controller.inbox, isNot(contains(id)));
      var resurrected = false;
      controller.addListener(
        () => resurrected |= controller.inbox.containsKey(id),
      );
      native.readGate!.complete();
      await Future.wait([reading, polling]);
      expect(resurrected, isFalse);
      expect(controller.inbox, isEmpty);
    },
  );

  test(
    'inbox reconciliation: rejected deletion preserves receipt and permits retry',
    () async {
      await controller.ensureLocal();
      final native = created.single, id = receipt(0)['id'] as String;
      native.deleteError = 'busy';
      await expectLater(
        controller.deleteReceipt(id),
        throwsA(isA<TransferException>().having((e) => e.code, 'code', 'busy')),
      );
      await controller.refresh();
      expect(controller.inbox, contains(id));
      expect(rows, hasLength(1));
      native.deleteError = null;
      await controller.deleteReceipt(id);
      expect(controller.inbox, isEmpty);
      expect(rows, isEmpty);
    },
  );

  test(
    'inbox reconciliation: restart reloads disk without old commit overlay',
    () async {
      await controller.ensureLocal();
      final native = created.single,
          old = receipt(0),
          id = receipt(0)['id'] as String;
      native.events.add({
        'kind': 'event',
        'event': {'kind': 'committed', 'receipt': old},
      });
      await controller.poll();
      native.deleteGate = Completer<void>();
      native.deleteEntered = Completer<void>();
      final deleting = controller.deleteReceipt(id);
      await native.deleteEntered!.future;
      await controller.stop();
      rows.add(receipt(1));
      await controller.ensureLocal();
      expect(controller.inbox.keys, [receipt(1)['id']]);
      native.deleteGate!.complete();
      await deleting;
      expect(controller.inbox.keys, [receipt(1)['id']]);
      expect(controller.running, isTrue);
    },
  );
}
