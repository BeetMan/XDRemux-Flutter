// Real worker/native startup delayed only after the owned HTTPS listener is ready.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import '../tool/transfer_worker_smoke.dart' show fileHash;

class _StartupNative extends TransferService {
  _StartupNative(this.library, {this.entered, this.resume});
  final String library;
  final Completer<void>? entered;
  final Future<void>? resume;
  final dispatched = <String>[];

  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
    final result = await super.start(
      supportRoot: supportRoot,
      libraryPath: library,
      bind: bind,
      alias: alias,
      pin: pin,
    );
    if (result.available) entered?.complete();
    await resume;
    return result;
  }

  @override
  Future<dynamic> command(Map<String, dynamic> request) {
    if ([
      'discovery_start',
      'send',
      'send_batch',
      'retry_send',
    ].contains(request['command'])) {
      dispatched.add(request['command'] as String);
    }
    return super.command(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XDREMUX_TRANSFER_TEST_DLL'];
  final reportPath = Platform.environment['XDREMUX_TRANSFER_STARTUP_REPORT'];
  final skip =
      !Platform.isWindows || library == null || !File(library).existsSync();
  final checks = <String>[];
  for (final receive in [false, true]) {
    test(
      'real DLL stop during startup receive=$receive releases port and root',
      () async {
        SharedPreferences.setMockInitialValues({});
        final root = await Directory.systemTemp.createTemp('xdremux-startup-');
        final entered = Completer<void>(), resume = Completer<void>();
        final created = <_StartupNative>[];
        final controller = TransferController(
          serviceFactory: () {
            final service = _StartupNative(
              library!,
              entered: created.isEmpty ? entered : null,
              resume: created.isEmpty ? resume.future : null,
            );
            created.add(service);
            return service;
          },
          supportDirectory: () async => root,
          observeLifecycle: false,
        )..discoveryInterface = '127.0.0.1';
        try {
          final reserved = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = reserved.port;
          await reserved.close();
          final opening = receive
              ? controller.enableReceiving(port: port)
              : controller.ensureLocal();
          final rejected = expectLater(
            opening,
            throwsA(
              isA<TransferException>().having((e) => e.code, 'code', 'closed'),
            ),
          );
          await entered.future.timeout(const Duration(seconds: 30));
          final first = Map<String, dynamic>.from(created.single.ready!);
          final address = first['address'] as String;
          final actualPort = int.parse(address.split(':').last);
          var stopped = false;
          final closing = controller.stop().then((_) => stopped = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            stopped,
            isFalse,
            reason: 'Stop must wait for native initialization',
          );
          resume.complete();
          await Future.wait([closing, rejected]);
          expect(controller.running, isFalse);
          expect(controller.receiving, isFalse);
          expect(controller.discovering, isFalse);
          expect(created.single.dispatched, isEmpty);
          final rebound = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            actualPort,
          );
          await rebound.close();
          // Same root/identity must reopen only on the next explicit action.
          expect(created, hasLength(1));
          await controller.ensureLocal();
          expect(created, hasLength(2));
          expect(controller.running, isTrue);
          expect(controller.receiving, isFalse);
          expect(controller.ready!['fingerprint'], first['fingerprint']);
          expect(
            controller.ready!['core_instance_id'],
            isNot(first['core_instance_id']),
          );
          expect(controller.error, isNull);
          checks.add(
            receive
                ? 'receive_start_cancelled_port_and_root_reusable'
                : 'local_start_cancelled_port_and_root_reusable',
          );
        } finally {
          if (!resume.isCompleted) resume.complete();
          await controller.stop();
          controller.dispose();
          final owned = await root.resolveSymbolicLinks();
          final temporary = await Directory.systemTemp.resolveSymbolicLinks();
          expect(
            await Directory(owned).parent.resolveSymbolicLinks(),
            temporary,
          );
          expect(
            Directory(owned).uri.pathSegments.where((s) => s.isNotEmpty).last,
            startsWith('xdremux-startup-'),
          );
          await Directory(owned).delete(recursive: true);
        }
      },
      skip: skip,
    );
  }
  tearDownAll(() async {
    if (!skip && reportPath != null && checks.length == 2) {
      await File(reportPath).writeAsString(
        jsonEncode({
          'passed': true,
          'scope': 'Real Windows DLL and worker, owned loopback HTTPS',
          'checks': checks,
          'stopWaitedForNativeStartup': true,
          'receiveAndDiscoveryRemainOff': true,
          'noMetadataDispatch': true,
          'receivePortRebound': true,
          'sameRootIdentityPreserved': true,
          'explicitRestartNewRuntime': true,
          'librarySha256': await fileHash(File(library)),
        }),
      );
    }
  });
}
