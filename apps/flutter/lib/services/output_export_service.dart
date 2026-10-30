import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../ffi/xdremux_ffi.dart';
import '../l10n/l10n.dart';
import '../models/app_models.dart';
import 'file_action_service.dart';

/// A Live Photo is an output bundle, never just the still at outputPath.
bool hasLivePhotoOutput(QueueItem item) =>
    item.motionPhoto != null &&
    item.motionPhotoMode == MotionPhotoMode.livePhotoPair &&
    !item.actionUsesInput;

String livePhotoMoviePath(String still) =>
    still.replaceFirst(RegExp(r'\.[^./\\]+$'), '.mov');

/// The `.pvt` Live Photo bundle directory holding [still], or null when the
/// pair sits loose in the output directory.
String? livePhotoBundleDir(String still) {
  final parent = File(still).parent.path;
  return parent.toLowerCase().endsWith('.pvt') ? parent : null;
}

/// The planned flat output path of a bundled still:
/// `<dir>/<stem>.pvt/<stem>.heic` -> `<dir>/<stem>.heic`.
String livePhotoFlatPath(String still) {
  final bundle = livePhotoBundleDir(still);
  if (bundle == null) return still;
  return '${File(bundle).parent.path}${still.substring(bundle.length)}';
}

/// Where a still planned at [flat] lands once bundled:
/// `<dir>/<stem>.heic` -> `<dir>/<stem>.pvt/<stem>.heic`.
String livePhotoBundledPath(String flat) {
  final cut = flat.lastIndexOf(RegExp(r'[/\\]')) + 1;
  final name = flat.substring(cut);
  final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final separator = cut > 0 ? flat[cut - 1] : Platform.pathSeparator;
  return '${flat.substring(0, cut)}$stem.pvt$separator$name';
}

/// Zips a `.pvt` bundle into one shareable file and returns its path.
typedef LivePhotoBundleArchiver = Future<String> Function(String bundleDir);

/// Zip of [bundleDir] at deflate level 0 (HEIC/MOV are already compressed;
/// archive 4.x still labels such entries Deflate) in a fresh temp directory.
/// Entries keep the `<name>.pvt/` prefix, so unzipping on a Mac yields the
/// bundle that Photos imports as one Live Photo.
Future<String> zipLivePhotoBundle(String bundleDir) async {
  final name = Directory(
    bundleDir,
  ).uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  final out = await Directory.systemTemp.createTemp('xdremux-pvt-share-');
  final zipPath = '${out.path}${Platform.pathSeparator}$name.zip';
  await Isolate.run(() async {
    final encoder = ZipFileEncoder()
      ..create(zipPath, level: ZipFileEncoder.store);
    await encoder.addDirectory(
      Directory(bundleDir),
      filter: (entity, _) =>
          entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty).startsWith('.')
          ? ZipFileOperation.skip
          : ZipFileOperation.include,
    );
    await encoder.close();
  });
  return zipPath;
}

enum GalleryExportKind { image, independentPair, livePhoto }

class GalleryExportResult {
  final GalleryExportKind kind;
  final int savedResources;
  final int expectedResources;
  final String? errorMessage;
  const GalleryExportResult(
    this.kind,
    this.savedResources,
    this.expectedResources, [
    this.errorMessage,
  ]);
  bool get success =>
      savedResources == expectedResources && errorMessage == null;
  bool get partial => savedResources > 0 && !success;

  String get message {
    if (!success) {
      final prefix = partial
          ? t(
              '仅保存了部分文件，实况未完整保存。',
              'Only some files were saved; the Live Photo export is incomplete.',
            )
          : t('保存失败。', 'Save failed.');
      return '$prefix ${errorMessage ?? ""}';
    }
    return switch (kind) {
      GalleryExportKind.image => t('已保存到相册', 'Saved to gallery'),
      GalleryExportKind.livePhoto => t(
        '已保存为 Live Photo',
        'Saved as a Live Photo',
      ),
      GalleryExportKind.independentPair => t(
        'HEIF + MOV 已保存为两个独立文件；Android 相册不会因此显示为 Apple Live Photo。传输时请一同发送原文件。',
        'HEIF + MOV saved as two separate files, not an Android Live Photo. Transfer both originals together.',
      ),
    };
  }
}

/// Small injectable platform boundary; production uses the same destination
/// for single-item, automatic and manual batch saves.
abstract interface class OutputExportDestination {
  String get operatingSystem;
  Future<bool> galleryPermission();
  Future<void> saveImage(String path, String? album);
  Future<void> saveVideo(String path, String? album);
  Future<void> saveLivePhoto(String still, String movie);
  Future<void> share(List<String> paths, {required bool originals});
}

class NativeOutputExportDestination implements OutputExportDestination {
  const NativeOutputExportDestination();
  static const _livePhotoChannel = MethodChannel('xdremux/live-photo');
  @override
  String get operatingSystem => Platform.operatingSystem;
  @override
  Future<bool> galleryPermission() async =>
      await FileActionService.hasGalleryPermission() ||
      await FileActionService.requestGalleryPermission();
  @override
  Future<void> saveImage(String path, String? album) =>
      Gal.putImage(path, album: album ?? 'XDRemux');
  @override
  Future<void> saveVideo(String path, String? album) =>
      Gal.putVideo(path, album: album ?? 'XDRemux');
  @override
  Future<void> saveLivePhoto(String still, String movie) async {
    final ok = await _livePhotoChannel.invokeMethod<bool>('saveLivePhoto', {
      'stillPath': still,
      'videoPath': movie,
    });
    if (ok != true) {
      throw StateError(
        t(
          '系统未确认 Live Photo 保存成功',
          'Photos did not confirm the Live Photo save',
        ),
      );
    }
  }

