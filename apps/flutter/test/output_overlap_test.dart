import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/output_overlap.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('xdremux-overlap-'));
  tearDown(() => dir.delete(recursive: true));

  test('the same path is the input', () {
    final input = '${dir.path}/IMG_1.heic';
    File(input).writeAsStringSync('original');
    expect(outputWouldOverwriteInput(input, input), isTrue);
    expect(outputWouldOverwriteInput(input, '${dir.path}/./IMG_1.heic'), isTrue);
  });

  test('another file, or one that does not exist yet, is not', () {
    final input = '${dir.path}/IMG_1.HEIC';
    File(input).writeAsStringSync('original');
    File('${dir.path}/other.heic').writeAsStringSync('other');
    expect(outputWouldOverwriteInput(input, '${dir.path}/other.heic'), isFalse);
    expect(outputWouldOverwriteInput(input, '${dir.path}/IMG_1_iso.heic'), isFalse);
  });

  test('another letter case is the input on a case-insensitive volume', () {
    // An empty file-name suffix turns IMG_1.HEIC into IMG_1.heic.
    final input = '${dir.path}/IMG_1.HEIC';
    final output = '${dir.path}/IMG_1.heic';
    File(input).writeAsStringSync('original');
    final caseInsensitive = File(output).existsSync();
    expect(outputWouldOverwriteInput(input, output), caseInsensitive);
  });

  test(
    'an output folder that links to the source folder is the input',
    () {
      final source = Directory('${dir.path}/source')..createSync();
      final input = '${source.path}/IMG_1.heic';
      File(input).writeAsStringSync('original');
      Link('${dir.path}/out').createSync(source.path);
      expect(outputWouldOverwriteInput(input, '${dir.path}/out/IMG_1.heic'), isTrue);
    },
    skip: Platform.isWindows ? 'links need extra rights on Windows' : false,
  );
}
