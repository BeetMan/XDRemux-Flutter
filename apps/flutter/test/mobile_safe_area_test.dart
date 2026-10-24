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

  // iPhone Duo (iOS 27.1 simulator) reports 466x678pt with the safe area on the
  // right edge (84pt, a side-mounted status/camera strip). Apple's own apps keep
  // surfaces edge-to-edge and inset only the content, so the Scaffold must stay
  // 466pt wide while the header/actions stay out of the strip.
  testWidgets('Duo side inset keeps the app bar and progress header inside', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1398, 2034);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = FakeViewPadding(right: 252, bottom: 102);
    tester.view.viewPadding = FakeViewPadding(right: 252, bottom: 102);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XdRemuxApp());
    await tester.pumpAndSettle();

    const usableWidth = 466.0 - 84.0;
    // Surfaces stay edge-to-edge: only the content is inset.
    final scaffold = tester.getSize(find.byType(Scaffold).first);
    expect(scaffold.width, moreOrLessEquals(466.0, epsilon: 0.5));

    final bar = tester.getRect(find.byType(LinearProgressIndicator).first);
    expect(bar.right, greaterThan(0));
    expect(bar.right, lessThanOrEqualTo(usableWidth + 0.5));

    final iconButtons = find.byType(IconButton);
    expect(iconButtons, findsWidgets);
    final rightMost = tester.getRect(iconButtons.last);
    expect(rightMost.right, lessThanOrEqualTo(usableWidth + 0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // When the platform reports a trailing vertical bar (iOS 27
  // `UITraitCollection.verticalBarEdge`, which iPhone Duo reports as trailing),
  // the actions move into the reserved strip and the content keeps 382pt.
  testWidgets('Duo trailing vertical bar holds actions inside the strip', (
    tester,
  ) async {
    PlatformLayoutTraits.verticalBarEdge = 'trailing';
    addTearDown(() => PlatformLayoutTraits.verticalBarEdge = 'unspecified');
    tester.view.physicalSize = const Size(1398, 2034);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = FakeViewPadding(right: 252, bottom: 102);
    tester.view.viewPadding = FakeViewPadding(right: 252, bottom: 102);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XdRemuxApp());
    await tester.pumpAndSettle();

    const stripLeft = 466.0 - 84.0;
    for (final tooltip in ['添加文件', '设置']) {
      final finder = find.byTooltip(tooltip);
      expect(finder, findsOneWidget, reason: tooltip);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(stripLeft - 0.5), reason: tooltip);
      expect(rect.right, lessThanOrEqualTo(466.0 + 0.5), reason: tooltip);
    }

    // Content still stops before the strip.
    final bar = tester.getRect(find.byType(LinearProgressIndicator).first);
    expect(bar.right, lessThanOrEqualTo(stripLeft + 0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
