import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'package:xdremux/main.dart';

void main() {
  setUpAll(() {
    // receive_sharing_intent's mobile implementation touches MethodChannels
    // unconditionally; stub it so widget tests run on the host without a
    // platform side.
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream.empty(),
    );
  });

  test('input path filter accepts HEIC/HEIF and rejects unrelated files', () {
    expect(isSupportedInputPath('photo.HEIC'), isTrue);
    expect(isSupportedInputPath('photo.heif'), isTrue);
    expect(isSupportedInputPath('photo.jpg'), isFalse);
    expect(isSupportedInputPath('photo.heic.jpg'), isFalse);
  });

  testWidgets('XdRemuxApp renders home page', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // App bar title is present
    expect(find.textContaining('XDRemux'), findsOneWidget);

    // Empty state shows "添加文件" button
    expect(find.widgetWithText(FilledButton, '添加文件'), findsOneWidget);

    // Progress bar shows "就绪"
    expect(find.text('就绪'), findsOneWidget);
  });

  testWidgets('AppBar no longer shows OPPO compat toggle', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // The OPPO compat toggle was removed from the AppBar; the options now
    // live collapsed behind the "高级模式" (advanced) header in settings.
    expect(find.text('OPPO'), findsNothing);
  });

  testWidgets('Settings button opens bottom sheet', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const XdRemuxApp());

    // Tap the settings (tune) icon button
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // Settings sheet should show its title and the sections that now exist.
    expect(find.text('转换设置'), findsOneWidget);
    expect(find.text('跳过已有有效输出'), findsOneWidget);
    // Advanced OPPO options are collapsed by default behind a warning header.
    expect(find.text('高级模式'), findsOneWidget);
    expect(find.text('不建议更改，可能影响相册兼容性'), findsOneWidget);
    // Auto/X6/X7 and OPPO compat live inside the collapsed advanced section,
    // so they are not visible until expanded.
    expect(find.text('输入 HDR 类型'), findsNothing);
    expect(find.text('OPPO 兼容模式'), findsNothing);

    // Expanding 高级模式 reveals them.
    await tester.tap(find.text('高级模式'));
    await tester.pumpAndSettle();
    expect(find.text('输入 HDR 类型'), findsOneWidget);
    expect(find.text('OPPO 兼容模式'), findsOneWidget);
  });

  testWidgets('Add files button is visible and enabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const XdRemuxApp());

    // The empty-state button
    expect(find.widgetWithText(FilledButton, '添加文件'), findsOneWidget);

    // The AppBar add button
    expect(find.byIcon(Icons.add_photo_alternate), findsOneWidget);
  });

  testWidgets('Mobile layout keeps primary actions in the bottom action bar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const XdRemuxApp());

    expect(find.text('开始转换'), findsOneWidget);
    expect(find.byIcon(Icons.add_photo_alternate), findsNothing);
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsWidgets);
    expect(find.byType(GridView), findsNothing);
  });
}
