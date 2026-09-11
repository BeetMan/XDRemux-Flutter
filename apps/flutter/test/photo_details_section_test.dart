import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/widgets/photo_details_section.dart';

void main() {
  for (final title in [
    '拍摄参数 (EXIF)',
    'Shooting Parameters (EXIF)',
    '实况照片 (Live / Motion Photo)',
    'HDR & Dynamic Range',
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$title fits a narrow detail sheet at ${scale}x', (
        tester,
      ) async {
        // 320px viewport minus the detail sheet's 20px horizontal padding.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Center(
                  child: SizedBox(
                    width: 280,
                    child: PhotoDetailsSection(
                      icon: Icons.info_outline,
                      title: title,
                      children: const [Text('Detail value')],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text(title), findsOneWidget);
        expect(find.text('Detail value'), findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsOneWidget);
        final heading = tester.widget<Text>(find.text(title));
        expect(heading.maxLines, isNull);
        expect(heading.overflow, isNot(TextOverflow.ellipsis));
      });
    }
  }
}
