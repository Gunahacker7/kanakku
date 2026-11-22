import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  // Phase 3 reskin regression: the pushed Transactions / Budgets /
  // Insights / Splits pages render in the v1.2 design system
  // (KPageHeader titles, KCard surfaces) and stay reachable from
  // the same entry points as before — Settings profile chips for
  // Transactions / Budgets / Insights, the Home shortcut for
  // Splits. Content assertions pin the visible copy each page is
  // known by, so a future restyle cannot silently drop a page.
  testWidgets('reskinned pages render and stay reachable', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    Future<void> openSettings() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('bottom-nav-item-2')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Local account'), findsOneWidget);
    }

    Future<void> back() async {
      // Pushed pages have no AppBar back button (system back
      // only), so pop the app Navigator directly.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }

    // ---- Transactions via the Settings chip ----------------------
    await openSettings();
    await tester.tap(find.widgetWithText(ActionChip, 'Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Transactions'), findsWidgets);
    expect(
      find.text('Your income and spending, all in one place.'),
      findsOneWidget,
    );
    expect(find.text('+  Add transaction'), findsOneWidget);
    expect(find.text('Upload bank statement'), findsOneWidget);
    await back();

    // ---- Budgets via the Settings chip ---------------------------
    await tester.tap(find.widgetWithText(ActionChip, 'Budgets'));
    await tester.pumpAndSettle();
    expect(find.text('Keep spending within your monthly plan.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Salary split · 50 / 30 / 20'),
      200,
    );
    expect(find.text('Salary split · 50 / 30 / 20'), findsOneWidget);
    await back();

    // ---- Insights via the Settings chip --------------------------
    await tester.tap(find.widgetWithText(ActionChip, 'Insights'));
    await tester.pumpAndSettle();
    expect(find.text('A quick view of your money movement.'), findsOneWidget);
    expect(find.text('Total income'), findsOneWidget);
    expect(find.text('Total expenses'), findsOneWidget);
    await back();

    // ---- Splits via the Home shortcut ----------------------------
    await tester.tap(find.byKey(const ValueKey<String>('bottom-nav-item-0')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Splits'), 200);
    // Scroll a little further: right after scrollUntilVisible the
    // Explore row can sit under the bottom bar and eat the tap.
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Splits'));
    await tester.pumpAndSettle();
    expect(find.text('Split bills'), findsOneWidget);
    expect(find.text('Balances'), findsOneWidget);
    expect(find.text('No splits yet'), findsOneWidget);
    await back();

    // Drain framework exceptions (only test-font RenderFlex
    // overflows are tolerated, as in bottom_nav_test).
    var drained = tester.takeException();
    while (drained != null) {
      expect(drained.toString(), contains('RenderFlex overflowed'));
      drained = tester.takeException();
    }
  });
}
