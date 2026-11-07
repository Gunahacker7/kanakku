import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  testWidgets('Kanakku home shows the v0.7 overview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    // Brand bar + headline (no platform channel in tests → no PIN lock)
    expect(find.text('Kanakku'), findsOneWidget);
    expect(find.text('PERSONAL FINANCE'), findsOneWidget);
    expect(find.text('Your money, in control.'), findsOneWidget);
    // Demo SMS parsed live: income ₹45,000, spent 250+499+1200+350+2499
    expect(find.text('₹40,202'), findsWidgets); // hero TOTAL BALANCE (net)
    expect(find.text('₹4,798'), findsWidgets); // expenses
    // OTP message must NOT appear as a transaction
    expect(find.text('Money in'), findsNothing);
    // Text-only bottom nav tabs
    expect(find.text('Splits'), findsOneWidget);

    // Capture chips live in the Today card, below the hero + stats
    await tester.scrollUntilVisible(find.text('SMS off — tap'), 250);
    expect(find.text('SMS off — tap'), findsOneWidget);

    // Budget check-in card further down the Home list
    await tester.scrollUntilVisible(find.text('Budget check-in'), 250);
    expect(find.text('Budget check-in'), findsOneWidget);
    // Statement upload card sits below the check-in card
    await tester.scrollUntilVisible(find.text('Upload bank statement'), 250);
    expect(find.text('Upload bank statement'), findsWidgets);
  });
}
