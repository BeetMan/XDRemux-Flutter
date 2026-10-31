// Explicit TEST target, never included by lib/main.dart. No production auto-accept.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_export.dart';
import 'package:xdremux/transfer_page.dart';

Future<T> waitFor<T>(Future<T?> Function() action) async {
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final value = await action();
      if (value != null) return value;
    } on FormatException {
      /* host may still be publishing its small JSON */
    } on FileSystemException {
      /* deployment/read may race */
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('App integration deadline');
}

Future<String> hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'release application LAN transfer, explicit identity/offer, export and stop',
    (tester) async {
      const role = String.fromEnvironment('P22_ROLE');
      const run = String.fromEnvironment('P22_RUN');
      const hostDirectory = String.fromEnvironment('P22_WORKDIR');
      const windowsHost = String.fromEnvironment(
        'P22_WINDOWS_HOST',
        defaultValue: '192.168.31.5',
      );
      const androidHost = String.fromEnvironment(
        'P22_ANDROID_HOST',
        defaultValue: '192.168.31.53',
      );
      if (run.isEmpty || !['windows', 'android'].contains(role)) {
        throw StateError('Explicit test role/run required');
      }
      final windows = role == 'windows';
      final directory = windows
          ? Directory(hostDirectory)
          : Directory(
              '${(await getExternalStorageDirectory())!.path}/p22-$run',
            );
      await directory.create(recursive: true);
      final status = File('${directory.path}/status.json');
      Future<void> stage(
        String value, [
        Map<String, dynamic> extra = const {},
      ]) async => status.writeAsString(
        jsonEncode({'stage': value, ...extra}),
        flush: true,
      );
      final manifest = File('${directory.path}/fixtures.json');
      await stage('fixtures');
      final entries = await waitFor<List<dynamic>>(
        () async => await manifest.exists()
            ? jsonDecode(await manifest.readAsString()) as List
            : null,
      );
      final paths = <String>[];
      for (final entry in entries) {
        final file = File('${directory.path}/${entry['name']}');
        await waitFor<bool>(
          () async =>
              await file.exists() && await file.length() == entry['size']
              ? true
              : null,
        );
        expect(await hash(file), entry['sha256']);
        paths.add(file.path);
      }
      final support = windows
          ? Directory('${directory.path}/private')
          : await getApplicationSupportDirectory();
      final controller = TransferController(
        supportDirectory: () async => support,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TransferPage(
            controller: controller,
            initialPaths: paths,
            sourceLabel: 'P22 test fixtures',
          ),
        ),
      );
      Future<void> connect(Map<String, dynamic> peer) async {
        final address = (peer['address'] as String).split(':');
        await stage('connect');
        // TestTextInput's registration relies on assertions and is unavailable
        // in a release target. Populate the actual fields, then tap actual UI.
        for (final entry in {
          'peer-host': address[0],
          'peer-port': address[1],
        }.entries) {
          final field = tester.widget<TextField>(
            find.byKey(ValueKey(entry.key)),
          );
          field.controller!.text = entry.value;
          field.onChanged?.call(entry.value);
        }
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('connect-peer')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('connect-peer')))
            .onPressed!();
        await waitFor<bool>(() async {
          await tester.pump();
          final message = find.byKey(const ValueKey('transfer-message'));
          if (message.evaluate().isNotEmpty) {
            throw StateError(
              'Connect UI: ${tester.widget<Text>(message).data}',
            );
          }
          return find
                  .byKey(const ValueKey('confirm-peer'))
                  .evaluate()
                  .isNotEmpty
              ? true
              : null;
        });
        final expected = RegExp('.{1,8}')
            .allMatches(peer['fingerprint'] as String)
            .map((m) => m.group(0))
            .join(' ');
        expect(find.text(expected), findsWidgets);
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('confirm-peer')))
            .onPressed!();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.ensureVisible(find.byKey(const ValueKey('send-files')));
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('send-files')))
            .onPressed!();
        await stage('send-requested');
        await tester.pump();
        await waitFor<bool>(() async {
          await controller.refresh();
          final jobs = controller.transfers.values
              .where((r) => r['direction'] == 'send')
              .toList();
          if (jobs.any((r) => r['phase'] == 'failed')) {
            throw StateError(
              'Send failed: ${jobs.map((r) => r['error']).join(',')}',
            );
          }
          return jobs.any((r) => r['phase'] == 'completed') ? true : null;
        });
      }

      Future<void> receive() async {
        // A host-side rebuild may resume a completed, hash-verified receive leg.
        if (controller.inbox.length != entries.length) {
          await stage('waiting-offer');
          await waitFor<bool>(() async {
            await controller.refresh();
            return controller.transfers.values.any(
                  (r) => r['direction'] == 'receive' && r['phase'] == 'pending',
                )
                ? true
                : null;
          });
          await stage('offer-observed');
          await tester.pump();
          await tester.scrollUntilVisible(
            find.text('接收全部'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('接收全部').hitTestable(), findsOneWidget);
          // Exercise the production confirmation callback. Desktop tests may run
          // occluded; native input delivery is covered separately by widget tests.
          final accept = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '接收全部'),
          );
          expect(accept.onPressed, isNotNull);
          accept.onPressed!();
          await tester.pump();
          await waitFor<bool>(() async {
            await controller.refresh();
            await stage('receiving', {
              'jobs': controller.transfers.values.toList(),
              'count': controller.inbox.length,
            });
            return controller.inbox.length == entries.length ? true : null;
          });
        }
        for (final receipt in controller.inbox.values.toList()) {
          final expected =
              entries.firstWhere((e) => e['name'] == receipt['name']) as Map;
          expect(receipt['size'], expected['size']);
          expect(receipt['sha256'], expected['sha256']);
          await controller.withReceipt(receipt['id'] as String, (lease) async {
            expect(
              await hash(File(lease['path'] as String)),
              expected['sha256'],
            );
          });
        }
      }

      try {
        if (windows) {
          await tester.tap(find.byKey(const ValueKey('receive-toggle')));
          await waitFor<bool>(() async {
            if (controller.error != null) {
              throw StateError('Receiver startup: ${controller.error}');
            }
            return controller.receiving ? true : null;
          });
          final port = (controller.ready!['address'] as String).split(':').last;
          await File('${directory.path}/windows-ready.json').writeAsString(
            jsonEncode({
              'address': '$windowsHost:$port',
              'fingerprint': controller.ready!['fingerprint'],
            }),
          );
          await stage('receive');
          await receive();
          final exports = Directory('${directory.path}/export');
          await exports.create();
          for (final receipt in controller.inbox.values.toList()) {
            if (!await File('${exports.path}/${receipt['name']}').exists()) {
              await controller.exportDesktop(
                receipt['id'] as String,
                exports.path,
              );
            }
            expect(
              await hash(File('${exports.path}/${receipt['name']}')),
              receipt['sha256'],
            );
          }
          await stage('send');
          final peerFile = File('${directory.path}/android-peer.json');
          final peer = await waitFor<Map<String, dynamic>>(
            () async => await peerFile.exists()
                ? jsonDecode(await peerFile.readAsString())
                      as Map<String, dynamic>
                : null,
          );
          await connect(peer);
        } else {
          await controller.ensureLocal();
          if (controller.inbox.length != entries.length) {
            final peerFile = File('${directory.path}/windows-peer.json');
            final peer = await waitFor<Map<String, dynamic>>(
              () async => await peerFile.exists()
                  ? jsonDecode(await peerFile.readAsString())
                        as Map<String, dynamic>
                  : null,
            );
            await connect(peer);
            await controller.enableReceiving(port: 53324);
            await File('${directory.path}/android-ready.json').writeAsString(
              jsonEncode({
                'address': '$androidHost:53324',
                'fingerprint': controller.ready!['fingerprint'],
              }),
            );
            await stage('receive');
          }
          await receive();
          // Also verify lifecycle when resuming only the SAF leg after a rebuild.
          if (!controller.receiving) {
            await controller.enableReceiving(port: 53324);
          }
          final movie = controller.inbox.values.firstWhere(
            (r) => (r['name'] as String).endsWith('.mov'),
          );
          await stage('export-picker');
          expect(controller.receiving, isTrue);
          expect(
            await TransferExport.save(
              controller,
              movie['id'] as String,
              'p22-$run.mov',
            ),
            isTrue,
          );
          expect(
            controller.receiving,
            isFalse,
          ); // explicit stop before entering the system document picker
        }
        await controller.stop();
        await stage('done', {
          'files': entries.length,
          'hashesMatch': true,
          'exportVerified': true,
          'role': role,
        });
      } catch (e, stack) {
        await stage('failed', {
          'error': e.toString(),
          'stack': stack.toString(),
        });
        rethrow;
      } finally {
        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
