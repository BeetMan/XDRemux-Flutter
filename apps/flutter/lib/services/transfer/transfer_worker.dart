import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import '../../ffi/transfer_ffi.dart';
import 'transfer_copy.dart';
import 'transfer_models.dart';

class _Pending {
  _Pending(this.command);
  final String command;
  final result = Completer<dynamic>();
  final started = DateTime.now();
}

/// Only maps, scalar values and ports cross the isolate boundary.
void transferWorkerMain(Map<String, dynamic> args) {
  final owner = args['owner'] as SendPort;
  final input = ReceivePort();
  owner.send({'type': 'port', 'port': input.sendPort});
  try {
    final ffi = TransferBindings(args['libraryPath'] as String?);
    final worker = _Worker(owner, input, ffi, args);
    worker.start();
  } on TransferException catch (e) {
    owner.send({'type': 'availability', 'available': false, 'reason': e.code});
    input.close();
  } catch (_) {
    owner.send({
      'type': 'availability',
      'available': false,
      'reason': 'internal',
    });
    input.close();
  }
}

class _Worker {
  _Worker(this.owner, this.input, this.ffi, this.args);
  final SendPort owner;
  final ReceivePort input;
  final TransferBindings ffi;
  final Map<String, dynamic> args;
  final pending = <int, _Pending>{};
  final recovery = <int, int>{};
  final events = Queue<Map<String, dynamic>>();
  final copies = <Future<dynamic>>{};
  late int handle;
  Timer? timer;
  bool closing = false, stopped = false, ready = false;
  int lastLost = 0, eventBytes = 0;
  bool resync = false;
  Map<String, dynamic>? readyInfo;
  Future<void>? stopFuture;
  DateTime lastRecovery = DateTime.now();

  void start() {
    handle = ffi.create(Map<String, dynamic>.from(args['config'] as Map));
    input.listen((message) {
      unawaited(receive(Map<String, dynamic>.from(message as Map)));
    });
    timer = Timer.periodic(const Duration(milliseconds: 50), (_) => tick());
    tick();
  }

  void tick() {
    if (stopped) return;
    try {
      final page = ffi.poll(handle);
      final lost = page['lost'] as int;
      if (lost != lastLost) {
        resync = true;
        lastLost = lost;
      }
      if (!ready && page['phase'] == 1) {
        ready = true;
        readyInfo = Map<String, dynamic>.from(page['ready'] as Map);
        owner.send({
          'type': 'availability',
          'available': true,
          'ready': readyInfo,
        });
      }
      for (final record in page['records'] as List) {
        final body = Map<String, dynamic>.from(record['body'] as Map);
        if (body['kind'] == 'result') {
          final id = body['operation_id'] as int;
          final original = recovery.remove(id);
          if (original != null) {
            final data = body['data'];
            if (data is Map && data['kind'] == 'result') {
              _complete(Map<String, dynamic>.from(data));
            }
          } else {
            _complete(body);
          }
        } else {
          if (body['kind'] == 'resync_required') resync = true;
          if (body['kind'] == 'start_failed') {
            owner.send({
              'type': 'availability',
              'available': false,
              'reason': body['error'],
              'nativeStarted': true,
            });
          }
          final bytes = utf8.encode(jsonEncode(body)).length;
          while (events.isNotEmpty &&
              (events.length >= 256 || eventBytes + bytes > 2097152)) {
            eventBytes -= utf8.encode(jsonEncode(events.removeFirst())).length;
            resync = true;
          }
          if (bytes <= 2097152) {
            events.add(body);
            eventBytes += bytes;
          } else {
            resync = true;
          }
        }
      }
      if (page['phase'] == 3) {
        stopped = true;
        timer?.cancel();
        ffi.release(handle);
        for (final p in pending.values) {
          p.result.completeError(const TransferException('closed'));
        }
        pending.clear();
        recovery.clear();
        if (!ready) {
          owner.send({
            'type': 'availability',
            'available': false,
            'reason': 'closed',
            'nativeStarted': true,
          });
        }
        return;
      }
      // Recover lost command results without ever resubmitting the mutation itself.
      if (DateTime.now().difference(lastRecovery).inSeconds >= 1) {
        lastRecovery = DateTime.now();
        recovery.clear();
        final expired = pending.entries
            .where(
              (e) => DateTime.now().difference(e.value.started).inSeconds >= 30,
            )
            .toList();
        for (final entry in expired) {
          pending
              .remove(entry.key)
              ?.result
              .completeError(
                TransferException('outcome_unknown', operationId: entry.key),
              );
          resync = true;
          if (entry.value.command == 'acquire_receipt' ||
              entry.value.command == 'release_receipt') {
            // Stop after the copy settles to revoke a potentially orphaned lease.
            unawaited(stop());
          }
        }
        for (final entry in pending.entries) {
          if (recovery.length >= 8) break;
          if (DateTime.now().difference(entry.value.started).inSeconds < 2 ||
              recovery.containsValue(entry.key)) {
            continue;
          }
          try {
            recovery[ffi.submit(handle, {
                  'command': 'operation',
                  'operation_id': entry.key,
                })] =
                entry.key;
          } on TransferException {
            break;
          }
        }
      }
    } catch (_) {
      resync = true;
      // Keep the isolate/runtime alive until the native stop/release handshake finishes.
      if (!closing) {
        closing = true;
        unawaited(stop());
      }
    }
  }

