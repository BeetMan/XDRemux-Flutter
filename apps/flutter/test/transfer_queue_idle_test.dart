import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/transfer/transfer_queue.dart';

void main() {
  test('whenIdle waits for every import and notifies listeners', () async {
    var notified = 0;
    void listener() => notified++;
    TransferQueue.addImportListener(listener);
    TransferQueue.imports++;
    TransferQueue.imports++;
    var idle = false;
    final waiting = TransferQueue.whenIdle().then((_) => idle = true);
    TransferQueue.imports--;
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    TransferQueue.imports--;
    await waiting;
    expect(idle, isTrue);
    expect(notified, 4);
    TransferQueue.removeImportListener(listener);
    await TransferQueue.whenIdle();
  });
}
