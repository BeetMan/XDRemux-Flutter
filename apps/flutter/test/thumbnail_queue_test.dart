import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/xdremux_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('xdremux/thumbnail');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    XdRemuxService.clearThumbnailCache();
  });
  test('duplicate requests share native decode and cache', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return Uint8List.fromList([1, 2, 3]);
        });
    final out = await Future.wait([
      XdRemuxService.getThumbnail('same'),
      XdRemuxService.getThumbnail('same'),
    ]);
    expect(out.first, out.last);
    await XdRemuxService.getThumbnail('same');
    expect(calls, 1);
  });
  test('cache clear does not strand queued callers; size clamped', () async {
    final gates = <Completer<Uint8List>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          expect((call.arguments as Map)['maxPixelSize'], 2048);
          final gate = Completer<Uint8List>();
          gates.add(gate);
          return gate.future;
        });
    final jobs = List.generate(
      12,
      (i) => XdRemuxService.getThumbnail('queued-$i', maxPixelSize: 99999),
    );
    for (var i = 0; i < 100 && gates.length < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates.length, 8);
    XdRemuxService.clearThumbnailCache();
    for (var i = 0; i < 12; i++) {
      while (gates.length <= i) {
        await Future<void>.delayed(Duration.zero);
      }
      gates[i].complete(Uint8List.fromList([i]));
      await Future<void>.delayed(Duration.zero);
    }
    expect(await Future.wait(jobs), hasLength(12));
  });
}
