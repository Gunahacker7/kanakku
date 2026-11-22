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

    // v1.2: the Add sheet opens from the Home greeting header's +.
    await tester.tap(find.byIcon(Icons.add));
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

    // The entry is listed as a credit with the chosen label
    // (Home's Recent list — scroll it into view).
    await tester.scrollUntilVisible(find.text('+₹5,000'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsWidgets);
    expect(find.text('+₹5,000'), findsOneWidget);

    // Totals: the Insights page (Home → Explore) carries the
    // manual income in its Total income stat.
    await tester.scrollUntilVisible(find.text('Insights'), -200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insights'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Total income'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Total income'), findsOneWidget);
    expect(find.text('₹5,000'), findsWidgets);
  });
}
