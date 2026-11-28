import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/l10n/l10n.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/models/oppo_tail_details.dart';

/// What Rust reports for IMG20260807145722.heic: a mirrored front-camera
/// portrait in a master-mode frame.
final frontPortrait = <String, dynamic>{
  'device': 'OPPO Find X8 Ultra',
  'entries': [
    {'name': 'src.image', 'length': 2223272},
    {'name': 'filter.info', 'length': 140},
    {'name': 'private.emptyspace', 'length': 4},
  ],
  'filter': {
    'colorTemperature': 6119.0,
    'enabled': true,
    'intensity': 100,
    'lut': 'fuji_cc.bin',
    'luxIndex': 289.6,
    'mirrored': true,
    'saturation': 1.0,
    'softLight': true,
    'sourceOrientation': 270,
    'version': 4.0,
  },
  'portrait': {
    'camera': 'front',
    'depthHeight': 616,
    'depthWidth': 820,
    'fNumber': 4.5,
    'faceCount': 1,
    'mirrored': true,
  },
  'sourceImage': {'height': 2464, 'width': 3280},
  'watermark': {
    'kind': 'frame',
    'margins': {'bottom': 1082, 'left': 136, 'right': 136, 'top': 1082},
    'picture': {'height': 6560, 'width': 4928, 'x': 136, 'y': 1082},
    'style': 'hassel_style_master_mode_1',
  },
};

Map<String, String> rowsOf(Map<String, dynamic> json) => {
  for (final row in OppoTailDetails.fromJson(json)!.rows())
    row.label: row.value,
};

void main() {
  tearDown(() => setUiLanguage(AppLanguage.chinese));

  group('OppoTailDetails', () {
    test('a framed front portrait lists every part it carries', () {
      expect(rowsOf(frontPortrait), {
        '水印机型': 'OPPO Find X8 Ultra',
        '水印': '烘焙边框',
        '水印样式': 'hassel_style_master_mode_1',
        '边框内画面': '4928 × 6560，边框 左 136 上 1082 右 136 下 1082',
        '滤镜': 'fuji_cc.bin，强度 100，柔光',
        '拍摄时的光线': '色温 6119，照度指数 289.6',
        '原图方向': '270°，成片左右镜像',
        '滤镜数据版本': '4.0',
        '人像景深': '前置 820 × 616，虚化光圈 f/4.5，1 张人脸，成片左右镜像',
        '未处理原图': '3280 × 2464',
        '尾部条目': '3 项，共 2.12 MB',
        '条目清单':
            'src.image (2.12 MB)\nfilter.info (140 B)\nprivate.emptyspace (4 B)',
      });
    });

    test('the same report reads in English', () {
      setUiLanguage(AppLanguage.english);
      final rows = rowsOf(frontPortrait);
      expect(rows['Watermark'], 'Baked-in frame');
      expect(rows['Watermark Style'], 'hassel_style_master_mode_1');
      expect(
        rows['Picture Inside Frame'],
        '4928 × 6560, frame L 136 T 1082 R 136 B 1082',
      );
      expect(rows['Filter'], 'fuji_cc.bin, intensity 100, soft light');
      expect(
        rows['Portrait Depth'],
        'Front camera 820 × 616, blur aperture f/4.5, 1 face, saved mirrored',
      );
      expect(rows['Tail Entries'], '3 entries, 2.12 MB');
    });

    test('a Find X10 shot without a watermark says so', () {
      final rows = rowsOf({
        'device': 'OPPO Find X10',
        'entries': [
          {'name': 'watermark.device', 'length': 80},
        ],
        'filter': {
          'captureMode': 'common',
          'enabled': true,
          'intensity': 100,
          'lut': 'portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin',
          'mirrored': false,
          'palette': true,
          'softLight': false,
          'sourceOrientation': 90,
          'tone': 0,
          'version': 5.1,
        },
        'watermark': {'kind': 'none'},
      });
      expect(rows['水印'], '无');
      expect(
        rows['滤镜'],
        'portra400_hdr_normal_a_1.bin,portra400_hdr_normal_d_1.bin，强度 100，调色盘',
      );
      expect(rows['相机记录的模式'], 'common');
      expect(rows['原图方向'], '90°');
      expect(rows['滤镜数据版本'], '5.1');
      expect(rows.containsKey('人像景深'), isFalse);
      expect(rows.containsKey('拍摄时的光线'), isFalse);
    });

    test('watermark kinds and a rear portrait', () {
      expect(
        rowsOf({
          'watermark': {'kind': 'png', 'width': 3688, 'height': 218},
        })['水印'],
        'PNG 叠加层 3688 × 218',
      );
      expect(
        rowsOf({
          'watermark': {'kind': 'unknown'},
        })['水印'],
        '有水印条目，类型未识别',
      );
      // A frame whose geometry Rust could not confirm has no picture line.
      final frame = rowsOf({
        'watermark': {'kind': 'frame', 'style': 'hassel_style_2'},
      });
      expect(frame['水印'], '烘焙边框');
      expect(frame['水印样式'], 'hassel_style_2');
      expect(frame.containsKey('边框内画面'), isFalse);
      expect(
        rowsOf({
          'portrait': {'camera': 'rear', 'fNumber': 9.0},
        })['人像景深'],
        '后摄，虚化光圈 f/9',
      );
      expect(
        rowsOf({
          'filter': {'enabled': false, 'version': 4.0},
        })['滤镜'],
        '未启用',
      );
    });

    test('missing or malformed parts are left out, not thrown on', () {
      expect(OppoTailDetails.fromJson(null), isNull);
      expect(OppoTailDetails.fromJson('oppo'), isNull);
      expect(OppoTailDetails.fromJson(<String, dynamic>{})!.rows(), isEmpty);
      final odd = OppoTailDetails.fromJson({
        'entries': 'none',
        'watermark': 7,
        'filter': [1, 2],
        'portrait': null,
        'sourceImage': {'width': 'wide'},
      })!;
      expect(odd.rows(), isEmpty);
      expect(odd.entries, isEmpty);
    });

    test('PhotoDetailsModel carries the object through fromJson', () {
      final details = PhotoDetailsModel.fromJson({
        'success': true,
        'oppo': frontPortrait,
      });
      expect(details.oppo!.device, 'OPPO Find X8 Ultra');
      expect(details.oppo!.entries.first, ('src.image', 2223272));
      expect(
        details.oppo!.toClipboardText(),
        contains('水印机型: OPPO Find X8 Ultra'),
      );
      expect(PhotoDetailsModel.fromJson({'success': true}).oppo, isNull);
    });
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('details sheet shows the OPPO section at $width wide', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoDetailsContent(
              item: QueueItem(
                id: 'oppo-section',
                inputPath: '/missing/photo.heic',
                outputPath: '/missing/photo_iso.heic',
              ),
              details: PhotoDetailsModel(
                success: true,
                oppo: OppoTailDetails.fromJson(frontPortrait),
              ),
              fileSizeMb: '11.1',
              isBottomSheet: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('OPPO 私有数据'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('OPPO 私有数据'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('条目清单'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('hassel_style_master_mode_1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('details sheet has no OPPO section for a file without a tail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoDetailsContent(
            item: QueueItem(
              id: 'plain',
              inputPath: '/missing/photo.heic',
              outputPath: '/missing/photo_iso.heic',
            ),
            details: const PhotoDetailsModel(success: true),
            fileSizeMb: '1.0',
            isBottomSheet: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OPPO 私有数据'), findsNothing);
  });
}
