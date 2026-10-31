import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_queue.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import '../tool/transfer_worker_smoke.dart' show event, fileHash;

class _LibraryService extends TransferService {
  _LibraryService(this.library);
  final String library;
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
}

class _StorageController extends TransferController {
  _StorageController({
    required super.serviceFactory,
    required super.supportDirectory,
  }) : super(observeLifecycle: false);
  // Drive transfer events explicitly; storage methods and stop use production code.
  @override
  Future<void> poll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XDREMUX_TRANSFER_TEST_DLL'];
  test(
    'real DLL storage cleanup honors read leases and preserves adopted copies',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xdremux-storage-native-',
      );
      SharedPreferences.setMockInitialValues({});
      final sender = TransferService(), receiver = _LibraryService(library!);
      final support = await Directory('${root.path}/receiver').create();
      final controller = _StorageController(
        serviceFactory: () => receiver,
        supportDirectory: () async => support,
      );
      final owner = Object();
      final retained = <String>{};
      TransferQueue.register(
        owner,
        (_) async => const TransferIntakeAck(TransferIntakeStatus.rejected),
        retainedInputs: () => retained,
      );
      Map<String, dynamic>? lease;
      Map<String, dynamic>? evidence;
      try {
        expect(
          (await sender.start(
            supportRoot: '${root.path}/sender',
            libraryPath: library,
          )).available,
          isTrue,
        );
        await controller.ensureLocal();
        final source = File('${root.path}/照片🧪.jpg');
        final bytes = [
          255,
          216,
          255,
          ...List.generate(128 * 1024, (i) => i % 256),
        ];
        await source.writeAsBytes(bytes);
        final hash = sha256.convert(bytes).toString();
        final peer = await sender.command({
          'command': 'probe',
          'address': receiver.ready!['address'],
        });
        await sender.command({
          'command': 'send',
          'peer': peer,
          'paths': [source.path],
        });
        final offer = (await event(receiver, 'offer'))['offer'];
        expect(offer['peer_fingerprint'], sender.ready!['fingerprint']);
        expect(
          (offer['files'] as List).single['name'],
          source.uri.pathSegments.last,
        );
        await receiver.command({
          'command': 'decide',
          'transfer_id': offer['session_id'],
          'accept': true,
        });
        expect((await event(sender, 'sent'))['report']['error'], isNull);
        final receipt =
            (await receiver.command({'command': 'receipts', 'limit': 64})
                    as List)
                .single;
        final id = receipt['id'] as String;
        lease = Map<String, dynamic>.from(
          await receiver.command({
                'command': 'acquire_receipt',
                'receipt_id': id,
              })
              as Map,
        );
        final copied = await receiver.prepareInput(id);
        retained.add(copied.path);
        final plan = await controller.inspectStorage();
        expect(plan.countFor('inbox'), 1);
        expect(plan.bytesFor('inbox'), bytes.length);
        expect(plan.countFor('copy'), 1);
        expect(
          plan.items.singleWhere((item) => item.kind == 'copy').reason,
          'queue',
        );
        final first = await controller.cleanStorage(plan, {'inbox:$id'});
        expect(first.failed, {'inbox:$id': 'busy'});
        expect(await fileHash(File(lease['path'] as String)), hash);
        await receiver.command({
          'command': 'release_receipt',
          'lease_id': lease['lease_id'],
        });
        lease = null;
        final retried = await controller.cleanStorage(
          await controller.inspectStorage(),
          {'inbox:$id'},
        );
        expect(retried.deleted, {'inbox:$id'});
        expect(
          await receiver.command({'command': 'receipts', 'limit': 64}),
          isEmpty,
        );
        expect(await fileHash(File(copied.path)), hash);
        expect(await fileHash(source), hash);
        retained.clear();
        final unused = await controller.inspectStorage();
        expect(unused.items.single.canClean, isTrue);
        expect(
          (await controller.cleanStorage(unused, {
            unused.items.single.id,
          })).failed,
          isEmpty,
        );
        expect(await File(copied.path).exists(), isFalse);
        expect(await source.exists(), isTrue);
        evidence = {
          'passed': true,
          'realDllAndWorker': true,
          'leasedInboxDeletionRejected': true,
          'explicitRetryAfterRelease': true,
          'adoptedCopyPreserved': true,
          'unreferencedCopyExplicitlyCleaned': true,
          'sourceSha256': hash,
          'sourceUnchanged': true,
          'librarySha256': await fileHash(File(library)),
        };
      } finally {
        if (lease != null) {
          await receiver.command({
            'command': 'release_receipt',
            'lease_id': lease['lease_id'],
          });
        }
        TransferQueue.unregister(owner);
        await sender.dispose();
        await controller.stop();
        controller.dispose();
        await root.delete(recursive: true);
      }
      final report = Platform.environment['XDREMUX_TRANSFER_STORAGE_REPORT'];
      if (report != null) {
        evidence['cleanupCompleted'] = true;
        await File(report).writeAsString(jsonEncode(evidence));
      }
    },
    skip: !Platform.isWindows || library == null || !File(library).existsSync(),
  );
}
