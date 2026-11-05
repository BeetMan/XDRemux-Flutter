import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'transfer_models.dart';
import 'transfer_worker.dart';

/// Optional native capability. Construction does not load a library or listen.
class TransferService {
  final _port = ReceivePort();
  final _exited = Completer<void>();
  final _pending = <int, Completer<dynamic>>{};
  final _availability = Completer<TransferAvailability>();
  SendPort? _worker;
  int _next = 0;
  bool _started = false, _closing = false;
  bool _nativeCreated = false;
  Future<void>? _dispose;
  Map<String, dynamic>? ready;

  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
    if (_started) throw const TransferException('invalid_input');
    if (_closing) throw const TransferException('closed');
    _started = true;
    void failed() {
      _worker = null;
      _nativeCreated = false;
      if (!_availability.isCompleted) {
        _availability.complete(
          const TransferAvailability(false, 'worker_stopped'),
        );
      }
      for (final pending in _pending.values) {
        pending.completeError(const TransferException('worker_stopped'));
      }
      _pending.clear();
    }

    _port.listen((raw) {
      if (raw == null) {
        failed();
        if (!_exited.isCompleted) _exited.complete();
        return;
      }
      if (raw is List) {
        failed();
        return;
      }
      final msg = Map<String, dynamic>.from(raw as Map);
      switch (msg['type']) {
        case 'port':
          _worker = msg['port'] as SendPort;
        case 'availability':
          _nativeCreated =
              _nativeCreated ||
              msg['available'] == true ||
              msg['nativeStarted'] == true;
          if (msg['ready'] is Map) {
            ready = Map<String, dynamic>.from(msg['ready'] as Map);
          }
          if (!_availability.isCompleted) {
            _availability.complete(
              TransferAvailability(
                msg['available'] == true,
                msg['reason'] as String?,
              ),
            );
          }
        case 'reply':
          final pending = _pending.remove(msg['id']);
          if (msg['error'] != null) {
            pending?.completeError(
              TransferException(
                msg['error'] as String,
                operationId: msg['operationId'] as int?,
              ),
            );
          } else {
            pending?.complete(msg['result']);
          }
      }
    });
    try {
      await Directory(supportRoot).create(recursive: true);
      await Isolate.spawn(
        transferWorkerMain,
        <String, dynamic>{
          'owner': _port.sendPort,
          'libraryPath': libraryPath,
          'supportRoot': supportRoot,
          'config': {
            'root': '$supportRoot${Platform.pathSeparator}transfer',
            'bind': bind,
            'alias': alias,
            'pin': pin,
          },
        },
        onError: _port.sendPort,
        onExit: _port.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      failed();
      if (!_exited.isCompleted) _exited.complete();
    }
    return _availability.future;
  }

  Future<dynamic> _request(
    String method, [
    Map<String, dynamic> values = const {},
  ]) {
    if (_worker == null || (_closing && method != 'stop')) {
      throw const TransferException('closed');
    }
    if (_pending.length >= 40 && method != 'stop') {
      throw const TransferException('busy');
    }
    final id = ++_next;
    final result = Completer<dynamic>();
    _pending[id] = result;
    _worker!.send({'id': id, 'method': method, ...values});
    return result.future;
  }

  Future<dynamic> command(Map<String, dynamic> request) =>
      _request('command', {'request': request});
  Future<Map<String, dynamic>> drainEvents() async =>
      Map<String, dynamic>.from(await _request('events') as Map);
  Future<TransferInput> prepareInput(String receiptId) async {
    final result = Map<String, dynamic>.from(
      await _request('prepare', {'receiptId': receiptId}) as Map,
    );
    return TransferInput(
      receiptId: result['receiptId'] as String,
      path: result['path'] as String,
      outputDirectory: result['outputDirectory'] as String,
      name: result['name'] as String,
    );
  }

  Future<void> dispose() => _dispose ??= _close();
  Future<void> _close() async {
    _closing = true;
    try {
      if (_started) {
        await _availability.future;
        if (_nativeCreated && _worker != null) await _request('stop');
        await _exited.future;
      }
    } finally {
      _port.close();
    }
  }
}
