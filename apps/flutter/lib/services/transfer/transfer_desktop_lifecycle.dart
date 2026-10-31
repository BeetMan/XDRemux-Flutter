import 'dart:io' as io;
import 'package:flutter/services.dart';

/// Shared window/tray shutdown owner. Stop must finish before either exit path.
class TransferDesktopLifecycle {
  TransferDesktopLifecycle({
    required Future<void> Function() stop,
    MethodChannel channel = const MethodChannel('xdremux/transfer-lifecycle'),
    void Function(int) exitProcess = io.exit,
    Duration stopTimeout = const Duration(seconds: 10),
  }) : _stop = stop,
       _channel = channel,
       _exitProcess = exitProcess,
       _stopTimeout = stopTimeout;

  final Future<void> Function() _stop;
  final MethodChannel _channel;
  final void Function(int) _exitProcess;
  final Duration _stopTimeout;
  Future<void>? _shutdown, _windowClose, _applicationExit;

  Future<void> register() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'requestClose') throw MissingPluginException();
      await closeWindow();
    });
    await _channel.invokeMethod<void>('ready');
  }

  Future<void> _stopOnce() {
    // Share pending cleanup, not its result: if approval fails and the user opens
    // a new receiver, the next close must stop that receiver as well.
    return _shutdown ??= Future<void>.sync(
      _stop,
    ).whenComplete(() => _shutdown = null);
  }

  // A failed stop keeps the window open so the user can retry, but a stop that
  // never settles (wedged worker or native shutdown) must not disable the
  // close button and tray exit for good. Process exit ends any native work;
  // the next start recovers its staging directories.
  Future<void> _stopBounded() =>
      _stopOnce().timeout(_stopTimeout, onTimeout: () {});

  Future<void> closeWindow() =>
      _windowClose ??= _closeWindow().whenComplete(() => _windowClose = null);
  Future<void> _closeWindow() async {
    await _stopBounded();
    await _channel.invokeMethod<void>('approveClose');
  }

  Future<void> exitApplication() =>
      _applicationExit ??= _exit().whenComplete(() => _applicationExit = null);
  Future<void> _exit() async {
    await _stopBounded();
    _exitProcess(0);
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
