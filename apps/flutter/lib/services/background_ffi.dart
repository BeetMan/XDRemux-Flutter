import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Runs a synchronous Rust FFI call on a short-lived background isolate.
///
/// The import probes (verify, classify, Huawei inspect, Motion Photo inspect)
/// each read the whole photo and parse it: ~120 ms per 10 MB OPPO HEIC on an
/// M-series Mac, several times that on a phone. On the root isolate that
/// freezes the UI — and with Flutter's merged UI/platform thread on Android,
/// the Android main thread too — for seconds when 20–30 photos are picked.
///
/// Conversion has long run FFI in `Isolate.run` on every platform, but
/// release builds once failed to open the Rust library from a spawned isolate
/// (8797fad moved classification back to the root isolate for that). Keep an
/// escape hatch: when a call fails in the background but succeeds on the root
/// isolate, later calls stay on the root isolate instead of failing imports.
class BackgroundFfi {
  BackgroundFfi._();

  static bool _rootIsolateOnly = false;

  /// True once a spawned isolate failed where the root isolate succeeded.
  static bool get rootIsolateOnly => _rootIsolateOnly;

  /// Run [call] off the UI isolate. [call] must only capture sendable values
  /// (strings, numbers, booleans) and return a sendable result.
  static Future<T> run<T>(T Function() call, {required String label}) async {
    if (_rootIsolateOnly) return call();
    try {
      return await Isolate.run(call, debugName: 'xdremux-$label');
    } catch (error) {
      debugPrint(
        '[XDRemux][ffi] $label failed on a background isolate ($error); '
        'retrying on the root isolate',
      );
      // Rethrows when the call itself fails; only an isolate-specific failure
      // switches later calls to the root isolate.
      final result = call();
      _rootIsolateOnly = true;
      return result;
    }
  }

  @visibleForTesting
  static void resetForTesting() => _rootIsolateOnly = false;
}
