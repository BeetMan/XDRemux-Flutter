import 'dart:io';

import 'package:flutter/services.dart';

/// A gain-map tile to hardware-encode: packed I420 (Y, then U, then V) and its
/// grid position (row-major index).
class TileInput {
  final Uint8List yuv420;
  final int index;

  TileInput(this.yuv420, this.index);
}

/// Drives the native MediaCodec HEVC encoder for gain-map tiles.
///
/// Each tile is encoded to an Annex-B HEVC byte stream that Rust wraps into
/// the ISO 21496-1 container. Any failure returns null so the caller falls
/// back to the x265 software path.
class HardwareEncodeService {
  HardwareEncodeService._();

  static const _channel = MethodChannel('xdremux/hw-encode');
  static const _tileSize = 512;

  /// Whether this device can actually encode 4:2:0 HEVC (a real configure
  /// attempt). Cached after the first probe. Any error → false (falls back to
  /// the software path). Must be called on Android only.
  static Future<bool>? _availability;

  static Future<bool> isAvailable() {
    return _availability ??= _probe();
  }

  static Future<bool> _probe() async {
    try {
      return await _channel.invokeMethod<bool>('canEncode') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Encode `tiles` (all `_tileSize`×`_tileSize` I420) to HEVC byte streams,
  /// preserving input order. Returns null if any tile fails to encode.
  static Future<List<Uint8List>?> encodeTiles(List<TileInput> tiles) async {
    if (tiles.isEmpty) return <Uint8List>[];
    // macOS VideoToolbox: reset the "first tile" flag so this batch's first
    // tile carries VPS/SPS/PPS for hvcC extraction. No-op on Android.
    if (Platform.isMacOS) {
      try {
        await _channel.invokeMethod<void>('reset');
      } catch (_) {}
    }
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
