import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'package:xdremux/services/xdremux_service.dart';
import 'package:xdremux/transfer_page.dart';

class _Native extends TransferService {
  final calls = <Map<String, dynamic>>[];
  bool ended = false;
  String phase = 'pending';
  bool multicastUnavailable = false;
  bool commandsClosed = false;
  String? startError;
  String? probeError;
  Future<void>? probeGate;
  Future<void>? startGate;
  Completer<void>? startEntered;
  int startCalls = 0;
  String direction = 'receive';
  bool retryAvailable = false;
  List<Map<String, dynamic>>? fileRows;
  final discovered = <Map<String, dynamic>>[];
  final receipts = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];
  String? lastAlias;
  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
    startCalls++;
    lastAlias = alias;
    startEntered?.complete();
    await startGate;
    if (startError != null) return TransferAvailability(false, startError);
    ready = {
      'address': bind,
      'fingerprint': 'A' * 64,
      'core_instance_id': 'test',
    };
    return const TransferAvailability(true);
  }

  @override
  Future<dynamic> command(Map<String, dynamic> command) async {
    calls.add(command);
    if (commandsClosed) throw const TransferException('closed');
    switch (command['command']) {
      case 'probe':
        await probeGate;
        if (probeError != null) throw TransferException(probeError!);
        return {'address': command['address'], 'fingerprint': 'B' * 64};
      case 'discovery_start':
        if (multicastUnavailable) {
          throw const TransferException('discovery_unavailable');
        }
        return {'enabled': true, 'error': null, 'peers': discovered};
      case 'discovery_status':
        return {
          'enabled': !multicastUnavailable,
          'error': multicastUnavailable ? 'discovery_unavailable' : null,
          'peers': discovered,
        };
      case 'send':
      case 'send_batch':
      case 'retry_send':
        return {'transfer_id': 'send-1'};
      case 'decide':
        phase = command['accept'] == true ? 'accepted' : 'failed';
        return null;
      case 'snapshot':
        return {
          'transfers': [
            {
              'id': 'receive-1',
              'phase': phase,
              'direction': direction,
              'retry_available': retryAvailable,
              'file_count': fileRows?.length ?? 1,
              'alias': 'Test',
              'peer_fingerprint': 'B' * 64,
            },
          ],
          'next': null,
        };
      case 'transfer':
        if (fileRows != null) {
          final filtered = fileRows!
              .where(
                (f) =>
                    command['after'] == null ||
                    (f['id'] as String).compareTo(command['after'] as String) >
                        0,
              )
              .toList();
          return {
            'files': filtered.take(64).toList(),
            'next': filtered.length > 64 ? filtered[63]['id'] : null,
          };
        }
        return {
          'files': [
            {
              'id': 'file-1',
              'name': 'photo.heic',
              'size': 3,
              'bytes': 0,
              'phase': 'waiting',
            },
          ],
          'next': null,
        };
      case 'receipts':
        return receipts
            .where(
              (r) =>
                  command['after'] == null ||
                  (r['id'] as String).compareTo(command['after'] as String) > 0,
            )
            .take(64)
            .toList();
      case 'acquire_receipt':
        return {
          'lease_id': 1,
          'path': '/private/data',
          'receipt': {'size': 3},
        };
      default:
        return null;
    }
  }

  @override
  Future<Map<String, dynamic>> drainEvents() async {
    final next = List.of(events);
    events.clear();
    return {'events': next, 'resync': false};
  }

  @override
  Future<void> dispose() async {
    ended = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late TransferController controller;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    native = _Native();
    controller = TransferController(
      serviceFactory: () => native,
      supportDirectory: () async => Directory.systemTemp,
      observeLifecycle: false,
    );
  });
  tearDown(() async {
    await controller.stop();
    controller.dispose();
  });
  for (final state in [
    ('completed', 'sent'),
    ('completed', 'committed'),
    ('failed', 'failed'),
    ('transferring', 'sent'),
    ('transferring', 'failed'),
  ]) {
    test(
      'terminal boundary: late progress preserves ${state.$1}/${state.$2}',
      () async {
        native.phase = state.$1;
        native.fileRows = [
          {
            'id': 'file-1',
            'name': 'photo.heic',
            'size': 3,
            'bytes': 3,
            'phase': state.$2,
            'error': state.$2 == 'failed' ? 'checksum_mismatch' : null,
          },
        ];
        await controller.ensureLocal();
        native.events.add({
          'kind': 'event',
          'event': {
            'kind': 'progress',
            'transfer_id': 'receive-1',
            'file_id': 'file-1',
            'bytes': 1,
            'total': 3,
          },
        });
        await controller.poll();
        final file = controller.files['receive-1']!.single;
        expect(file['phase'], state.$2);
        expect(file['bytes'], 3);
        if (state.$2 == 'failed') expect(file['error'], 'checksum_mismatch');
      },
    );
  }
  for (final bytes in [1, 9]) {
    test(
      'terminal boundary: live progress $bytes stays monotonic and bounded',
      () async {
        native.phase = 'transferring';
        native.fileRows = [
          {
            'id': 'file-1',
            'name': 'photo.heic',
            'size': 3,
            'bytes': 2,
            'phase': 'transferring',
          },
        ];
        await controller.ensureLocal();
        native.events.add({
          'kind': 'event',
          'event': {
            'kind': 'progress',
            'transfer_id': 'receive-1',
            'file_id': 'file-1',
            'bytes': bytes,
            'total': 3,
          },
        });
        await controller.poll();
        expect(
          controller.files['receive-1']!.single['bytes'],
          bytes == 1 ? 2 : 3,
        );
      },
    );
  }
  test(
    'terminal boundary: live failed file refreshes for a peer retry',
    () async {
      native.phase = 'transferring';
      native.fileRows = [
        {
          'id': 'file-1',
          'name': 'photo.heic',
          'size': 3,
          'bytes': 3,
          'phase': 'failed',
          'error': 'checksum_mismatch',
        },
      ];
      await controller.ensureLocal();
      native.fileRows = [
        {
          'id': 'file-1',
          'name': 'photo.heic',
          'size': 3,
          'bytes': 1,
          'phase': 'transferring',
          'error': 'checksum_mismatch',
        },
      ];
      native.events.add({
        'kind': 'event',
        'event': {
          'kind': 'progress',
          'transfer_id': 'receive-1',
          'file_id': 'file-1',
          'bytes': 1,
          'total': 3,
        },
      });
      await controller.poll();
      expect(controller.files['receive-1']!.single['phase'], 'transferring');
      expect(controller.files['receive-1']!.single['bytes'], 1);
    },
  );

  Future<Completer<Directory>> gateStartup() async {
    await controller.stop();
    controller.dispose();
    final gate = Completer<Directory>();
    controller = TransferController(
      serviceFactory: () => native,
      supportDirectory: () => gate.future,
      observeLifecycle: false,
    );
    return gate;
  }

  for (final receive in [false, true]) {
    test(
      'startup boundary: stop during directory selection receive=$receive',
      () async {
        final gate = await gateStartup();
        final opening = receive
            ? controller.enableReceiving()
            : controller.ensureLocal();
        final rejected = expectLater(
          opening,
          throwsA(
            isA<TransferException>().having((e) => e.code, 'code', 'closed'),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.starting, isTrue);
        final closing = controller.stop();
        gate.complete(Directory.systemTemp);
        await Future.wait([rejected, closing]);
        expect(controller.running, isFalse);
        expect(controller.receiving, isFalse);
        expect(native.startCalls, 0);
        expect(native.ended, isTrue);
        expect(native.calls, isEmpty);
      },
    );
    test(
      'startup boundary: stop during native startup receive=$receive',
      () async {
        final gate = Completer<void>();
        native.startGate = gate.future;
        native.startEntered = Completer<void>();
        final opening = receive
            ? controller.enableReceiving()
            : controller.ensureLocal();
        final rejected = expectLater(
          opening,
          throwsA(
            isA<TransferException>().having((e) => e.code, 'code', 'closed'),
          ),
        );
        await native.startEntered!.future;
        final closing = controller.stop();
        expect(native.ended, isFalse);
        gate.complete();
        await Future.wait([rejected, closing]);
        expect(controller.running, isFalse);
        expect(controller.receiving, isFalse);
        expect(native.startCalls, 1);
        expect(native.ended, isTrue);
        expect(native.calls, isEmpty);
      },
    );
  }
  test(
    'startup boundary: a second stop revokes receive waiting for read cleanup',
    () async {
      await controller.ensureLocal();
      final entered = Completer<void>(), finish = Completer<void>();
      final reading = controller.withReceipt('id', (_) async {
        entered.complete();
        await finish.future;
      });
      await entered.future;
      final opening = controller.enableReceiving();
      final rejected = expectLater(
        opening,
        throwsA(
          isA<TransferException>().having((e) => e.code, 'code', 'closed'),
        ),
      );
      final closing = controller.stop();
      finish.complete();
      await Future.wait([reading, closing, rejected]);
      expect(controller.running, isFalse);
      expect(controller.receiving, isFalse);
      expect(native.startCalls, 1);
      expect(
        native.calls.where((c) => c['command'] == 'discovery_start'),
        isEmpty,
      );
    },
  );

  test(
    'confirmation boundary: revocation during startup prevents metadata dispatch',
    () async {
      final gate = await gateStartup();
      final peer = {'address': '127.0.0.1:53319', 'fingerprint': 'B' * 64};
      await controller.confirmPeer(peer, remember: false);
      final sending = controller.send(peer, ['/original.bin']);
      await controller.forgetPeers();
      final rejected = expectLater(
        sending,
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'identity_mismatch',
          ),
        ),
      );
      gate.complete(Directory.systemTemp);
      await rejected;
      expect(
        native.calls.where(
          (c) => ['send', 'send_batch'].contains(c['command']),
        ),
        isEmpty,
      );
    },
  );

  test(
    'confirmation boundary: startup keeps the selected recipient and source list',
    () async {
      final gate = await gateStartup();
      final peer = {'address': '127.0.0.1:53319', 'fingerprint': 'B' * 64};
      final paths = ['/original.bin'];
      await controller.confirmPeer(peer, remember: false);
      final sending = controller.send(peer, paths);
      peer['address'] = '127.0.0.1:53320';
      peer['fingerprint'] = 'C' * 64;
      paths[0] = '/replacement.bin';
      gate.complete(Directory.systemTemp);
      await sending;
      final request = native.calls.singleWhere((c) => c['command'] == 'send');
      expect(request['peer'], {
        'address': '127.0.0.1:53319',
        'fingerprint': 'B' * 64,
      });
      expect(request['paths'], ['/original.bin']);
    },
  );

  test(
    'confirmation boundary: malformed identity returns the stable error',
    () async {
      await expectLater(
        controller.send({'fingerprint': null}, ['/original.bin']),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'identity_mismatch',
          ),
        ),
      );
    },
  );

  Future<void> showConfirmedPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: TransferPage(
          controller: controller,
          initialPaths: const ['/photo.jpg'],
        ),
      ),
    );
    await tester.runAsync(controller.ensureLocal);
    await tester.enterText(
      find.byKey(const ValueKey('peer-host')),
      '127.0.0.1',
    );
    await tester.tap(find.byKey(const ValueKey('connect-peer')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已选择'), findsOneWidget);
  }

  for (final outcome in ['network']) {
    testWidgets(
      'confirmation boundary: reconnect $outcome clears the previous selection',
      (tester) async {
        await showConfirmedPage(tester);
        native.probeError = outcome;
        await tester.tap(find.byKey(const ValueKey('connect-peer')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('已选择'), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('send-files')))
              .onPressed,
          isNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'confirmation boundary: pending probe locks the displayed endpoint',
    (tester) async {
      await showConfirmedPage(tester);
      final gate = Completer<void>();
      native.probeGate = gate.future;
      await tester.tap(find.byKey(const ValueKey('connect-peer')));
      await tester.pump();
      final hostEnabled = tester
          .widget<TextField>(find.byKey(const ValueKey('peer-host')))
          .enabled;
      final portEnabled = tester
          .widget<TextField>(find.byKey(const ValueKey('peer-port')))
          .enabled;
      gate.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(hostEnabled, isFalse);
      expect(portEnabled, isFalse);
    },
  );

  test(
    'file metadata cannot be sent before fingerprint confirmation; forgetting revokes trust',
    () async {
      final peer = await controller.probe('127.0.0.1', 53319);
      await expectLater(
        controller.send(peer, ['/input.heic']),
        throwsA(isA<TransferException>()),
      );
      expect(native.calls.any((c) => c['command'] == 'send'), isFalse);
      await controller.confirmPeer(peer, remember: true);
      expect(await controller.send(peer, ['/input.heic']), 'send-1');
      expect(controller.trusted, contains('B' * 64));
      await controller.forgetPeers();
      await expectLater(
        controller.send(peer, ['/input.heic']),
        throwsA(isA<TransferException>()),
      );
    },
  );
  test(
    'stop waits for external document copy and releases lease before native disposal',
    () async {
      await controller.ensureLocal();
      final entered = Completer<void>(), finish = Completer<void>();
      final exporting = controller.withReceipt('id', (_) async {
        entered.complete();
        await finish.future;
      });
      await entered.future;
      final stopping = controller.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.ended, isFalse);
      finish.complete();
      await exporting;
      await stopping;
      expect(
        native.calls.any((c) => c['command'] == 'release_receipt'),
        isTrue,
      );
      expect(native.ended, isTrue);
      expect(controller.receiving, isFalse);
    },
  );
  test(
    'refresh retains loaded pages and commits outside the UUID cursor window',
    () async {
      native.receipts.addAll(
        List.generate(140, (i) => {'id': i.toString().padLeft(4, '0')}),
      );
      await controller.ensureLocal();
      expect(controller.inbox.length, 64);
      await controller.loadInbox();
      expect(controller.inbox.length, 128);
      final late = {'id': 'zzzz'};
      native.receipts.add(late);
      native.events.add({
        'kind': 'event',
        'event': {'kind': 'committed', 'receipt': late},
      });
      await controller.poll();
      expect(controller.inbox.length, 129);
      expect(controller.inbox, contains('zzzz'));
      await controller.refresh();
      expect(controller.inbox.length, 129);
      await controller.loadInbox();
      expect(controller.inbox.length, 141);
      expect(controller.moreInbox, isFalse);
      await controller.refresh();
      expect(controller.inbox.length, 141);
    },
  );
  test(
    'multicast failure leaves receiving and manual sends available',
    () async {
      native.multicastUnavailable = true;
      await controller.enableReceiving();
      expect(controller.receiving, isTrue);
      expect(controller.discovering, isFalse);
      expect(controller.discoveryError, 'discovery_unavailable');
      final peer = await controller.probe('127.0.0.1', 53319);
      await controller.confirmPeer(peer, remember: false);
      expect(await controller.send(peer, ['/photo.jpg']), 'send-1');
      await controller.stop();
      expect(controller.receiving, isFalse);
      expect(controller.discovering, isFalse);
    },
  );
  test(
    'stopped event wins over a discovery query on a closed runtime',
    () async {
      await controller.enableReceiving();
      native.events.add({'kind': 'stopped'});
      native.commandsClosed = true;
      await controller.poll();
      await Future<void>.delayed(Duration.zero);
      expect(controller.receiving, isFalse);
      expect(controller.running, isFalse);
      expect(controller.discovering, isFalse);
      expect(native.ended, isTrue);
      expect(controller.error, 'closed');
    },
  );
  test(
    'closed command without a retained stopped event clears stale receiving',
    () async {
      await controller.enableReceiving();
      native.commandsClosed = true;
      await controller.poll();
      await Future<void>.delayed(Duration.zero);
      expect(controller.receiving, isFalse);
      expect(controller.running, isFalse);
      expect(native.ended, isTrue);
    },
  );
  for (final body in [
    {'kind': 'fatal'},
    {
      'kind': 'event',
      'event': {'kind': 'stopped'},
    },
  ]) {
    test('terminal ${body['kind']} does not query discovery again', () async {
      await controller.enableReceiving();
      native.calls.clear();
      native.events.add(body);
      native.commandsClosed = true;
      await controller.poll();
      expect(controller.receiving, isFalse);
      expect(native.ended, isTrue);
      expect(native.calls, isEmpty);
    });
  }
  test(
    'asynchronous discovery failure clears peers and explicit refresh recovers',
    () async {
      native.discovered.add({
        'alias': 'Peer',
        'address': '192.168.1.2:53319',
        'fingerprint': 'B' * 64,
      });
      await controller.enableReceiving();
      expect(controller.peers, hasLength(1));
      native.multicastUnavailable = true;
      await controller.poll();
      expect(controller.receiving, isTrue);
      expect(controller.discovering, isFalse);
      expect(controller.peers, isEmpty);
      expect(controller.discoveryError, 'discovery_unavailable');
      native.multicastUnavailable = false;
      await controller.discover();
      expect(controller.discovering, isTrue);
      expect(controller.discoveryError, isNull);
      expect(controller.peers, hasLength(1));
      expect(native.calls.any((c) => c['command'] == 'send'), isFalse);
    },
  );
  test(
    'a stopped controller waits for an explicit restart with a new runtime',
    () async {
      final created = <_Native>[];
      final owner = TransferController(
        serviceFactory: () {
          final service = _Native();
          created.add(service);
          return service;
        },
        supportDirectory: () async => Directory.systemTemp,
        observeLifecycle: false,
      );
      try {
        await owner.enableReceiving();
        created.single.commandsClosed = true;
        await owner.poll();
        expect(owner.running, isFalse);
        expect(created, hasLength(1));
        await owner.enableReceiving();
        expect(created, hasLength(2));
        expect(owner.receiving, isTrue);
        expect(owner.error, isNull);
      } finally {
        await owner.stop();
        owner.dispose();
      }
    },
  );
  test(
    '1000 sibling paths fit the bounded request and every file page is loaded',
    () async {
      final peer = await controller.probe('127.0.0.1', 53319);
      await controller.confirmPeer(peer, remember: false);
      await controller.send(
        peer,
        List.generate(
          1000,
          (i) =>
              '${Directory.systemTemp.path}/a-very-long-test-directory/p23-$i.bin',
        ),
      );
      final batch = native.calls.lastWhere((c) => c['command'] == 'send_batch');
      expect((batch['names'] as List).length, 1000);
      expect(batch.containsKey('paths'), isFalse);
      native.fileRows = List.generate(
        130,
        (i) => {
          'id': i.toString().padLeft(4, '0'),
          'name': 'p23-$i.bin',
          'size': 0,
          'bytes': 0,
          'phase': 'waiting',
        },
      );
      await controller.refresh();
      expect(controller.files['receive-1']!.length, 130);
      await controller.send(peer, [
        '/a.bin',
      ]); // regular single-file command remains supported
      await expectLater(
        controller.send(
          peer,
          List.generate(
            1000,
            (i) =>
                '${Directory.systemTemp.path}/unique-folder-$i/${'x' * 100}.bin',
          ),
        ),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'batch_too_large',
          ),
        ),
      );
    },
  );
  testWidgets('conversion list adds converted outputs, then originals', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('queue').path;
    for (final name in ['A.HEIC', 'A_iso.heic', 'B.HEIC']) {
      File('$dir/$name').writeAsBytesSync([1]);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: TransferPage(
          controller: controller,
          sources: [
            TransferSource(
              name: 'A.HEIC',
              original: '$dir/A.HEIC',
              converted: ['$dir/A_iso.heic'],
            ),
            TransferSource(name: 'B.HEIC', original: '$dir/B.HEIC'),
          ],
        ),
      ),
    );
    Future<void> add() async {
      await tester.tap(find.byKey(const ValueKey('add-from-queue')));
      await tester.pumpAndSettle();
    }

    await add();
    expect(find.text('尚未转换'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-queue-sources')));
    await tester.pumpAndSettle();
    expect(find.text('A_iso.heic'), findsOneWidget);
    expect(find.text('B.HEIC'), findsNothing);
    await add();
    await tester.tap(find.text('原文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-queue-sources')));
    await tester.pumpAndSettle();
    expect(find.text('A_iso.heic'), findsOneWidget);
    expect(find.text('A.HEIC'), findsOneWidget);
    expect(find.text('B.HEIC'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('a subnet scan finds a peer that multicast missed', () async {
    final server = await ServerSocket.bind('127.0.0.1', 53317);
    final accepted = server.listen((socket) => socket.destroy());
    addTearDown(() async {
      await accepted.cancel();
      await server.close();
    });
    await controller.enableReceiving();
    controller.addresses = ['127.0.0.9'];
    await controller.scanSubnet();
    expect(controller.scanning, isFalse);
    final found = controller.peers.singleWhere(
      (p) => p['address'] == '127.0.0.1:53317',
    );
    expect(found['fingerprint'], 'B' * 64);
    // A later multicast update keeps the scanned peer.
    await controller.discover();
    expect(
      controller.peers.where((p) => p['address'] == '127.0.0.1:53317'),
      hasLength(1),
    );
  });

  testWidgets('a still and its same-named MOV read as one Live Photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    native.receipts.addAll([
      {'id': 'a', 'name': 'IMG_7.HEIC', 'size': 3},
      {'id': 'b', 'name': 'IMG_7.MOV', 'size': 3},
      {'id': 'c', 'name': 'notes.txt', 'size': 3},
    ]);
    XdRemuxService.thumbnailRendererForTesting = (_, _) async => null;
    addTearDown(() => XdRemuxService.thumbnailRendererForTesting = null);
    await tester.runAsync(controller.ensureLocal);
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-receive')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('实况照片'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('clear-inbox')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('confirm-clear-inbox')));
    for (var i = 0; i < 10 && controller.inbox.isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(controller.inbox, isEmpty);
    expect(
      native.calls.where((c) => c['command'] == 'delete_receipt'),
      hasLength(3),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a .pvt Live Photo is sent as one .pvt.zip', (tester) async {
    final bundle = Directory.systemTemp.createTempSync('live').path;
    final pvt = Directory('$bundle/IMG_1.pvt')..createSync();
    for (final name in ['IMG_1.HEIC', 'IMG_1.MOV', 'metadata.plist']) {
      File('${pvt.path}/$name').writeAsBytesSync([1, 2, 3]);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: TransferPage(controller: controller, initialPaths: [pvt.path]),
      ),
    );
    for (var i = 0; i < 20 && find.text('IMG_1.pvt.zip').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text('IMG_1.pvt.zip'), findsOneWidget);
    expect(find.text('IMG_1.HEIC'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'a changed discovery identity cannot reach confirmation or send',
    (tester) async {
      native.discovered.add({
        'alias': 'Discovered',
        'address': '192.168.31.53:53319',
        'fingerprint': 'C' * 64,
      });
      await tester.pumpWidget(
        MaterialApp(home: TransferPage(controller: controller)),
      );
      await tester.runAsync(() => controller.enableReceiving());
      await tester.pump();
      final device = find.byKey(ValueKey('peer-${'C' * 64}'));
      await tester.ensureVisible(device);
      await tester.tap(device);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('已选择'), findsNothing);
      expect(find.textContaining('设备身份发生变化'), findsOneWidget);
      expect(
        native.calls.where(
          (c) => ['send', 'send_batch', 'retry_send'].contains(c['command']),
        ),
        isEmpty,
      );
      expect(controller.trusted, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'retry requires verified identity and an explicit replay decision',
    (tester) async {
      native.phase = 'failed';
      native.direction = 'send';
      native.retryAvailable = true;
      native.discovered.add({
        'alias': 'Discovered',
        'address': '192.168.31.53:53319',
        'fingerprint': 'B' * 64,
      });
      await tester.pumpWidget(
        MaterialApp(home: TransferPage(controller: controller)),
      );
      await tester.runAsync(() => controller.enableReceiving());
      await tester.pump();
      final retry = find.byKey(const ValueKey('retry-receive-1'));
      await tester.scrollUntilVisible(
        retry,
        300,
        scrollable: _tabScroll,
      );
      expect(tester.widget<TextButton>(retry).onPressed, isNull);
      final device = find.byKey(ValueKey('peer-${'B' * 64}'));
      await tester.scrollUntilVisible(
        device,
        -300,
        scrollable: _tabScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(device);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.scrollUntilVisible(
        retry,
        300,
        scrollable: _tabScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('confirm-retry')), findsOneWidget);
      expect(native.calls.any((c) => c['command'] == 'retry_send'), isFalse);
      await tester.tap(find.byKey(const ValueKey('confirm-retry')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(native.calls.where((c) => c['command'] == 'retry_send').length, 1);
      await controller.stop();
      expect(controller.transfers, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a renamed device announces its new name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-receive')));
    await tester.pumpAndSettle();
    final edit = find.byKey(const ValueKey('edit-device-name'));
    for (var i = 0; i < 10 && edit.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.tap(edit);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('device-name-field')),
      '  Desk Phone ',
    );
    await tester.tap(find.byKey(const ValueKey('save-device-name')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Desk Phone'), findsOneWidget);
    // Reception announces the saved name.
    await tester.runAsync(() => controller.enableReceiving());
    expect(native.lastAlias, 'Desk Phone');
    await tester.runAsync(controller.stop);
    await tester.runAsync(() => TransferController.setDeviceName(null));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('the send tab can start discovery itself', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(controller: controller)),
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('start-discovery'))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.receiving, isTrue);
    expect(find.byKey(const ValueKey('start-discovery')), findsNothing);
    await tester.runAsync(controller.stop);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('a terminated runtime returns the page to explicit enable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-receive')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => controller.enableReceiving());
    await tester.pump();
    expect(find.text('停止接收'), findsOneWidget);
    native.commandsClosed = true;
    native.events.add({'kind': 'stopped'});
    await tester.runAsync(controller.poll);
    await tester.pump();
    expect(find.text('开启接收'), findsOneWidget);
    expect(find.text('停止接收'), findsNothing);
    expect(find.text('接收已关闭'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('port collision leaves the listen port editable for retry', (
    tester,
  ) async {
    native.startError = 'port_in_use';
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('tab-receive')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('receive-toggle'))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('接收端口已被占用'), findsOneWidget);
    expect(controller.receiving, isFalse);
    await tester.enterText(find.byKey(const ValueKey('listen-port')), '53320');
    native.startError = null;
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('receive-toggle'))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.receiving, isTrue);
    expect(native.ready!['address'], '0.0.0.0:53320');
    await tester.runAsync(controller.stop);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'page requires a selected device and explicit offer acceptance',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TransferPage(
            controller: controller,
            initialPaths: const ['/photo.jpg'],
          ),
        ),
      );
      expect(
        (tester.widget<FilledButton>(
          find.byKey(const ValueKey('send-files')),
        )).onPressed,
        isNull,
      );
      await tester.runAsync(() => controller.enableReceiving());
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('接收全部'),
        200,
        scrollable: _tabScroll,
      );
      expect(find.text('接收全部'), findsOneWidget);
      expect(native.calls.any((c) => c['command'] == 'decide'), isFalse);
      await tester.ensureVisible(find.text('接收全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接收全部'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(
        native.calls.lastWhere((c) => c['command'] == 'decide')['accept'],
        isTrue,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('peer-host')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('peer-host')),
        '127.0.0.1',
      );
      await tester.tap(find.byKey(const ValueKey('connect-peer')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Selecting a device never sends by itself.
      expect(native.calls.any((c) => c['command'] == 'send'), isFalse);
      expect(
        (tester.widget<FilledButton>(
          find.byKey(const ValueKey('send-files')),
        )).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

/// The vertical scroll view of whichever transfer tab is showing.
final _tabScroll = find
    .descendant(
      of: find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView &&
            (w.key == const ValueKey('send-tab') ||
                w.key == const ValueKey('receive-tab')),
      ),
      matching: find.byType(Scrollable),
    )
    .first;
