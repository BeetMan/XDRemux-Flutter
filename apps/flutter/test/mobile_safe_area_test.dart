import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/models/app_models.dart';

void main() {
  setUpAll(() {
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
  });

  for (final bottomInset in [0.0, 16.0, 24.0, 48.0]) {
    testWidgets('Home buttons retain inner spacing above $bottomInset inset', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(bottom: bottomInset);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const XdRemuxApp());
      await tester.pumpAndSettle();

      final button = find.widgetWithText(FilledButton, '开始转换');
      final rect = tester.getRect(button);
      expect(844 - rect.bottom, greaterThanOrEqualTo(bottomInset + 12));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    for (final width in [320.0, 390.0]) {
      testWidgets('Details footer avoids $bottomInset inset at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = FakeViewPadding(bottom: bottomInset);
        tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      useSafeArea: true,
                      isScrollControlled: true,
                      builder: (context) => ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 700),
                        child: PhotoDetailsContent(
                          item: QueueItem(
                            id: 'safe-area',
                            inputPath: '/missing/photo.heic',
                            outputPath: '/missing/photo_iso.heic',
                          ),
                          details: PhotoDetailsModel(success: true),
                          fileSizeMb: '1.0',
                          isBottomSheet: true,
                        ),
                      ),
                    ),
                    child: const Text('Open details'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open details'));
        await tester.pumpAndSettle();
        final close = find.widgetWithText(FilledButton, '关闭');
        final copy = find.widgetWithText(OutlinedButton, '复制全部信息');
        for (final button in [close, copy]) {
          final rect = tester.getRect(button);
          expect(844 - rect.bottom, greaterThanOrEqualTo(bottomInset + 10));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        expect(tester.takeException(), isNull);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(PhotoDetailsContent), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
