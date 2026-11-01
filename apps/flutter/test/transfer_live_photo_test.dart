import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/output_export_service.dart';
import 'package:xdremux/services/transfer/transfer_live_photo.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('live-zip-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('a zipped .pvt unpacks into the same bundle', () async {
    final pvt = Directory('${temp.path}/IMG_1.pvt')..createSync();
    File('${pvt.path}/IMG_1.heic').writeAsStringSync('still');
    File('${pvt.path}/IMG_1.mov').writeAsStringSync('movie');
    File('${pvt.path}/metadata.plist').writeAsStringSync('plist');
    final zip = await zipLivePhotoBundle(pvt.path);
    expect(isLivePhotoZip(zip), isTrue);
    final out = Directory('${temp.path}/out')..createSync();
    final parts = await extractLivePhotoZip(zip, out.path, 'IMG_1.pvt.zip');
    expect(parts.bundle, '${out.path}${Platform.pathSeparator}IMG_1.pvt');
    expect(File(parts.still).readAsStringSync(), 'still');
    expect(File(parts.movie).readAsStringSync(), 'movie');
    expect(File('${parts.bundle}/metadata.plist').existsSync(), isTrue);
    await expectLater(
      extractLivePhotoZip(zip, out.path, 'IMG_1.pvt.zip'),
      throwsA(
        isA<TransferException>().having(
          (e) => e.code,
          'code',
          'already_exists',
        ),
      ),
    );
  });

  for (final entry in [
    '../evil.heic',
    'IMG_1.pvt/../evil.mov',
    'other/x.mov',
  ]) {
    test('rejects an entry outside the bundle: $entry', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('IMG_1.pvt/IMG_1.heic', [1]))
        ..add(ArchiveFile.bytes('IMG_1.pvt/IMG_1.mov', [1]))
        ..add(ArchiveFile.bytes(entry, [1]));
      final zip = File('${temp.path}/IMG_1.pvt.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      await expectLater(
        extractLivePhotoZip(zip.path, temp.path, 'IMG_1.pvt.zip'),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'invalid_live_photo',
          ),
        ),
      );
      expect(Directory('${temp.path}/IMG_1.pvt').existsSync(), isFalse);
    });
  }
}
