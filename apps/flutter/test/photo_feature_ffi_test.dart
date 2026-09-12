import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';
import 'package:xdremux/services/photo_feature_service.dart';

// Fixed 2x2 RGB JPEG with orientation=6 and capture datetime, not Ultra HDR.
const _baseJpegHex =
    'ffd8ffe000104a46494600010100000100010000ffe100424578696600004d4d002a00000008000201120003000000010006'
    '000001320002000000140000002600000000323032363a30393a31302031333a30313a303200ffdb00430008060607060508'
    '0707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30313434341f27393d'
    '38323c2e333432ffdb0043010909090c0b0c180d0d1832211c21323232323232323232323232323232323232323232323232'
    '3232323232323232323232323232323232323232323232323232ffc00011080002000203012200021101031101ffc4001f00'
    '00010501010101010100000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01'
    '020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a34'
    '35363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495'
    '969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9'
    'eaf1f2f3f4f5f6f7f8f9faffc4001f0100030101010101010101010000000000000102030405060708090a0bffc400b51100'
    '020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f0156272'
    'd10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475'
    '767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9ca'
    'd2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9faffda000c03010002110311003f00f11a28a2b6323fffd9';

// Run against a freshly rebuilt library, not the research-branch binary.
void main() {
  test(
    'additive JSON APIs preserve C layouts and handle malformed input repeatedly',
    () async {
      expect(ffi.sizeOf<ConvertConfig>(), 5);
      if (ffi.sizeOf<ffi.IntPtr>() == 8) {
        expect(ffi.sizeOf<ConversionResult>(), 48);
        expect(ffi.sizeOf<ClassificationResult>(), 72);
      }
      final dir = await Directory.systemTemp.createTemp('xdremux-feature-ffi-');
      try {
        final input = File('${dir.path}/bad.jpg');
        await input.writeAsString('x[{"name":}]');
        final output = File('${dir.path}/base.jpg');
        for (var i = 0; i < 32; i++) {
          expect(
            XdRemuxFFI.photographicStyleInspect(
              input.path,
            )['hasPhotographicStyle'],
            false,
          );
          expect(XdRemuxFFI.inspectPortrait(input.path)['hasPortrait'], false);
          expect(
            XdRemuxFFI.extractBasePhoto(input.path, output.path)['success'],
            false,
          );
        }
        expect(output.existsSync(), false);
        expect(
          XdRemuxFFI.photographicStyleInspect(
            '${dir.path}/missing',
          )['errorMessage'],
          isA<String>(),
        );
        expect(
          XdRemuxFFI.inspectPortrait('${dir.path}/missing')['errorMessage'],
          isA<String>(),
        );
        final service = PhotoFeatureService();
        final result = await service.inspect(input.path);
        await service.waitUntilIdle();
        expect(result.style, isNull);
        expect(result.portrait, isNull);
        await expectLater(
          PhotoFeatureService.extractBase(input.path, output.path),
          throwsStateError,
        );
        final jpeg = Uint8List.fromList([
          for (var i = 0; i < _baseJpegHex.length; i += 2)
            int.parse(_baseJpegHex.substring(i, i + 2), radix: 16),
        ]);
        final filter = Uint8List(28 + 'qing_tou.bin'.length + 1);
        ByteData.sublistView(filter).setFloat32(0, 1.0, Endian.little);
        filter.setRange(
          28,
          28 + 'qing_tou.bin'.length,
          ascii.encode('qing_tou.bin'),
        );
        final original = [
          ...jpeg,
          ...filter,
          ...utf8.encode(
            jsonEncode([
              {
                'name': 'src.image',
                'offset': jpeg.length + filter.length,
                'length': jpeg.length,
              },
              {
                'name': 'filter.info',
                'offset': filter.length,
                'length': filter.length,
              },
            ]),
          ),
        ];
        await input.writeAsBytes(original);
        expect(
          XdRemuxFFI.photographicStyleInspect(input.path)['styleNameEn'],
          'Fresh',
        );
        await PhotoFeatureService.extractBase(input.path, output.path);
        expect(await output.readAsBytes(), jpeg);
        await expectLater(
          PhotoFeatureService.extractBase(input.path, output.path),
          throwsStateError,
        );
        expect(await output.readAsBytes(), jpeg);
        // Raw JPEG export is valid, but is not falsely promised as convertible HDR.
        await expectLater(
          PhotoFeatureService.prepareBasePhoto(
            input.path,
            requireUltraHdr: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Ultra HDR'),
            ),
          ),
        );
        expect(await input.readAsBytes(), original);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
