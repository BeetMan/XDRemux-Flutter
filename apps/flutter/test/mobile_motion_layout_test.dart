import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/l10n/l10n.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/models/app_models.dart';

void main() {
  for (final language in AppLanguage.values) {
    for (final width in [320.0, 360.0, 384.0, 600.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final mode in MotionPhotoMode.values) {
          testWidgets(
            '${language.name} motion card $width px ${scale}x ${mode.name}',
            (tester) async {
              setUiLanguage(language);
              addTearDown(() => setUiLanguage(AppLanguage.chinese));
              tester.view.physicalSize = Size(width, 1600);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final item = QueueItem(
                id: 'motion-layout',
                inputPath: '/missing/IMG20261014221712345.jpg',
                outputPath: '/missing/IMG20261014221712345.heic',
                hdrKind: 'uhdr',
                motionPhotoMode: mode,
                motionPhoto: const MotionPhotoSummary(
                  kind: 'oppoLivePhoto',
                  stillBytes: 100,
                  videoBytes: 100,
                  streamCount: 2,
                  videoWidth: 1728,
                  videoHeight: 1296,
                ),
              );
              MotionPhotoMode? selected;
              await tester.pumpWidget(
                MaterialApp(
                  home: Scaffold(
                    body: MediaQuery(
                      data: MediaQueryData(
                        size: Size(width, 1600),
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: StatefulBuilder(
                        builder: (context, setState) => ListView(
                          // Keep the anchor away from screen edges so popup
                          // repositioning cannot be hidden by viewport clamping.
                          padding: const EdgeInsets.fromLTRB(12, 400, 12, 12),
                          children: [
                            MobileQueueCard(
                              item: item,
                              isSelected: true,
                              onTap: () {},
                              onRetry: () {},
                              onRemove: () {},
                              onMotionModeChanged: (value) => setState(() {
                                selected = value;
                                if (value != null) item.motionPhotoMode = value;
                              }),
                            ),
                            const SizedBox(
                              key: ValueKey('following-item'),
                              height: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
              expect(find.textContaining('1728'), findsOneWidget);
              final menu = find.byWidgetPredicate(
                (widget) => widget is PopupMenuButton<MotionPhotoMode>,
              );
              final cardRect = tester.getRect(find.byType(MobileQueueCard));
              final menuRect = tester.getRect(menu);
              final nextRect = tester.getRect(
                find.byKey(const ValueKey('following-item')),
              );
              final resolutionRect = tester.getRect(
                find.textContaining('1728'),
              );
              Rect? popupRect;
              // Actually rebuild after each choice, not just check the callback.
              // A valid, non-overflowing layout can still move the entire queue.
              for (final next in [...MotionPhotoMode.values, mode]) {
                await tester.ensureVisible(menu);
                await tester.tap(menu);
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
                final firstOption = find
                    .byWidgetPredicate(
                      (widget) => widget is PopupMenuItem<MotionPhotoMode>,
                    )
                    .first;
                popupRect ??= tester.getRect(firstOption);
                expect(
                  tester.getRect(firstOption),
                  popupRect,
                  reason:
                      'Popup must open at the same position for every selection',
                );
                await tester.tap(find.text(next.displayName).last);
                await tester.pumpAndSettle();
                expect(selected, next);
                expect(item.motionPhotoMode, next);
                expect(tester.takeException(), isNull);
                expect(
                  tester.getRect(find.byType(MobileQueueCard)),
                  cardRect,
                  reason: 'Card must not resize when choosing ${next.name}',
                );
                expect(
                  tester.getRect(menu),
                  menuRect,
                  reason: 'Mode button must not resize or move',
                );
                expect(
                  tester.getRect(find.textContaining('1728')),
                  resolutionRect,
                );
                expect(
                  tester.getRect(find.byKey(const ValueKey('following-item'))),
                  nextRect,
                  reason: 'Following queue items must not move',
                );
              }
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
