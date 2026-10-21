import 'dart:io' as io;
import 'package:flutter/services.dart';

/// Shared window/tray shutdown owner. Stop must finish before either exit path.
class TransferDesktopLifecycle {
  TransferDesktopLifecycle({
    required Future<void> Function() stop,
    MethodChannel channel = const MethodChannel('xdremux/transfer-lifecycle'),
    void Function(int) exitProcess = io.exit,
  }) : _stop = stop,
       _channel = channel,
       _exitProcess = exitProcess;

  final Future<void> Function() _stop;
  final MethodChannel _channel;
  final void Function(int) _exitProcess;
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

  Future<void> closeWindow() =>
      _windowClose ??= _closeWindow().whenComplete(() => _windowClose = null);
  Future<void> _closeWindow() async {
    await _stopOnce();
    await _channel.invokeMethod<void>('approveClose');
  }

  Future<void> exitApplication() =>
      _applicationExit ??= _exit().whenComplete(() => _applicationExit = null);
  Future<void> _exit() async {
    await _stopOnce();
    _exitProcess(0);
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
