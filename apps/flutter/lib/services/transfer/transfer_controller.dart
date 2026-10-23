import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'transfer_intake.dart';
import 'transfer_models.dart';
import 'transfer_service.dart';

/// Application-scoped owner. No sockets until an explicit receive/send/inbox action.
class TransferController extends ChangeNotifier with WidgetsBindingObserver {
  TransferController({
    TransferService Function()? serviceFactory,
    Future<Directory> Function()? supportDirectory,
    bool observeLifecycle = true,
  }) : _factory = serviceFactory ?? TransferService.new,
       _support = supportDirectory ?? getApplicationSupportDirectory {
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    _observing = observeLifecycle;
  }
  static final instance = TransferController();
  final TransferService Function() _factory;
  final Future<Directory> Function() _support;
  bool _observing = false;
  TransferService? _service;
  Future<void>? _startup, _stopTask;
  int _stopGeneration = 0;
  Future<void>? _refreshTask, _inboxTask;
  final Set<Future<dynamic>> _reads = {};
  Timer? _timer;
  bool _polling = false, receiving = false, starting = false, stopping = false;
  bool discovering = false;
  String? discoveryError;
  final List<Map<String, dynamic>> peers = [];
  final Map<String, String> interfaces = {};
  String? discoveryInterface;
  DateTime _lastDiscoveryPoll = DateTime.fromMillisecondsSinceEpoch(0);
  static const _multicast = MethodChannel('xdremux/transfer-discovery');
  String? error;
  Map<String, dynamic>? ready;
  final Map<String, Map<String, dynamic>> transfers = {};
  final Map<String, List<Map<String, dynamic>>> files = {};
  final Map<String, Map<String, dynamic>> inbox = {};
  final Set<String> trusted = {}, _confirmed = {};
  List<String> addresses = [];
  bool moreInbox = false;
  String? _receiptCursor;
  int _receiptPages = 1;
  final Map<String, Map<String, dynamic>> _newReceipts = {};
  bool get running => _service != null && ready != null;
  bool get busy => starting || stopping;
  TransferService get service {
    if (_service == null || stopping) throw const TransferException('closed');
    return _service!;
  }

