// Explicit desktop release test target. Never imported by the production entry.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/transfer_page.dart';
import 'local_transfer_test.dart' show hash;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'release application interoperates with official LocalSend',
    (tester) async {
      const path = String.fromEnvironment('P3_WORKDIR');
      const host = String.fromEnvironment(
        'P3_HOST',
        defaultValue: '192.168.31.5',
      );
      if (!Platform.isWindows || path.isEmpty || !Directory(path).isAbsolute) {
        throw StateError('Explicit Windows P3_WORKDIR required');
      }
      final root = Directory(path);
      final entries =
          jsonDecode(await File('$path/fixtures.json').readAsString()) as List;
      if (entries.length != 5 ||
          entries.any(
            (e) => !(e['name'] as String).startsWith('p3-official-'),
          )) {
        throw StateError(
          'Only five explicitly named P3 synthetic fixtures allowed',
        );
      }
      Future<void> stage(
        String value, [
        Map<String, dynamic> fields = const {},
      ]) => File(
        '$path/status.json',
      ).writeAsString(jsonEncode({'stage': value, ...fields}), flush: true);
      Future<T> until<T>(Future<T?> Function() f) async {
        final deadline = DateTime.now().add(const Duration(minutes: 8));
        while (DateTime.now().isBefore(deadline)) {
          final value = await f();
          if (value != null) return value;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        throw StateError('P3 stage deadline');
      }

      final paths = <String>[];
      for (final e in entries) {
        final file = File('$path/${e['name']}');
        expect(await file.length(), e['size']);
        expect(await hash(file), e['sha256']);
        paths.add(file.path);
      }
      final controller = TransferController(
        supportDirectory: () async => Directory('${root.path}/private'),
      );
      try {
        controller.discoveryInterface = host;
        await tester.pumpWidget(
          MaterialApp(
            home: TransferPage(controller: controller, initialPaths: paths),
          ),
        );
        await controller.enableReceiving(port: 53319);
        expect(
          controller.discovering,
          isTrue,
          reason: controller.discoveryError,
        );
        await File(
          '$path/windows-ready.json',
        ).writeAsString(jsonEncode(controller.ready), flush: true);
        final expected =
            jsonDecode(await File('$path/official-peer.json').readAsString())
                as Map;
        await stage('discovering');
        final discovered = await until<Map<String, dynamic>>(() async {
          await controller.poll();
          for (final peer in controller.peers) {
            if (peer['address'] == expected['address'] &&
                peer['fingerprint'] == expected['fingerprint']) {
              return peer;
            }
          }
          return null;
        });
        await stage('discovered', {'peer': discovered});
        await tester.pump();
        final tile = find.byKey(ValueKey('peer-${expected['fingerprint']}'));
        await tester.scrollUntilVisible(
          tile,
          -250,
          scrollable: find.byType(Scrollable).first,
        );
        tester.widget<ListTile>(tile).onTap!();
        final confirm = find.byKey(const ValueKey('confirm-peer'));
        await until<bool>(() async {
          await tester.pump();
          return confirm.evaluate().isNotEmpty ? true : null;
        });
        final fp = RegExp('.{1,8}')
            .allMatches(expected['fingerprint'] as String)
            .map((m) => m.group(0))
            .join(' ');
        expect(find.text(fp), findsWidgets);
        tester.widget<FilledButton>(confirm).onPressed!();
        await tester.pump(const Duration(milliseconds: 400));
        final send = find.byKey(const ValueKey('send-files'));
        await tester.scrollUntilVisible(
          send,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await stage('sending');
        tester.widget<FilledButton>(send).onPressed!();
        await until<bool>(() async {
          await controller.refresh();
          final jobs = controller.transfers.values.where(
            (r) => r['direction'] == 'send',
          );
          for (final job in jobs) {
            if (job['phase'] == 'failed') {
              throw StateError('Official send failed: ${job['error']}');
            }
          }
          return jobs.any((r) => r['phase'] == 'completed') ? true : null;
        });
        await stage('waiting-return', {
          'sentFiles': entries.length,
          'multicastVerified': true,
        });
        await until<bool>(() async {
          await controller.refresh();
          return controller.transfers.values.any(
                (r) => r['direction'] == 'receive' && r['phase'] == 'pending',
              )
              ? true
              : null;
        });
        final offer = controller.transfers.values.firstWhere(
          (r) => r['direction'] == 'receive' && r['phase'] == 'pending',
        );
        final rows = controller.files[offer['id']]!;
        expect(rows.length, entries.length);
        expect(
          rows.map((r) => r['name']).toSet(),
          entries.map((e) => e['name']).toSet(),
        );
        await tester.pump();
        final accept = find.widgetWithText(FilledButton, '接收全部');
        await tester.scrollUntilVisible(
          accept,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        tester.widget<FilledButton>(accept).onPressed!();
        await until<bool>(() async {
          await controller.refresh();
          return controller.inbox.length == entries.length ? true : null;
        });
        final verified = <Map<String, dynamic>>[];
        for (final receipt in controller.inbox.values.toList()) {
          final e = entries.firstWhere((e) => e['name'] == receipt['name']);
          expect(receipt['size'], e['size']);
          expect(receipt['sha256'], e['sha256']);
          await controller.withReceipt(receipt['id'] as String, (lease) async {
            expect(await hash(File(lease['path'] as String)), e['sha256']);
          });
          verified.add({
            'name': receipt['name'],
            'size': receipt['size'],
            'sha256': receipt['sha256'],
            'peerHashPresent': receipt['peer_hash_present'],
          });
        }
        await File(
          '$path/received.json',
        ).writeAsString(jsonEncode(verified), flush: true);
        for (final e in entries) {
          expect(await hash(File('$path/${e['name']}')), e['sha256']);
        }
        await controller.stop();
        await stage('done', {
          'filesPerDirection': entries.length,
          'multicastVerified': true,
          'receiveHashesMatch': true,
          'sourceUnchanged': true,
          'stopVerified': true,
        });
      } catch (e) {
        await stage('failed', {'error': e.toString()});
        rethrow;
      } finally {
        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
