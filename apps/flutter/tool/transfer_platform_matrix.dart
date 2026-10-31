// Autonomous Windows socket/identity matrix. Uses only owned roots and fixtures.
import 'dart:convert';
import 'dart:io';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'transfer_worker_smoke.dart' show check, event, fileHash;

Future<void> main(List<String> args) async {
  if (args.length != 2 && args.length != 4) {
    throw ArgumentError(
      'DLL_PATH NEW_ABSOLUTE_ROOT [LOCAL_IPV4_A LOCAL_IPV4_B]',
    );
  }
  final library = File(args[0]).absolute.path;
  final root = Directory(args[1]);
  check(root.isAbsolute && !await root.exists(), 'new owned root required');
  await root.create();
  final services = <TransferService>[];
  final checks = <String>[];
  final results = <String, dynamic>{
    'passed': false,
    'scope':
        'Windows real DLL and Dart worker; loopback and explicitly assigned local interfaces, no OS network changes',
  };
  TransferService make() {
    final s = TransferService();
    services.add(s);
    return s;
  }

  Future<void> start(TransferService s, String name, String bind) async {
    final availability = await s.start(
      supportRoot: '${root.path}/$name',
      libraryPath: library,
      bind: bind,
      alias: 'XDRemux automated $name',
    );
    check(availability.available, 'startup $name: ${availability.reason}');
  }

  Future<void> exchange(
    TransferService from,
    TransferService to,
    List<String> paths,
  ) async {
    final peer = await from.command({
      'command': 'probe',
      'address': to.ready!['address'],
    });
    check(peer['fingerprint'] == to.ready!['fingerprint'], 'expected identity');
    await from.command({'command': 'send', 'peer': peer, 'paths': paths});
    final offer = (await event(to, 'offer'))['offer'];
    final expected = {
      for (final path in paths)
        File(path).uri.pathSegments.last: {
          'size': await File(path).length(),
          'sha256': await fileHash(File(path)),
        },
    };
    final offeredNames = <String>{};
    var owned =
        offer['peer_fingerprint'] == from.ready!['fingerprint'] &&
        offer['files'].length == paths.length;
    for (final file in offer['files'] as List) {
      final selected = expected[file['name']];
      owned =
          owned &&
          selected != null &&
          offeredNames.add(file['name']) &&
          file['size'] == selected['size'] &&
          file['sha256'] == selected['sha256'];
    }
    if (!owned) {
      await to.command({
        'command': 'decide',
        'transfer_id': offer['session_id'],
        'accept': false,
      });
    }
    check(
      owned,
      'only pinned fixture sender and selected file metadata accepted',
    );
    await to.command({
      'command': 'decide',
      'transfer_id': offer['session_id'],
      'accept': true,
    });
    final sent = (await event(from, 'sent'))['report'];
    check(
      sent['error'] == null && sent['files'].length == paths.length,
      'all files acknowledged',
    );
    final receipts =
        await to.command({'command': 'receipts', 'limit': 64}) as List;
    for (final path in paths) {
      final source = File(path);
      final name = source.uri.pathSegments.last;
      final matches = receipts.where((r) => r['name'] == name).toList();
      check(matches.length == 1, 'one receipt per selected name');
      final lease = await to.command({
        'command': 'acquire_receipt',
        'receipt_id': matches.single['id'],
      });
      try {
        check(
          await File(lease['path']).length() == await source.length(),
          'length preserved',
        );
        check(
          await fileHash(File(lease['path'])) == await fileHash(source),
          'independent receipt hash',
        );
      } finally {
        await to.command({
          'command': 'release_receipt',
          'lease_id': lease['lease_id'],
        });
      }
    }
  }

  try {
    final inputs = Directory('${root.path}/fixtures');
    await inputs.create();
    final paths = <String>[];
    for (final entry in <String, List<int>>{
      'empty.bin': [],
      '中文-🧪.bin': utf8.encode('owned unicode filename and content'),
      'opaque.heic': [
        0,
        0,
        0,
        24,
        ...ascii.encode('ftypheic'),
        ...List.generate(65536, (i) => i % 251),
      ],
      'opaque.mov': List.generate(1024 * 1024, (i) => (i * 7) % 251),
    }.entries) {
      final file = File('${inputs.path}/${entry.key}');
      await file.writeAsBytes(entry.value);
      paths.add(file.path);
    }
    final sourceHashes = {
      for (final path in paths)
        File(path).uri.pathSegments.last: await fileHash(File(path)),
    };
    final a = make(), b = make();
    await start(a, 'ipv4-a', '127.0.0.1:0');
    final port = int.parse((a.ready!['address'] as String).split(':').last);
    await start(b, 'ipv4-b', '127.0.0.2:$port');
    check(
      a.ready!['fingerprint'] != b.ready!['fingerprint'],
      'isolated roots have distinct certificates',
    );
    await exchange(a, b, paths);
    await exchange(b, a, paths);
    checks.add(
      'ipv4_distinct_loopback_addresses_same_port_bidirectional_four_files',
    );
    final conflict = make();
    final blocked = await conflict.start(
      supportRoot: '${root.path}/port-conflict',
      libraryPath: library,
      bind: '127.0.0.1:$port',
    );
    check(
      !blocked.available && blocked.reason == 'port_in_use',
      'same address collision actionable',
    );
    await conflict.dispose();
    checks.add('same_address_port_conflict_does_not_stop_other_receivers');
    final locked = make();
    final denied = await locked.start(
      supportRoot: '${root.path}/ipv4-a',
      libraryPath: library,
    );
    check(!denied.available, 'shared private root cannot start twice');
    results['sharedRootError'] = denied.reason;
    await locked.dispose();
    final peer = await b.command({
      'command': 'probe',
      'address': a.ready!['address'],
    });
    check(
      peer['fingerprint'] == a.ready!['fingerprint'],
      'owner remains alive after root conflict',
    );
    checks.add('same_root_exclusive_lease_preserves_original_runtime');
    final originalIdentity = a.ready!['fingerprint'];
    final originalInstance = a.ready!['core_instance_id'];
    await a.dispose();
    final livePeer = await b.command({
      'command': 'probe',
      'address': b.ready!['address'],
    });
    check(
      livePeer['fingerprint'] == b.ready!['fingerprint'],
      'stopping one runtime leaves the other alive',
    );
    final restored = make();
    await start(restored, 'ipv4-a', '127.0.0.1:$port');
    check(
      restored.ready!['fingerprint'] == originalIdentity &&
          restored.ready!['core_instance_id'] != originalInstance,
      'same root and exact port reopen with same identity/new runtime',
    );
    check(
      (await restored.command({'command': 'receipts', 'limit': 64}) as List)
              .length ==
          paths.length,
      'committed inbox survives restart',
    );
    checks.add(
      'independent_stop_exact_port_root_reopen_and_persistent_receipts',
    );
    await restored.dispose();
    await b.dispose();

    // This is a real IPv6 stack/listener test, not a parser-only address check.
    final v6a = make(), v6b = make();
    await start(v6a, 'ipv6-a', '[::1]:0');
    await start(v6b, 'ipv6-b', '[::1]:0');
    check(
      (v6a.ready!['address'] as String).startsWith('[::1]:'),
      'actual IPv6 endpoint retained',
    );
    await exchange(v6a, v6b, paths);
    await exchange(v6b, v6a, paths);
    checks.add('ipv6_loopback_https_certificate_and_bidirectional_four_files');
    await v6a.dispose();
    await v6b.dispose();
    if (args.length == 4) {
      final first = args[2], second = args[3];
      final networks = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final assigned = {
        for (final network in networks)
          for (final address in network.addresses)
            address.address: network.index,
      };
      check(
        first != second &&
            assigned.containsKey(first) &&
            assigned.containsKey(second) &&
            assigned[first] != assigned[second],
        'two explicit addresses on distinct assigned interfaces',
      );
      final nicA = make(), nicB = make();
      await start(nicA, 'nic-a', '$first:0');
      final nicPort = int.parse(
        (nicA.ready!['address'] as String).split(':').last,
      );
      await start(nicB, 'nic-b', '$second:$nicPort');
      await exchange(nicA, nicB, paths);
      await exchange(nicB, nicA, paths);
      Socket? unexpected;
      try {
        unexpected = await Socket.connect(
          '127.0.0.1',
          nicPort,
          timeout: const Duration(seconds: 2),
        );
      } on SocketException {
        /* Neither selected-address listener binds loopback. */
      }
      final loopbackClosed = unexpected == null;
      unexpected?.destroy();
      check(
        loopbackClosed,
        'specific interfaces do not expose a wildcard listener',
      );
      checks.add(
        'two_assigned_interfaces_same_port_bidirectional_and_no_wildcard_bind',
      );
      final identity = nicA.ready!['fingerprint'],
          instance = nicA.ready!['core_instance_id'];
      await nicA.dispose();
      final moved = make();
      await start(moved, 'nic-a', '$second:0');
      check(
        moved.ready!['fingerprint'] == identity &&
            moved.ready!['core_instance_id'] != instance,
        'explicit interface rebind preserves identity',
      );
      check(
        (await moved.command({'command': 'receipts', 'limit': 64}) as List)
                .length ==
            paths.length,
        'inbox survives explicit interface rebind',
      );
      final stillAlive = await moved.command({
        'command': 'probe',
        'address': nicB.ready!['address'],
      });
      check(
        stillAlive['fingerprint'] == nicB.ready!['fingerprint'],
        'unrelated interface receiver stays alive',
      );
      final extra = File('${inputs.path}/after-interface.bin');
      await extra.writeAsString(
        'explicit owned bind configuration change, not an OS network switch',
      );
      final extraHash = await fileHash(extra);
      await exchange(nicB, moved, [extra.path]);
      check(
        await fileHash(extra) == extraHash,
        'interface rebind source unchanged',
      );
      checks.add(
        'explicit_interface_rebind_same_root_identity_and_new_transfer',
      );
      results['multiInterfaceDirections'] = 3;
      results['assignedInterfacesTested'] = 2;
      results['interfaceChangeType'] =
          'explicit service bind change; OS interfaces untouched';
    }
    for (final path in paths) {
      check(
        await fileHash(File(path)) ==
            sourceHashes[File(path).uri.pathSegments.last],
        'source unchanged',
      );
    }
    results.addAll({
      'passed': true,
      'checks': checks,
      'filesPerLoopbackDirection': paths.length,
      'loopbackDirections': 4,
      'verifiedFileDeliveries': 16 + (args.length == 4 ? 9 : 0),
      'independentHashes': true,
      'sourceHashes': sourceHashes,
      'sourceUnchanged': true,
      'librarySha256': await fileHash(File(library)),
      'osNetworkSettingsChanged': false,
    });
  } catch (e) {
    results.addAll({'error': e.toString(), 'checks': checks});
    rethrow;
  } finally {
    for (final s in services.reversed) {
      try {
        await s.dispose();
      } catch (e) {
        results['passed'] = false;
        results['cleanupError'] = e.toString();
      }
    }
    await File('${root.path}/result.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(results)}\n',
      flush: true,
    );
    stdout.writeln(jsonEncode(results));
  }
  check(results['passed'] == true, 'all cleanup completed');
}