  @override
  Future<void> share(List<String> paths, {required bool originals}) =>
      FileActionService.shareFiles(paths, asOriginalFiles: originals);
}

typedef LivePhotoValidator = Future<bool> Function(String still, String movie);

class GalleryExportBatchResult {
  final List<GalleryExportResult> results;
  GalleryExportBatchResult(List<GalleryExportResult> results)
    : results = List.unmodifiable(results);
  int get saved => results.where((r) => r.success).length;
  int get failed => results.length - saved;
  int get partial => results.where((r) => r.partial).length;
  String get message {
    final summary = t(
      '$saved 项完整保存，$failed 项未完整保存',
      '$saved items fully saved, $failed incomplete',
    );
    final detail = partial > 0
        ? t('（其中 $partial 项仅保存部分文件）', ' ($partial partially saved)')
        : '';
    final separate =
        results.any((r) => r.kind == GalleryExportKind.independentPair)
        ? t(
            '；配对项在 Android 相册中是 HEIF + MOV 两个独立文件。',
            '; Android pairs are separate HEIF + MOV files.',
          )
        : '';
    final firstError = results
        .where((r) => !r.success)
        .firstOrNull
        ?.errorMessage;
    return '$summary$detail$separate${firstError == null ? "" : "\n$firstError"}';
  }
}

class OutputExportService {
  final OutputExportDestination destination;
  final LivePhotoValidator _validatePair;
  final LivePhotoBundleArchiver _archiveBundle;
  OutputExportService({
    this.destination = const NativeOutputExportDestination(),
    LivePhotoValidator? validatePair,
    LivePhotoBundleArchiver? archiveBundle,
  }) : _validatePair = validatePair ?? _nativeValidate,
       _archiveBundle = archiveBundle ?? zipLivePhotoBundle;

  static Future<bool> _nativeValidate(String still, String movie) =>
      Isolate.run(() => XdRemuxFFI.livePhotoPairValid(still, movie));

  Future<List<String>> filesFor(QueueItem item) async {
    if (!item.isSuccessful) {
      throw StateError(
        t('此项尚未成功转换', 'This item has not converted successfully'),
      );
    }
    final still = item.actionUsesInput ? item.inputPath : item.outputPath;
    final paired = hasLivePhotoOutput(item);
    final paths = [still, if (paired) livePhotoMoviePath(still)];
    // Validate the complete bundle before any gallery write or share action.
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        throw StateError(
          t(
            '输出文件缺失或为空：$path；请重新转换。',
            'Missing or empty output: $path; convert again.',
          ),
        );
      }
    }
    final bundle = paired ? livePhotoBundleDir(still) : null;
    if (bundle != null && !await File('$bundle/metadata.plist').exists()) {
      throw StateError(
        t(
          '.pvt 包缺少 metadata.plist，请重新转换。',
          'The .pvt bundle lacks metadata.plist; convert again.',
        ),
      );
    }
    if (paired && !await _validatePair(paths[0], paths[1])) {
      throw StateError(
        t(
          'HEIF 与 MOV 配对校验失败，请重新转换；不会只导出静图。',
          'HEIF/MOV pair verification failed; convert again. No still-only fallback.',
        ),
      );
    }
    return paths;
  }

  Future<GalleryExportResult> save(QueueItem item, {String? album}) async {
    final paired = hasLivePhotoOutput(item);
    final iosPair = paired && destination.operatingSystem == 'ios';
    final kind = iosPair
        ? GalleryExportKind.livePhoto
        : paired
        ? GalleryExportKind.independentPair
        : GalleryExportKind.image;
    final expected = paired ? 2 : 1;
    var saved = 0;
    try {
      final paths = await filesFor(item);
      if (iosPair) {
        // PhotoKit requests add-only permission itself and writes both
        // resources in one transaction. Never call Gal.putImage afterwards.
        await destination.saveLivePhoto(paths[0], paths[1]);
        saved = 2;
      } else {
        if (!['android', 'ios'].contains(destination.operatingSystem)) {
          throw UnsupportedError(
            t(
              '此平台请使用文件分享导出原件',
              'Use file sharing to export originals on this platform',
            ),
          );
        }
        if (!await destination.galleryPermission()) {
          throw StateError(t('未获得相册写入权限', 'Gallery write permission denied'));
        }
        await destination.saveImage(paths[0], album);
        saved = 1;
        if (paired) {
          await destination.saveVideo(paths[1], album);
          saved = 2;
        }
      }
      return GalleryExportResult(kind, saved, expected);
    } catch (e) {
      // Android MediaStore has no cross-image/video transaction in gal. Keep
      // any saved original and report partial failure; never delete user media.
      return GalleryExportResult(kind, saved, expected, e.toString());
    }
  }

  Future<void> share(QueueItem item) async {
    final paths = await filesFor(item);
    final bundle = hasLivePhotoOutput(item)
        ? livePhotoBundleDir(paths.first)
        : null;
    if (bundle != null) {
      // A directory cannot go through a share sheet; send the bundle as one
      // zip so the HEIF + MOV pair stays together on every platform.
      await destination.share([await _archiveBundle(bundle)], originals: true);
      return;
    }
    // Do not swallow missing MOV / platform / presentation errors, and do not
    // call a displayed share sheet a completed transfer.
    await destination.share(paths, originals: hasLivePhotoOutput(item));
  }

  Future<GalleryExportBatchResult> saveBatch(
    Iterable<QueueItem> items, {
    String? Function(QueueItem)? albumFor,
  }) async {
    final results = <GalleryExportResult>[];
    for (final item in items.toList()) {
      results.add(await save(item, album: albumFor?.call(item)));
    }
    return GalleryExportBatchResult(results);
  }
}
