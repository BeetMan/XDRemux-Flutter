import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

class _DelayedNative extends TransferService {
  final pending = <String, Completer<dynamic>>{};
  final entered = <String, Completer<void>>{};
  final calls = <String>[];
  bool ended = false;
  String alias = 'Old';

  Completer<dynamic> delay(String method) {
    entered[method] = Completer<void>();
    return pending[method] = Completer<dynamic>();
  }

  Map<String, dynamic> get discovery => {
    'enabled': true,
    'error': null,
    'peers': [
      {'alias': alias, 'address': '192.168.1.2:53319', 'fingerprint': 'B' * 64},
    ],
  };

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

  Future<dynamic> reply(String method) async {
    calls.add(method);
    final gate = pending[method];
    if (gate != null) {
      if (!entered[method]!.isCompleted) entered[method]!.complete();
      return gate.future;
    }
    return switch (method) {
      'discovery_start' || 'discovery_status' => discovery,
      'snapshot' => {'transfers': [], 'next': null},
      'receipts' => [],
      'events' => {'events': [], 'resync': false},
      _ => throw StateError('Unexpected command: $method'),
    };
  }

  @override
  Future<dynamic> command(Map<String, dynamic> request) =>
      reply(request['command'] as String);

  @override
  Future<Map<String, dynamic>> drainEvents() async =>
      Map<String, dynamic>.from(await reply('events') as Map);

