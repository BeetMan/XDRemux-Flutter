import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Rotating the unfolded Duo can put the 84pt strip on the left. The content
  // must still avoid it, whether or not the platform reports a vertical bar,
  // and a reported bar draws its actions inside that left strip.
  for (final edge in ['trailing', 'leading', 'unspecified']) {
    testWidgets('Duo strip on the left keeps content clear (edge $edge)', (
      tester,
    ) async {
      PlatformLayoutTraits.verticalBarEdge = edge;
      addTearDown(() => PlatformLayoutTraits.verticalBarEdge = 'unspecified');
      _setDuoView(tester, const Size(951, 669), left: 84, bottom: 21);

      await tester.pumpWidget(const XdRemuxApp());
      await tester.pumpAndSettle();

      final bar = tester.getRect(find.byType(LinearProgressIndicator).first);
      expect(bar.left, greaterThanOrEqualTo(84 - 0.5));
      if (edge != 'unspecified') {
        for (final tooltip in ['添加文件', '设置']) {
          final rect = tester.getRect(find.byTooltip(tooltip));
          expect(rect.left, greaterThanOrEqualTo(0), reason: tooltip);
          expect(rect.right, lessThanOrEqualTo(84 + 0.5), reason: tooltip);
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Without a bottom bar the floating actions are overlays on a body that runs
  // to the screen edge; they must stay above the home indicator.
  // The folded layout only drops its bottom bar once the queue reaches
  // kFloatingActionQueueThreshold, so that case queues files first.
  for (final (name, size, right, bottom, queued) in [
    ('folded, long queue', const Size(466, 678), 84.0, 34.0, 5),
    ('unfolded landscape', const Size(951, 669), 84.0, 21.0, 0),
  ]) {
    testWidgets('Duo floating actions stay above the home indicator ($name)', (
      tester,
    ) async {
      PlatformLayoutTraits.verticalBarEdge = 'trailing';
      addTearDown(() => PlatformLayoutTraits.verticalBarEdge = 'unspecified');
      _setDuoView(tester, size, right: right, bottom: bottom);

      await tester.pumpWidget(const XdRemuxApp());
      await tester.pumpAndSettle();
      if (queued > 0) {
        await _dropFiles(tester, [
          for (var i = 0; i < queued; i++) '/nonexistent/duo-$i.heic',
        ]);
        // The floating start action only exists once the bottom bar is gone.
        expect(find.byTooltip('开始转换'), findsOneWidget);
      }

      final fabs = find.byType(FloatingActionButton);
      expect(fabs, findsWidgets);
      for (var i = 0; i < fabs.evaluate().length; i++) {
        final rect = tester.getRect(fabs.at(i));
        expect(rect.bottom, lessThanOrEqualTo(size.height - bottom + 0.5));
        // Clear of the indicator, but not lifted by a second inset.
        expect(rect.bottom, greaterThan(size.height - bottom - 40));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Unfolded portrait has no bottom bar, so "Start conversion" floats even
  // over an empty queue; it must not look tappable while it is disabled.
  testWidgets('Disabled floating start action uses disabled colours', (
    tester,
  ) async {
    _setDuoView(tester, const Size(669, 951), bottom: 21);

    await tester.pumpWidget(const XdRemuxApp());
    await tester.pumpAndSettle();

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.onPressed, isNull);
    final scheme = Theme.of(
      tester.element(find.byType(FloatingActionButton)),
    ).colorScheme;
    expect(fab.backgroundColor, isNot(scheme.primary));
    expect(fab.foregroundColor, isNot(scheme.onPrimary));
    final rect = tester.getRect(find.byType(FloatingActionButton));
    expect(rect.bottom, lessThanOrEqualTo(951 - 21 + 0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

void _setDuoView(
  WidgetTester tester,
  Size logicalSize, {
  double left = 0,
  double right = 0,
  double bottom = 0,
}) {
  const ratio = 3.0;
  tester.view.physicalSize = logicalSize * ratio;
  tester.view.devicePixelRatio = ratio;
  final padding = FakeViewPadding(
    left: left * ratio,
    right: right * ratio,
    bottom: bottom * ratio,
  );
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
}

/// Queues files through the desktop drop channel, the same intake the host
/// window uses; the paths only need a supported extension.
Future<void> _dropFiles(WidgetTester tester, List<String> paths) async {
  final message = const StandardMethodCodec().encodeMethodCall(
    MethodCall('onFilesDropped', paths),
  );
  await tester.runAsync(() async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'xdremux/drop',
      message,
      (_) {},
    );
  });
  // Intake awaits file and FFI probes outside the fake clock.
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (find.byTooltip('开始转换').evaluate().isNotEmpty) break;
  }
  await tester.pumpAndSettle();
}
