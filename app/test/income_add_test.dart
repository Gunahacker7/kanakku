import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  testWidgets('Add sheet: manual Salary income lands in totals', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    // Transactions tab → big Add button at the top.
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+  Add transaction'));
    await tester.pumpAndSettle();

    // Sheet opens in Expense mode; switch to Income.
    expect(find.text('Log expense'), findsOneWidget);
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    expect(find.text('Add income'), findsWidgets);

    // Amount first, then the Salary type chip.
    await tester.enterText(find.byType(TextField).first, '5000');
    await tester.tap(find.text('Salary'));
    await tester.pumpAndSettle();
    // The v1.0 sheet is taller (payment mode + tag): scroll it in.
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add income'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add income'));
    await tester.pumpAndSettle();

    // The entry is listed as a credit with the chosen label.
    expect(find.text('Salary'), findsWidgets);
    expect(find.text('+₹5,000'), findsOneWidget);

    // Home: with a manual entry present the app runs on real data —
    // hero net balance and the Total income stat both carry it.
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Total income'), findsOneWidget);
    expect(find.text('₹5,000'), findsWidgets);
  });
}
