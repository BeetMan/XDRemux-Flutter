import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/services/transfer/transfer_controller.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

class N extends TransferService {
  String phase = 'transferring';
  Completer<void>? gate;
  final events = <Map<String, dynamic>>[];
  @override
  Future<TransferAvailability> start({
    required String supportRoot,
    String? libraryPath,
    String bind = '127.0.0.1:0',
    String alias = 'XDRemux',
    String? pin,
  }) async {
    ready = {'core_instance_id': 't'};
    return const TransferAvailability(true);
  }

  @override
  Future<dynamic> command(Map<String, dynamic> c) async {
    switch (c['command']) {
      case 'snapshot':
        final snap = phase; // captured when the command is processed
        if (gate != null) await gate!.future;
        return {
          'transfers': [
            {'id': 'r1', 'phase': snap, 'direction': 'receive'},
          ],
          'next': null,
        };
      case 'transfer':
        return {
          'files': [
            {
              'id': 'f',
              'name': 'a.heic',
              'size': 3,
              'bytes': 1,
              'phase': phase == 'completed' ? 'committed' : 'transferring',
            },
          ],
          'next': null,
        };
      case 'receipts':
        return [];
      case 'decide':
        return null;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> drainEvents() async {
    final n = List.of(events);
    events.clear();
    return {'events': n, 'resync': false};
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a poll during an in-flight refresh still applies the newer state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final n = N();
      final c = TransferController(
        serviceFactory: () => n,
        supportDirectory: () async => Directory.systemTemp,
        observeLifecycle: false,
      );
      await c.ensureLocal();
      n.gate = Completer();
      final r = c.refresh(); // e.g. from decide()
      await Future<void>.delayed(Duration.zero);
      n.phase = 'completed';
      n.events.add({
        'kind': 'event',
        'event': {'kind': 'transfer_finished', 'transfer_id': 'r1'},
      });
      final p = c.poll();
      n.gate!.complete();
      await r;
      await p;
      n.gate = null;
      await c.poll(); // no further events
      expect(c.transfers['r1']!['phase'], 'completed');
      await c.stop();
    },
  );
}
