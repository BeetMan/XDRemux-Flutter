import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/widgets/photo_feature_menu.dart';

import 'photo_feature_policy_test.dart' show photo;

void main() {
  testWidgets('standard HDR remains reachable without portrait detection', (
    tester,
  ) async {
    final item = photo()..portrait = null;
    PortraitMode? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoFeatureMenu(
            item: item,
            enabled: true,
            applePortraitAvailable: true,
            onStyleChanged: (_) {},
            onPortraitChanged: (mode) => selected = mode,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final apple = tester.widget<CheckedPopupMenuItem<Object>>(
      find.ancestor(
        of: find.text(PortraitMode.applePortrait.displayName),
        matching: find.byType(CheckedPopupMenuItem<Object>),
      ),
    );
    expect(apple.enabled, false);
    await tester.tap(
      find.ancestor(
        of: find.text(PortraitMode.standard.displayName),
        matching: find.byType(CheckedPopupMenuItem<Object>),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, PortraitMode.standard);
  });

  testWidgets(
    'explicit portrait is capability-gated and processing disables edits',
    (tester) async {
      final item = photo();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoFeatureMenu(
              item: item,
              enabled: true,
              applePortraitAvailable: false,
              onStyleChanged: (_) {},
              onPortraitChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      final apple = tester.widget<CheckedPopupMenuItem<Object>>(
        find.ancestor(
          of: find.text(PortraitMode.applePortrait.displayName),
          matching: find.byType(CheckedPopupMenuItem<Object>),
        ),
      );
      expect(apple.enabled, false);
      await tester.tap(
        find.ancestor(
          of: find.text(PortraitMode.inherit.displayName),
          matching: find.byType(CheckedPopupMenuItem<Object>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoFeatureMenu(
              item: item,
              enabled: false,
              applePortraitAvailable: true,
              onStyleChanged: (_) => fail('disabled'),
              onPortraitChanged: (_) => fail('disabled'),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.byType(CheckedPopupMenuItem<Object>), findsNothing);
    },
  );
}
