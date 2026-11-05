import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'transfer_models.dart';

/// LocalSend moves files, not folders, so a `.pvt` Live Photo travels as
/// `<stem>.pvt.zip` (see zipLivePhotoBundle) and is unpacked on receipt.
bool isLivePhotoZip(String name) => name.toLowerCase().endsWith('.pvt.zip');

class LivePhotoParts {
  const LivePhotoParts(this.bundle, this.still, this.movie);
  final String bundle;
  final String still;
  final String movie;
}

/// Unpacks a received [name] (`<stem>.pvt.zip`, read from [zipPath]) into
/// `[directory]/<stem>.pvt`. Only flat entries under that one folder are
/// accepted, and the bundle must hold exactly one still and one MOV.
Future<LivePhotoParts> extractLivePhotoZip(
  String zipPath,
  String directory,
  String name,
) async {
  final bundleName = name.substring(0, name.length - '.zip'.length);
  final bundle = '$directory${Platform.pathSeparator}$bundleName';
  if (FileSystemEntity.typeSync(bundle) != FileSystemEntityType.notFound) {
    throw const TransferException('already_exists');
  }
  final names = await Isolate.run(() {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final files = <ArchiveFile>[];
      for (final entry in archive) {
        final parts = entry.name.split('/');
        if (!entry.isFile) {
          if (parts.where((p) => p.isNotEmpty).join('/') != bundleName) {
            throw const TransferException('invalid_live_photo');
          }
          continue;
        }
        if (parts.length != 2 ||
            parts[0] != bundleName ||
            parts[1].isEmpty ||
            parts[1].startsWith('.') ||
            parts[1].contains('\\')) {
          throw const TransferException('invalid_live_photo');
        }
        files.add(entry);
      }
      Directory(bundle).createSync();
      final written = <String>[];
      try {
        for (final entry in files) {
          final out = OutputFileStream(
            '$bundle${Platform.pathSeparator}${entry.name.split('/')[1]}',
          );
          entry.writeContent(out);
          out.closeSync();
          written.add(entry.name.split('/')[1]);
        }
      } catch (_) {
        Directory(bundle).deleteSync(recursive: true);
        rethrow;
      }
      return written;
    } finally {
      input.closeSync();
    }
  });
  String? pick(List<String> extensions) {
    final hits = [
      for (final n in names)
        if (extensions.any((e) => n.toLowerCase().endsWith(e))) n,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  final still = pick(['.heic', '.heif', '.jpg', '.jpeg']);
  final movie = pick(['.mov']);
  if (still == null || movie == null) {
    await Directory(bundle).delete(recursive: true);
    throw const TransferException('invalid_live_photo');
  }
  final sep = Platform.pathSeparator;
  return LivePhotoParts(bundle, '$bundle$sep$still', '$bundle$sep$movie');
}

/// Writes only the still of a received `.pvt.zip` into [directory], for a
/// preview, and returns its path.
Future<String> extractLivePhotoStill(String zipPath, String directory) =>
    Isolate.run(() {
      final input = InputFileStream(zipPath);
      try {
        final stills = [
          for (final entry in ZipDecoder().decodeStream(input))
            if (entry.isFile &&
                RegExp(
                  r'^[^/]+\.pvt/[^/.][^/]*\.(heic|heif|jpe?g)$',
                  caseSensitive: false,
                ).hasMatch(entry.name))
              entry,
        ];
        if (stills.length != 1) {
          throw const TransferException('invalid_live_photo');
        }
        final path =
            '$directory${Platform.pathSeparator}${stills.single.name.split('/').last}';
        final out = OutputFileStream(path);
        stills.single.writeContent(out);
        out.closeSync();
        return path;
      } finally {
        input.closeSync();
      }
    });
