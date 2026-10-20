// Explicit release integration target; never imported by the production entry.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/transfer_page.dart';
import 'local_transfer_test.dart' show hash;

Future<T> until<T>(Future<T?> Function() action) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final value = await action();
      if (value != null) return value;
    } on FormatException {
      /* host publication */
    } on FileSystemException {
      /* host publication */
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('P23 deadline');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'release multicast discovery, fingerprint confirmation, declined-send retry, bytes and stop',
    (tester) async {
      const role = String.fromEnvironment('P23_ROLE');
      const run = String.fromEnvironment('P23_RUN');
      const hostRoot = String.fromEnvironment('P23_WORKDIR');
      const windowsIp = String.fromEnvironment(
        'P23_WINDOWS_HOST',
        defaultValue: '192.168.31.5',
      );
      const androidIp = String.fromEnvironment(
        'P23_ANDROID_HOST',
        defaultValue: '192.168.31.53',
      );
      if (run.isEmpty || !['windows', 'android'].contains(role)) {
        throw StateError('Explicit P23 role/run required');
      }
      final windows = role == 'windows';
      final root = windows
          ? Directory(hostRoot)
          : Directory(
              '${(await getExternalStorageDirectory())!.path}/p23-$run',
            );
      await root.create(recursive: true);
      Future<void> stage(
        String name, [
        Map<String, dynamic> fields = const {},
      ]) async => File(
        '${root.path}/status.json',
      ).writeAsString(jsonEncode({'stage': name, ...fields}), flush: true);
      TransferController? owner;
      try {
        await stage('fixtures');
        final manifest = File('${root.path}/fixtures.json');
        final entries = await until<List<dynamic>>(
          () async => await manifest.exists()
              ? jsonDecode(await manifest.readAsString()) as List
              : null,
        );
        final paths = <String>[];
        for (final entry in entries) {
          final file = File('${root.path}/${entry['name']}');
          await until<bool>(
            () async =>
                await file.exists() && await file.length() == entry['size']
                ? true
                : null,
          );
          expect(await hash(file), entry['sha256']);
          paths.add(file.path);
        }
        final support = windows
            ? Directory('${root.path}/private')
            : Directory(
                '${(await getApplicationSupportDirectory()).path}/p23-$run',
              );
        final controller = TransferController(
          supportDirectory: () async => support,
        );
        owner = controller;
        controller.discoveryInterface = windows ? windowsIp : androidIp;
        await tester.pumpWidget(
          MaterialApp(
            home: TransferPage(
              controller: controller,
              initialPaths: paths,
              sourceLabel: 'P23 synthetic fixtures',
            ),
          ),
        );
        await controller.enableReceiving(port: windows ? 53319 : 53324);
        expect(
          controller.discovering,
          isTrue,
          reason: controller.discoveryError,
        );
        if (!windows) {
          expect(
            await const MethodChannel(
              'xdremux/transfer-discovery',
            ).invokeMethod<bool>('isHeld'),
            isTrue,
          );
        }
        await File('${root.path}/$role-ready.json').writeAsString(
          jsonEncode({
            'address':
                '${windows ? windowsIp : androidIp}:${windows ? 53319 : 53324}',
            'fingerprint': controller.ready!['fingerprint'],
          }),
          flush: true,
        );
        final peerFile = File(
          '${root.path}/${windows ? 'android' : 'windows'}-peer.json',
        );
        Future<Map<String, dynamic>> peer() => until(
          () async => await peerFile.exists()
              ? jsonDecode(await peerFile.readAsString())
                    as Map<String, dynamic>
              : null,
        );
        Future<void> findAndSend(Map<String, dynamic> expected) async {
          await stage('discovering');
          await until<bool>(() async {
            await controller.poll();
            return controller.peers.any(
                  (p) => p['fingerprint'] == expected['fingerprint'],
                )
                ? true
                : null;
          });
          await stage('discovered', {'peerCount': controller.peers.length});
          await tester.pump();
          final tile = find.byKey(ValueKey('peer-${expected['fingerprint']}'));
          await tester.scrollUntilVisible(
            tile,
            -250,
            scrollable: find.byType(Scrollable).first,
          );
          tester.widget<ListTile>(tile).onTap!();
          await until<bool>(() async {
            await tester.pump();
            return find
                    .byKey(const ValueKey('confirm-peer'))
                    .evaluate()
                    .isNotEmpty
                ? true
                : null;
          });
          final fp = RegExp('.{1,8}')
              .allMatches(expected['fingerprint'] as String)
              .map((m) => m.group(0))
              .join(' ');
          expect(find.text(fp), findsWidgets);
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('confirm-peer')))
              .onPressed!();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('send-files')),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('send-files')))
              .onPressed!();
          String? failedId;
          await until<bool>(() async {
            await controller.refresh();
            await tester.pump();
            final jobs = controller.transfers.values
                .where((r) => r['direction'] == 'send' && r['id'] != failedId)
                .toList();
            if (jobs.any((r) => r['phase'] == 'failed')) {
              final job = jobs.firstWhere((r) => r['phase'] == 'failed');
              if (windows || failedId != null || job['error'] != 'declined') {
                throw StateError('Unexpected send failure: ${job['error']}');
              }
              expect(job['retry_available'], isTrue);
              failedId = job['id'] as String;
              await stage('retrying');
              final retry = find.byKey(ValueKey('retry-$failedId'));
              await tester.scrollUntilVisible(
                retry,
                250,
                scrollable: find.byType(Scrollable).first,
              );
              tester.widget<TextButton>(retry).onPressed!();
              await tester.pump(const Duration(milliseconds: 400));
              expect(find.textContaining('回执丢失'), findsOneWidget);
              tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('confirm-retry')),
                  )
                  .onPressed!();
              await tester.pump(const Duration(milliseconds: 400));
              return null;
            }
            return jobs.any((r) => r['phase'] == 'completed') ? true : null;
          });
          if (!windows) expect(failedId, isNotNull);
        }

        Future<void> receive({bool decline = false}) async {
          await stage(decline ? 'waiting-decline-offer' : 'waiting-offer');
          await until<bool>(() async {
            await controller.refresh();
            return controller.transfers.values.any(
                  (r) => r['direction'] == 'receive' && r['phase'] == 'pending',
                )
                ? true
                : null;
          });
          await tester.pump();
          final label = decline ? '拒绝' : '接收全部';
          await tester.scrollUntilVisible(
            find.text(label),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump(const Duration(milliseconds: 400));
          if (decline) {
            final old =
                controller.transfers.values.firstWhere(
                      (r) =>
                          r['direction'] == 'receive' &&
                          r['phase'] == 'pending',
                    )['id']
                    as String;
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, label),
                )
                .onPressed!();
            await until<bool>(() async {
              await controller.refresh();
              return controller.transfers[old]?['phase'] != 'pending'
                  ? true
                  : null;
            });
            await tester.pump(const Duration(milliseconds: 400));
            return;
          }
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed!();
          await until<bool>(() async {
            await controller.refresh();
            return controller.inbox.length == entries.length ? true : null;
          });
          for (final receipt in controller.inbox.values.toList()) {
            final expected = entries.firstWhere(
              (e) => e['name'] == receipt['name'],
            );
            expect(receipt['size'], expected['size']);
            expect(receipt['sha256'], expected['sha256']);
            await controller.withReceipt(
              receipt['id'] as String,
              (lease) async => expect(
                await hash(File(lease['path'] as String)),
                expected['sha256'],
              ),
            );
          }
        }

        if (windows) {
          await receive(decline: true);
          await receive();
          final exports = Directory('${root.path}/export');
          await exports.create();
          for (final receipt in controller.inbox.values.toList()) {
            await controller.exportDesktop(
              receipt['id'] as String,
              exports.path,
            );
            expect(
              await hash(File('${exports.path}/${receipt['name']}')),
              receipt['sha256'],
            );
          }
          await findAndSend(await peer());
        } else {
          await findAndSend(await peer());
          await receive();
        }
        await controller.stop();
        if (!windows) {
          expect(
            await const MethodChannel(
              'xdremux/transfer-discovery',
            ).invokeMethod<bool>('isHeld'),
            isFalse,
          );
        }
        await stage('done', {
          'role': role,
          'files': entries.length,
          'hashesMatch': true,
          'multicastVerified': true,
          'declinedRetryVerified': !windows,
          'stopVerified': true,
        });
      } catch (e, stack) {
        await stage('failed', {
          'error': e.toString(),
          'stack': stack.toString(),
        });
        rethrow;
      } finally {
        await owner?.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        owner?.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
