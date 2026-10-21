// Explicit device-only validation target; never used by lib/main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/transfer_page.dart';

class LifecycleLog with WidgetsBindingObserver {
  final events = <String>[];
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    events.add(state.name);
    if (events.length > 32) events.removeAt(0);
  }
}

Future<Map<String, int>> inventory(Directory root) async {
  var files = 0, bytes = 0;
  if (await root.exists()) {
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is File) {
        files++;
        bytes += await entry.length();
      }
    }
  }
  return {'files': files, 'bytes': bytes};
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('P32_RUN');
  const interface = String.fromEnvironment('P32_INTERFACE');
  const port = int.fromEnvironment('P32_PORT', defaultValue: 53326);
  if (!Platform.isAndroid ||
      !RegExp(r'^[a-f0-9]{16}$').hasMatch(run) ||
      InternetAddress.tryParse(interface)?.type != InternetAddressType.IPv4 ||
      port < 1 ||
      port > 65535) {
    throw StateError('Explicit Android P32_RUN/interface/port required');
  }
  final root = Directory(
    '${(await getExternalStorageDirectory())!.path}/p32-$run',
  );
  final support = Directory(
    '${(await getApplicationSupportDirectory()).path}/p32-$run',
  );
  await root.create(recursive: true);
  final incoming = Directory('${support.path}/transfer/.incoming');
  final received = Directory('${support.path}/transfer/received');
  // Observe crash leftovers before opening native storage (which recovers it).
  final beforeStartup = await inventory(incoming);
  final boot = DateTime.now().microsecondsSinceEpoch.toString();
  final lifecycle = LifecycleLog();
  WidgetsBinding.instance.addObserver(lifecycle);
  final controller = TransferController(supportDirectory: () async => support);
  controller.discoveryInterface = interface;
  const multicast = MethodChannel('xdremux/transfer-discovery');
  runApp(MaterialApp(home: TransferPage(controller: controller)));
  final control = File('${root.path}/command.json');
  var acknowledged = '';
  if (await control.exists()) {
    acknowledged =
        (jsonDecode(await control.readAsString()) as Map)['id'] as String;
  }
  String? error;
  final audited = <Map<String, dynamic>>[];
  Future<void> snapshot() async {
    final value = {
      'run': run,
      'boot': boot,
      'updated': DateTime.now().toIso8601String(),
      'acknowledged': acknowledged,
      'error': error,
      'lifecycle': lifecycle.events,
      'running': controller.running,
      'receiving': controller.receiving,
      'busy': controller.busy,
      'discovering': controller.discovering,
      'multicastHeld': await multicast.invokeMethod<bool>('isHeld'),
      'ready': controller.ready,
      'beforeStartupIncoming': beforeStartup,
      'incoming': await inventory(incoming),
      'published': await inventory(received),
      'transfers': controller.transfers.values.toList(),
      'files': controller.files,
      'audited': audited,
    };
    final temp = File('${root.path}/status.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename('${root.path}/status.json');
  }

  await snapshot();
  // Serialized commands/snapshots; no automatic LAN startup or offer acceptance.
  while (true) {
    try {
      if (await control.exists()) {
        final command = jsonDecode(await control.readAsString()) as Map;
        if (command['run'] != run) throw StateError('Wrong test run');
        final id = command['id'] as String;
        if (id != acknowledged) {
          error = null;
          try {
            switch (command['action']) {
              case 'start':
                await controller.enableReceiving(port: port);
              case 'stop':
                await controller.stop();
              case 'accept':
                final transfer = controller.transfers[command['transferId']];
                final files = controller.files[command['transferId']];
                if (transfer?['peer_fingerprint'] != command['fingerprint'] ||
                    files?.length != 1 ||
                    !RegExp(
                      r'^p32-[a-z]+\.bin$',
                    ).hasMatch(files!.single['name']) ||
                    files.single['size'] > 2 * 1024 * 1024) {
                  throw StateError(
                    'Only explicitly selected owned fixture allowed',
                  );
                }
                await controller.decide(command['transferId'] as String, true);
              case 'audit':
                await controller.ensureLocal();
                await controller.loadInbox(reset: true);
                audited.clear();
                final exports = Directory('${root.path}/audit');
                await exports.create();
                for (final receipt in controller.inbox.values) {
                  final name = receipt['name'] as String;
                  if (!RegExp(r'^p32-[a-z]+\.bin$').hasMatch(name)) {
                    throw StateError('Unexpected fixture');
                  }
                  await controller.withReceipt(receipt['id'] as String, (
                    lease,
                  ) async {
                    final file = File(lease['path'] as String);
                    final hash = (await sha256.bind(file.openRead()).first)
                        .toString();
                    // File.copy preserves the private inbox mode (0600), which
                    // prevents shell/ADB readback even in this fixture directory.
                    // Create a separate synthetic export with normal app-external
                    // file permissions, without changing the managed source.
                    final exported = File('${exports.path}/$name');
                    if (await exported.exists()) await exported.delete();
                    final output = exported.openWrite();
                    try {
                      await output.addStream(file.openRead());
                      await output.flush();
                    } finally {
                      await output.close();
                    }
                    audited.add({
                      'name': name,
                      'size': await file.length(),
                      'sha256': hash,
                    });
                  });
                }
              case 'snapshot':
                break;
              default:
                throw StateError('Unknown test command');
            }
          } catch (e) {
            error = e.toString();
          }
          acknowledged = id;
        }
      }
      await snapshot();
    } catch (e) {
      // Files can disappear while native shutdown removes its own transaction.
      // Retry the next snapshot; commands always have an explicit result.
      error = e.toString();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}
