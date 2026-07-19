import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xdremux/main.dart';

void main() {
  testWidgets('XdRemuxApp renders home page', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // App bar title is present
    expect(find.textContaining('XDRemux'), findsOneWidget);

    // Empty state shows "添加文件" button
    expect(find.widgetWithText(FilledButton, '添加文件'), findsOneWidget);

    // Progress bar shows "就绪"
    expect(find.text('就绪'), findsOneWidget);
  });

  testWidgets('AppBar shows OPPO compat toggle', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // OPPO compatibility toggle is in the AppBar actions
    expect(find.text('OPPO'), findsOneWidget);

    // Tap it — toggles from off (grey) to on (primary container).
    await tester.tap(find.text('OPPO'));
    await tester.pump();
  });

  testWidgets('Settings button opens bottom sheet', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // Tap the settings (tune) icon button
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // Settings sheet should show its title and the sections that now exist.
    expect(find.text('转换设置'), findsOneWidget);
    expect(find.text('输入 HDR 类型'), findsOneWidget);
    expect(find.text('高级'), findsOneWidget);
  });

  testWidgets('Add files button is visible and enabled', (WidgetTester tester) async {
    await tester.pumpWidget(const XdRemuxApp());

    // The empty-state button
    expect(find.widgetWithText(FilledButton, '添加文件'), findsOneWidget);

    // The AppBar add button
    expect(find.byIcon(Icons.add_photo_alternate), findsOneWidget);
  });
}
