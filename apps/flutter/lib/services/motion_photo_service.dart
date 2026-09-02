import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ffi/xdremux_ffi.dart';
import '../models/app_models.dart';

/// Thin async wrapper over the Rust Motion Photo FFI.
///
/// Detection is best-effort: malformed inputs and unsupported files resolve
/// to null (treated as ordinary photos) so a broken file never blocks the
/// main conversion flow.
class MotionPhotoService {
  MotionPhotoService._();

  /// Inspect [path] and return a summary when it is a Motion Photo.
  static Future<MotionPhotoSummary?> inspect(String path) async {
    try {
      final report = XdRemuxFFI.motionPhotoInspect(path);
      if (report['isMotionPhoto'] != true) return null;
      final stillStart = (report['stillStart'] as num?)?.toInt() ?? 0;
      final stillEnd = (report['stillEnd'] as num?)?.toInt() ?? 0;
      final videoStart = (report['videoStart'] as num?)?.toInt() ?? 0;
      final videoEnd = (report['videoEnd'] as num?)?.toInt() ?? 0;
      final meta = report['oppoMetadata'];
      final streams = meta is Map
          ? (meta['streamCount'] as num?)?.toInt() ?? 1
          : 1;
      return MotionPhotoSummary(
        kind: report['sourceKind'] as String? ?? 'unknown',
        stillBytes: stillEnd - stillStart,
        videoBytes: videoEnd - videoStart,
        streamCount: streams,
      );
    } catch (e) {
      debugPrint('[XDRemux][motion] inspect failed for $path: $e');
      return null;
    }
  }

  /// Export the video stream(s) of a Motion Photo next to [outputPath].
  ///
  /// Writes `<output stem>.motion.mp4` (full video range) and, for OPPO
  /// dual-stream files, `<output stem>.primary.mp4` (high-quality stream).
  /// Returns the written file names. Throws on failure; the caller decides
  /// whether to surface the error or degrade silently.
  static Future<List<String>> exportVideos(
    String inputPath,
    String outputPath,
  ) async {
    final temp = await getTemporaryDirectory();
    final splitDir = Directory(
      '${temp.path}${Platform.pathSeparator}motion_split_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      final report = XdRemuxFFI.motionPhotoSplit(inputPath, splitDir.path);
      if (report['success'] != true) {
        throw report['errorMessage'] ?? 'split failed';
      }
      final outFile = File(outputPath);
      final stem = outFile.uri.pathSegments.last.replaceAll(
        RegExp(r'\.[^.]+$'),
        '',
      );
      final written = <String>[];
      final candidates = <String, String>{
        'videoPath': '$stem.motion.mp4',
        'primaryVideoPath': '$stem.primary.mp4',
      };
      for (final entry in candidates.entries) {
        final src = report[entry.key] as String?;
        if (src == null || src.isEmpty) continue;
        final srcFile = File(src);
        if (!srcFile.existsSync()) continue;
        final destDir = outFile.parent.path;
        final desired = entry.value;
        // Collision avoidance: never overwrite a previously exported video.
        var target = '$destDir${Platform.pathSeparator}$desired';
        if (File(target).existsSync()) {
          final dot = desired.lastIndexOf('.');
          final s = dot > 0 ? desired.substring(0, dot) : desired;
          final ext = dot > 0 ? desired.substring(dot) : '';
          var i = 2;
          while (true) {
            target = '$destDir${Platform.pathSeparator}$s $i$ext';
            if (!File(target).existsSync()) break;
            i++;
          }
        }
        await srcFile.copy(target);
        written.add(target.split(Platform.pathSeparator).last);
      }
      return written;
    } finally {
      if (splitDir.existsSync()) {
        try {
          splitDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Extract the still image of a Motion Photo to a temporary file and
  /// return its path. Used by the Apple/OPPO workflow where the donor must
  /// be the still image (watermark graph, EXIF and ProXDR metadata all live
  /// in the still byte range).
  static Future<String> extractStillToTemp(String inputPath) async {
    final temp = await getTemporaryDirectory();
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}motion_still',
    );
    await dir.create(recursive: true);
    final report = XdRemuxFFI.motionPhotoSplit(inputPath, dir.path);
    if (report['success'] != true) {
      throw report['errorMessage'] ?? 'split failed';
    }
    final still = report['stillPath'] as String?;
    if (still == null || !File(still).existsSync()) {
      throw 'still extraction produced no file';
    }
    return still;
  }
}
