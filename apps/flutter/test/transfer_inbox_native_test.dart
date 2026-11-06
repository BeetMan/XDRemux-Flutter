import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import '../tool/transfer_worker_smoke.dart' show check, event, fileHash;

// Schedule controller polling explicitly so the timer cannot consume the one
// native page that this fixture deliberately delays. Native worker polling runs.
class _ManualController extends TransferController {
  _ManualController({
    required super.serviceFactory,
    required super.supportDirectory,
  }) : super(observeLifecycle: false);
  @override
  Future<void> poll() async {}
  Future<void> pollNow() => super.poll();
}

class _InboxNative extends TransferService {
  _InboxNative(this.library);
  final String library;
  bool holdNextPage = false;
  final captured = Completer<void>(), resume = Completer<void>();
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
  Future<dynamic> command(Map<String, dynamic> request) async {
    final result = await super.command(request);
    if (request['command'] == 'receipts' && holdNextPage) {
      holdNextPage = false;
      captured.complete();
      await resume.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XDREMUX_TRANSFER_TEST_DLL'];
  final report = Platform.environment['XDREMUX_TRANSFER_INBOX_REPORT'];
  final skip =
      !Platform.isWindows || library == null || !File(library).existsSync();
  test(
    'real DLL deletion survives an older inbox page and preserves leased data',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('xdremux-inbox-');
      final created = <_InboxNative>[];
      final controller = _ManualController(
        serviceFactory: () {
          final service = _InboxNative(library!);
          created.add(service);
          return service;
        },
        supportDirectory: () async => Directory('${root.path}/receiver'),
      );
      final sender = TransferService();
      Future<void>? loading;
      try {
        await controller.ensureLocal();
        final native = created.single;
        final identity = Map<String, dynamic>.from(controller.ready!);
        check(
          (await sender.start(
            supportRoot: '${root.path}/sender',
            libraryPath: library,
          )).available,
          'Real sender startup',
        );
        final source = File('${root.path}/original.bin');
        await source.writeAsBytes(List.generate(65536, (i) => i % 251));
        final hash = await fileHash(source);
        final peer = await sender.command({
          'command': 'probe',
          'address': controller.ready!['address'],
        });
        expect(peer['fingerprint'], controller.ready!['fingerprint']);
        await sender.command({
          'command': 'send',
          'peer': peer,
          'paths': [source.path],
        });
        final offer = (await event(native, 'offer'))['offer'];
        // Owned fixture acceptance uses the raw service; the controller stays in
        // inbox-only loopback mode throughout, with no LAN reception or discovery.
        await native.command({
          'command': 'decide',
          'transfer_id': offer['session_id'],
          'accept': true,
        });
        final committed = (await event(native, 'committed'))['receipt'] as Map;
        final id = committed['id'] as String;
        await controller.refresh();
        expect(controller.inbox, contains(id));
        final original = await controller.withReceipt<String>(id, (
          lease,
        ) async {
          expect(await fileHash(File(lease['path'] as String)), hash);
          return lease['path'] as String;
        });

        native.holdNextPage = true;
        loading = controller.loadInbox(reset: true);
        await native.captured.future.timeout(const Duration(seconds: 10));
        await controller.withReceipt(id, (_) async {
          await expectLater(
            controller.deleteReceipt(id),
            throwsA(
              isA<TransferException>().having((e) => e.code, 'code', 'busy'),
            ),
          );
          expect(await fileHash(File(original)), hash);
          expect(controller.inbox, contains(id));
        });
        await controller.deleteReceipt(id);
        expect(await File(original).exists(), isFalse);
        expect(
          await native.command({'command': 'receipts', 'limit': 64}),
          isEmpty,
        );
        native.resume.complete();
        await loading;
        expect(controller.inbox, isEmpty);
        await controller.pollNow();
        expect(controller.inbox, isEmpty);
        await controller.stop();
        await controller.ensureLocal();
        expect(controller.inbox, isEmpty);
        expect(controller.ready!['fingerprint'], identity['fingerprint']);
        expect(
          controller.ready!['core_instance_id'],
          isNot(identity['core_instance_id']),
        );
        expect(await fileHash(source), hash);
        await controller.stop();
        if (report != null) {
          await File(report).writeAsString(
            jsonEncode({
              'passed': true,
              'scope':
                  'Real Windows DLL and worker over owned loopback HTTPS; one synthetic inbox file',
              'controllerPolling': 'explicitly scheduled by fixture',
              'nativeWorkerPollingUnchanged': true,
              'leasedDeletionRejectedWithBusy': true,
              'leasedFileHashPreserved': true,
              'acknowledgedDeletionRemovedDiskFile': true,
              'nativeReceiptsEmpty': true,
              'olderNativePageCannotResurrectReceipt': true,
              'explicitRestartInboxEmpty': true,
              'sameRootIdentityPreserved': true,
              'sourceUnchanged': true,
              'receivedBytes': await source.length(),
              'independentSha256': hash,
              'librarySha256': await fileHash(File(library!)),
            }),
            flush: true,
          );
        }
      } finally {
        for (final native in created) {
          if (!native.resume.isCompleted) native.resume.complete();
        }
        try {
          await loading;
        } catch (_) {}
        await controller.stop();
        controller.dispose();
        await sender.dispose();
        final owned = await root.resolveSymbolicLinks();
        final temporary = await Directory.systemTemp.resolveSymbolicLinks();
        check(
          await Directory(owned).parent.resolveSymbolicLinks() == temporary &&
              Directory(owned).uri.pathSegments
                  .where((s) => s.isNotEmpty)
                  .last
                  .startsWith('xdremux-inbox-'),
          'Owned temporary directory before cleanup',
        );
        await Directory(owned).delete(recursive: true);
      }
    },
    skip: skip,
  );
}