  void _complete(Map<String, dynamic> body) {
    final id = body['operation_id'] as int;
    final p = pending.remove(id);
    if (p == null) return;
    if (body['error'] != null) {
      p.result.completeError(
        TransferException(body['error'] as String, operationId: id),
      );
    } else {
      p.result.complete(body['data']);
    }
  }

  Future<dynamic> command(
    Map<String, dynamic> request, {
    bool cleanup = false,
  }) {
    if ((closing && !cleanup) || stopped) {
      throw const TransferException('closed');
    }
    final priority =
        cleanup ||
        [
          'cancel_send',
          'cancel_receive',
          'release_receipt',
        ].contains(request['command']);
    if (pending.length >= (priority ? 32 : 24)) {
      throw const TransferException('busy');
    }
    final id = ffi.submit(handle, request);
    final p = _Pending(request['command'] as String);
    pending[id] = p;
    return p.result.future;
  }

  Future<dynamic> prepare(String id) async {
    final lease = Map<String, dynamic>.from(
      await command({'command': 'acquire_receipt', 'receipt_id': id}) as Map,
    );
    try {
      await command({
        'command': 'check_space',
        'bytes': lease['receipt']['size'],
        'reserve': 64 * 1024 * 1024,
      });
      return await copyTransferInput(args['supportRoot'] as String, lease);
    } finally {
      for (var attempt = 0; ; attempt++) {
        try {
          await command({
            'command': 'release_receipt',
            'lease_id': lease['lease_id'],
          }, cleanup: true);
          break;
        } on TransferException catch (e) {
          if (e.code == 'busy' && attempt < 20) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          // Once this copy unwinds, stop revokes any unreleased native lease.
          unawaited(stop());
          rethrow;
        }
      }
    }
  }

  Future<void> receive(Map<String, dynamic> msg) async {
    final id = msg['id'];
    try {
      dynamic result;
      switch (msg['method']) {
        case 'command':
          result = await command(
            Map<String, dynamic>.from(msg['request'] as Map),
          );
        case 'events':
          result = {
            'ready': readyInfo,
            'resync': resync,
            'events': events.toList(),
          };
          events.clear();
          eventBytes = 0;
          resync = false;
        case 'prepare':
          if (copies.isNotEmpty) throw const TransferException('busy');
          final task = prepare(msg['receiptId'] as String);
          copies.add(task);
          try {
            result = await task;
          } finally {
            copies.remove(task);
          }
        case 'stop':
          await stop();
        default:
          throw const TransferException('invalid_input');
      }
      owner.send({'type': 'reply', 'id': id, 'result': result});
      if (msg['method'] == 'stop') input.close();
    } on TransferException catch (e) {
      owner.send({
        'type': 'reply',
        'id': id,
        'error': e.code,
        'operationId': e.operationId,
      });
    } catch (_) {
      owner.send({'type': 'reply', 'id': id, 'error': 'io'});
    }
  }

  Future<void> stop() => stopFuture ??= _stop();
  Future<void> _stop() async {
    closing = true;
    for (final copy in copies.toList()) {
      try {
        await copy;
      } catch (_) {
        /* Preserve the receipt; caller receives the error. */
      }
    }
    if (!stopped) ffi.stop(handle);
    while (!stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
