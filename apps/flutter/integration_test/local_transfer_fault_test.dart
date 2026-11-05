// Explicit release fault target. Uses only owned sockets and a fresh test root.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/transfer_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'release port collision, discovery stop and runtime recovery',
    (tester) async {
      const run = String.fromEnvironment('P31_RUN');
      const workdir = String.fromEnvironment('P31_WORKDIR');
      const interface = String.fromEnvironment('P31_INTERFACE');
      if (!RegExp(r'^[a-f0-9]{16}$').hasMatch(run) ||
          InternetAddress.tryParse(interface) == null ||
          (!Platform.isAndroid && !Platform.isWindows)) {
        throw StateError(
          'Explicit P31_RUN and local IPv4 P31_INTERFACE required',
        );
      }
      final root = Platform.isWindows
          ? Directory(workdir)
          : Directory(
              '${(await getExternalStorageDirectory())!.path}/p31-$run',
            );
      if (!root.isAbsolute) {
        throw StateError('Absolute test work directory required');
      }
      await root.create(recursive: true);
      final support = Platform.isWindows
          ? Directory('${root.path}/private')
          : Directory(
              '${(await getApplicationSupportDirectory()).path}/p31-$run',
            );
      final controller = TransferController(
        supportDirectory: () async => support,
      );
      const multicast = MethodChannel('xdremux/transfer-discovery');
      Future<bool> held() async =>
          await multicast.invokeMethod<bool>('isHeld') == true;
      Future<void> stage(
        String value, [
        Map<String, dynamic> fields = const {},
      ]) async {
        await File(
          '${root.path}/status.json',
        ).writeAsString(jsonEncode({'stage': value, ...fields}), flush: true);
      }

      ServerSocket? occupied;
      try {
        await tester.pumpWidget(
          MaterialApp(home: TransferPage(controller: controller)),
        );
        controller.discoveryInterface = interface;
        occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
        final port = occupied.port;
        await stage('port-conflict');
        try {
          await controller.enableReceiving(port: port);
          fail('Expected port collision');
        } on TransferException catch (e) {
          expect(e.code, 'port_in_use');
        }
        expect(controller.receiving, isFalse);
        expect(controller.running, isFalse);
        await tester.pump();
        expect(find.textContaining('接收端口已被占用'), findsOneWidget);
        await occupied.close();
        occupied = null;
        await controller.enableReceiving(port: port);
        expect(controller.receiving, isTrue);
        expect(
          controller.discovering,
          isTrue,
          reason: controller.discoveryError,
        );
        final original = Map<String, dynamic>.from(controller.ready!);
        if (Platform.isAndroid) expect(await held(), isTrue);
        await stage('discovery-stop');
        // Stop the actual UDP subsystem outside the controller, then let polling
        // observe disabled discovery just as it would after a socket failure.
        await controller.service.command({'command': 'discovery_stop'});
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (controller.discovering && DateTime.now().isBefore(deadline)) {
          await controller.poll();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(controller.discovering, isFalse);
        expect(controller.receiving, isTrue);
        if (Platform.isAndroid) expect(await held(), isFalse);
        await controller.discover();
        expect(controller.discovering, isTrue);
        if (Platform.isAndroid) expect(await held(), isTrue);
        await stage('runtime-stop');
        // Actually terminate the native runtime/worker without first updating the
        // controller. Its next poll must clear stale reception and dispose safely.
        await controller.service.dispose();
        await controller.poll();
        expect(controller.running, isFalse);
        expect(controller.receiving, isFalse);
        expect(controller.discovering, isFalse);
        if (Platform.isAndroid) expect(await held(), isFalse);
        await tester.pump();
        expect(find.text('开启接收'), findsOneWidget);
        expect(find.text('停止接收'), findsNothing);
        occupied = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await occupied.close();
        occupied = null;
        await stage('explicit-restart');
        await controller.enableReceiving(port: port);
        expect(controller.receiving, isTrue);
        expect(controller.ready!['fingerprint'], original['fingerprint']);
        expect(
          controller.ready!['core_instance_id'],
          isNot(original['core_instance_id']),
        );
        await controller.stop();
        if (Platform.isAndroid) expect(await held(), isFalse);
        occupied = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await occupied.close();
        occupied = null;
        await stage('done', {
          'platform': Platform.operatingSystem,
          'portConflictVerified': true,
          'discoveryStopPreservesReception': true,
          'discoveryRestartVerified': true,
          'runtimeStopClearsReception': true,
          'sameRootPortRestartVerified': true,
          'identityPersists': true,
          'finalPortReleased': true,
          'androidMulticastLockTransitionsVerified': Platform.isAndroid,
        });
      } catch (e) {
        await stage('failed', {'error': e.toString()});
        rethrow;
      } finally {
        await occupied?.close();
        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
