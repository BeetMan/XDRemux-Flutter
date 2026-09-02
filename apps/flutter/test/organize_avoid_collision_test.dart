import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xdremux/organize_page.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('organize_avoid_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('free destination is used as-is without sequence suffix', () {
    final out = organizeAvoidCollision(tempDir.path, 'IMG_1', '.heic', {});
    expect(out, '${tempDir.path}/IMG_1.heic');
  });

  test('existing file forces a (2) suffix', () {
    File('${tempDir.path}/IMG_1.heic').writeAsBytesSync([1]);
    final out = organizeAvoidCollision(tempDir.path, 'IMG_1', '.heic', {});
    expect(out, '${tempDir.path}/IMG_1 (2).heic');
  });

  test('existing keepPath does not count as a collision (in-place organize)', () {
    final src = File('${tempDir.path}/IMG_1.heic')..writeAsBytesSync([1]);
    final out = organizeAvoidCollision(
      tempDir.path,
      'IMG_1',
      '.heic',
      {},
      keepPath: src.path,
    );
    expect(out, src.path);
  });

  test('reserved names force a suffix even when files do not exist yet', () {
    final first = organizeAvoidCollision(tempDir.path, 'IMG_1', '.heic', {});
    final reserved = {first.toLowerCase()};
    final second = organizeAvoidCollision(
      tempDir.path,
      'IMG_1',
      '.heic',
      reserved,
    );
    expect(second, '${tempDir.path}/IMG_1 (2).heic');
  });

  test('MOV destination avoids collision with a different source MOV', () {
    // Destination stem + .mov already taken by an unrelated file.
    File('${tempDir.path}/IMG_1.mov').writeAsBytesSync([1]);
    final other = File('${tempDir.path}/elsewhere.mov')..writeAsBytesSync([2]);
    final out = organizeAvoidCollision(
      tempDir.path,
      'IMG_1',
      '.mov',
      {},
      keepPath: other.path,
    );
    expect(out, '${tempDir.path}/IMG_1 (2).mov');
  });

  test('MOV destination reuses the source path when organizing in place', () {
    final mov = File('${tempDir.path}/IMG_1.mov')..writeAsBytesSync([1]);
    final out = organizeAvoidCollision(
      tempDir.path,
      'IMG_1',
      '.mov',
      {},
      keepPath: mov.path,
    );
    expect(out, mov.path);
  });
}