  @override
  Future<void> dispose() async {
    ended = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<_DelayedNative> created;
  late TransferController controller;
  late List<bool> locks;
  late bool held;
  late List<Completer<void>> lockGates;
  Future<void> Function(bool)? lockAction;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    created = [];
    locks = [];
    held = false;
    lockGates = [];
    lockAction = null;
    controller = TransferController(
      serviceFactory: () {
        final native = _DelayedNative()
          ..alias = created.isEmpty ? 'Old' : 'New';
        created.add(native);
        return native;
      },
      supportDirectory: () async => Directory.systemTemp,
      multicastLock: (acquire) async {
        locks.add(acquire);
        await lockAction?.call(acquire);
        held = acquire;
      },
      observeLifecycle: false,
    );
  });
  tearDown(() async {
    // Do not leave an intentionally suspended callback or timer behind on failure.
    for (final gate in lockGates) {
      if (!gate.isCompleted) gate.complete();
    }
    lockAction = null;
    for (final native in created) {
      for (final entry in native.pending.entries) {
        if (!entry.value.isCompleted) {
          entry.value.complete(switch (entry.key) {
            'events' => {'events': [], 'resync': false},
            'snapshot' => {'transfers': [], 'next': null},
            'receipts' => [],
            _ => native.discovery,
          });
        }
      }
    }
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    controller.dispose();
  });

  Future<void> restart() async {
    await controller.stop();
    await controller.enableReceiving();
    expect(created, hasLength(2));
  }

  void expectReplacementHealthy() {
    expect(controller.running, isTrue);
    expect(controller.receiving, isTrue);
    expect(controller.discovering, isTrue);
    expect(controller.peers.single['alias'], 'New');
    expect(controller.discoveryError, isNull);
    expect(controller.error, isNull);
    expect(created.first.ended, isTrue);
    expect(created.last.ended, isFalse);
    expect(held, isTrue);
  }

  void expectRefreshedDiscovery() {
    expect(controller.running, isTrue);
    expect(controller.receiving, isTrue);
    expect(controller.discovering, isTrue);
    expect(controller.peers.single['alias'], 'New');
    expect(controller.discoveryError, isNull);
    expect(controller.error, isNull);
    expect(created.last.ended, isFalse);
    expect(held, isTrue);
  }

  for (final enabled in [false, true]) {
    test(
      'discovery ordering: older status enabled=$enabled cannot overwrite refresh',
      () async {
        await controller.enableReceiving();
        final native = created.single;
        final stale = enabled
            ? native.discovery
            : {'enabled': false, 'error': 'discovery_unavailable', 'peers': []};
        final status = native.delay('discovery_status');
        final polling = controller.poll();
        await native.entered['discovery_status']!.future;
        native.alias = 'New';
        await controller.discover();
        final lockCount = locks.length;
        status.complete(stale);
        await polling;
        expect(locks, hasLength(lockCount));
        expectRefreshedDiscovery();
      },
    );
  }

  for (final error in ['network', 'closed', 'worker_stopped']) {
    test(
      'discovery ordering: older status $error respects runtime health',
      () async {
        await controller.enableReceiving();
        final native = created.single;
        final status = native.delay('discovery_status');
        final polling = controller.poll();
        await native.entered['discovery_status']!.future;
        native.alias = 'New';
        await controller.discover();
        status.completeError(TransferException(error));
        await polling;
        if (error == 'network') {
          expectRefreshedDiscovery();
        } else {
          expect(controller.running, isFalse);
          expect(controller.receiving, isFalse);
          expect(controller.error, 'closed');
          expect(native.ended, isTrue);
          expect(held, isFalse);
        }
      },
    );
  }

  test(
    'discovery ordering: repeated refresh shares one pending announcement',
    () async {
      await controller.enableReceiving();
      final native = created.single;
      native.alias = 'New';
      final gate = native.delay('discovery_start');
      final first = controller.discover();
      await native.entered['discovery_start']!.future;
      final lockCount = locks.length;
      final second = controller.discover();
      await Future<void>.delayed(Duration.zero);
      expect(native.calls.where((c) => c == 'discovery_start'), hasLength(2));
      expect(locks, hasLength(lockCount));
      gate.complete(native.discovery);
      await Future.wait([first, second]);
      native.pending.remove('discovery_start');
      await controller.discover();
      expect(native.calls.where((c) => c == 'discovery_start'), hasLength(3));
      expectRefreshedDiscovery();
    },
  );

  test(
    'discovery ordering: poll consumes receipts while refresh is pending',
    () async {
      await controller.enableReceiving();
      final native = created.single;
      final gate = native.delay('discovery_start');
      final discovering = controller.discover();
      await native.entered['discovery_start']!.future;
      final statusCount = native.calls
          .where((c) => c == 'discovery_status')
          .length;
      native.delay('events').complete({
        'events': [
          {
            'kind': 'event',
            'event': {
              'kind': 'committed',
              'receipt': {'id': 'new-receipt'},
            },
          },
        ],
        'resync': false,
      });
      await controller.poll();
      expect(controller.inbox, contains('new-receipt'));
      expect(
        native.calls.where((c) => c == 'discovery_status'),
        hasLength(statusCount),
      );
      native.alias = 'New';
      gate.complete(native.discovery);
      await discovering;
      expectRefreshedDiscovery();
    },
  );

  test(
    'discovery ordering: old completion cannot unlock a replacement refresh',
    () async {
      await controller.enableReceiving();
      final old = created.single;
      final oldGate = old.delay('discovery_start');
      final oldRefresh = controller.discover();
      await old.entered['discovery_start']!.future;
      await restart();
      final next = created.last;
      final newGate = next.delay('discovery_start');
      final newRefresh = controller.discover();
      await next.entered['discovery_start']!.future;
      oldGate.complete(old.discovery);
      await oldRefresh;
      final shared = controller.discover();
      await Future<void>.delayed(Duration.zero);
      expect(next.calls.where((c) => c == 'discovery_start'), hasLength(2));
      newGate.complete(next.discovery);
      await Future.wait([newRefresh, shared]);
      expectReplacementHealthy();
    },
  );

  for (final failure in [false, true]) {
    test(
      'runtime boundary: late discovery failure=$failure cannot replace peers',
      () async {
        await controller.enableReceiving();
        final old = created.single;
        final gate = old.delay('discovery_start');
        final discovering = controller.discover();
        await old.entered['discovery_start']!.future;
        await restart();
        final lockCount = locks.length;
        if (failure) {
          gate.completeError(const TransferException('discovery_unavailable'));
        } else {
          gate.complete(old.discovery);
        }
        await discovering;
        expect(locks, hasLength(lockCount));
        expectReplacementHealthy();
      },
    );
  }

  for (final method in ['events', 'discovery_status']) {
    for (final error in ['closed', 'worker_stopped', 'network']) {
      test(
        'runtime boundary: late $method $error cannot stop replacement',
        () async {
          await controller.enableReceiving();
          final old = created.single;
          final gate = old.delay(method);
          final polling = controller.poll();
          await old.entered[method]!.future;
          await restart();
          gate.completeError(TransferException(error));
          await polling;
          expectReplacementHealthy();
        },
      );
    }
  }

  test(
    'runtime boundary: late terminal event cannot stop replacement',
    () async {
      await controller.enableReceiving();
      final old = created.single;
      final gate = old.delay('events');
      final polling = controller.poll();
      await old.entered['events']!.future;
      await restart();
      gate.complete({
        'events': [
          {'kind': 'stopped'},
        ],
        'resync': false,
      });
      await polling;
      expectReplacementHealthy();
    },
  );

  test(
    'runtime boundary: old poll cannot block or unlock a replacement poll',
    () async {
      await controller.enableReceiving();
      final old = created.single;
      final oldGate = old.delay('events');
      final oldPoll = controller.poll();
      await old.entered['events']!.future;
      await restart();
      final next = created.last;
      final newGate = next.delay('events');
      final newPoll = controller.poll();
      // A new runtime must poll even before the old reply returns.
      expect(next.calls.where((c) => c == 'events'), hasLength(1));
      oldGate.complete({'events': [], 'resync': false});
      await oldPoll;
      await controller.poll();
      expect(next.calls.where((c) => c == 'events'), hasLength(1));
      newGate.complete({'events': [], 'resync': false});
      await newPoll;
      next.pending.clear();
      await controller.poll();
      expect(next.calls.where((c) => c == 'events'), hasLength(2));
      expectReplacementHealthy();
    },
  );

  for (final failure in [false, true]) {
    test(
      'runtime boundary: replacement snapshot does not share old failure=$failure',
      () async {
        await controller.enableReceiving();
        final old = created.single;
        final gate = old.delay('snapshot');
        final refreshing = controller.refresh();
        final checked = failure
            ? expectLater(refreshing, throwsA(isA<TransferException>()))
            : refreshing;
        await old.entered['snapshot']!.future;
        await restart().timeout(const Duration(seconds: 5));
        final next = created.last;
        final newGate = next.delay('snapshot');
        final newRefresh = controller.refresh();
        await next.entered['snapshot']!.future;
        if (failure) {
          gate.completeError(const TransferException('closed'));
        } else {
          gate.complete({'transfers': [], 'next': null});
        }
        await checked;
        expect(identical(controller.refresh(), newRefresh), isTrue);
        newGate.complete({'transfers': [], 'next': null});
        await newRefresh;
        expect(next.calls.where((c) => c == 'snapshot'), hasLength(2));
        expectReplacementHealthy();
      },
    );

    test(
      'runtime boundary: old queued inbox read cannot enter replacement failure=$failure',
      () async {
        await controller.enableReceiving();
        final old = created.single;
        final gate = old.delay('receipts');
        final reading = controller.loadInbox();
        await old.entered['receipts']!.future;
        final queued = controller.loadInbox();
        final checked = failure
            ? Future.wait([
                expectLater(reading, throwsA(isA<TransferException>())),
                expectLater(queued, throwsA(isA<TransferException>())),
              ])
            : Future.wait([reading, queued]);
        await restart().timeout(const Duration(seconds: 5));
        if (failure) {
          gate.completeError(const TransferException('closed'));
        } else {
          gate.complete([
            {'id': 'old-receipt'},
          ]);
        }
        await checked;
        expect(created.last.calls.where((c) => c == 'receipts'), hasLength(1));
        expect(controller.inbox, isEmpty);
        expectReplacementHealthy();
      },
    );
  }

  for (final failure in [false, true]) {
    test(
      'runtime boundary: stop orders release after pending acquire failure=$failure',
      () async {
        final entered = Completer<void>(), gate = Completer<void>();
        lockGates.add(gate);
        lockAction = (acquire) async {
          if (acquire) {
            entered.complete();
            await gate.future;
          }
        };
        final opening = controller.enableReceiving();
        await entered.future;
        var stopped = false;
        final closing = controller.stop().then((_) => stopped = true);
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        expect(controller.stopping, isTrue);
        expect(locks.last, isTrue);
        if (failure) {
          gate.completeError(const TransferException('discovery_unavailable'));
        } else {
          gate.complete();
        }
        await Future.wait([opening, closing]);
        expect(controller.running, isFalse);
        expect(controller.discovering, isFalse);
        expect(created.single.calls, isNot(contains('discovery_start')));
        expect(locks.last, isFalse);
        expect(held, isFalse);
        lockAction = null;
        await controller.enableReceiving();
        expectReplacementHealthy();
      },
    );
  }

  test(
    'runtime boundary: failed multicast release does not poison later cleanup',
    () async {
      await controller.enableReceiving();
      var failOnce = true;
      lockAction = (acquire) async {
        if (!acquire && failOnce) {
          failOnce = false;
          throw const TransferException('discovery_unavailable');
        }
      };
      await controller.stop();
      await controller.enableReceiving();
      expectReplacementHealthy();
      await controller.stop();
      expect(held, isFalse);
      expect(controller.stopping, isFalse);
    },
  );
}
