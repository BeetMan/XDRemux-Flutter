// Explicit real-DLL checks, using owned loopback receivers and synthetic files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import '../tool/transfer_worker_smoke.dart' show check, event, fileHash, until;

class _LinkedNative extends TransferService {
  _LinkedNative(this.library);
  final String library;
  final dispatched = <String>[];
  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) => super.start(
    supportRoot: supportRoot,
    libraryPath: library,
    bind: bind,
    alias: alias,
    pin: pin,
  );
  @override
  Future<dynamic> command(Map<String, dynamic> request) {
    if (['send', 'send_batch', 'retry_send'].contains(request['command'])) {
      dispatched.add(request['command'] as String);
    }
    return super.command(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XDREMUX_TRANSFER_TEST_DLL'];
  final reportPath =
      Platform.environment['XDREMUX_TRANSFER_CONFIRMATION_REPORT'];
  final skip =
      !Platform.isWindows || library == null || !File(library).existsSync();
  final checks = <String>[];
  late Directory root;
  late TransferController controller;
  late _LinkedNative outbound;
  late Completer<Directory> startup;
  final receivers = <TransferService>[];
  setUp(() async {
    if (skip) return;
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('xdremux-confirmation-');
    outbound = _LinkedNative(library);
    startup = Completer<Directory>();
    controller = TransferController(
      serviceFactory: () => outbound,
      supportDirectory: () => startup.future,
      observeLifecycle: false,
    );
  });
  tearDown(() async {
    if (skip) return;
    if (!startup.isCompleted) {
      startup.complete(Directory('${root.path}/sender'));
    }
    await controller.stop();
    controller.dispose();
    for (final receiver in receivers) {
      await receiver.dispose();
    }
    receivers.clear();
    final owned = await root.resolveSymbolicLinks();
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    check(
      await Directory(owned).parent.resolveSymbolicLinks() == temporary &&
          Directory(owned).uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('xdremux-confirmation-'),
      'Owned temporary directory before cleanup',
    );
    await Directory(owned).delete(recursive: true);
  });
  Future<TransferService> receiver(String name) async {
    final service = TransferService();
    receivers.add(service);
    check(
      (await service.start(
        supportRoot: '${root.path}/$name',
        libraryPath: library,
      )).available,
      'Real fixture receiver',
    );
    return service;
  }

  Map<String, dynamic> peer(TransferService service) => {
    'address': service.ready!['address'],
    'fingerprint': service.ready!['fingerprint'],
  };

  test(
    'real DLL confirmation revocation during startup never dispatches file metadata',
    () async {
      final target = await receiver('target');
      final selected = peer(target);
      final source = File('${root.path}/selected.bin');
      await source.writeAsString('owned fixture, not shared after revocation');
      await controller.confirmPeer(selected, remember: false);
      final sending = controller.send(selected, [source.path]);
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
      await controller.forgetPeers();
      startup.complete(Directory('${root.path}/sender'));
      await rejected;
      expect(outbound.dispatched, isEmpty);
      expect(
        (await target.command({
          'command': 'snapshot',
          'limit': 64,
        }))['transfers'],
        isEmpty,
      );
      expect(
        await target.command({'command': 'receipts', 'limit': 64}),
        isEmpty,
      );
      checks.add('revocation_before_dispatch_sends_no_metadata_or_content');
    },
    skip: skip,
  );

  test(
    'real DLL startup preserves selected receiver and source despite caller mutation',
    () async {
      final selectedReceiver = await receiver('selected');
      final otherReceiver = await receiver('other');
      final selected = peer(selectedReceiver);
      final source = File('${root.path}/selected.bin');
      final replacement = File('${root.path}/replacement.bin');
      await source.writeAsBytes(List.generate(65536, (i) => i % 251));
      await replacement.writeAsString(
        'owned replacement must never be offered',
      );
      final expectedHash = await fileHash(source);
      final paths = [source.path];
      await controller.confirmPeer(selected, remember: false);
      final sending = controller.send(selected, paths);
      selected.addAll(peer(otherReceiver));
      paths[0] = replacement.path;
      startup.complete(Directory('${root.path}/sender'));
      final id = await sending;
      final offer = (await event(selectedReceiver, 'offer'))['offer'];
      expect(offer['files'].length, 1);
      expect(offer['files'][0]['name'], 'selected.bin');
      await selectedReceiver.command({
        'command': 'decide',
        'transfer_id': offer['session_id'],
        'accept': true,
      });
      await until<bool>(() async {
        await controller.poll();
        return controller.transfers[id]?['phase'] == 'completed' ? true : null;
      });
      final receipts =
          await selectedReceiver.command({'command': 'receipts', 'limit': 64})
              as List;
      expect(receipts.length, 1);
      final lease = await selectedReceiver.command({
        'command': 'acquire_receipt',
        'receipt_id': receipts.single['id'],
      });
      try {
        expect(await fileHash(File(lease['path'])), expectedHash);
      } finally {
        await selectedReceiver.command({
          'command': 'release_receipt',
          'lease_id': lease['lease_id'],
        });
      }
      expect(
        (await otherReceiver.command({
          'command': 'snapshot',
          'limit': 64,
        }))['transfers'],
        isEmpty,
      );
      expect(
        await otherReceiver.command({'command': 'receipts', 'limit': 64}),
        isEmpty,
      );
      expect(await fileHash(source), expectedHash);
      checks.add('selected_receiver_and_source_snapshot_survive_async_startup');
      if (reportPath != null) {
        expect(checks.length, 2);
        await File(reportPath).writeAsString(
          jsonEncode({
            'passed': true,
            'scope':
                'Windows real DLL and Dart worker over owned loopback HTTPS',
            'checks': checks,
            'receivedFiles': 1,
            'receivedBytes': await source.length(),
            'independentSha256': expectedHash,
            'sourceUnchanged': true,
            'unselectedReceiverReceivedNothing': true,
            'librarySha256': await fileHash(File(library!)),
          }),
          flush: true,
        );
      }
    },
    skip: skip,
  );
}
