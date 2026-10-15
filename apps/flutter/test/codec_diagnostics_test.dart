import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/codec_diagnostics.dart';
import 'package:xdremux/widgets/codec_diagnostics_tile.dart';

void main() {
  test('known errors are hints, unknown errors are not guessed', () {
    for (final pair in <String, CodecErrorKind>{
      'Failed to load dynamic library (126)': CodecErrorKind.dependency,
      'No decoding plugin installed': CodecErrorKind.codec,
      'only 4:2:0; libheif fallback failed: invalid bitstream':
          CodecErrorKind.malformed,
      'only 4:2:0 (chroma_format_idc=1) supported': CodecErrorKind.chroma,
      'cannot expand Apple MakerNote': CodecErrorKind.styles,
      'Truncated HEIF': CodecErrorKind.malformed,
      'Permission denied (os error 5)': CodecErrorKind.io,
      'preview resource limit': CodecErrorKind.resource,
      'PQ/HLG HEIF needs HDR-aware decoding': CodecErrorKind.hdr,
      'cancelled': CodecErrorKind.cancelled,
      'unexpected status': CodecErrorKind.unknown,
    }.entries) {
      expect(CodecDiagnostics.classify(pair.key), pair.value);
      expect(CodecDiagnostics.hint(pair.value), isNotEmpty);
      expect(CodecDiagnostics.hint(pair.value, english: true), isNotEmpty);
    }
  });
  test('export strips private fields and raw exceptions', () {
    CodecDiagnostics.describe('invalid input at C:/private/secret.jpg GPS=123');
    final output = CodecDiagnostics.report({
      'coreVersion': '0.4.3',
      'path': 'secret.jpg',
      'exif': {'GPS': 123},
      'libheif': {
        'compiled': true,
        'runtimeVersion': '1.23.4',
        'path': 'private',
      },
    });
    expect(output, isNot(contains('secret')));
    expect(output, isNot(contains('C:/private')));
    final json = jsonDecode(output) as Map;
    expect(json['codec']['libheif']['compiled'], true);
    expect(json['failureCategories']['malformed'], greaterThan(0));
  });
  testWidgets('runtime facts and privacy report visible in settings tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodecDiagnosticsTile(
            probe: () async => {
              'coreVersion': '0.4.3',
              'libheif': {
                'compiled': true,
                'runtimeVersion': '1.23.4',
                'hevcDecoderAvailable': true,
              },
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('libheif 1.23.4'), findsOneWidget);
    await tester.tap(find.text('Codec 能力与诊断'));
    await tester.pumpAndSettle();
    expect(find.text('导出 JSON'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.textContaining('不含照片'), findsOneWidget);
  });
  testWidgets('missing probe remains diagnosable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodecDiagnosticsTile(
            english: true,
            probe: () async => {'probeAvailable': false},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Core capability probe unavailable'), findsOneWidget);
  });
}
