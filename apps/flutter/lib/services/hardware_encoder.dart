import 'dart:io';

import 'package:flutter/services.dart';

import '../ffi/xdremux_ffi.dart';

/// A gain-map tile to hardware-encode: packed I420 (Y, then U, then V) and its
/// grid position (row-major index).
class TileInput {
  final Uint8List yuv420;
  final int index;

  TileInput(this.yuv420, this.index);
}

/// GPU hardware HEVC encoding.
///
/// - Android: drives the native MediaCodec encoder for gain-map tiles. Each
///   tile is encoded to an Annex-B HEVC byte stream that Rust wraps into the
///   ISO 21496-1 container. Any failure returns null so the caller falls back
///   to the x265 software path.
/// - macOS/iOS: the Rust core encodes with VideoToolbox itself (built with
///   `XDREMUX_HEVC_BACKEND=videotoolbox+x265`); [selectCoreEncoder] picks
///   VideoToolbox or x265 for every conversion, Live Photo and writeback.
class HardwareEncodeService {
  HardwareEncodeService._();

  static const _channel = MethodChannel('xdremux/hw-encode');
  static const _tileSize = 512;
  static const _coreHardwareEncoder = 'videotoolbox';

  /// Whether the core picks the encoder (macOS/iOS) instead of the Android
  /// tile path.
  static bool get usesCoreEncoder => Platform.isMacOS || Platform.isIOS;

  /// Whether this device can hardware-encode. Android: a real 4:2:0 HEVC
  /// configure attempt. macOS/iOS: the core lists the VideoToolbox encoder.
  /// Cached after the first probe. Any error → false (software path).
  static Future<bool>? _availability;

  static Future<bool> isAvailable() {
    return _availability ??= _probe();
  }

  static Future<bool> _probe() async {
    if (usesCoreEncoder) return _coreEncoders().contains(_coreHardwareEncoder);
    try {
      return await _channel.invokeMethod<bool>('canEncode') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// `hevcEncoders` from the core's capability report, preferred first.
  /// Fixed for the life of the process, so read once.
  static List<String>? _encoders;

  static List<String> _coreEncoders() {
    return _encoders ??= () {
      try {
        final encoders = XdRemuxFFI.codecCapabilities()['hevcEncoders'];
        return encoders is List
            ? encoders.whereType<String>().toList()
            : const <String>[];
      } catch (_) {
        return const <String>[];
      }
    }();
  }

  /// macOS/iOS: set the core's process-wide HEVC encoder from the GPU switch.
  /// On: VideoToolbox. Off: the core's other encoder (x265), so output stays
  /// the same as before the switch existed. A core without both leaves its
  /// only encoder in place. No-op on other platforms.
  static void selectCoreEncoder({required bool hardware}) {
    if (!usesCoreEncoder) return;
    final encoders = _coreEncoders();
    if (encoders.length < 2) return;
    final name = hardware
        ? _coreHardwareEncoder
        : encoders.firstWhere(
            (e) => e != _coreHardwareEncoder,
            orElse: () => encoders.first,
          );
    XdRemuxFFI.setHevcEncoder(name);
  }

  /// Android: encode `tiles` (all `_tileSize`×`_tileSize` I420) to HEVC byte
  /// streams, preserving input order. Returns null if any tile fails to
  /// encode.
  static Future<List<Uint8List>?> encodeTiles(List<TileInput> tiles) async {
    if (tiles.isEmpty) return <Uint8List>[];
    final streams = <Uint8List>[];
    for (final tile in tiles) {
      final stream = await _channel.invokeMethod<Uint8List>(
        'encodeTile',
        {
          'yuv': tile.yuv420,
          'width': _tileSize,
          'height': _tileSize,
        },
      );
      if (stream == null || stream.isEmpty) {
        return null;
      }
      streams.add(stream);
    }
    return streams;
  }
}