  static String code(Object e) => e is TransferException ? e.code : 'io';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((Platform.isAndroid || Platform.isIOS) &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      unawaited(stop());
    }
  }

  Future<void> enableReceiving({int port = 53319}) async {
    if (port < 1 || port > 65535) {
      throw const TransferException('invalid_input');
    }
    if (busy) throw const TransferException('busy');
    final cleanup = stop();
    final generation = _stopGeneration;
    await cleanup;
    _checkStartup(generation);
    await _start('${discoveryInterface ?? '0.0.0.0'}:$port', true);
    _checkStartup(generation);
    await discover();
  }

  Future<void> enumerateInterfaces() async {
    final next = <String, String>{};
    for (final network in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final ip in network.addresses) {
        if (!ip.isLoopback && !ip.isMulticast && ip.address != '0.0.0.0') {
          next[ip.address] = network.name;
        }
      }
    }
    interfaces
      ..clear()
      ..addAll(next);
    addresses = discoveryInterface == null
        ? next.keys.toList()
        : [discoveryInterface!];
    notifyListeners();
  }

  Future<void> discover() async {
    if (!receiving || stopping) throw const TransferException('closed');
    final native = service;
    discoveryError = null;
    try {
      if (Platform.isAndroid) await _multicast.invokeMethod<void>('acquire');
      final result = await native.command({
        'command': 'discovery_start',
        'interface': discoveryInterface,
      });
      if (stopping || !identical(_service, native)) return;
      await _discoveryState(result as Map);
    } catch (e) {
      discoveryError = code(e);
      discovering = false;
      peers.clear();
      if (Platform.isAndroid) {
        try {
          await _multicast.invokeMethod<void>('release');
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> _discoveryState(Map result) async {
    discovering = result['enabled'] == true;
    discoveryError = result['error'] as String?;
    peers
      ..clear()
      ..addAll(
        (discovering ? result['peers'] as List : const []).map(
          (p) => Map<String, dynamic>.from(p as Map),
        ),
      );
    if (!discovering && Platform.isAndroid) {
      try {
        await _multicast.invokeMethod<void>('release');
      } catch (_) {}
    }
  }

  Future<void> ensureLocal() async {
    if (stopping) throw const TransferException('closed');
    if (running) return;
    final generation = _stopGeneration;
    await (_startup ?? _start('127.0.0.1:0', false));
    _checkStartup(generation);
  }

  void _checkStartup(int generation) {
    if (stopping || generation != _stopGeneration) {
      throw const TransferException('closed');
    }
  }

  Future<void> _start(String bind, bool receive) =>
      _startup ??= _startNow(bind, receive).whenComplete(() => _startup = null);
  Future<void> _startNow(String bind, bool receive) async {
    final generation = _stopGeneration;
    starting = true;
    error = null;
    notifyListeners();
    final native = _factory();
    try {
      final dir = await _support();
      _checkStartup(generation);
      final available = await native.start(supportRoot: dir.path, bind: bind);
      _checkStartup(generation);
      if (!available.available) {
        throw TransferException(available.reason ?? 'closed');
      }
      _service = native;
      ready = native.ready;
      receiving = receive;
      trusted.addAll(
        (await SharedPreferences.getInstance()).getStringList(
              'transfer.trusted.v1',
            ) ??
            [],
      );
      await enumerateInterfaces();
      _checkStartup(generation);
      await refresh();
      _checkStartup(generation);
      _timer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(poll()),
      );
    } catch (e) {
      error = code(e);
      await native.dispose();
      _service = null;
      ready = null;
      receiving = false;
      throw TransferException(error!);
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> probe(String host, int port) async {
    final ip = InternetAddress.tryParse(host.trim());
    if (ip == null || port < 1 || port > 65535) {
      throw const TransferException('invalid_input');
    }
    await ensureLocal();
    final address = ip.type == InternetAddressType.IPv6
        ? '[${ip.address}]:$port'
        : '${ip.address}:$port';
    return Map<String, dynamic>.from(
      await service.command({'command': 'probe', 'address': address}) as Map,
    );
  }

  Future<void> confirmPeer(
    Map<String, dynamic> peer, {
    required bool remember,
  }) async {
    final value = peer['fingerprint'];
    if (value is! String) throw const TransferException('identity_mismatch');
    final fp = value.toUpperCase();
    if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(fp)) {
      throw const TransferException('identity_mismatch');
    }
    _confirmed.add(fp);
    if (remember) {
      trusted.add(fp);
      if (trusted.length > 128) trusted.remove(trusted.first);
      await (await SharedPreferences.getInstance()).setStringList(
        'transfer.trusted.v1',
        trusted.toList(),
      );
    }
    notifyListeners();
  }

  bool isPeerConfirmed(Map<String, dynamic> peer) {
    final fingerprint = peer['fingerprint'];
    return fingerprint is String &&
        _confirmed.contains(fingerprint.toUpperCase());
  }

  void _requirePeerConfirmation(Map<String, dynamic> peer) {
    if (!isPeerConfirmed(peer)) {
      throw const TransferException('identity_mismatch');
    }
  }

  Future<void> forgetPeers() async {
    trusted.clear();
    _confirmed.clear();
    await (await SharedPreferences.getInstance()).remove('transfer.trusted.v1');
    notifyListeners();
  }

  Future<String> send(
    Map<String, dynamic> peer,
    List<String> paths, {
    String? pin,
  }) async {
    // The caller can change its selection while startup awaits disk/native I/O.
    // Keep this request fixed, and honor revocation before dispatching metadata.
    final selectedPeer = Map<String, dynamic>.unmodifiable(peer);
    final selectedPaths = List<String>.unmodifiable(paths);
    _requirePeerConfirmation(selectedPeer);
    await ensureLocal();
    _requirePeerConfirmation(selectedPeer);
    final parent = selectedPaths.isEmpty
        ? null
        : File(selectedPaths.first).parent.path;
    final compact =
        selectedPaths.length > 1 &&
        selectedPaths.every((p) => File(p).parent.path == parent);
    final request = <String, dynamic>{
      'command': 'send',
      'peer': selectedPeer,
      'paths': selectedPaths,
      'pin': pin,
    };
    if (compact) {
      request
        ..['command'] = 'send_batch'
        ..remove('paths')
        ..['directory'] = parent
        ..['names'] = selectedPaths
            .map((p) => File(p).uri.pathSegments.last)
            .toList();
    }
    if (utf8.encode(jsonEncode(request)).length > 64 * 1024) {
      throw const TransferException('batch_too_large');
    }
    final result = await service.command(request);
    return result['transfer_id'] as String;
  }

  Future<void> decide(String id, bool accept) async {
    if (accept && !receiving) throw const TransferException('closed');
    await service.command({
      'command': 'decide',
      'transfer_id': id,
      'accept': accept,
    });
    await refresh();
  }

  Future<String> retry(
    String id,
    Map<String, dynamic> peer, {
    String? pin,
  }) async {
    final selectedPeer = Map<String, dynamic>.unmodifiable(peer);
    _requirePeerConfirmation(selectedPeer);
    final result = await service.command({
      'command': 'retry_send',
      'transfer_id': id,
      'peer': selectedPeer,
      'pin': pin,
    });
    await refresh();
    return result['transfer_id'] as String;
  }

  Future<void> cancel(String id) async {
    final kind = transfers[id]?['direction'] == 'send'
        ? 'cancel_send'
        : 'cancel_receive';
    await service.command({'command': kind, 'transfer_id': id});
    await refresh();
  }

  Future<void> poll() async {
    if (_polling || !running || stopping) return;
    _polling = true;
    try {
      final native = service;
      final page = await native.drainEvents();
      if (stopping || !identical(_service, native)) return;
      var dirty = page['resync'] == true;
      var ended = false;
      for (final body in page['events'] as List) {
        if (body['kind'] == 'event') {
          final e = body['event'] as Map;
          if (e['kind'] == 'stopped') ended = true;
          if (e['kind'] == 'committed') {
            final receipt = Map<String, dynamic>.from(e['receipt'] as Map);
            _newReceipts[receipt['id'] as String] = receipt;
            inbox[receipt['id'] as String] = receipt;
          } else if (e['kind'] == 'receipt_deleted') {
            inbox.remove(e['receipt_id']);
            _newReceipts.remove(e['receipt_id']);
          }
          if (e['kind'] == 'progress') {
            // A refreshed snapshot may already be newer than queued progress.
            // Terminal snapshots/ACKs win, and live progress cannot go backwards.
            if ([
              'completed',
              'failed',
            ].contains(transfers[e['transfer_id']]?['phase'])) {
              continue;
            }
            for (final file
                in files[e['transfer_id']] ?? <Map<String, dynamic>>[]) {
              if (file['id'] == e['file_id'] && file['phase'] == 'failed') {
                // A peer may retry a checksum failure in the same live session.
                // Only a fresh native snapshot can distinguish that from lag.
                dirty = true;
                continue;
              }
              if (file['id'] == e['file_id'] &&
                  !['sent', 'committed'].contains(file['phase'])) {
                final bytes = (e['bytes'] as int).clamp(0, file['size'] as int);
                if (bytes > (file['bytes'] as int)) file['bytes'] = bytes;
                file['phase'] = 'transferring';
              }
            }
          } else if (e['kind'] != 'stopped') {
            dirty = true;
          }
        } else if (body['kind'] == 'fatal' || body['kind'] == 'stopped') {
          ended = true;
        }
      }
      // Consume terminal events before issuing any query against that runtime.
      if (ended) {
        error = 'closed';
        await stop();
        return;
      }
      if (receiving &&
          DateTime.now().difference(_lastDiscoveryPoll).inSeconds >= 1) {
        _lastDiscoveryPoll = DateTime.now();
        final state = await native.command({'command': 'discovery_status'});
        if (stopping || !identical(_service, native)) return;
        await _discoveryState(state as Map);
      }
      if (dirty) {
        await refresh();
        // UUID order is not commit order. Recover every page after overflow.
        if (page['resync'] == true) {
          while (moreInbox && !stopping && identical(_service, native)) {
            await loadInbox();
          }
        }
      } else {
        notifyListeners();
      }
    } catch (e) {
      if (!stopping) {
        error = code(e);
        if (error == 'closed' || error == 'worker_stopped') {
          error = 'closed';
          await stop();
        } else {
          notifyListeners();
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> refresh() =>
      _refreshTask ??= _refreshNow().whenComplete(() => _refreshTask = null);
  Future<void> _refreshNow() async {
    final native = service;
    final nextTransfers = <String, Map<String, dynamic>>{};
    String? cursor;
    do {
      final page = await native.command({
        'command': 'snapshot',
        'after': cursor,
        'limit': 64,
      });
      for (final row in page['transfers'] as List) {
        nextTransfers[row['id'] as String] = Map<String, dynamic>.from(
          row as Map,
        );
      }
      cursor = page['next'] as String?;
    } while (cursor != null);
    final nextFiles = <String, List<Map<String, dynamic>>>{};
    for (final id in nextTransfers.keys) {
      try {
        final rows = <Map<String, dynamic>>[];
        String? fileCursor;
        do {
          final page = await native.command({
            'command': 'transfer',
            'transfer_id': id,
            'after': fileCursor,
            'limit': 64,
          });
          rows.addAll(
            (page['files'] as List).map(
              (f) => Map<String, dynamic>.from(f as Map),
            ),
          );
          fileCursor = page['next'] as String?;
          if (rows.length > 1024) {
            throw const TransferException('invalid_input');
          }
        } while (fileCursor != null);
        nextFiles[id] = rows;
      } on TransferException catch (e) {
        if (e.code != 'invalid_input') rethrow;
      }
    }
    if (stopping || !identical(_service, native)) return;
    transfers
      ..clear()
      ..addAll(nextTransfers);
    files
      ..clear()
      ..addAll(nextFiles);
    await loadInbox(reset: true);
    notifyListeners();
  }

  Future<void> loadInbox({bool reset = false}) async {
    if (_inboxTask != null) await _inboxTask;
    final task = _loadInbox(reset: reset);
    _inboxTask = task;
    try {
      await task;
    } finally {
      if (identical(_inboxTask, task)) _inboxTask = null;
    }
  }

  Future<void> _loadInbox({required bool reset}) async {
    final native = service;
    final rows = <String, Map<String, dynamic>>{};
    String? cursor = reset ? null : _receiptCursor;
    var more = false;
    var readPages = 0;
    do {
      final page =
          await native.command({
                'command': 'receipts',
                'after': cursor,
                'limit': 64,
              })
              as List;
      for (final row in page) {
        rows[row['id'] as String] = Map<String, dynamic>.from(row as Map);
      }
      cursor = page.isEmpty ? cursor : page.last['id'] as String;
      more = page.length == 64;
      readPages++;
    } while (reset && more && readPages < _receiptPages);
    if (stopping || !identical(_service, native)) return;
    if (reset) inbox.clear();
    inbox.addAll(rows);
    // New commits may sort before/after the loaded window; keep them visible.
    inbox.addAll(_newReceipts);
    _receiptCursor = cursor;
    moreInbox = more;
    _receiptPages = reset ? readPages : _receiptPages + readPages;
    notifyListeners();
  }

  Future<TransferIntakeAck> importReceipt(String id) async {
    await ensureLocal();
    return _hold(() => TransferIntake(service).importReceipt(id));
  }

  Future<void> deleteReceipt(String id) async {
    await ensureLocal();
    await service.command({'command': 'delete_receipt', 'receipt_id': id});
    inbox.remove(id);
    _newReceipts.remove(id);
    notifyListeners();
  }

  Future<T> _hold<T>(Future<T> Function() work) async {
    if (stopping) throw const TransferException('closed');
    final task = work();
    _reads.add(task);
    try {
      return await task;
    } finally {
      _reads.remove(task);
    }
  }

  Future<T> withReceipt<T>(
    String id,
    Future<T> Function(Map<String, dynamic> lease) work,
  ) async {
    await ensureLocal();
    final native = service;
    return _hold(() async {
      final lease = Map<String, dynamic>.from(
        await native.command({'command': 'acquire_receipt', 'receipt_id': id})
            as Map,
      );
      try {
        return await work(lease);
      } finally {
        await native.command({
          'command': 'release_receipt',
          'lease_id': lease['lease_id'],
        });
      }
    });
  }

  Future<void> exportDesktop(String id, String directory) async {
    await ensureLocal();
    final native = service;
    await _hold(
      () => native.command({
        'command': 'export_receipt',
        'receipt_id': id,
        'directory': directory,
      }),
    );
  }

  Future<void> stop() {
    // Every request revokes pending starts, even when cleanup is already shared.
    _stopGeneration++;
    return _stopTask ??= _stopNow().whenComplete(() => _stopTask = null);
  }

  Future<void> _stopNow() async {
    stopping = true;
    receiving = false;
    discovering = false;
    peers.clear();
    _timer?.cancel();
    notifyListeners();
    try {
      try {
        await _startup;
      } catch (_) {
        /* startup already reports its error */
      }
      for (final read in _reads.toList()) {
        try {
          await read;
        } catch (_) {}
      }
      final native = _service;
      _service = null;
      ready = null;
      if (native != null) await native.dispose();
      transfers.clear();
      files.clear();
    } finally {
      if (Platform.isAndroid) {
        try {
          await _multicast.invokeMethod<void>('release');
        } catch (_) {}
      }
      stopping = false;
      starting = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}
