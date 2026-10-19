import 'dart:isolate';
import 'transfer_copy.dart';
import 'transfer_models.dart';
import 'transfer_service.dart';
import 'transfer_queue.dart';

/// P2.2 wires the page's explicit import action to this handoff. The queue owns
/// the independent checkpoint copy after ACK; native inbox retention is separate.
class TransferIntake {
  TransferIntake(this.service, [TransferQueueIntake? intake])
    : intake = intake ?? TransferQueue.enqueue;
  final TransferService service;
  final TransferQueueIntake intake;
  final _active = <String, Future<TransferIntakeAck>>{};

  Future<TransferIntakeAck> importReceipt(String id) {
    final active = _active[id];
    if (active != null) return active;
    TransferQueue.imports++;
    return _active[id] = TransferQueue.withInputAccess(() => _import(id))
        .whenComplete(() {
          _active.remove(id);
          TransferQueue.imports--;
        });
  }

  Future<TransferIntakeAck> _import(String id) async {
    try {
      final input = await service.prepareInput(id);
      final ack = await intake(input);
      // Never delete the copy after the queue may have accepted it, including a
      // failed persistence response. A retry uses the same path and asks intake again.
      if (ack.status == TransferIntakeStatus.added ||
          ack.status == TransferIntakeStatus.duplicate) {
        if (ack.queueId == null || ack.queueId!.isEmpty) {
          throw const TransferException('invalid_ack');
        }
        await Isolate.run(() => persistTransferAck(input.path, ack));
      }
      return ack;
    } on TransferException catch (e) {
      if (e.code == 'unsupported') {
        return const TransferIntakeAck(TransferIntakeStatus.unsupported);
      }
      rethrow;
    } catch (_) {
      throw const TransferException('io');
    }
  }
}
