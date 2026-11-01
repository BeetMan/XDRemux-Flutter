// Native -> existing official LocalSend 1.17 Windows receiver, with optional UI
// reverse validation using only this run's fixed fixtures and pinned identities.
// Only the child process uses the fresh APPDATA/LOCALAPPDATA settings below.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';
import 'transfer_worker_smoke.dart' show check, fileHash;

Future<void> main(List<String> args) async {
  if (args.length != 4 && !(args.length == 5 && args[4] == '--bidirectional')) {
    throw ArgumentError(
      'DLL_PATH NEW_ROOT EXISTING_OFFICIAL_EXE LOCAL_IPV4 [--bidirectional]',
    );
  }
  final bidirectional = args.length == 5;
  final library = File(args[0]).absolute.path, root = Directory(args[1]);
  const port = 53317;
  final executable = File(args[2]).absolute.path, local = args[3];
  check(
    Platform.isWindows && await File(executable).exists(),
    'existing Windows client required',
  );
  final metadata = await Process.run(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'(Get-Item -LiteralPath $env:XDREMUX_P3_OFFICIAL_EXE).VersionInfo.ProductVersion',
    ],
    environment: {'XDREMUX_P3_OFFICIAL_EXE': executable},
  );
  final version = (metadata.stdout as String).trim();
  check(
    metadata.exitCode == 0 && version == '1.17.0+58',
    'only the verified official 1.17.0+58 settings schema is supported',
  );
  // Refuse to attach to or replace an already listening user application.
  final reserved = await ServerSocket.bind('127.0.0.1', port);
  await reserved.close();
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  check(
    interfaces.expand((i) => i.addresses).any((a) => a.address == local),
    'explicit assigned IPv4',
  );
  check(root.isAbsolute && !await root.exists(), 'new owned root');
  await root.create();
  Process? official;
  final logTasks = <Future<void>>[];
  final originalConfigs = <String, String?>{};
  for (final path in [
    '${File(executable).parent.path}/settings.json',
    '${Platform.environment['APPDATA']}/LocalSend/settings.json',
    '${Platform.environment['APPDATA']}/org.localsend/localsend_app/shared_preferences.json',
  ]) {
    originalConfigs[path] = await File(path).exists()
        ? await fileHash(File(path))
        : null;
  }
  check(
    originalConfigs['${File(executable).parent.path}/settings.json'] == null,
    'installed client must not use adjacent portable settings',
  );
  final native = TransferService(), conflict = TransferService();
  final events = <Map<String, dynamic>>[];
  final result = <String, dynamic>{
    'passed': false,
    'officialPort': port,
    'officialVersion': version,
    'mode': bidirectional ? 'bidirectional_ui' : 'receive_only',
    'scope': bidirectional
        ? 'Windows native/worker <-> official 1.17 with actual sender UI; same-host traffic'
        : 'Windows native -> official 1.17 receiver; same-host multicast coexistence; reverse UI not covered',
  };
  Future<void> stage(String name, [Map<String, dynamic> fields = const {}]) =>
      File(
        '${root.path}/status.json',
      ).writeAsString(jsonEncode({'stage': name, ...fields}), flush: true);
  Future<Map<String, dynamic>> next(
    String kind, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final index = events.indexWhere((e) => e['kind'] == kind);
      if (index >= 0) return events.removeAt(index);
      final page = await native.drainEvents();
      check(page['resync'] == false, 'no event loss');
      for (final body in page['events'] as List) {
        if (body['kind'] == 'event' && body['event']['kind'] != 'progress') {
          events.add(Map<String, dynamic>.from(body['event']));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('fixture event deadline: $kind');
  }

  try {
    final fixture = Directory('${root.path}/fixtures'),
        received = Directory('${root.path}/official-received');
    await fixture.create();
    await received.create();
    final paths = <String>[];
    final expected = <String, Map<String, dynamic>>{};
    for (final entry in <String, List<int>>{
      'p3-auto-empty.bin': [],
      'p3-auto-中文-🧪.bin': utf8.encode('owned test data only'),
      'p3-auto-opaque.heic': [
        0,
        0,
        0,
        24,
        ...ascii.encode('ftypheic'),
        ...List.generate(65536, (i) => i % 251),
      ],
      'p3-auto-opaque.mov': List.generate(1024 * 1024, (i) => (i * 7) % 251),
    }.entries) {
      final file = File('${fixture.path}/${entry.key}');
      await file.writeAsBytes(entry.value);
      paths.add(file.path);
      expected[entry.key] = {
        'size': entry.value.length,
        'sha256': await fileHash(file),
      };
    }
    check(
      (await native.start(
        supportRoot: '${root.path}/native',
        libraryPath: library,
        bind: '0.0.0.0:0',
        alias: 'XDRemux P3 automated fixture',
      )).available,
      'real native receiver',
    );
    final nativePort = int.parse(
      (native.ready!['address'] as String).split(':').last,
    );
    await File('${root.path}/ready.json').writeAsString(
      jsonEncode({
        'address': '127.0.0.1:$nativePort',
        'fingerprint': native.ready!['fingerprint'],
        'instanceId': native.ready!['core_instance_id'],
        'paths': paths,
        'expected': expected,
        'officialDestination': received.path,
      }),
      flush: true,
    );
    await stage('waiting_official');
    final roaming = Directory('${root.path}/appdata'),
        localData = Directory('${root.path}/localappdata');
    await Directory('${roaming.path}/LocalSend').create(recursive: true);
    await localData.create();
    final random = Random.secure();
    final pin = List.generate(
      24,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    const officialAlias = 'LocalSend P3 isolated receiver';
    await File('${roaming.path}/LocalSend/settings.json').writeAsString(
      jsonEncode({
        'flutter.ls_version': 2,
        'flutter.ls_locale': 'en',
        'flutter.ls_alias': officialAlias,
        'flutter.ls_port': port,
        'flutter.ls_https': true,
        'flutter.ls_network_whitelist': [local],
        'flutter.ls_destination': received.path,
        'flutter.ls_quick_save': false,
        'flutter.ls_quick_save_from_favorites': true,
        'flutter.ls_receive_pin': pin,
        'flutter.ls_auto_finish': !bidirectional,
        'flutter.ls_save_to_gallery': false,
        'flutter.ls_save_to_history': false,
        'flutter.ls_enable_animations': false,
        'flutter.ls_favorites': [
          jsonEncode({
            'id': '11111111-1111-4111-8111-111111111111',
            'fingerprint': native.ready!['fingerprint'],
            'ip': '127.0.0.1',
            'port': nativePort,
            'alias': 'XDRemux P3 automated fixture',
            'customAlias': true,
          }),
        ],
      }),
      flush: true,
    );
    official = await Process.start(
      executable,
      ['--hidden', if (bidirectional) ...paths],
      environment: {'APPDATA': roaming.path, 'LOCALAPPDATA': localData.path},
    );
    logTasks.add(
      official.stdout.pipe(
        File('${root.path}/official-stdout.txt').openWrite(),
      ),
    );
    logTasks.add(
      official.stderr.pipe(
        File('${root.path}/official-stderr.txt').openWrite(),
      ),
    );
    result['officialPid'] = official.pid;
    result['officialExecutableSha256'] = await fileHash(File(executable));
    Map<String, dynamic>? peer;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (peer == null && DateTime.now().isBefore(deadline)) {
      try {
        peer = Map<String, dynamic>.from(
          await native.command({
            'command': 'probe',
            'address': '127.0.0.1:$port',
          }),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    check(peer != null, 'official listener ready');
    final pinned = peer!;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    http.findProxy = (_) => 'DIRECT';
    http.badCertificateCallback = (cert, _, _) =>
        sha256.convert(cert.der).toString().toUpperCase() ==
        (pinned['fingerprint'] as String).toUpperCase();
    try {
      final request = await http.getUrl(
        Uri.parse('https://127.0.0.1:$port/api/localsend/v2/info'),
      );
      final response = await request.close();
      check(response.statusCode == 200, 'official info endpoint');
      final info = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      check(
        info['alias'] == officialAlias,
        'listener uses isolated test configuration',
      );
      result['officialProtocolVersion'] = info['version'];
    } finally {
      http.close(force: true);
    }
    result['officialFingerprint'] = pinned['fingerprint'];
    final availability = await conflict.start(
      supportRoot: '${root.path}/collision',
      libraryPath: library,
      bind: '127.0.0.1:$port',
    );
    check(
      !availability.available && availability.reason == 'port_in_use',
      'official port conflict classified',
    );
    await conflict.dispose();
    check(
      (await native.command({
            'command': 'probe',
            'address': pinned['address'],
          }))['fingerprint'] ==
          pinned['fingerprint'],
      'official still alive after collision',
    );
    result['officialPortConflictAndAlternateListener'] = true;
    await native.command({'command': 'discovery_start', 'interface': local});
    var seen = false;
    final discoveryDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (!seen && DateTime.now().isBefore(discoveryDeadline)) {
      final snapshot = await native.command({'command': 'discovery_status'});
      seen = (snapshot['peers'] as List).any(
        (p) =>
            p['fingerprint'] == pinned['fingerprint'] &&
            (p['address'] as String).endsWith(':$port'),
      );
      if (!seen) await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    result['nativeDiscoverySeesOfficial'] = seen;
    check(
      seen,
      'certificate-verified official peer observed through multicast',
    );
    result['simultaneousMulticastStart'] = true;
    await stage('sending_to_official');
    await native.command({
      'command': 'send',
      'peer': {...pinned, 'fingerprint': '0' * 64},
      'paths': paths,
      'pin': pin,
    });
    check(
      (await next('sent'))['report']['error'] == 'identity_mismatch',
      'official certificate mismatch rejected',
    );
    check(
      (await received.list().toList()).isEmpty,
      'wrong identity exposes no destination file',
    );
    result['wrongFingerprintRejectedWithoutFiles'] = true;
    await native.command({
      'command': 'send',
      'peer': pinned,
      'paths': paths,
      'pin': '${pin}x',
    });
    check(
      (await next('sent'))['report']['error'] == 'authentication',
      'official rejects incorrect PIN',
    );
    check(
      (await received.list().toList()).isEmpty,
      'wrong PIN exposes no destination file',
    );
    result['wrongPinRejectedWithoutFiles'] = true;
    await native.command({
      'command': 'send',
      'peer': pinned,
      'paths': paths,
      'pin': pin,
    });
    final sent = (await next('sent'))['report'];
    check(
      sent['error'] == null && sent['files'].length == expected.length,
      'official acknowledges all files',
    );
    for (final entry in expected.entries) {
      final file = File('${received.path}/${entry.key}');
      check(
        await file.exists() &&
            await file.length() == entry.value['size'] &&
            await fileHash(file) == entry.value['sha256'],
        'official independent destination hash',
      );
    }
    result['nativeToOfficial'] = {
      'files': expected.length,
      'independentHashes': true,
    };
    if (bidirectional) {
      await stage('reverse_ready', {
        'officialFingerprint': pinned['fingerprint'],
        'nativeInstanceId': native.ready!['core_instance_id'],
      });
      final offer = (await next(
        'offer',
        timeout: const Duration(minutes: 5),
      ))['offer'];
      final names = <String>{};
      var owned =
          offer['peer_fingerprint'] == pinned['fingerprint'] &&
          offer['files'].length == expected.length;
      for (final file in offer['files'] as List) {
        final selected = expected[file['name']];
        owned =
            owned &&
            selected != null &&
            names.add(file['name']) &&
            file['size'] == selected['size'] &&
            (file['sha256'] == null || file['sha256'] == selected['sha256']);
      }
      await native.command({
        'command': 'decide',
        'transfer_id': offer['session_id'],
        'accept': owned,
      });
      check(
        owned,
        'only pinned official sender and fixed synthetic file set accepted',
      );
      for (var i = 0; i < expected.length; i++) {
        await next('committed');
      }
      final receipts =
          await native.command({'command': 'receipts', 'limit': 64}) as List;
      check(
        receipts.length == expected.length,
        'one native receipt per official file',
      );
      for (final receipt in receipts) {
        final selected = expected[receipt['name']];
        check(selected != null, 'only selected native receipts');
        final lease = await native.command({
          'command': 'acquire_receipt',
          'receipt_id': receipt['id'],
        });
        try {
          final file = File(lease['path']);
          check(
            await file.length() == selected!['size'] &&
                await fileHash(file) == selected['sha256'],
            'reverse independent disk length/hash',
          );
        } finally {
          await native.command({
            'command': 'release_receipt',
            'lease_id': lease['lease_id'],
          });
        }
      }
      await stage('reverse_committed', {
        'officialFingerprint': pinned['fingerprint'],
        'nativeInstanceId': native.ready!['core_instance_id'],
        'files': receipts.length,
      });
      // The observer must actually inspect the official sender's Finished page.
      // This prevents a receiver-only commit from standing in for sender UI ACK.
      final proof = File('${root.path}/ui-finished.json');
      final uiDeadline = DateTime.now().add(const Duration(minutes: 5));
      while (!await proof.exists() && DateTime.now().isBefore(uiDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      check(
        await proof.exists(),
        'official sender Finished UI observation required',
      );
      final observed = jsonDecode(await proof.readAsString()) as Map;
      check(
        observed['status'] == 'finished' &&
            observed['officialFingerprint'] == pinned['fingerprint'] &&
            observed['nativeInstanceId'] == native.ready!['core_instance_id'] &&
            observed['fileCount'] == expected.length,
        'current-run official UI result',
      );
      result['officialToNative'] = {
        'status': 'passed',
        'files': receipts.length,
        'independentHashes': true,
        'officialSenderFinishedUiObserved': true,
        'peerHashPresent': receipts.every(
          (r) => r['peer_hash_present'] == true,
        ),
      };
    }
    for (final path in paths) {
      check(
        await fileHash(File(path)) ==
            expected[File(path).uri.pathSegments.last]!['sha256'],
        'source unchanged',
      );
    }
    result['officialToNative'] ??= {
      'status': 'not_run',
      'reason': 'receive-only harness; reverse UI must be validated separately',
    };
    result.addAll({
      'passed': true,
      'fixtures': expected,
      'sourceUnchanged': true,
      'librarySha256': await fileHash(File(library)),
      'osNetworkSettingsChanged': false,
    });
    await stage('complete');
  } catch (e) {
    result['error'] = e.toString();
    await stage('failed', {'error': e.toString()});
    rethrow;
  } finally {
    if (official != null) {
      official.kill();
      try {
        await official.exitCode.timeout(const Duration(seconds: 10));
        await Future.wait(logTasks);
      } catch (e) {
        result['passed'] = false;
        result['officialCleanupError'] = e.toString();
      }
    }
    try {
      await conflict.dispose();
      await native.dispose();
    } catch (e) {
      result['passed'] = false;
      result['cleanupError'] = e.toString();
    }
    var unchanged = true;
    for (final entry in originalConfigs.entries) {
      final current = await File(entry.key).exists()
          ? await fileHash(File(entry.key))
          : null;
      unchanged = unchanged && current == entry.value;
    }
    result['originalConfigurationUnchanged'] = unchanged;
    if (!unchanged) result['passed'] = false;
    await File('${root.path}/result.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(result)}\n',
      flush: true,
    );
    stdout.writeln(jsonEncode(result));
  }
  check(result['passed'] == true, 'cleanup completed');
}
