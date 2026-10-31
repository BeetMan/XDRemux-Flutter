// Real DLL/worker fault validation, with owned sockets and synthetic fixtures only.
import 'dart:convert';
import 'dart:io';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'transfer_worker_smoke.dart' show check, event, fileHash;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('DLL_PATH REPORT_PATH LOCAL_PRIVATE_IPV4');
  }
  final library = File(args[0]).absolute.path;
  final local = args[2];
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  final addresses = interfaces
      .expand((i) => i.addresses)
      .map((a) => a.address)
      .toSet();
  check(addresses.contains(local), 'explicit local interface required');
  final absent = List.generate(
    254,
    (i) => '10.254.254.${i + 1}',
  ).firstWhere((ip) => !addresses.contains(ip));
  final root = await Directory.systemTemp.createTemp('xdremux-fault-smoke-');
  final services = <TransferService>[];
  ServerSocket? occupied;
  TransferService make() {
    final s = TransferService();
    services.add(s);
    return s;
  }

  Future<void> start(TransferService s, String folder, String bind) async {
    check(
      (await s.start(
        supportRoot: '${root.path}/$folder',
        libraryPath: library,
        bind: bind,
        alias: 'XDRemux P31 fixture',
      )).available,
      'native startup',
    );
  }

  final checks = <String>[];
  try {
    occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final oldPort = occupied.port;
    final failed = make();
    final unavailable = await failed.start(
      supportRoot: '${root.path}/b',
      libraryPath: library,
      bind: '127.0.0.1:$oldPort',
    );
    check(
      !unavailable.available && unavailable.reason == 'port_in_use',
      'actionable port conflict',
    );
    await failed.dispose();
    await occupied.close();
    occupied = null;
    final a = make(), b = make();
    await start(a, 'a', '127.0.0.1:0');
    await start(b, 'b', '0.0.0.0:$oldPort');
    checks.add('port_collision_then_exact_root_port_recovery');
    try {
      await b.command({'command': 'discovery_start', 'interface': absent});
      throw StateError('expected discovery_unavailable');
    } on TransferException catch (e) {
      check(
        e.code == 'discovery_unavailable',
        'multicast failure classification',
      );
    }
    final failedDiscovery = await b.command({'command': 'discovery_status'});
    check(
      failedDiscovery['enabled'] == false &&
          failedDiscovery['error'] == 'discovery_unavailable',
      'failed discovery snapshot',
    );
    final peer = await a.command({
      'command': 'probe',
      'address': '127.0.0.1:$oldPort',
    });
    final fixture = File('${root.path}/p31-fallback.bin');
    await fixture.writeAsBytes(List.generate(65536, (i) => i % 251));
    final expected = await fileHash(fixture);
    await a.command({
      'command': 'send',
      'peer': peer,
      'paths': [fixture.path],
    });
    final offer = (await event(b, 'offer'))['offer'];
    check(
      offer['files'].length == 1 &&
          offer['files'][0]['name'] == 'p31-fallback.bin',
      'only owned fixture offered',
    );
    await b.command({
      'command': 'decide',
      'transfer_id': offer['session_id'],
      'accept': true,
    });
    check(
      (await event(a, 'sent'))['report']['error'] == null,
      'manual HTTPS survives discovery failure',
    );
    final receipts =
        await b.command({'command': 'receipts', 'limit': 64}) as List;
    check(receipts.length == 1, 'one fallback receipt');
    final lease = await b.command({
      'command': 'acquire_receipt',
      'receipt_id': receipts.single['id'],
    });
    check(
      await fileHash(File(lease['path'])) == expected,
      'fallback independent disk hash',
    );
    await b.command({
      'command': 'release_receipt',
      'lease_id': lease['lease_id'],
    });
    checks.add('real_discovery_failure_preserves_manual_https_and_bytes');
    final discovery = await b.command({
      'command': 'discovery_start',
      'interface': local,
    });
    check(
      discovery['enabled'] == true && discovery['error'] == null,
      'discovery explicit recovery on available interface',
    );
    await b.command({'command': 'discovery_stop'});
    final stopped = await b.command({'command': 'discovery_status'});
    check(
      stopped['enabled'] == false && stopped['error'] == null,
      'discovery stop clears transient error',
    );
    checks.add('explicit_discovery_recovery_on_available_interface');
    await b.dispose();
    final retrySource = File('${root.path}/p31-reconnect.bin');
    await retrySource.writeAsString('opaque reconnect fixture');
    final started = await a.command({
      'command': 'send',
      'peer': peer,
      'paths': [retrySource.path],
    });
    final failedSend = (await event(a, 'sent'))['report'];
    check(
      failedSend['error'] == 'network' && (failedSend['files'] as List).isEmpty,
      'closed endpoint fails without ACK',
    );
    occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, oldPort);
    final restored = make();
    await start(restored, 'b', '127.0.0.1:0');
    final newPeer = await a.command({
      'command': 'probe',
      'address': restored.ready!['address'],
    });
    check(
      newPeer['fingerprint'] == peer['fingerprint'] &&
          newPeer['address'] != peer['address'],
      'identity persists at new endpoint',
    );
    await a.command({
      'command': 'retry_send',
      'transfer_id': started['transfer_id'],
      'peer': newPeer,
    });
    final retryOffer = (await event(restored, 'offer'))['offer'];
    check(
      retryOffer['files'].length == 1 &&
          retryOffer['files'][0]['name'] == 'p31-reconnect.bin',
      'explicit retry only failed source',
    );
    await restored.command({
      'command': 'decide',
      'transfer_id': retryOffer['session_id'],
      'accept': true,
    });
    check(
      (await event(a, 'sent'))['report']['error'] == null,
      'retry at new endpoint succeeds',
    );
    final all =
        await restored.command({'command': 'receipts', 'limit': 64}) as List;
    check(all.length == 2, 'old receipt retained and one retry committed');
    for (final receipt in all) {
      final source = receipt['name'] == 'p31-fallback.bin'
          ? fixture
          : retrySource;
      final lease = await restored.command({
        'command': 'acquire_receipt',
        'receipt_id': receipt['id'],
      });
      check(
        await fileHash(File(lease['path'])) == await fileHash(source),
        'independent final receipt hash',
      );
      await restored.command({
        'command': 'release_receipt',
        'lease_id': lease['lease_id'],
      });
    }
    checks.add('closed_endpoint_explicit_retry_same_identity_new_address');
    check(await fileHash(fixture) == expected, 'source unchanged');
    final report = {
      'passed': true,
      'date': DateTime.now().toIso8601String().split('T').first,
      'scope':
          'real Windows DLL and Dart worker; owned endpoint/interface configuration faults, not Wi-Fi interruption',
      'checks': checks,
      'independentHashes': true,
      'receivedFiles': all.length,
      'librarySha256': await fileHash(File(library)),
    };
    await File(args[1]).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      flush: true,
    );
    stdout.writeln(jsonEncode(report));
  } finally {
    await occupied?.close();
    for (final s in services.reversed) {
      await s.dispose();
    }
    // This directory was created by this process and has never been handed off.
    final ownedRoot = await root.resolveSymbolicLinks();
    final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
    check(
      await Directory(ownedRoot).parent.resolveSymbolicLinks() == tempRoot &&
          Directory(ownedRoot).uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('xdremux-fault-smoke-'),
      'owned temporary root before cleanup',
    );
    await Directory(ownedRoot).delete(recursive: true);
  }
}
