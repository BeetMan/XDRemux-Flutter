import 'dart:io';

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

  testWidgets('AppBar no longer shows OPPO compat toggle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const XdRemuxApp());

    // The OPPO compat toggle was moved into the advanced settings section.
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
    expect(find.text('输出模式'), findsOneWidget);
    expect(find.text('Apple 标准'), findsOneWidget);
    expect(find.text('跳过已有有效输出'), findsOneWidget);
    expect(
      find.text('转换引擎（怎么生成文件）'),
      (Platform.isMacOS || Platform.isIOS) ? findsOneWidget : findsNothing,
    );
    expect(find.text('兼容性高级设置'), findsOneWidget);
    expect(find.text('一般保持默认；只在排查相册兼容性时修改'), findsOneWidget);
    expect(find.text('输入照片类型'), findsNothing);
    expect(find.text('OPPO 兼容模式'), findsNothing);

    await tester.ensureVisible(find.text('兼容性高级设置'));
    await tester.tap(find.text('兼容性高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('输入照片类型'), findsOneWidget);
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

  testWidgets('Apple/OPPO workflow has a separate Apple-platform entry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const XdRemuxApp());

    expect(
      find.byIcon(Icons.auto_awesome_motion_outlined),
      (Platform.isMacOS || Platform.isIOS) ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('Apple Portrait lab has a separate macOS-only entry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const XdRemuxApp());

    expect(
      find.byIcon(Icons.camera_alt_outlined),
      Platform.isMacOS ? findsOneWidget : findsNothing,
    );
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
