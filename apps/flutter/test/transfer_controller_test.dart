import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'package:xdremux/transfer_page.dart';

class _Native extends TransferService {
  final calls = <Map<String, dynamic>>[];
  bool ended = false;
  String phase = 'pending';
  bool multicastUnavailable = false;
  String direction = 'receive';
  bool retryAvailable = false;
  List<Map<String, dynamic>>? fileRows;
  final discovered = <Map<String, dynamic>>[];
  final receipts = <Map<String, dynamic>>[];
  final events = <Map<String, dynamic>>[];
  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
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
    switch (command['command']) {
      case 'probe':
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
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('confirm-peer')), findsNothing);
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
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<TextButton>(retry).onPressed, isNull);
      final device = find.byKey(ValueKey('peer-${'B' * 64}'));
      await tester.scrollUntilVisible(
        device,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(device);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('confirm-peer')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.scrollUntilVisible(
        retry,
        300,
        scrollable: find.byType(Scrollable).first,
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
  testWidgets(
    'page requires identity confirmation and explicit offer acceptance',
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
        scrollable: find.byType(Scrollable).first,
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
      // The page intentionally animates a progress bar while the dialog is open.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('confirm-peer')), findsOneWidget);
      expect(native.calls.any((c) => c['command'] == 'send'), isFalse);
      await tester.tap(find.byKey(const ValueKey('confirm-peer')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
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
