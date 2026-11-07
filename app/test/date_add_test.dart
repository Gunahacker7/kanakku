import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _fmt(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Transactions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('+  Add transaction'));
  await tester.pumpAndSettle();
  expect(find.text('Log expense'), findsOneWidget);
}

Future<void> _saveExpense(
  WidgetTester tester, {
  required String amount,
  required String note,
}) async {
  await tester.enterText(find.byType(TextField).first, amount);
  // Fields in the sheet: amount, (subcategory dropdown), note, tag
  // (v1.0 added the tag field — the note is targeted by its label).
  await tester.enterText(
    find.widgetWithText(TextField, 'Note (optional)'),
    note,
  );
  // The v1.0 sheet is taller (payment mode + tag): scroll Save in.
  await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(installCaptureChannelMock);

  testWidgets('Add sheet date row: default Today, Yesterday chip, '
      'entry saved under the picked date', (WidgetTester tester) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();
    await _openSheet(tester);

    final now = DateTime.now();
    // Date row defaults to today.
    expect(find.text('Today · ${_fmt(now)}'), findsOneWidget);

    // Quick chip backdates the entry by a day.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Yesterday'));
    await tester.pumpAndSettle();
    final yday = now.subtract(const Duration(days: 1));
    expect(find.text('Yesterday · ${_fmt(yday)}'), findsOneWidget);

    await _saveExpense(tester, amount: '250', note: 'YdayEntry');
    expect(find.text('YdayEntry'), findsWidgets);
    expect(find.text('-₹250'), findsOneWidget);
    // v1.0.1 regression: the note rides as the row subtitle — the
    // picked subcategory (Groceries) stays the entry's category
    // instead of being replaced by the note (the v0.9 bug).
    expect(find.text('Groceries'), findsWidgets);
  });

  testWidgets('Add sheet date row opens the calendar picker; '
      'Cancel keeps the sheet open', (WidgetTester tester) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();
    await _openSheet(tester);

    await tester.tap(find.text('Today · ${_fmt(DateTime.now())}'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Log expense'), findsOneWidget);
  });

  testWidgets('Backdated entry sorts below today\'s entry '
      '(lists are newest-first)', (WidgetTester tester) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    // Entry 1: today.
    await _openSheet(tester);
    await _saveExpense(tester, amount: '111', note: 'AlphaToday');

    // Entry 2: yesterday (backdated via the quick chip).
    await tester.tap(find.text('+  Add transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Yesterday'));
    await tester.pumpAndSettle();
    await _saveExpense(tester, amount: '222', note: 'BetaYday');

    // Newest first: today's entry renders above yesterday's.
    final todayPos = tester.getTopLeft(find.text('AlphaToday').first);
    final ydayPos = tester.getTopLeft(find.text('BetaYday').first);
    expect(todayPos.dy, lessThan(ydayPos.dy));
  });
}
