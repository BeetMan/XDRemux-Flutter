import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/transfer/transfer_desktop_lifecycle.dart';

class _Channel extends MethodChannel {
  _Channel() : super('desktop-close-test');
  final calls = <String>[];
  Future<dynamic> Function(MethodCall)? handler;
  bool failApproval = false;
  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? callback) {
    handler = callback;
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    calls.add(method);
    if (method == 'approveClose' && failApproval) {
      throw PlatformException(code: 'fixture');
    }
    return null;
  }
}

void main() {
  test(
    'window and tray share pending cleanup; neither exits before it finishes',
    () async {
      final channel = _Channel(), gate = Completer<void>();
      var stops = 0, exits = 0;
      final owner = TransferDesktopLifecycle(
        channel: channel,
        stop: () async {
          stops++;
          await gate.future;
        },
        exitProcess: (_) => exits++,
      );
      await owner.register();
      final first = channel.handler!(const MethodCall('requestClose'));
      final duplicate = owner.closeWindow();
      final tray = owner.exitApplication();
      await Future<void>.delayed(Duration.zero);
      expect(stops, 1);
      expect(channel.calls, ['ready']);
      expect(exits, 0);
      gate.complete();
      await Future.wait([first, duplicate, tray]);
      expect(channel.calls, ['ready', 'approveClose']);
      expect(exits, 1);
      owner.dispose();
      expect(channel.handler, isNull);
    },
  );

  test(
    'cleanup failure preserves the window; an explicit retry runs cleanup again',
    () async {
      final channel = _Channel();
      var stops = 0;
      final owner = TransferDesktopLifecycle(
        channel: channel,
        stop: () async {
          if (++stops == 1) throw StateError('fixture cleanup failure');
        },
      );
      await owner.register();
      await expectLater(owner.closeWindow(), throwsStateError);
      expect(channel.calls, ['ready']);
      await owner.closeWindow();
      expect(stops, 2);
      expect(channel.calls, ['ready', 'approveClose']);
      owner.dispose();
    },
  );

  test(
    'approval delivery failure drains any new work on the next close attempt',
    () async {
      final channel = _Channel()..failApproval = true;
      var stops = 0;
      final owner = TransferDesktopLifecycle(
        channel: channel,
        stop: () async {
          stops++;
        },
      );
      await owner.register();
      await expectLater(owner.closeWindow(), throwsA(isA<PlatformException>()));
      channel.failApproval = false;
      await owner.closeWindow();
      expect(stops, 2);
      expect(channel.calls, ['ready', 'approveClose', 'approveClose']);
      owner.dispose();
    },
  );

  test(
    'tray cleanup failure does not exit; retry exits after cleanup',
    () async {
      var stops = 0, exits = 0;
      final owner = TransferDesktopLifecycle(
        channel: _Channel(),
        stop: () async {
          if (++stops == 1) throw StateError('fixture cleanup failure');
        },
        exitProcess: (_) => exits++,
      );
      await expectLater(owner.exitApplication(), throwsStateError);
      expect(exits, 0);
      await owner.exitApplication();
      expect(stops, 2);
      expect(exits, 1);
      owner.dispose();
    },
  );
}
