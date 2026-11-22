import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  // v1.2 shell regression (replaces the v1.0.3 glass-footer test):
  // the floating glass pill and its raised centre Add button are
  // gone. The bar is a flat three-tab strip — Home · Calendar ·
  // Settings — with equal-width slots and one-line labels; the Add
  // action lives in the Home greeting header instead.
  testWidgets('bottom nav: three equal tabs, taps switch pages', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('glass-nav-add')), findsNothing);

    final rects = <Rect>[];
    for (var i = 0; i < 3; i++) {
      final item = find.byKey(ValueKey<String>('bottom-nav-item-$i'));
      expect(item, findsOneWidget);
      rects.add(tester.getRect(item));
    }
    for (final r in rects.skip(1)) {
      expect(r.width, closeTo(rects.first.width, 0.5));
      expect(r.height, rects.first.height);
    }

    // All three labels render on ONE line.
    for (final label in ['Home', 'Calendar', 'Settings']) {
      final labelRect = tester.getRect(find.text(label));
      expect(
        labelRect.height,
        lessThan(20),
        reason: '"$label" label wrapped to two lines ($labelRect)',
      );
    }

    // Calendar tab → the real month calendar (Phase 2): the
    // "This month" pill, the current month's title and the
    // payments summary line — the placeholder is gone.
    await tester.tap(find.byKey(const ValueKey<String>('bottom-nav-item-1')));
    await tester.pumpAndSettle();
    expect(find.text('Coming in Phase 2'), findsNothing);
    expect(find.text('This month'), findsOneWidget);
    expect(find.textContaining('payments · ₹'), findsOneWidget);

    // Settings tab → the existing settings page, hosted in-shell.
    await tester.tap(find.byKey(const ValueKey<String>('bottom-nav-item-2')));
    await tester.pumpAndSettle();
    expect(find.text('Local account'), findsOneWidget);

    // Home tab → back to the overview.
    await tester.tap(find.byKey(const ValueKey<String>('bottom-nav-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('Spent this month'), findsOneWidget);

    // Drain framework exceptions. The only kind tolerated is a
    // RenderFlex overflow from test-font metrics (the flutter_test
    // font renders wider than the bundled fonts on device).
    var drained = tester.takeException();
    while (drained != null) {
      expect(drained.toString(), contains('RenderFlex overflowed'));
      drained = tester.takeException();
    }
  });
}
