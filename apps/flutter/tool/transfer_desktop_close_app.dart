// Release-only desktop validation entry; all files/sockets belong to this run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_desktop_lifecycle.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'package:xdremux/transfer_page.dart';
import 'transfer_worker_smoke.dart' show check, event, fileHash, until;

class _Relay {
  _Relay(this.listener, this.destination) {
    listener.listen((client) => unawaited(_forward(client)));
  }
  final ServerSocket listener;
  final int destination;
  final gate = Completer<void>();
  final sockets = <Socket>[];
  Future<void> _forward(Socket client) async {
    Socket? upstream;
    try {
      sockets.add(client);
      upstream = await Socket.connect('127.0.0.1', destination);
      sockets.add(upstream);
      upstream.listen(
        client.add,
        onDone: client.destroy,
        onError: (_) => client.destroy(),
      );
      var forwarded = 0;
      await for (final bytes in client) {
        // Hold an opaque TLS upload after a prefix; never decrypt it.
        if (forwarded >= 192 * 1024) await gate.future;
        upstream.add(bytes);
        await upstream.flush();
        forwarded += bytes.length;
      }
    } catch (_) {
      // Peers are intentionally stopped during this fixture.
    } finally {
      upstream?.destroy();
      client.destroy();
    }
  }

  Future<void> close() async {
    if (!gate.isCompleted) gate.complete();
    await listener.close();
    for (final socket in sockets) {
      socket.destroy();
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('P32_DESKTOP_ROOT');
  final root = Directory(directory);
  check(
    Platform.isWindows &&
        root.isAbsolute &&
        RegExp(
          r'^p32-desktop-[a-f0-9]{16}$',
        ).hasMatch(root.uri.pathSegments.where((p) => p.isNotEmpty).last),
    'Explicit owned desktop run required',
  );
  final scenario =
      (jsonDecode(await File('$directory/scenario.json').readAsString())
          as Map)['case'];
  check(
    ['retry-before', 'retry-after', 'drain', 'recover'].contains(scenario),
    'Explicit scenario',
  );
  final work = Directory(
    '$directory/${scenario == 'recover' ? 'drain' : scenario}',
  );
  await work.create(recursive: true);
  final controller = TransferController(
    supportDirectory: () async => Directory('${work.path}/receiver'),
  );
  controller.discoveryInterface = '127.0.0.1'; // No LAN or multicast required.
  var stopCalls = 0, held = false;
  TransferService? sender;
  _Relay? relay;
  Future<void> write(
    String stage, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final data = jsonEncode({
      'case': scenario,
      'stage': stage,
      'stopCalls': stopCalls,
      'leaseHeld': held,
      ...fields,
    });
    await File('${work.path}/status.json').writeAsString(data, flush: true);
    await File('$directory/status.json').writeAsString(data, flush: true);
  }

  try {
    if (scenario == 'recover') {
      final original =
          jsonDecode(await File('${work.path}/ready.json').readAsString())
              as Map;
      final incoming = Directory('${work.path}/receiver/transfer/.incoming');
      check(
        (await incoming.list().toList()).isEmpty,
        'No staging left after graceful close',
      );
      final port = int.parse((original['address'] as String).split(':').last);
      final socket = await ServerSocket.bind('127.0.0.1', port);
      await socket.close();
      await controller.ensureLocal();
      check(!controller.receiving, 'Recovery does not enable reception');
      check(
        controller.ready!['fingerprint'] == original['fingerprint'],
        'Identity persists',
      );
      check(
        controller.ready!['core_instance_id'] != original['core_instance_id'],
        'New runtime',
      );
      await controller.loadInbox(reset: true);
      check(controller.inbox.length == 1, 'Partial never published');
      await controller.withReceipt(controller.inbox.keys.single, (lease) async {
        check(
          await fileHash(File(lease['path'])) ==
              await fileHash(File('${work.path}/p32-complete.bin')),
          'Committed baseline hash after restart',
        );
      });
      check(
        await fileHash(File('${work.path}/leased-copy.bin')) ==
            await fileHash(File('${work.path}/p32-complete.bin')),
        'Held read completed before exit',
      );
      await controller.stop();
      await write('recovered', {
        'portReleased': true,
        'identityPersists': true,
        'partialNotPublished': true,
        'stagingCleanBeforeRecovery': true,
        'committedHashPreserved': true,
        'leasedCopyHashVerified': true,
        'receptionRemainsOff': true,
      });
      exit(0);
    }
    final owner = TransferDesktopLifecycle(
      stop: () async {
        stopCalls++;
        if ((scenario as String).startsWith('retry') && stopCalls == 1) {
          await write('first-close-failed');
          throw StateError('Owned fixture cleanup failure before stop');
        }
        await write('close-requested');
        await controller.stop();
        await relay?.close();
        await sender?.dispose();
        await write('closed', {
          'running': controller.running,
          'receiving': controller.receiving,
        });
      },
    );
    runApp(MaterialApp(home: TransferPage(controller: controller)));
    await owner.register();
    final reservation = await ServerSocket.bind('127.0.0.1', 0);
    final port = reservation.port;
    await reservation.close();
    await controller.enableReceiving(port: port);
    await File(
      '${work.path}/ready.json',
    ).writeAsString(jsonEncode(controller.ready));
    if (scenario == 'drain') {
      final source = File('${work.path}/p32-complete.bin');
      await source.writeAsBytes(List.generate(65536, (i) => i % 251));
      final outbound = TransferService();
      sender = outbound;
      check(
        (await outbound.start(supportRoot: '${work.path}/sender')).available,
        'Sender startup',
      );
      Future<void> send(File file, int peerPort) async {
        final peer = await outbound.command({
          'command': 'probe',
          'address': '127.0.0.1:$peerPort',
        });
        check(
          peer['fingerprint'] == controller.ready!['fingerprint'],
          'Fixture certificate',
        );
        await outbound.command({
          'command': 'send',
          'peer': peer,
          'paths': [file.path],
        });
        final id = await until<String>(() async {
          await controller.poll();
          for (final entry in controller.files.entries) {
            if (controller.transfers[entry.key]?['phase'] == 'pending' &&
                entry.value.single['name'] == file.uri.pathSegments.last) {
              return entry.key;
            }
          }
          return null;
        });
        await controller.decide(id, true);
      }

      await send(source, port);
      check(
        (await event(outbound, 'sent'))['report']['error'] == null,
        'Baseline ACK',
      );
      await controller.loadInbox(reset: true);
      check(controller.inbox.length == 1, 'One baseline receipt');
      final partial = File('${work.path}/p32-partial.bin');
      await partial.writeAsBytes(
        List.generate(2 * 1024 * 1024, (i) => i % 239),
      );
      relay = _Relay(await ServerSocket.bind('127.0.0.1', 0), port);
      await send(partial, relay.listener.port);
      final partialBytes = await until<int>(() async {
        final incoming = Directory('${work.path}/receiver/transfer/.incoming');
        await for (final child in incoming.list(recursive: true)) {
          if (child is File) {
            final size = await child.length();
            if (size > 0 && size < 2 * 1024 * 1024) return size;
          }
        }
        return null;
      });
      final entered = Completer<void>();
      unawaited(
        controller.withReceipt(controller.inbox.keys.single, (lease) async {
          held = true;
          entered.complete();
          final deadline = DateTime.now().add(const Duration(minutes: 5));
          while (!await File('$directory/release-read').exists()) {
            check(
              DateTime.now().isBefore(deadline),
              'Explicit read release deadline',
            );
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await File(lease['path']).copy('${work.path}/leased-copy.bin');
          held = false;
        }),
      );
      await entered.future;
      await write('ready-to-close', {
        'ready': controller.ready,
        'partialBytes': partialBytes,
        'baselineSha256': await fileHash(source),
      });
    } else {
      await write('ready-to-close', {'ready': controller.ready});
    }
  } catch (e) {
    await write('failed', {'error': e.toString()});
    await relay?.close();
    await controller.stop();
    await sender?.dispose();
    exit(1);
  }
}
